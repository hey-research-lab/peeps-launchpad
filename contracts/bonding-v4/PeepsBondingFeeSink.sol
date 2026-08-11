// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {ZeroAddress} from "../v4/errors/PeepsV4Errors.sol";

interface IPeepsProtocolFeeNotify {
    function notifyFees(
        address launchToken,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) external;
}

/// @title PeepsBondingFeeSink — curve protocol fee → Instant fee router (referrals)
/// @notice Set as bonding factory `treasury` so {PeepsBondingCurve-sweepProtocolFees} wraps ETH
///         to WETH and calls {PeepsProtocolFeeRouter-notifyFees} under the token's referral plan.
contract PeepsBondingFeeSink {
    using SafeERC20 for IERC20;

    address public immutable weth;
    address public immutable feeRouter;

    error InvalidValue();
    error NotifyFeesFailed();

    constructor(address weth_, address feeRouter_) {
        if (weth_ == address(0) || feeRouter_ == address(0)) revert ZeroAddress();
        weth = weth_;
        feeRouter = feeRouter_;
    }

    /// @dev Called by {PeepsBondingCurve-sweepProtocolFees} with `msg.value == amount`.
    function onCurveProtocolFees(address token, uint256 amount) external payable {
        if (token == address(0) || amount == 0 || msg.value != amount) revert InvalidValue();
        IWETH9(weth).deposit{value: amount}();
        IERC20(weth).safeTransfer(feeRouter, amount);
        // Single-asset notify (WETH only).
        try IPeepsProtocolFeeNotify(feeRouter).notifyFees(token, weth, weth, amount, 0) {}
        catch {
            revert NotifyFeesFailed();
        }
    }

    /// @dev Reject bare ETH — curve must call {onCurveProtocolFees}.
    receive() external payable {
        revert InvalidValue();
    }
}
