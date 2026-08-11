// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title HookMiner — FIND CREATE2 salt so hook address carries required permission bits
/// @notice Port of Uniswap v4-periphery HookMiner (flags in low bits of address).
library HookMiner {
    uint160 internal constant FLAG_MASK = 0x3FFF; // low 14 bits

    /// @dev Mine `salt` such that CREATE2(deployer, salt, initCodeHash) has `flags` set.
    function find(address deployer, uint160 flags, bytes32 initCodeHash)
        internal
        pure
        returns (address hook, bytes32 salt)
    {
        flags = flags & FLAG_MASK;
        for (uint256 i = 0; i < type(uint256).max;) {
            salt = bytes32(i);
            hook = computeAddress(deployer, salt, initCodeHash);
            if (uint160(hook) & FLAG_MASK == flags) {
                return (hook, salt);
            }
            unchecked {
                ++i;
            }
        }
        revert("HookMiner: salt not found");
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
