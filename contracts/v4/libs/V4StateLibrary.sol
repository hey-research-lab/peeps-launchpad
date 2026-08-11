// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPoolManager} from "../interfaces/external/IUniswapV4.sol";

/// @dev Minimal PoolManager slot0 reader (Uniswap v4-core StateLibrary layout).
library V4StateLibrary {
    /// @dev PoolManager `_pools` mapping slot in v4-core 1.0.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    function getSqrtPriceX96(IPoolManager manager, bytes32 poolId) internal view returns (uint160 sqrtPriceX96) {
        bytes32 stateSlot = keccak256(abi.encodePacked(poolId, POOLS_SLOT));
        bytes32 data = manager.extsload(stateSlot);
        sqrtPriceX96 = uint160(uint256(data));
    }
}
