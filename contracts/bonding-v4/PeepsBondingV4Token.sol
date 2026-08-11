// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title PeepsBondingV4Token — clean bonding→V4 launch token
/// @notice Fixed 1B supply, ownerless, no mint/burn/tax/blacklist/freeze/pause on the token.
///         Entire supply minted once to the bonding curve. Creator-set Instant-style tax is
///         applied by {PeepsBondingV4Router} on the curve and by {PeepsV4TaxHook} after migrate.
contract PeepsBondingV4Token is ERC20, ERC20Permit {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;
    bytes32 public immutable metadataHash;
    address public immutable curve;

    constructor(string memory name_, string memory symbol_, bytes32 metadataHash_, address curve_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
    {
        metadataHash = metadataHash_;
        curve = curve_;
        _mint(curve_, TOTAL_SUPPLY);
    }
}
