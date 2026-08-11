// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {IPeepsBondingCurve} from "../legacy-curve/interfaces/IPeepsBondingCurve.sol";
import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {IPeepsV4Factory} from "../v4/interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "../v4/interfaces/IPeepsV4Registry.sol";
import {
    Currency,
    PoolKey,
    IPoolManager,
    IV4PositionManager,
    IAllowanceTransfer,
    Actions,
    DYNAMIC_FEE_FLAG
} from "../v4/interfaces/external/IUniswapV4.sol";
import {PeepsTickMath} from "../instant/libraries/PeepsTickMath.sol";
import {V4LiquidityMath} from "../v4/libs/V4LiquidityMath.sol";
import {PeepsBondingV4TaxStore} from "./PeepsBondingV4TaxStore.sol";
import {PeepsGraduationSeedGuard} from "./PeepsGraduationSeedGuard.sol";
import {
    NotCurve,
    NotFactory,
    ZeroAddress,
    InsufficientLiquidityMinted
} from "../legacy-curve/errors/PeepsErrors.sol";
import {InvalidTaxConfig} from "../v4/errors/PeepsV4Errors.sol";

/// @title PeepsBondingV4Migrator — bonding curve → Uni V4 + Instant-style token tax
/// @notice Graduate path:
///         1. Load creator tax from {PeepsBondingV4TaxStore}
///         2. Register tax on {PeepsV4Registry} (same hook as Instant V4)
///         3. Init dynamic-fee + tax-hook pool (1% LP fee via hook)
///         4. Mint two-sided full-range LP to vault — no arb Swap
contract PeepsBondingV4Migrator {
    using SafeERC20 for IERC20;

    int24 public constant TICK_SPACING = 200;
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;
    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable weth;
    address public immutable poolManager;
    address public immutable positionManager;
    address public immutable vault;
    address public immutable taxHook;
    address public immutable v4Registry;
    address public immutable taxStore;
    uint160 public immutable SQRT_PRICE_TOKEN0_X96;
    uint160 public immutable SQRT_PRICE_TOKEN1_X96;

    mapping(address token => bytes32) public poolIdOf;
    mapping(address token => uint256) public positionTokenId;

    event PoolInitialized(address indexed token, bytes32 indexed poolId, uint160 sqrtPriceX96, bool preExisting);
    event Graduated(
        address indexed token,
        bytes32 indexed poolId,
        uint256 indexed tokenId,
        uint128 liquidity,
        uint256 wethInPosition,
        uint256 tokensInPosition,
        uint256 graduationFee,
        address caller,
        uint256 callerReward,
        uint256 tokensBurned,
        uint256 wethDustToTreasury
    );

    struct MigratorInit {
        address factory;
        address weth;
        address poolManager;
        address positionManager;
        address vault;
        address taxHook;
        address v4Registry;
        address taxStore;
        uint160 sqrtPriceToken0X96;
        uint160 sqrtPriceToken1X96;
    }

    constructor(MigratorInit memory p) {
        if (
            p.factory == address(0) || p.weth == address(0) || p.poolManager == address(0)
                || p.positionManager == address(0) || p.vault == address(0) || p.taxHook == address(0)
                || p.v4Registry == address(0) || p.taxStore == address(0)
        ) {
            revert ZeroAddress();
        }
        if (p.sqrtPriceToken0X96 == 0 || p.sqrtPriceToken1X96 == 0) revert ZeroAddress();
        factory = p.factory;
        weth = p.weth;
        poolManager = p.poolManager;
        positionManager = p.positionManager;
        vault = p.vault;
        taxHook = p.taxHook;
        v4Registry = p.v4Registry;
        taxStore = p.taxStore;
        SQRT_PRICE_TOKEN0_X96 = p.sqrtPriceToken0X96;
        SQRT_PRICE_TOKEN1_X96 = p.sqrtPriceToken1X96;
    }

    function initializePool(address token) external returns (address) {
        if (msg.sender != factory) revert NotFactory();
        if (token == address(0)) revert ZeroAddress();
        return address(0);
    }

    function migrate(address token) external payable returns (uint256 tokenId, uint128 liquidity) {
        if (!IPeepsCurveFactory(factory).isCurve(msg.sender)) revert NotCurve();
        if (!PeepsBondingV4TaxStore(taxStore).hasTax(token)) revert InvalidTaxConfig();

        IPeepsV4Factory.V4TaxLaunchConfig memory tax = PeepsBondingV4TaxStore(taxStore).taxConfig(token);

        address treasury = IPeepsCurveFactory(factory).treasury();
        uint256 gradFee = IPeepsBondingCurve(msg.sender).GRADUATION_FEE();

        IWETH9(weth).deposit{value: msg.value}();
        if (gradFee != 0) IERC20(weth).safeTransfer(treasury, gradFee);
        uint256 wethForMint = msg.value - gradFee;

        // Register Instant-compatible tax + init hook pool (1% LP via hook + creator token tax).
        bytes32 poolId = IPeepsV4Registry(v4Registry).setTaxForBondingLaunch(token, tax);
        poolIdOf[token] = poolId;
        emit PoolInitialized(token, poolId, token < weth ? SQRT_PRICE_TOKEN0_X96 : SQRT_PRICE_TOKEN1_X96, false);

        PoolKey memory key = _poolKey(token);
        // Base LP tranche + pre-grad virtual LP (tax liquidity sent to curve, not sellable).
        uint256 tokensForMint = IERC20(token).balanceOf(address(this));
        if (tokensForMint == 0 || wethForMint == 0) revert InsufficientLiquidityMinted();

        // Pons-style seed preflight: fail before PositionManager if V4 would reject the mint.
        _assertGraduationSeed(token, tokensForMint, wethForMint);

        (tokenId, liquidity) = _mintTwoSided(token, key, tokensForMint, wethForMint, vault);
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        positionTokenId[token] = tokenId;
        (bool ok,) = vault.call(abi.encodeWithSignature("registerPosition(uint256,address)", tokenId, token));
        ok;

        // Sync Instant registry position id if vault is shared.
        uint256 tokensBurned = IERC20(token).balanceOf(address(this));
        if (tokensBurned != 0) IERC20(token).safeTransfer(DEAD, tokensBurned);
        uint256 wethDust = IERC20(weth).balanceOf(address(this));
        if (wethDust != 0) IERC20(weth).safeTransfer(treasury, wethDust);

        emit Graduated(
            token,
            poolId,
            tokenId,
            liquidity,
            wethForMint > wethDust ? wethForMint - wethDust : 0,
            tokensForMint,
            gradFee,
            msg.sender,
            IPeepsBondingCurve(msg.sender).CALLER_REWARD(),
            tokensBurned,
            wethDust
        );
    }

    function _poolKey(address token) internal view returns (PoolKey memory key) {
        address weth_ = weth;
        (address c0, address c1) = token < weth_ ? (token, weth_) : (weth_, token);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: taxHook
        });
    }

    function _assertGraduationSeed(address token, uint256 tokenAmt, uint256 wethAmt) internal view {
        uint160 sqrtP = token < weth ? SQRT_PRICE_TOKEN0_X96 : SQRT_PRICE_TOKEN1_X96;
        (uint256 amount0, uint256 amount1) =
            token < weth ? (tokenAmt, wethAmt) : (wethAmt, tokenAmt);
        PeepsGraduationSeedGuard.assertSeedable(
            sqrtP, TICK_LOWER, TICK_UPPER, TICK_SPACING, amount0, amount1
        );
    }

    function _mintTwoSided(
        address token,
        PoolKey memory key,
        uint256 tokenAmt,
        uint256 wethAmt,
        address nftRecipient
    ) internal returns (uint256 tokenId, uint128 liquidity) {
        uint160 sqrtP = token < weth ? SQRT_PRICE_TOKEN0_X96 : SQRT_PRICE_TOKEN1_X96;
        uint160 sqrtA = PeepsTickMath.getSqrtRatioAtTick(TICK_LOWER);
        uint160 sqrtB = PeepsTickMath.getSqrtRatioAtTick(TICK_UPPER);

        uint256 amount0;
        uint256 amount1;
        if (token < weth) {
            amount0 = tokenAmt;
            amount1 = wethAmt;
        } else {
            amount0 = wethAmt;
            amount1 = tokenAmt;
        }

        liquidity = V4LiquidityMath.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1);
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _approvePermit2(token);
        _approvePermit2(weth);

        uint256 nextId = IV4PositionManager(positionManager).nextTokenId();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key, TICK_LOWER, TICK_UPPER, uint256(liquidity), amount0, amount1, nftRecipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        // Open Instant liquidity gate if vault/registry support it (anti-farmer bypass during mint).
        address reg = v4Registry;
        (bool gateOk,) = reg.call(abi.encodeWithSignature("setLiquidityGateForVault(address,bool)", token, true));
        gateOk;
        IV4PositionManager(positionManager).modifyLiquidities(abi.encode(actions, params), block.timestamp + 1);
        (bool gateOff,) = reg.call(abi.encodeWithSignature("setLiquidityGateForVault(address,bool)", token, false));
        gateOff;

        tokenId = nextId;
    }

    function _approvePermit2(address asset) internal {
        IERC20(asset).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(asset, positionManager, type(uint160).max, type(uint48).max);
    }
}
