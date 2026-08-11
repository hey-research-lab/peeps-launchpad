// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PeepsV4Token} from "./PeepsV4Token.sol";
import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {
    IPoolManager,
    IV4PositionManager
} from "./interfaces/external/IUniswapV4.sol";
import {PeepsTickMath} from "../instant/libraries/PeepsTickMath.sol";
import {V4LiquidityMath} from "./libs/V4LiquidityMath.sol";
import {V4StateLibrary} from "./libs/V4StateLibrary.sol";
import {ZeroAddress} from "./errors/PeepsV4Errors.sol";

interface IPeepsV4SwapRouterBuy {
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);
}

interface IPeepsProtocolFeeRouterSpecial {
    function redeemSpecialOffer(bytes32 codeHash, address token, address creator) external;
}

/// @title PeepsV4Factory — Pons-style Instant launch into Uniswap V4 + tax hook
/// @notice No bonding curve. Deploys token, registers tax, mints one-sided (0 WETH) locked V4 LP.
///         Optional ETH above the launch fee is an initial buy (same as Instant V3), not LP seed.
contract PeepsV4Factory is IPeepsV4Factory, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant DEFAULT_SUPPLY = 1_000_000_000 ether;
    uint16 public constant DEFAULT_CREATOR_SHARE_BPS = 7000; // 70% creator / 30% protocol of LP fees
    /// @dev Same product graduation target as Instant V3 / Pons launch config 0.
    uint256 public constant GRADUATION_THRESHOLD = 4.2 ether;

    error LaunchFeeNotPaid();
    error InvalidTaxConfig();
    error SeedFailed();
    error FeeTransferFailed();
    error TokenNotFound();
    error RouterNotSet();
    error InitialBuyFailed();
    error ClearingStartFailed();
    error FeeRouterNotSet();
    error SpecialRedeemFailed();

    event V4TokenLaunched(
        address indexed token,
        address indexed creator,
        bytes32 indexed poolId,
        uint256 ethSeeded,
        uint256 tokensSeeded
    );
    event FeeRouterUpdated(address indexed feeRouter);

    address public immutable override weth;
    address public override treasury;
    address public override v4Registry;
    address public v4SwapRouter;
    /// @dev PeepsProtocolFeeRouter — used for atomic special-code redeem on create.
    address public feeRouter;
    uint256 public launchFeeWei;

    mapping(address token => address creator) internal _creatorOf;
    mapping(address token => uint16 shareBps) internal _shareBpsOf;
    mapping(address token => uint256 threshold) private _graduationThresholds;
    mapping(address => bool) public isToken;

    constructor(address owner_, address weth_, address treasury_, uint256 launchFeeWei_) Ownable(owner_) {
        if (weth_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        weth = weth_;
        treasury = treasury_;
        launchFeeWei = launchFeeWei_;
    }

    function setV4Registry(address registry_) external onlyOwner {
        if (registry_ == address(0)) revert ZeroAddress();
        v4Registry = registry_;
    }

    function setV4SwapRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        v4SwapRouter = router_;
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
    }

    function setLaunchFeeWei(uint256 fee) external onlyOwner {
        launchFeeWei = fee;
    }

    function setFeeRouter(address feeRouter_) external onlyOwner {
        if (feeRouter_ == address(0)) revert ZeroAddress();
        feeRouter = feeRouter_;
        emit FeeRouterUpdated(feeRouter_);
    }

    /// @inheritdoc IPeepsV4Factory
    function creatorOf(address token) external view override returns (address) {
        return _creatorOf[token];
    }

    /// @inheritdoc IPeepsV4Factory
    function postGradCreatorShareBpsOf(address token) external view override returns (uint16) {
        return _shareBpsOf[token];
    }

    /**
     * @notice View-only product graduation (same semantics as Instant V3).
     * @dev Paired WETH principal in the locked V4 position vs 4.2 ETH.
     *      Distinct from registry.seededAt (which means tax pool is live after seed).
     */
    function graduationStatus(address token)
        external
        view
        returns (uint256 pairedPrincipal, uint256 threshold, bool graduated)
    {
        if (!isToken[token]) revert TokenNotFound();
        threshold = _graduationThresholds[token];
        pairedPrincipal = _pairedWethPrincipal(token);
        graduated = threshold != 0 && pairedPrincipal >= threshold;
    }

    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address feeWallet;
    }

    /// @notice Instant V4 launch: create token + init tax pool + one-sided locked LP.
    /// @param initialBuyEthWei ETH (after launch fee) spent as an optional first buy. LP itself needs 0 WETH.
    /// @param lpTokenBps Share of total supply seeded as LP (remainder stays with creator). 1–10000.
    /// @param specialCodeHash keccak256(code) for atomic special redeem; bytes32(0) = no special.
    function createTokenV4(
        TokenParams calldata params,
        V4TaxLaunchConfig calldata tax,
        uint256 initialBuyEthWei,
        uint16 lpTokenBps,
        bytes32 specialCodeHash
    ) external payable nonReentrant returns (address token, bytes32 poolId) {
        if (v4Registry == address(0)) revert ZeroAddress();
        if (bytes(params.name).length == 0 || bytes(params.symbol).length == 0) revert InvalidTaxConfig();
        if (lpTokenBps == 0 || lpTokenBps > 10_000) revert InvalidTaxConfig();
        if (msg.value < launchFeeWei + initialBuyEthWei) revert LaunchFeeNotPaid();
        if (specialCodeHash != bytes32(0) && feeRouter == address(0)) revert FeeRouterNotSet();

        if (tax.taxRecipient == address(0)) revert InvalidTaxConfig();
        if (tax.base.postGradCreatorShareBps != DEFAULT_CREATOR_SHARE_BPS) revert InvalidTaxConfig();

        if (launchFeeWei > 0) {
            (bool ok,) = treasury.call{value: launchFeeWei}("");
            if (!ok) revert FeeTransferFailed();
        }

        PeepsV4Token.Socials memory socials = PeepsV4Token.Socials({
            twitter: params.socials.twitter,
            telegram: params.socials.telegram,
            discord: params.socials.discord,
            website: params.socials.website,
            farcaster: params.socials.farcaster
        });

        token = address(
            new PeepsV4Token(
                params.name,
                params.symbol,
                params.logo,
                params.description,
                socials,
                msg.sender,
                DEFAULT_SUPPLY
            )
        );

        // Launcher is always creator (board + LP fee claims). Tax funds use tax.taxRecipient.
        // feeWallet is accepted for ABI parity with Instant V3 create params but ignored here.
        _creatorOf[token] = msg.sender;
        _shareBpsOf[token] = DEFAULT_CREATOR_SHARE_BPS;
        _graduationThresholds[token] = GRADUATION_THRESHOLD;
        isToken[token] = true;

        // Atomic special: any redeem failure reverts the whole create (no live token).
        if (specialCodeHash != bytes32(0)) {
            try IPeepsProtocolFeeRouterSpecial(feeRouter).redeemSpecialOffer(
                specialCodeHash, token, msg.sender
            ) {} catch {
                revert SpecialRedeemFailed();
            }
        }

        poolId = IPeepsV4Registry(v4Registry).initializePool(token, tax);

        uint256 lpTokens = (DEFAULT_SUPPLY * lpTokenBps) / 10_000;
        uint256 creatorTokens = DEFAULT_SUPPLY - lpTokens;
        if (creatorTokens > 0) {
            IERC20(token).safeTransfer(msg.sender, creatorTokens);
        }
        IERC20(token).safeTransfer(v4Registry, lpTokens);

        // One-sided Instant LP — no WETH in the position.
        (bool seeded,) = v4Registry.call{value: 0}(
            abi.encodeWithSelector(IPeepsV4Registry.instantSeed.selector, token)
        );
        if (!seeded) revert SeedFailed();

        // Creator initial buy runs as a normal spot buy BEFORE anti-bundle opens.
        address buyRecipient = params.feeWallet == address(0) ? msg.sender : params.feeWallet;
        if (initialBuyEthWei != 0) {
            if (v4SwapRouter == address(0)) revert RouterNotSet();
            try IPeepsV4SwapRouterBuy(v4SwapRouter).buy{value: initialBuyEthWei}(
                token, buyRecipient, 0, block.timestamp
            ) {} catch {
                revert InitialBuyFailed();
            }
        }

        if (tax.base.uniformClearing) {
            try IPeepsV4Registry(v4Registry).startUniformClearing(token) {} catch {
                revert ClearingStartFailed();
            }
        }

        // Refund dust ETH above fee + optional initial buy.
        uint256 spent = launchFeeWei + initialBuyEthWei;
        if (msg.value > spent) {
            (bool refunded,) = msg.sender.call{value: msg.value - spent}("");
            if (!refunded) revert FeeTransferFailed();
        }

        // ethSeeded field retained for ABI/indexer parity; always 0 (LP is token-only).
        emit V4TokenLaunched(token, msg.sender, poolId, 0, lpTokens);
    }

    function _pairedWethPrincipal(address token) internal view returns (uint256) {
        IPeepsV4Registry registry = IPeepsV4Registry(v4Registry);
        uint256 tokenId = registry.positionTokenId(token);
        if (tokenId == 0) return 0;

        address pm = registry.positionManager();
        address poolMgr = registry.poolManager();
        bytes32 poolId = registry.poolIdOf(token);
        if (pm == address(0) || poolMgr == address(0) || poolId == bytes32(0)) return 0;

        uint128 liquidity = IV4PositionManager(pm).getPositionLiquidity(tokenId);
        if (liquidity == 0) return 0;

        uint160 sqrtPriceX96 = V4StateLibrary.getSqrtPriceX96(IPoolManager(poolMgr), poolId);
        if (sqrtPriceX96 == 0) {
            // Fallback: launch price if slot0 unreadable.
            sqrtPriceX96 = token < weth ? registry.SQRT_PRICE_TOKEN0_X96() : registry.SQRT_PRICE_TOKEN1_X96();
        }

        (int24 tickLower, int24 tickUpper) = registry.positionRange(token);
        uint160 sqrtA = PeepsTickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = PeepsTickMath.getSqrtRatioAtTick(tickUpper);

        (uint256 amount0, uint256 amount1) =
            V4LiquidityMath.getAmountsForLiquidity(sqrtPriceX96, sqrtA, sqrtB, liquidity);
        // WETH is the higher address when token < weth → amount1; else amount0.
        return token < weth ? amount1 : amount0;
    }

    receive() external payable {}
}
