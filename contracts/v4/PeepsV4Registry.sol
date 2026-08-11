// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {
    Currency,
    PoolKey,
    IPoolManager,
    IV4PositionManager,
    IAllowanceTransfer,
    Actions,
    DYNAMIC_FEE_FLAG
} from "./interfaces/external/IUniswapV4.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {PeepsTickMath} from "../instant/libraries/PeepsTickMath.sol";
import {V4LiquidityMath} from "./libs/V4LiquidityMath.sol";

import {
    ZeroAddress,
    NotFactory,
    NotSeeded,
    InsufficientLiquidityMinted,
    ClearingAlreadyStarted
} from "./errors/PeepsV4Errors.sol";

/// @title PeepsV4Registry — Instant V4 tax pool registry + LP seed (no bonding curve)
/// @notice Called only via `instantSeed` from PeepsV4Factory.
/// @dev LP is Instant-V3-style one-sided (token-only at launch). Optional ETH is an initial buy on the factory, not LP seed.
contract PeepsV4Registry is IPeepsV4Registry, Ownable2Step {
    using SafeERC20 for IERC20;

    /// @dev Dynamic fee pool — hook beforeSwap supplies the LP fee override.
    uint24 public constant FEE_TIER = DYNAMIC_FEE_FLAG;
    int24 public constant TICK_SPACING = 200;
    /// @dev Usable min/max ticks for spacing 200 (same as Instant V3 / Uniswap).
    int24 public constant TICK_LOWER = -887_200;
    int24 public constant TICK_UPPER = 887_200;
    /// @dev Match Instant V3 / Pons launchConfig.initialTick.
    int24 public constant INITIAL_TICK = -204_200;
    /// @dev Instant V3-style anti-snipe (when tax.base.antiSnipe).
    uint32 public constant ANTI_SNIPE_BLOCKS = 2;
    uint16 public constant MAX_WALLET_BPS = 500;
    uint16 public constant MAX_TX_BPS = 550;
    /// @dev Uniform clearing window (when tax.base.uniformClearing).
    uint64 public constant CLEARING_SECONDS = 45;
    /// @dev Full-span sqrt bounds (still used by vault helpers for extreme ticks).
    uint160 public constant SQRT_RATIO_LOWER = 4_295_128_739;
    uint160 public constant SQRT_RATIO_UPPER = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

    address public constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable weth;
    address public immutable factory;
    uint160 public immutable SQRT_PRICE_TOKEN0_X96;
    uint160 public immutable SQRT_PRICE_TOKEN1_X96;

    address public poolManager;
    address public override hook;
    address public positionManager;
    address public override lpFeeVault;
    address public override dividendDistributor;
    address public clearingHouse;
    address public swapRouter;
    /// @dev Bonding→V4 migrator may register Instant-compatible tax configs for graduated curve tokens.
    address public bondingMigrator;

    mapping(address token => IPeepsV4Factory.V4TaxLaunchConfig) internal _tax;
    mapping(address token => uint64) public override seededAt;
    mapping(address token => bytes32) public override poolIdOf;
    mapping(address token => uint256) public positionTokenId;
    /// @dev One-sided Instant range stored at seed (graduation + tax compound use these).
    mapping(address token => int24) public positionTickLower;
    mapping(address token => int24) public positionTickUpper;
    /// @dev Block when Instant seed completed (anti-snipe window start).
    mapping(address token => uint64) public launchBlock;
    /// @dev Timestamp end of uniform clearing window (0 = disabled).
    mapping(address token => uint64) public clearingEnd;
    /// @dev Cumulative tokens bought during anti-snipe window (per wallet).
    mapping(address token => mapping(address trader => uint256)) public restrictedBuys;
    /// @dev Transient: allows PositionManager to add liquidity during seed/compound (anti-farmer bypass).
    mapping(address token => bool) public liquidityGateOpen;

    error InvalidTaxConfig();
    error AlreadySeeded();
    error MissingHook();
    error MissingPoolManager();
    error MissingPositionManager();
    error MintFailed();
    error NotVault();
    error NotSwapRouter();

    struct RegistryInit {
        address weth;
        address factory;
        address poolManager;
        address initialOwner;
        uint160 sqrtPriceToken0X96;
        uint160 sqrtPriceToken1X96;
    }

    constructor(RegistryInit memory p) Ownable(p.initialOwner) {
        if (p.weth == address(0) || p.factory == address(0)) revert ZeroAddress();
        if (p.sqrtPriceToken0X96 == 0 || p.sqrtPriceToken1X96 == 0) revert ZeroAddress();
        weth = p.weth;
        factory = p.factory;
        poolManager = p.poolManager;
        SQRT_PRICE_TOKEN0_X96 = p.sqrtPriceToken0X96;
        SQRT_PRICE_TOKEN1_X96 = p.sqrtPriceToken1X96;
    }

    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
    }

    function setPoolManager(address poolManager_) external onlyOwner {
        poolManager = poolManager_;
    }

    function setPositionManager(address positionManager_) external onlyOwner {
        positionManager = positionManager_;
    }

    function setLpFeeVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        lpFeeVault = vault_;
    }

    function setDividendDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        dividendDistributor = distributor_;
    }

    function setClearingHouse(address clearingHouse_) external onlyOwner {
        if (clearingHouse_ == address(0)) revert ZeroAddress();
        clearingHouse = clearingHouse_;
    }

    function setSwapRouter(address swapRouter_) external onlyOwner {
        if (swapRouter_ == address(0)) revert ZeroAddress();
        swapRouter = swapRouter_;
    }

    function setBondingMigrator(address bondingMigrator_) external onlyOwner {
        if (bondingMigrator_ == address(0)) revert ZeroAddress();
        bondingMigrator = bondingMigrator_;
    }

    /// @notice Authorize bonding factory/router to configure + notify Instant dividends pre-grad.
    function setDividendTaxNotifier(address notifier, bool enabled) external onlyOwner {
        if (dividendDistributor == address(0) || notifier == address(0)) revert ZeroAddress();
        (bool ok,) = dividendDistributor.call(
            abi.encodeWithSignature("setTaxNotifier(address,bool)", notifier, enabled)
        );
        if (!ok) revert InvalidTaxConfig();
    }

    /// @notice Point dividend distributor at bonding factory (exclude curve/router from shares).
    function setDividendBondingFactory(address bondingFactory_) external onlyOwner {
        if (dividendDistributor == address(0) || bondingFactory_ == address(0)) revert ZeroAddress();
        (bool ok,) = dividendDistributor.call(
            abi.encodeWithSignature("setBondingFactory(address)", bondingFactory_)
        );
        if (!ok) revert InvalidTaxConfig();
    }

    /// @notice Bonding→V4 migrate: register the same Instant tax config so {PeepsV4TaxHook} applies
    ///         after graduation. Does not seed Instant one-sided LP — bonding migrator mints LP.
    function setTaxForBondingLaunch(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax)
        external
        returns (bytes32 poolId)
    {
        if (msg.sender != bondingMigrator) revert NotFactory();
        if (token == address(0)) revert ZeroAddress();
        _validateTax(tax);
        _tax[token] = tax;
        emit V4TaxConfigSet(token, tax);

        if (tax.dividendBps > 0 && dividendDistributor != address(0)) {
            (bool ok,) = dividendDistributor.call(
                abi.encodeWithSignature("configureToken(address,uint256)", token, tax.minDividendBalance)
            );
            if (!ok) revert InvalidTaxConfig();
        }

        if (poolManager == address(0)) revert MissingPoolManager();
        if (hook == address(0)) revert MissingHook();

        PoolKey memory key = _poolKey(token);
        poolId = keccak256(abi.encode(key));
        if (poolIdOf[token] == bytes32(0)) {
            try IPoolManager(poolManager).initialize(key, _targetSqrtPrice(token)) {
                poolIdOf[token] = poolId;
            } catch {
                poolIdOf[token] = poolId;
            }
        }
        // Mark seededAt so anti-snipe / hook paths that expect a live Instant-style pool work.
        if (seededAt[token] == 0) {
            seededAt[token] = uint64(block.timestamp);
            launchBlock[token] = uint64(block.number);
        }
        emit V4PoolInitialized(token, poolId, false);
    }

    function antiSnipeActive(address token) external view returns (bool) {
        if (!_tax[token].base.antiSnipe) return false;
        uint64 lb = launchBlock[token];
        return lb != 0 && block.number <= uint256(lb) + ANTI_SNIPE_BLOCKS;
    }

    function clearingActive(address token) external view returns (bool) {
        uint64 end = clearingEnd[token];
        return end != 0 && block.timestamp < end;
    }

    function recordRestrictedBuy(address token, address trader, uint256 tokensOut) external {
        if (msg.sender != swapRouter) revert NotSwapRouter();
        restrictedBuys[token][trader] += tokensOut;
    }

    /// @inheritdoc IPeepsV4Registry
    function setLiquidityGateForVault(address token, bool open) external {
        if (msg.sender != lpFeeVault && msg.sender != bondingMigrator) revert NotVault();
        liquidityGateOpen[token] = open;
    }

    /// @inheritdoc IPeepsV4Registry
    function taxConfig(address token)
        external
        view
        override
        returns (IPeepsV4Factory.V4TaxLaunchConfig memory)
    {
        return _tax[token];
    }

    /// @inheritdoc IPeepsV4Registry
    function initializePool(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax)
        external
        override
        returns (bytes32 poolId)
    {
        if (msg.sender != factory) revert NotFactory();
        _validateTax(tax);
        _tax[token] = tax;
        emit V4TaxConfigSet(token, tax);

        if (tax.dividendBps > 0 && dividendDistributor != address(0)) {
            (bool ok,) = dividendDistributor.call(
                abi.encodeWithSignature(
                    "configureToken(address,uint256)", token, tax.minDividendBalance
                )
            );
            if (!ok) revert InvalidTaxConfig();
        }

        if (poolManager == address(0)) revert MissingPoolManager();
        if (hook == address(0)) revert MissingHook();

        PoolKey memory key = _poolKey(token);
        poolId = keccak256(abi.encode(key));
        bool preExisting = poolIdOf[token] != bytes32(0);
        if (!preExisting) {
            // initialize reverts if the pool already exists — treat that as preExisting.
            try IPoolManager(poolManager).initialize(key, _targetSqrtPrice(token)) {
                poolIdOf[token] = poolId;
            } catch {
                poolIdOf[token] = poolId;
                preExisting = true;
            }
        }
        emit V4PoolInitialized(token, poolId, preExisting);
    }

    /// @inheritdoc IPeepsV4Registry
    function instantSeed(address token) external payable override returns (uint256 tokenId, uint128 liquidity) {
        if (msg.sender != factory) revert NotFactory();
        if (seededAt[token] != 0) revert AlreadySeeded();
        if (hook == address(0)) revert MissingHook();
        if (poolManager == address(0)) revert MissingPoolManager();

        IPeepsV4Factory.V4TaxLaunchConfig memory cfg = _tax[token];
        if (cfg.taxRecipient == address(0)) revert InvalidTaxConfig();

        // One-sided Instant mint: tokens only. Any ETH sent here is unexpected — refund to treasury.
        uint256 ethIn = msg.value;
        uint256 tokensIn = IERC20(token).balanceOf(address(this));
        if (tokensIn == 0) revert InsufficientLiquidityMinted();

        address treasury = IPeepsV4Factory(factory).treasury();
        if (ethIn > 0) {
            (bool sent,) = treasury.call{value: ethIn}("");
            if (!sent) {
                IWETH9(weth).deposit{value: ethIn}();
                IERC20(weth).safeTransfer(treasury, ethIn);
            }
            ethIn = 0;
        }

        PoolKey memory key = _poolKey(token);
        bytes32 poolId = keccak256(abi.encode(key));
        if (poolIdOf[token] == bytes32(0)) {
            try IPoolManager(poolManager).initialize(key, _targetSqrtPrice(token)) {
                poolIdOf[token] = poolId;
            } catch {
                // Pool already initialized by a prior initializePool / competing tx.
                poolIdOf[token] = poolId;
            }
        }

        seededAt[token] = uint64(block.timestamp);
        launchBlock[token] = uint64(block.number);
        // Uniform clearing starts after the factory's optional creator initial buy
        // (see `startUniformClearing`), so the creator can spot-buy before the window.

        if (positionManager == address(0)) revert MissingPositionManager();
        if (lpFeeVault == address(0)) revert ZeroAddress();

        (int24 tickLower, int24 tickUpper) = _positionRange(token < weth);
        positionTickLower[token] = tickLower;
        positionTickUpper[token] = tickUpper;

        (tokenId, liquidity) = _mintOneSided(token, key, tickLower, tickUpper, tokensIn, lpFeeVault);

        uint256 tokLeft = IERC20(token).balanceOf(address(this));
        if (tokLeft != 0) IERC20(token).safeTransfer(DEAD, tokLeft);

        positionTokenId[token] = tokenId;
        (bool ok,) = lpFeeVault.call(abi.encodeWithSignature("registerPosition(uint256,address)", tokenId, token));
        if (!ok) revert MintFailed();
        emit V4Seeded(token, msg.sender, poolId, 0, tokensIn, seededAt[token]);
    }

    /// @notice Begin the anti-bundle commit window. Factory-only; call after optional creator buy.
    function startUniformClearing(address token) external {
        if (msg.sender != factory) revert NotFactory();
        if (seededAt[token] == 0) revert NotSeeded();
        if (!_tax[token].base.uniformClearing) revert InvalidTaxConfig();
        if (clearingEnd[token] != 0) revert ClearingAlreadyStarted();
        clearingEnd[token] = uint64(block.timestamp) + CLEARING_SECONDS;
    }

    /// @notice Instant V3-style one-sided range for this token ordering.
    function positionRange(address token) external view returns (int24 tickLower, int24 tickUpper) {
        tickLower = positionTickLower[token];
        tickUpper = positionTickUpper[token];
        if (tickLower == 0 && tickUpper == 0) {
            (tickLower, tickUpper) = _positionRange(token < weth);
        }
    }

    function _positionRange(bool isToken0) internal pure returns (int24 tickLower, int24 tickUpper) {
        if (isToken0) {
            return (INITIAL_TICK, TICK_UPPER);
        }
        return (TICK_LOWER, -INITIAL_TICK);
    }

    function _mintOneSided(
        address token,
        PoolKey memory key,
        int24 tickLower,
        int24 tickUpper,
        uint256 tokenAmt,
        address nftRecipient
    ) internal returns (uint256 tokenId, uint128 liquidity) {
        if (positionManager == address(0)) revert MissingPositionManager();

        uint160 sqrtP = _targetSqrtPrice(token);
        uint160 sqrtA = PeepsTickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = PeepsTickMath.getSqrtRatioAtTick(tickUpper);

        uint256 amount0;
        uint256 amount1;
        if (token < weth) {
            amount0 = tokenAmt;
            amount1 = 0;
        } else {
            amount0 = 0;
            amount1 = tokenAmt;
        }

        liquidity = V4LiquidityMath.getLiquidityForAmounts(sqrtP, sqrtA, sqrtB, amount0, amount1);
        if (liquidity == 0) revert InsufficientLiquidityMinted();

        _approvePermit2(token);

        uint256 nextId = IV4PositionManager(positionManager).nextTokenId();

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            key, tickLower, tickUpper, uint256(liquidity), amount0, amount1, nftRecipient, bytes("")
        );
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, address(this));
        params[3] = abi.encode(key.currency1, address(this));

        bytes memory unlockData = abi.encode(actions, params);

        liquidityGateOpen[token] = true;
        try IV4PositionManager(positionManager).modifyLiquidities(unlockData, block.timestamp + 1) {
            tokenId = nextId;
        } catch {
            liquidityGateOpen[token] = false;
            revert MintFailed();
        }
        liquidityGateOpen[token] = false;
    }

    function _approvePermit2(address asset) internal {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(asset).forceApprove(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(asset, positionManager, type(uint160).max, type(uint48).max);
    }

    function _validateTax(IPeepsV4Factory.V4TaxLaunchConfig calldata tax) internal view {
        if (tax.taxRecipient == address(0)) revert InvalidTaxConfig();
        // Product: linked buy/sell tax 1%–10% (same rate both sides).
        if (tax.buyTaxBps != tax.sellTaxBps) revert InvalidTaxConfig();
        if (tax.buyTaxBps < 100 || tax.buyTaxBps > 1_000) revert InvalidTaxConfig();
        if (tax.antiFarmerDays > 365) revert InvalidTaxConfig();
        uint256 sum = uint256(tax.fundsBps) + tax.burnBps + tax.dividendBps + tax.liquidityBps;
        if (sum != 10_000) revert InvalidTaxConfig();
        if (tax.dividendBps > 0 && dividendDistributor == address(0)) revert InvalidTaxConfig();
    }

    function _poolKey(address token) internal view returns (PoolKey memory key) {
        address token0 = token < weth ? token : weth;
        address token1 = token < weth ? weth : token;
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    function _targetSqrtPrice(address token) internal view returns (uint160) {
        return token < weth ? SQRT_PRICE_TOKEN0_X96 : SQRT_PRICE_TOKEN1_X96;
    }
}
