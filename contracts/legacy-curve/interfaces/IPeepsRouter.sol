// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPeepsCurveFactory} from "./IPeepsCurveFactory.sol";

/// @title IPeepsRouter — user entrypoint for PEEPS launches and curve trades
interface IPeepsRouter {
    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch,
        uint256 minTokensOut,
        uint256 deadline
    ) external payable returns (address token, address curve, uint256 tokensOut);

    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);

    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        returns (uint256 ethOut);

    function sellWithPermit(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external returns (uint256 ethOut);

    function quoteBuy(address token, uint256 ethInGross)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedEthGross, uint256 refund);

    function quoteSell(address token, uint256 tokenAmount) external view returns (uint256 ethOut, uint256 fee);

    function factory() external view returns (address);
}
