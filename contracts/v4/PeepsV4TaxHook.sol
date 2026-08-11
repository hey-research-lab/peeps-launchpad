// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {
    Currency,
    PoolKey,
    SwapParams,
    ModifyLiquidityParams,
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    IPoolManager,
    OVERRIDE_FEE_FLAG
} from "./interfaces/external/IUniswapV4.sol";
import {ZeroAddress, ClearingWindowActive} from "./errors/PeepsV4Errors.sol";

/// @title PeepsV4TaxHook — tax take + bucket payout + anti-farmer
/// @notice CREATE2-deploy so address bits include beforeSwap | afterSwap | beforeAddLiquidity |
///         beforeSwapReturnsDelta.
/// @dev Tax is a BeforeSwapDelta skim (not ERC-20 transfer tax). afterSwap pulls via take() and
///      routes funds/burn/dividend/liquidity bps. Anti-farmer blocks third-party LP adds.
contract PeepsV4TaxHook {
    using SafeERC20 for IERC20;

    uint160 internal constant BEFORE_ADD_LIQUIDITY_FLAG = 1 << 11;
    uint160 internal constant BEFORE_SWAP_FLAG = 1 << 7;
    uint160 internal constant AFTER_SWAP_FLAG = 1 << 6;
    /// @dev Without this bit, PoolManager ignores BeforeSwapDelta — tax skim would be a no-op.
    uint160 internal constant BEFORE_SWAP_RETURNS_DELTA_FLAG = 1 << 3;
    /// @dev Match V3 migrator 1% LP fee so vault harvest has fees to collect.
    uint24 internal constant LP_FEE_BPS = 10_000;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPeepsV4Registry public immutable registry;
    address public immutable poolManager;
    address public immutable authorizedRegistry;

    /// @dev Transient accounting for the active unlock (exact-in tax skim).
    Currency internal _pendingTaxCurrency;
    uint256 internal _pendingTaxAmount;
    address internal _pendingToken;

    error NotPoolManager();
    error NotSeeded();
    error AntiFarmerActive();
    error InvalidHookAddress();
    error OnlyExactInput();
    error NotifyFailed();

    event TaxTaken(address indexed token, address indexed currency, uint256 amount, bool buy);
    event TaxDistributed(
        address indexed token,
        uint256 fundsAmt,
        uint256 burnAmt,
        uint256 dividendAmt,
        uint256 liquidityAmt,
        address taxRecipient,
        address liquiditySink
    );

    constructor(address poolManager_, address registry_, address authorizedRegistry_, bool requireFlags) {
        if (poolManager_ == address(0) || registry_ == address(0) || authorizedRegistry_ == address(0)) {
            revert ZeroAddress();
        }
        if (requireFlags) {
            uint160 flags = uint160(uint256(uint160(address(this))));
            uint160 need = BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | BEFORE_ADD_LIQUIDITY_FLAG
                | BEFORE_SWAP_RETURNS_DELTA_FLAG;
            if ((flags & need) != need) revert InvalidHookAddress();
        }
        poolManager = poolManager_;
        registry = IPeepsV4Registry(registry_);
        authorizedRegistry = authorizedRegistry_;
    }

    function getHookPermissions() external pure returns (uint160) {
        return BEFORE_SWAP_FLAG | AFTER_SWAP_FLAG | BEFORE_ADD_LIQUIDITY_FLAG
            | BEFORE_SWAP_RETURNS_DELTA_FLAG;
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        // Exact-input only (amountSpecified < 0). Exact-out would need different accounting.
        if (params.amountSpecified >= 0) revert OnlyExactInput();

        address token = _memeToken(key);
        uint64 seeded = registry.seededAt(token);
        if (seeded == 0) revert NotSeeded();

        // Uniform clearing: no spot swaps until the window ends and settle runs.
        if (registry.clearingActive(token)) revert ClearingWindowActive();

        IPeepsV4Factory.V4TaxLaunchConfig memory cfg = registry.taxConfig(token);
        bool buyingMeme = _isBuyMeme(key, token, params.zeroForOne);
        uint16 taxBps = buyingMeme ? cfg.buyTaxBps : cfg.sellTaxBps;

        BeforeSwapDelta delta = BeforeSwapDelta.wrap(0);
        if (taxBps != 0) {
            uint256 absIn = uint256(-params.amountSpecified);
            uint256 taxAmt = (absIn * taxBps) / 10_000;
            if (taxAmt > 0 && taxAmt < absIn) {
                // Positive specified delta → hook takes `taxAmt` of the input currency.
                delta = BeforeSwapDeltaLibrary.toBeforeSwapDelta(int128(int256(taxAmt)), 0);
                address input = params.zeroForOne
                    ? Currency.unwrap(key.currency0)
                    : Currency.unwrap(key.currency1);
                _pendingTaxCurrency = Currency.wrap(input);
                _pendingTaxAmount = taxAmt;
                _pendingToken = token;
                emit TaxTaken(token, input, taxAmt, buyingMeme);
            }
        }
        return (this.beforeSwap.selector, delta, LP_FEE_BPS | OVERRIDE_FEE_FLAG);
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, int256, bytes calldata)
        external
        returns (bytes4, int128)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        uint256 taxAmt = _pendingTaxAmount;
        if (taxAmt == 0) return (this.afterSwap.selector, 0);

        Currency currency = _pendingTaxCurrency;
        address token = _pendingToken;
        _pendingTaxAmount = 0;
        _pendingToken = address(0);

        IPoolManager(poolManager).take(currency, address(this), taxAmt);
        _distribute(token, Currency.unwrap(currency), taxAmt);
        return (this.afterSwap.selector, 0);
    }

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view returns (bytes4) {
        if (msg.sender != poolManager) revert NotPoolManager();
        address token = _memeToken(key);
        uint64 seeded = registry.seededAt(token);
        if (seeded == 0) revert NotSeeded();

        if (registry.liquidityGateOpen(token)) return this.beforeAddLiquidity.selector;
        if (sender == authorizedRegistry) return this.beforeAddLiquidity.selector;

        IPeepsV4Factory.V4TaxLaunchConfig memory cfg = registry.taxConfig(token);
        if (cfg.antiFarmerDays == 0) return this.beforeAddLiquidity.selector;

        uint256 unlockAt = uint256(seeded) + uint256(cfg.antiFarmerDays) * 1 days;
        if (block.timestamp < unlockAt) revert AntiFarmerActive();
        return this.beforeAddLiquidity.selector;
    }

    function _distribute(address token, address currency, uint256 amount) internal {
        IPeepsV4Factory.V4TaxLaunchConfig memory cfg = registry.taxConfig(token);
        uint256 fundsAmt = (amount * cfg.fundsBps) / 10_000;
        uint256 burnAmt = (amount * cfg.burnBps) / 10_000;
        uint256 dividendAmt = (amount * cfg.dividendBps) / 10_000;
        uint256 liquidityAmt = amount - fundsAmt - burnAmt - dividendAmt; // remainder = liquidity bps

        address liquiditySink = registry.lpFeeVault();
        if (liquiditySink == address(0)) liquiditySink = cfg.taxRecipient;
        address dividendSink = registry.dividendDistributor();

        if (fundsAmt != 0) IERC20(currency).safeTransfer(cfg.taxRecipient, fundsAmt);
        if (burnAmt != 0) IERC20(currency).safeTransfer(DEAD, burnAmt);
        if (dividendAmt != 0) {
            if (dividendSink == address(0)) revert ZeroAddress();
            IERC20(currency).safeTransfer(dividendSink, dividendAmt);
            (bool dok,) = dividendSink.call(
                abi.encodeWithSignature(
                    "notifyTaxDividend(address,address,uint256)", token, currency, dividendAmt
                )
            );
            if (!dok) revert NotifyFailed();
        }
        if (liquidityAmt != 0) {
            IERC20(currency).safeTransfer(liquiditySink, liquidityAmt);
            (bool ok,) = liquiditySink.call(
                abi.encodeWithSignature("notifyTaxLiquidity(address,address,uint256)", token, currency, liquidityAmt)
            );
            if (!ok) revert NotifyFailed();
        }

        emit TaxDistributed(token, fundsAmt, burnAmt, dividendAmt, liquidityAmt, cfg.taxRecipient, liquiditySink);
    }

    function _isBuyMeme(PoolKey calldata key, address token, bool zeroForOne) internal pure returns (bool) {
        address c0 = Currency.unwrap(key.currency0);
        if (token == c0) return !zeroForOne;
        return zeroForOne;
    }

    function _memeToken(PoolKey calldata key) internal view returns (address token) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        token = c0;
        if (registry.seededAt(c0) == 0 && registry.seededAt(c1) != 0) {
            token = c1;
        }
    }
}
