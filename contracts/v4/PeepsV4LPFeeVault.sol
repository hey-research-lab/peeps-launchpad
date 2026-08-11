// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "../legacy-curve/interfaces/IPeepsBondingCurve.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {
    IV4PositionManager,
    Actions,
    Currency,
    PoolKey,
    IPoolManager,
    IAllowanceTransfer
} from "./interfaces/external/IUniswapV4.sol";
import {PeepsTickMath} from "../instant/libraries/PeepsTickMath.sol";
import {V4LiquidityMath} from "./libs/V4LiquidityMath.sol";
import {V4StateLibrary} from "./libs/V4StateLibrary.sol";
import {
    ZeroAddress,
    NotRegistry,
    NotCreator,
    NothingToClaim,
    EthTransferFailed
} from "./errors/PeepsV4Errors.sol";

/// @title PeepsV4LPFeeVault — locked V4 LP NFT; fees split creator / protocol (mirrors V3 vault)
/// @notice Tax-liquidity deposits accumulate here and are compounded into the locked Uniswap
///         position (permissionless). They are NOT creator-withdrawable cash.
contract PeepsV4LPFeeVault is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant PROTOCOL_MARKETING_BPS = 2000;
    uint16 internal constant PROTOCOL_BUYBACK_BPS = 2000;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    /// @dev Match migrator full-range bounds (tick spacing 200).
    int24 internal constant TICK_LOWER = -887_200;
    int24 internal constant TICK_UPPER = 887_200;
    uint160 internal constant SQRT_RATIO_LOWER = 4_295_128_739;
    uint160 internal constant SQRT_RATIO_UPPER = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    address public immutable positionManager;
    address public immutable treasury;
    address public immutable marketingWallet;
    address public immutable buybackWallet;
    address public immutable factory;
    /// @dev PeepsProtocolFeeRouter — Instant V3 parity for referral/special plans.
    address public protocolFeeRecipient;
    /// @dev Bonding curve factory — creator / share lookup for bonding→V4 grads.
    address public bondingFactory;

    mapping(uint256 => address) public positionToken;
    mapping(address => uint256) public tokenPosition;
    mapping(address => uint256) public accruedCreatorEth;
    mapping(address => uint256) public accruedCreatorTokens;
    /// @dev Tax liquidity inventory awaiting compound into the locked LP NFT.
    mapping(address => uint256) public taxLiquidityTokens;
    mapping(address => uint256) public taxLiquidityWeth;

    event FeesCollected(
        address indexed launchToken,
        uint256 indexed tokenId,
        uint256 ethToCreator,
        uint256 ethToProtocol,
        uint256 tokenToCreator,
        uint256 tokenToProtocol
    );
    event CreatorLpFeesClaimed(
        address indexed launchToken, address indexed recipient, uint256 ethClaimed, uint256 tokenClaimed
    );
    event TaxLiquidityReceived(address indexed launchToken, address indexed currency, uint256 amount);
    event TaxLiquidityCompounded(
        address indexed launchToken, uint128 liquidity, uint256 wethUsed, uint256 tokensUsed
    );
    event ProtocolFeeRecipientUpdated(address indexed recipient);
    event BondingFactoryUpdated(address indexed bondingFactory);

    error NotPositionManager();
    error CompoundFailed();
    error NotifyFeesFailed();
    error NotFactoryOwner();
    error NotMigratorOrRegistry();

    constructor(
        address positionManager_,
        address treasury_,
        address marketingWallet_,
        address buybackWallet_,
        address factory_,
        address protocolFeeRecipient_
    ) {
        if (
            positionManager_ == address(0) || treasury_ == address(0) || marketingWallet_ == address(0)
                || buybackWallet_ == address(0) || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        positionManager = positionManager_;
        treasury = treasury_;
        marketingWallet = marketingWallet_;
        buybackWallet = buybackWallet_;
        factory = factory_;
        protocolFeeRecipient = protocolFeeRecipient_;
    }

    /// @notice Wire Instant fee router (owner of Instant V4 factory).
    function setProtocolFeeRecipient(address recipient) external {
        if (msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    /// @notice Bonding→V4 factory for creator/share resolution on graduated bonding tokens.
    function setBondingFactory(address bondingFactory_) external {
        if (msg.sender != Ownable(factory).owner()) revert NotFactoryOwner();
        bondingFactory = bondingFactory_;
        emit BondingFactoryUpdated(bondingFactory_);
    }

    receive() external payable {}

    function registerPosition(uint256 tokenId, address launchToken) external {
        address reg = IPeepsV4Factory(factory).v4Registry();
        address bondingMigrator;
        if (reg != address(0)) {
            (bool ok, bytes memory data) =
                reg.staticcall(abi.encodeWithSignature("bondingMigrator()"));
            if (ok && data.length >= 32) bondingMigrator = abi.decode(data, (address));
        }
        if (msg.sender != reg && msg.sender != bondingMigrator) revert NotMigratorOrRegistry();
        if (launchToken == address(0)) revert ZeroAddress();
        positionToken[tokenId] = launchToken;
        tokenPosition[launchToken] = tokenId;
    }

    /// @dev Only the live V4 tax hook may credit tax-liquidity accounting (must already have transferred).
    function notifyTaxLiquidity(address launchToken, address currency, uint256 amount) external {
        address v4m = IPeepsV4Factory(factory).v4Registry();
        if (v4m == address(0) || msg.sender != IPeepsV4Registry(v4m).hook()) revert NotRegistry();
        if (launchToken == address(0) || amount == 0) return;
        address weth = IPeepsV4Factory(factory).weth();
        if (currency == weth) taxLiquidityWeth[launchToken] += amount;
        else if (currency == launchToken) taxLiquidityTokens[launchToken] += amount;
        else revert ZeroAddress();
        emit TaxLiquidityReceived(launchToken, currency, amount);
    }

    /// @notice Permissionless: fold pending tax WETH+tokens into the locked Instant LP NFT.
    /// @dev Needs inventory on both sides once price is in-range. Uses position ticks for sizing.
    function compoundTaxLiquidity(address launchToken) external nonReentrant returns (uint128 liquidity) {
        uint256 tokenId = tokenPosition[launchToken];
        if (tokenId == 0) revert ZeroAddress();

        uint256 wethPending = taxLiquidityWeth[launchToken];
        uint256 tokPending = taxLiquidityTokens[launchToken];
        if (wethPending == 0 || tokPending == 0) return 0;

        address weth = IPeepsV4Factory(factory).weth();
        IPeepsV4Registry registry = IPeepsV4Registry(IPeepsV4Factory(factory).v4Registry());

        uint256 amount0;
        uint256 amount1;
        if (launchToken < weth) {
            amount0 = tokPending;
            amount1 = wethPending;
        } else {
            amount0 = wethPending;
            amount1 = tokPending;
        }

        // Prefer live pool price; fall back to launch sqrt if unreadable.
        bytes32 poolId = registry.poolIdOf(launchToken);
        uint160 sqrtP = poolId == bytes32(0)
            ? 0
            : V4StateLibrary.getSqrtPriceX96(IPoolManager(registry.poolManager()), poolId);
        if (sqrtP == 0) {
            sqrtP = launchToken < weth
                ? registry.SQRT_PRICE_TOKEN0_X96()
                : registry.SQRT_PRICE_TOKEN1_X96();
        }
        (int24 tickLower, int24 tickUpper) = registry.positionRange(launchToken);
        uint160 sqrtA = PeepsTickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = PeepsTickMath.getSqrtRatioAtTick(tickUpper);
        liquidity = V4LiquidityMath.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1);
        if (liquidity == 0) return 0;

        _approvePermit2(launchToken);
        _approvePermit2(weth);

        (PoolKey memory key,) = IV4PositionManager(positionManager).getPoolAndPositionInfo(tokenId);

        bytes memory actions = abi.encodePacked(
            uint8(Actions.INCREASE_LIQUIDITY), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            tokenId, uint256(liquidity), uint128(amount0), uint128(amount1), bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        registry.setLiquidityGateForVault(launchToken, true);
        uint256 wethBalBefore = IERC20(weth).balanceOf(address(this));
        uint256 tokBalBefore = IERC20(launchToken).balanceOf(address(this));
        try IV4PositionManager(positionManager).modifyLiquidities(
            abi.encode(actions, params), block.timestamp + 1
        ) {
            uint256 wethSpent = wethBalBefore - IERC20(weth).balanceOf(address(this));
            uint256 tokSpent = tokBalBefore - IERC20(launchToken).balanceOf(address(this));
            if (wethSpent > wethPending) wethSpent = wethPending;
            if (tokSpent > tokPending) tokSpent = tokPending;
            taxLiquidityWeth[launchToken] = wethPending - wethSpent;
            taxLiquidityTokens[launchToken] = tokPending - tokSpent;
            emit TaxLiquidityCompounded(launchToken, liquidity, wethSpent, tokSpent);
        } catch {
            registry.setLiquidityGateForVault(launchToken, false);
            revert CompoundFailed();
        }
        registry.setLiquidityGateForVault(launchToken, false);
    }

    function collectForToken(address launchToken) external returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = tokenPosition[launchToken];
        if (tokenId == 0) revert ZeroAddress();
        return _collect(tokenId);
    }

    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1) {
        return _collect(tokenId);
    }

    function _collect(uint256 tokenId) internal nonReentrant returns (uint256 amount0, uint256 amount1) {
        address launchToken = positionToken[tokenId];
        if (launchToken == address(0)) revert ZeroAddress();

        address weth = IPeepsV4Factory(factory).weth();
        (PoolKey memory key,) = IV4PositionManager(positionManager).getPoolAndPositionInfo(tokenId);

        uint256 bal0Before = _balance(Currency.unwrap(key.currency0));
        uint256 bal1Before = _balance(Currency.unwrap(key.currency1));

        // Harvest fees: decrease 0 liquidity + take pair.
        bytes memory actions =
            abi.encodePacked(uint8(Actions.DECREASE_LIQUIDITY), uint8(Actions.TAKE_PAIR));
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        IV4PositionManager(positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp);

        amount0 = _balance(Currency.unwrap(key.currency0)) - bal0Before;
        amount1 = _balance(Currency.unwrap(key.currency1)) - bal1Before;

        uint16 creatorShare = _creatorShareBps(launchToken);

        bool tokenIs0 = launchToken < weth;
        uint256 wethAmt = tokenIs0 ? amount1 : amount0;
        uint256 tokenAmt = tokenIs0 ? amount0 : amount1;

        uint256 ethToCreator;
        uint256 ethToProtocol;
        uint256 tokenToCreator;
        uint256 tokenToProtocol;

        if (wethAmt > 0) {
            ethToCreator = (wethAmt * creatorShare) / 10_000;
            ethToProtocol = wethAmt - ethToCreator;
            // Creator share → ETH accrual; protocol share stays WETH for fee router.
            if (ethToCreator > 0) {
                IWETH9(weth).withdraw(ethToCreator);
                accruedCreatorEth[launchToken] += ethToCreator;
            }
        }

        if (tokenAmt > 0) {
            tokenToCreator = (tokenAmt * creatorShare) / 10_000;
            tokenToProtocol = tokenAmt - tokenToCreator;
            if (tokenToCreator > 0) accruedCreatorTokens[launchToken] += tokenToCreator;
        }

        if (ethToProtocol > 0 || tokenToProtocol > 0) {
            _routeProtocolToFeeRouter(launchToken, weth, ethToProtocol, tokenToProtocol);
        }

        emit FeesCollected(launchToken, tokenId, ethToCreator, ethToProtocol, tokenToCreator, tokenToProtocol);
    }

    function claimCreatorLpFees(address launchToken)
        external
        nonReentrant
        returns (uint256 ethClaimed, uint256 tokenClaimed)
    {
        address creator = _creator(launchToken);
        if (creator == address(0)) revert ZeroAddress();
        if (msg.sender != creator) revert NotCreator();

        ethClaimed = accruedCreatorEth[launchToken];
        tokenClaimed = accruedCreatorTokens[launchToken];
        // Tax liquidity stays locked for compounding into LP — not claimable as cash.
        if (ethClaimed == 0 && tokenClaimed == 0) revert NothingToClaim();

        accruedCreatorEth[launchToken] = 0;
        accruedCreatorTokens[launchToken] = 0;

        if (ethClaimed != 0) {
            _sendEth(msg.sender, ethClaimed);
        }
        if (tokenClaimed != 0) IERC20(launchToken).safeTransfer(msg.sender, tokenClaimed);

        emit CreatorLpFeesClaimed(launchToken, msg.sender, ethClaimed, tokenClaimed);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != positionManager) revert NotPositionManager();
        return IERC721Receiver.onERC721Received.selector;
    }

    function _approvePermit2(address asset) internal {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(asset).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(asset, positionManager, type(uint160).max, type(uint48).max);
    }

    /// @dev Instant V3 parity: protocol LP share → PeepsProtocolFeeRouter.notifyFees.
    ///      Falls back to treasury/marketing/buyback wallets when no fee router is set.
    function _routeProtocolToFeeRouter(
        address launchToken,
        address weth,
        uint256 wethAmt,
        uint256 tokenAmt
    ) internal {
        address recipient = protocolFeeRecipient;
        if (recipient == address(0) || recipient.code.length == 0) {
            if (wethAmt > 0) {
                IWETH9(weth).withdraw(wethAmt);
                _routeProtocolEthFallback(wethAmt);
            }
            if (tokenAmt > 0) _routeProtocolTokensFallback(launchToken, tokenAmt);
            return;
        }

        if (wethAmt > 0) IERC20(weth).safeTransfer(recipient, wethAmt);
        if (tokenAmt > 0) IERC20(launchToken).safeTransfer(recipient, tokenAmt);

        address token0 = launchToken < weth ? launchToken : weth;
        address token1 = launchToken < weth ? weth : launchToken;
        uint256 amount0 = launchToken < weth ? tokenAmt : wethAmt;
        uint256 amount1 = launchToken < weth ? wethAmt : tokenAmt;

        (bool success,) = recipient.call(
            abi.encodeWithSignature(
                "notifyFees(address,address,address,uint256,uint256)",
                launchToken,
                token0,
                token1,
                amount0,
                amount1
            )
        );
        if (!success) revert NotifyFeesFailed();
    }

    function _routeProtocolEthFallback(uint256 amount) internal {
        uint256 toMarketing = (amount * PROTOCOL_MARKETING_BPS) / 10_000;
        uint256 toBuyback = (amount * PROTOCOL_BUYBACK_BPS) / 10_000;
        uint256 toTreasury = amount - toMarketing - toBuyback;
        _sendEth(marketingWallet, toMarketing);
        _sendEth(buybackWallet, toBuyback);
        _sendEth(treasury, toTreasury);
    }

    function _routeProtocolTokensFallback(address launchToken, uint256 amount) internal {
        uint256 toMarketing = (amount * PROTOCOL_MARKETING_BPS) / 10_000;
        uint256 toBuyback = (amount * PROTOCOL_BUYBACK_BPS) / 10_000;
        uint256 toTreasury = amount - toMarketing - toBuyback;
        if (toMarketing > 0) IERC20(launchToken).safeTransfer(marketingWallet, toMarketing);
        if (toBuyback > 0) IERC20(launchToken).safeTransfer(buybackWallet, toBuyback);
        if (toTreasury > 0) IERC20(launchToken).safeTransfer(treasury, toTreasury);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _balance(address asset) internal view returns (uint256) {
        if (asset == address(0)) return address(this).balance;
        return IERC20(asset).balanceOf(address(this));
    }

    function _creatorShareBps(address launchToken) internal view returns (uint16) {
        uint16 share = IPeepsV4Factory(factory).postGradCreatorShareBpsOf(launchToken);
        if (share != 0) return share;
        address curve = _bondingCurve(launchToken);
        if (curve != address(0)) return IPeepsBondingCurve(curve).postGradCreatorShareBps();
        return 0;
    }

    function _creator(address launchToken) internal view returns (address) {
        address creator = IPeepsV4Factory(factory).creatorOf(launchToken);
        if (creator != address(0)) return creator;
        address curve = _bondingCurve(launchToken);
        if (curve != address(0)) return IPeepsBondingCurve(curve).feeRecipient();
        return address(0);
    }

    function _bondingCurve(address launchToken) internal view returns (address) {
        address bf = bondingFactory;
        if (bf == address(0)) return address(0);
        return IPeepsCurveFactory(bf).curveOf(launchToken);
    }
}
