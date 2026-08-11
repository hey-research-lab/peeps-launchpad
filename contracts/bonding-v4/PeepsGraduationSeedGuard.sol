// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {PeepsTickMath} from "../instant/libraries/PeepsTickMath.sol";
import {V4LiquidityMath} from "../v4/libs/V4LiquidityMath.sol";

/// @title PeepsGraduationSeedGuard — Pons-style preflight for bonding→V3/V4 LP mint
/// @notice Pure checks before NPM / V4 PositionManager work:
///         amount ceilings, zero liquidity, tickSpacing max liquidityGross.
///         Ceiling uses V4's int128 BalanceDelta bound (also safe for V3 uint128 paths).
library PeepsGraduationSeedGuard {
    /// @dev V4 BalanceDelta halves are int128; V3 mint amounts must fit uint128 liquidity math.
    uint256 internal constant MAX_SEED_AMOUNT = uint256(uint128(type(int128).max));

    error GraduationSeedNotViable();

    /// @notice Assert a full-range mint at `sqrtPriceX96` is viable for the given amounts.
    /// @param sqrtPriceX96 Pool init price the migrator will use (immutable design price).
    /// @param tickLower Full-range lower tick (must be spacing-aligned).
    /// @param tickUpper Full-range upper tick (must be spacing-aligned).
    /// @param tickSpacing Pool tick spacing (Peeps bonding V4 = 200).
    /// @param amount0 Currency0 amount for the mint.
    /// @param amount1 Currency1 amount for the mint.
    function assertSeedable(
        uint160 sqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        int24 tickSpacing,
        uint256 amount0,
        uint256 amount1
    ) internal pure {
        if (
            sqrtPriceX96 == 0 || tickSpacing <= 0 || tickLower >= tickUpper || amount0 == 0 || amount1 == 0
                || amount0 > MAX_SEED_AMOUNT || amount1 > MAX_SEED_AMOUNT
        ) {
            revert GraduationSeedNotViable();
        }

        uint160 sqrtA = PeepsTickMath.getSqrtRatioAtTick(tickLower);
        uint160 sqrtB = PeepsTickMath.getSqrtRatioAtTick(tickUpper);
        uint128 liquidity = V4LiquidityMath.getLiquidityForAmounts(sqrtPriceX96, sqrtA, sqrtB, amount0, amount1);
        if (liquidity == 0 || liquidity > tickSpacingToMaxLiquidityPerTick(tickSpacing)) {
            revert GraduationSeedNotViable();
        }
    }

    /// @dev Same formula as Uniswap V4 `Pool.tickSpacingToMaxLiquidityPerTick`.
    function tickSpacingToMaxLiquidityPerTick(int24 tickSpacing) internal pure returns (uint128) {
        int24 minTick = (PeepsTickMath.MIN_TICK / tickSpacing) * tickSpacing;
        int24 maxTick = (PeepsTickMath.MAX_TICK / tickSpacing) * tickSpacing;
        uint24 numTicks = uint24((maxTick - minTick) / tickSpacing) + 1;
        return type(uint128).max / numTicks;
    }
}
