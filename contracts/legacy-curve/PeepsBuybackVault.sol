// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsBuybackVault} from "./interfaces/IPeepsBuybackVault.sol";
import {ISwapRouter02} from "src/interfaces/external/ISwapRouter02.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";
import {ZeroAddress, EthTransferFailed} from "./errors/PeepsErrors.sol";

/// @title PeepsBuybackVault — optional standalone $PEEPS market-buy + burn (not wired to curve furnace)
/// @notice Standalone vault for voluntary ETH deposits. Anyone may call `executeBuyback` to swap
///         accumulated ETH → $PEEPS on Uniswap V3 and burn to `0xdead`. The per-token curve furnace
///         (`executeFurnaceBurn` on {PeepsBondingCurve}) is separate and burns the launched token.
contract PeepsBuybackVault is IPeepsBuybackVault, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public peepsToken;
    address public immutable weth;
    address public immutable swapRouter;
    uint24 public immutable poolFee;

    uint256 public override totalBurned;
    uint256 public override maxChunk;

    constructor(address weth_, address swapRouter_, uint24 poolFee_, address owner_) Ownable(owner_) {
        if (weth_ == address(0) || swapRouter_ == address(0)) revert ZeroAddress();
        weth = weth_;
        swapRouter = swapRouter_;
        poolFee = poolFee_;
        maxChunk = 0.1 ether;
    }

    receive() external payable {
        emit EthReceived(msg.value);
    }

    /// @notice One-time wiring when $PEEPS is fair-launched through the factory.
    function setPeepsToken(address token) external onlyOwner {
        if (peepsToken != address(0)) revert ZeroAddress();
        if (token == address(0)) revert ZeroAddress();
        peepsToken = token;
        emit PeepsTokenSet(token);
    }

    function setMaxChunk(uint256 maxChunk_) external onlyOwner {
        maxChunk = maxChunk_;
    }

    function deposit() external payable {
        emit EthReceived(msg.value);
    }

    function executeBuyback(uint256 amountIn, uint256 minOut) external nonReentrant {
        _buyback(amountIn, minOut);
    }

    function executeBuybackAll(uint256 minOut) external nonReentrant {
        uint256 bal = address(this).balance;
        if (bal == 0) revert ZeroAddress();
        _buyback(bal, minOut);
    }

    function _buyback(uint256 amountIn, uint256 minOut) internal {
        if (peepsToken == address(0)) revert ZeroAddress();
        if (amountIn == 0) revert ZeroAddress();
        if (address(this).balance < amountIn) revert EthTransferFailed();

        uint256 chunk = amountIn > maxChunk ? maxChunk : amountIn;

        IWETH9(weth).deposit{value: chunk}();
        IERC20(weth).forceApprove(swapRouter, chunk);

        uint256 out = ISwapRouter02(swapRouter).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: peepsToken,
                fee: poolFee,
                recipient: address(this),
                amountIn: chunk,
                amountOutMinimum: minOut,
                sqrtPriceLimitX96: 0
            })
        );

        IERC20(peepsToken).safeTransfer(address(0xdead), out);
        totalBurned += out;
        emit BuybackExecuted(msg.sender, chunk, out);
    }
}
