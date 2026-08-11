// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsV3SwapRouter} from "./interfaces/IPeepsV3SwapRouter.sol";
import {IPeepsCurveFactory} from "./interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "./interfaces/IPeepsBondingCurve.sol";
import {ISwapRouter02} from "src/interfaces/external/ISwapRouter02.sol";
import {IQuoterV2} from "src/interfaces/external/IQuoterV2.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";

import {
    UnknownToken,
    InvalidMsgValue,
    DeadlineExpired,
    ZeroAddress,
    EthTransferFailed,
    NotGraduated
} from "./errors/PeepsErrors.sol";
import {PeepsGraduatedSwapFees} from "src/libs/PeepsGraduatedSwapFees.sol";

/// @title PeepsV3SwapRouter — graduated-token swaps via Uniswap V3 with 0.25% platform fee.
/// @notice The full 0.25% platform fee is sent directly to the team wallet (`platformSwapFeeWallet` at deploy).
contract PeepsV3SwapRouter is IPeepsV3SwapRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint24 internal constant POOL_FEE = 10_000;

    IPeepsCurveFactory public immutable factoryContract;
    ISwapRouter02 public immutable swapRouter;
    IQuoterV2 public immutable quoter;
    address public immutable weth;
    address public immutable platformSwapFeeWallet;

    constructor(
        IPeepsCurveFactory factory_,
        address swapRouter_,
        address quoter_,
        address weth_,
        address platformSwapFeeWallet_
    ) {
        if (
            address(factory_) == address(0) || swapRouter_ == address(0) || quoter_ == address(0)
                || weth_ == address(0) || platformSwapFeeWallet_ == address(0)
        ) {
            revert ZeroAddress();
        }
        factoryContract = factory_;
        swapRouter = ISwapRouter02(swapRouter_);
        quoter = IQuoterV2(quoter_);
        weth = weth_;
        platformSwapFeeWallet = platformSwapFeeWallet_;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @inheritdoc IPeepsV3SwapRouter
    function factory() external view override returns (address) {
        return address(factoryContract);
    }

    /// @inheritdoc IPeepsV3SwapRouter
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();

        address curve = _graduatedCurve(token);
        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);

        IWETH9(weth).deposit{value: net}();
        IERC20(weth).forceApprove(address(swapRouter), net);

        tokensOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                fee: POOL_FEE,
                recipient: recipient,
                amountIn: net,
                amountOutMinimum: minTokensOut,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @inheritdoc IPeepsV3SwapRouter
    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();

        address curve = _graduatedCurve(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(swapRouter), tokenAmount);

        bytes memory swapData = abi.encodeWithSelector(
            ISwapRouter02.exactInputSingle.selector,
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                fee: POOL_FEE,
                recipient: address(swapRouter),
                amountIn: tokenAmount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        bytes memory unwrapData =
            abi.encodeWithSelector(ISwapRouter02.unwrapWETH9.selector, uint256(0), address(this));
        bytes[] memory calls = new bytes[](2);
        calls[0] = swapData;
        calls[1] = unwrapData;
        swapRouter.multicall(calls);

        uint256 grossEth = address(this).balance;
        uint256 fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
        if (ethOut < minEthOut) revert InvalidMsgValue();

        _routePlatformFee(fee);
        _sendEth(recipient, ethOut);
    }

    /// @inheritdoc IPeepsV3SwapRouter
    function quoteBuy(address token, uint256 ethInGross)
        external
        override
        returns (uint256 tokensOut, uint256 fee)
    {
        _graduatedCurve(token);
        if (ethInGross == 0) return (0, 0);
        fee = _feeAmount(ethInGross);
        uint256 net = ethInGross - fee;
        if (net == 0) return (0, fee);
        (tokensOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                amountIn: net,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @inheritdoc IPeepsV3SwapRouter
    function quoteSell(address token, uint256 tokenAmount) external override returns (uint256 ethOut, uint256 fee) {
        _graduatedCurve(token);
        if (tokenAmount == 0) return (0, 0);
        (uint256 grossEth,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                amountIn: tokenAmount,
                fee: POOL_FEE,
                sqrtPriceLimitX96: 0
            })
        );
        fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
    }

    function _graduatedCurve(address token) internal view returns (address curve) {
        curve = factoryContract.curveOf(token);
        if (curve == address(0)) revert UnknownToken();
        if (IPeepsBondingCurve(curve).phase() != IPeepsBondingCurve.Phase.Graduated) revert NotGraduated();
    }

    function _feeAmount(uint256 gross) internal pure returns (uint256) {
        return PeepsGraduatedSwapFees.feeAmount(gross);
    }

    function _routePlatformFee(uint256 feeTotal) internal {
        if (feeTotal == 0) return;
        _sendEth(platformSwapFeeWallet, feeTotal);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    receive() external payable {}
}
