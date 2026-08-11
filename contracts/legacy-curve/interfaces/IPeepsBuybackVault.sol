// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IPeepsBuybackVault — accumulates ETH and market-buys + burns $PEEPS
interface IPeepsBuybackVault {
    event BuybackExecuted(address indexed caller, uint256 ethIn, uint256 peepsBurned);
    event EthReceived(uint256 amount);
    event PeepsTokenSet(address indexed token);

    function peepsToken() external view returns (address);
    function totalBurned() external view returns (uint256);
    function maxChunk() external view returns (uint256);

    function deposit() external payable;
    function executeBuyback(uint256 amountIn, uint256 minOut) external;
    function executeBuybackAll(uint256 minOut) external;
}
