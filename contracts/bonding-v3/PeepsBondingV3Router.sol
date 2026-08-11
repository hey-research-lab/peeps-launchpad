// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IPeepsRouter} from "../legacy-curve/interfaces/IPeepsRouter.sol";
import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "../legacy-curve/interfaces/IPeepsBondingCurve.sol";
import {IPeepsLaunchToken} from "../legacy-curve/interfaces/IPeepsLaunchToken.sol";
import {PeepsBondingV3Factory} from "./PeepsBondingV3Factory.sol";
import {PeepsBondingPlatformSwapFee} from "../bonding-v4/PeepsBondingPlatformSwapFee.sol";

import {
    CreatesPaused,
    BuysPaused,
    UnknownToken,
    InvalidMsgValue,
    DeadlineExpired,
    ZeroAddress,
    EthTransferFailed,
    InitialBuySupplyCapExceeded,
    SlippageExceeded
} from "../legacy-curve/errors/PeepsErrors.sol";

/// @title PeepsBondingV3Router — bonding create/trade + Instant-aligned 0.25% Peeps swap fee
/// @notice Curve takes 1% (70/30 creator/protocol). This router also takes the aggregator's
///         0.25% platform fee (referrer 0.05% / platform 0.20% when trader referrer is set).
contract PeepsBondingV3Router is IPeepsRouter, PeepsBondingPlatformSwapFee {
    using SafeERC20 for IERC20;

    uint16 internal constant MAX_INITIAL_BUY_BPS = 500;

    IPeepsCurveFactory public immutable factoryContract;

    constructor(IPeepsCurveFactory factory_, address platformSwapFeeWallet_, address referralLookup_)
        PeepsBondingPlatformSwapFee(platformSwapFeeWallet_, referralLookup_)
    {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factoryContract = factory_;
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    function factory() external view override returns (address) {
        return address(factoryContract);
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (address token, address curve, uint256 tokensOut)
    {
        return _create(name, symbol, metadataHash, metadataUri, launch, bytes32(0), address(0), minTokensOut);
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch,
        bytes32 specialCodeHash,
        address referrer,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (address token, address curve, uint256 tokensOut)
    {
        return _create(name, symbol, metadataHash, metadataUri, launch, specialCodeHash, referrer, minTokensOut);
    }

    function _create(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch,
        bytes32 specialCodeHash,
        address referrer,
        uint256 minTokensOut
    ) private returns (address token, address curve, uint256 tokensOut) {
        if (factoryContract.pauseCreates()) revert CreatesPaused();

        uint256 initialBuy = _splitCreateValue(minTokensOut);
        (token, curve,) = PeepsBondingV3Factory(address(factoryContract)).createTokenWithPlan(
            msg.sender, name, symbol, metadataHash, metadataUri, launch, specialCodeHash, referrer
        );

        uint256 creationFee = factoryContract.creationFee();
        if (creationFee != 0) {
            _sendEth(PeepsBondingV3Factory(address(factoryContract)).creationFeeRecipient(), creationFee);
        }

        if (initialBuy != 0) {
            uint256 netBuy = _takePlatformSwapFee(initialBuy, msg.sender);
            if (netBuy == 0) revert InvalidMsgValue();
            (tokensOut,,) =
                IPeepsBondingCurve(curve).buy{value: netBuy}(msg.sender, msg.sender, msg.sender, minTokensOut);
            uint256 maxInitial = (IPeepsLaunchToken(token).TOTAL_SUPPLY() * MAX_INITIAL_BUY_BPS) / 10_000;
            if (tokensOut > maxInitial) revert InitialBuySupplyCapExceeded(tokensOut, maxInitial);
            _sweepProtocolFees(curve);
            _tryAutoGraduate(curve, msg.sender);
        }
    }

    function _splitCreateValue(uint256 minTokensOut) private view returns (uint256 initialBuy) {
        uint256 creationFee = factoryContract.creationFee();
        if (msg.value < creationFee) revert InvalidMsgValue();
        unchecked {
            initialBuy = msg.value - creationFee;
        }
        if (initialBuy == 0 && minTokensOut != 0) revert InvalidMsgValue();
    }

    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (factoryContract.pauseBuys()) revert BuysPaused();
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();
        address curve = _curveOf(token);
        uint256 net = _takePlatformSwapFee(msg.value, msg.sender);
        if (net == 0) revert InvalidMsgValue();
        (tokensOut,,) = IPeepsBondingCurve(curve).buy{value: net}(msg.sender, recipient, msg.sender, minTokensOut);
        _sweepProtocolFees(curve);
        _tryAutoGraduate(curve, msg.sender);
    }

    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        return _sell(token, tokenAmount, recipient, minEthOut);
    }

    function sellWithPermit(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant checkDeadline(deadline) returns (uint256 ethOut) {
        try IERC20Permit(token).permit(msg.sender, address(this), tokenAmount, deadline, v, r, s) {} catch {}
        return _sell(token, tokenAmount, recipient, minEthOut);
    }

    function quoteBuy(address token, uint256 ethInGross)
        external
        view
        override
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedEthGross, uint256 refund)
    {
        uint256 platformFee = _platformFeeAmount(ethInGross);
        uint256 net = ethInGross - platformFee;
        if (net == 0) return (0, platformFee, 0, 0);
        uint256 curveFee;
        (tokensOut, curveFee, acceptedEthGross, refund) = IPeepsBondingCurve(_curveOf(token)).quoteBuy(net);
        fee = platformFee + curveFee;
        // acceptedEthGross is net-of-platform; surface full gross accepted for UI.
        if (acceptedEthGross != 0) acceptedEthGross += platformFee;
    }

    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        override
        returns (uint256 ethOut, uint256 fee)
    {
        uint256 curveFee;
        (ethOut, curveFee) = IPeepsBondingCurve(_curveOf(token)).quoteSell(tokenAmount);
        uint256 platformFee = _platformFeeAmount(ethOut);
        ethOut -= platformFee;
        fee = curveFee + platformFee;
    }

    function _sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut)
        private
        returns (uint256 ethOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        address curve = _curveOf(token);
        IERC20(token).safeTransferFrom(msg.sender, curve, tokenAmount);
        uint256 grossEth;
        (grossEth,) = IPeepsBondingCurve(curve).sell(msg.sender, address(this), tokenAmount, 0);
        ethOut = _takePlatformSwapFee(grossEth, msg.sender);
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);
        _sendEth(recipient, ethOut);
        _sweepProtocolFees(curve);
    }

    function _curveOf(address token) private view returns (address curve) {
        curve = factoryContract.curveOf(token);
        if (curve == address(0)) revert UnknownToken();
    }

    function _sweepProtocolFees(address curve) private {
        try IPeepsBondingCurve(curve).sweepProtocolFees() {} catch {}
    }

    function _tryAutoGraduate(address curve, address rewardTo) private {
        if (IPeepsBondingCurve(curve).phase() != IPeepsBondingCurve.Phase.ReadyToGraduate) return;

        _sweepProtocolFees(curve);
        uint256 balBefore = address(this).balance;
        try IPeepsBondingCurve(curve).graduate() {
            uint256 reward = address(this).balance - balBefore;
            if (reward != 0) _sendEth(rewardTo, reward);
        } catch {}
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    receive() external payable {}
}
