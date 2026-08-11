// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IPeepsV3SwapRouter — post-graduation swaps with 0.25% platform fee (100% team) + 1% V3 LP fee.
interface IPeepsV3SwapRouter {
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);

    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        returns (uint256 ethOut);

    function quoteBuy(address token, uint256 ethInGross)
        external
        returns (uint256 tokensOut, uint256 fee);

    function quoteSell(address token, uint256 tokenAmount) external returns (uint256 ethOut, uint256 fee);

    function factory() external view returns (address);
    function platformSwapFeeWallet() external view returns (address);
}
