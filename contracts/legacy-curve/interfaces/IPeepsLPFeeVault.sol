// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPeepsCurveFactory} from "./IPeepsCurveFactory.sol";

/// @title IPeepsLPFeeVault — locked LP principal; V3 fees split creator / protocol
interface IPeepsLPFeeVault {
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

    function collect(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);
    function collectForToken(address launchToken) external returns (uint256 amount0, uint256 amount1);
    function claimCreatorLpFees(address launchToken) external returns (uint256 ethClaimed, uint256 tokenClaimed);
    function registerPosition(uint256 tokenId, address launchToken) external;
    function positionManager() external view returns (address);
    function treasury() external view returns (address);
    function marketingWallet() external view returns (address);
    function buybackWallet() external view returns (address);
    function factory() external view returns (address);
    function tokenPosition(address launchToken) external view returns (uint256);
    function accruedCreatorEth(address launchToken) external view returns (uint256);
    function accruedCreatorTokens(address launchToken) external view returns (uint256);
}
