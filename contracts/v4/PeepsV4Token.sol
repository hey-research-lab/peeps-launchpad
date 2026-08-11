// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title PeepsV4Token — fixed-supply ERC-20 for Pons-style Instant Uniswap V4 launches.
/// @dev Ownable is renounced in the constructor so scanners see `owner() == 0`.
///      There are no `onlyOwner` controls on this token.
contract PeepsV4Token is ERC20, Ownable {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    error NotLaunchFactory();

    address public immutable deployer;
    address public immutable launchFactory;

    string public logo;
    string public description;
    Socials private _socials;

    constructor(
        string memory name_,
        string memory symbol_,
        string memory logo_,
        string memory description_,
        Socials memory socials_,
        address deployer_,
        uint256 supply_
    ) ERC20(name_, symbol_) Ownable(msg.sender) {
        deployer = deployer_;
        launchFactory = msg.sender;
        logo = logo_;
        description = description_;
        _socials = socials_;
        _mint(msg.sender, supply_);
        renounceOwnership();
    }

    function socials()
        external
        view
        returns (string memory twitter, string memory telegram, string memory discord, string memory website, string memory farcaster)
    {
        Socials memory s = _socials;
        return (s.twitter, s.telegram, s.discord, s.website, s.farcaster);
    }
}
