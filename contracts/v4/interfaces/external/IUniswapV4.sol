// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @dev Minimal Uniswap V4 types for PEEPS V4 tax + swap + vault path (Robinhood).
type Currency is address;
type BeforeSwapDelta is int256;

/// @dev Dynamic-fee marker for PoolKey.fee (hook supplies LP fee via beforeSwap override).
uint24 constant DYNAMIC_FEE_FLAG = 0x800000;
/// @dev OR into beforeSwap's uint24 return so PoolManager applies the hook LP fee.
uint24 constant OVERRIDE_FEE_FLAG = 0x400000;

struct PoolKey {
    Currency currency0;
    Currency currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

library BeforeSwapDeltaLibrary {
    function toBeforeSwapDelta(int128 deltaSpecified, int128 deltaUnspecified)
        internal
        pure
        returns (BeforeSwapDelta beforeSwapDelta)
    {
        assembly ("memory-safe") {
            beforeSwapDelta := or(shl(128, deltaSpecified), and(sub(shl(128, 1), 1), deltaUnspecified))
        }
    }
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);

    function unlock(bytes calldata data) external returns (bytes memory result);

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);

    function sync(Currency currency) external;

    function settle() external payable returns (uint256 paid);

    function take(Currency currency, address to, uint256 amount) external;

    function clear(Currency currency, uint256 amount) external;

    function extsload(bytes32 slot) external view returns (bytes32 value);

    function exttload(bytes32 slot) external view returns (bytes32 value);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IV4PositionManager {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;

    function nextTokenId() external view returns (uint256);

    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);

    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

library Actions {
    uint256 internal constant INCREASE_LIQUIDITY = 0x00;
    uint256 internal constant DECREASE_LIQUIDITY = 0x01;
    uint256 internal constant MINT_POSITION = 0x02;
    uint256 internal constant SETTLE_PAIR = 0x0d;
    uint256 internal constant TAKE_PAIR = 0x11;
    uint256 internal constant SWEEP = 0x14;
}

/// @dev Sqrt price limits used when no custom limit is set (TickMath min/max).
uint160 constant MIN_SQRT_RATIO = 4_295_128_739;
uint160 constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
