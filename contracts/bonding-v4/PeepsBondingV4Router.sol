// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IPeepsRouter} from "../legacy-curve/interfaces/IPeepsRouter.sol";
import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "../legacy-curve/interfaces/IPeepsBondingCurve.sol";
import {IPeepsLaunchToken} from "../legacy-curve/interfaces/IPeepsLaunchToken.sol";
import {IPeepsV4Factory} from "../v4/interfaces/IPeepsV4Factory.sol";
import {PeepsBondingV4Factory} from "./PeepsBondingV4Factory.sol";
import {PeepsBondingV4TaxStore} from "./PeepsBondingV4TaxStore.sol";
import {PeepsBondingPlatformSwapFee} from "./PeepsBondingPlatformSwapFee.sol";
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
import {InvalidTaxConfig} from "../v4/errors/PeepsV4Errors.sol";

interface IPeepsBondingDividendDistributor {
    function notifyTaxDividend(address launchToken, address currency, uint256 amount) external;
    function syncShares(address launchToken, address account0, address account1) external;
}

/// @title PeepsBondingV4Router — bonding create/trade with Instant tax + 0.25% Peeps swap fee
/// @notice Curve: 1% (70/30). Router: aggregator-aligned 0.25% plus Instant tax buckets on curve
///         (dividends → Instant distributor pre-grad; liquidity → curve virtual LP inventory).
contract PeepsBondingV4Router is IPeepsRouter, PeepsBondingPlatformSwapFee {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_INITIAL_BUY_BPS = 500;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPeepsCurveFactory public immutable factoryContract;
    PeepsBondingV4TaxStore public immutable taxStore;
    /// @dev Instant PeepsV4DividendDistributor (zero disables pre-grad dividend notify).
    address public immutable dividendDistributor;

    /// @notice Accrued liquidity-tax tokens when curve transfer fails (should stay ~0).
    mapping(address token => uint256) public pendingLiquidityTax;

    error DividendNotifyFailed();

    constructor(
        IPeepsCurveFactory factory_,
        PeepsBondingV4TaxStore taxStore_,
        address platformSwapFeeWallet_,
        address referralLookup_,
        address dividendDistributor_
    ) PeepsBondingPlatformSwapFee(platformSwapFeeWallet_, referralLookup_) {
        if (address(factory_) == address(0) || address(taxStore_) == address(0)) revert ZeroAddress();
        factoryContract = factory_;
        taxStore = taxStore_;
        dividendDistributor = dividendDistributor_;
    }

    function factory() external view override returns (address) {
        return address(factoryContract);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    function createToken(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch,
        IPeepsV4Factory.V4TaxLaunchConfig calldata tax,
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
        if (factoryContract.pauseCreates()) revert CreatesPaused();

        uint256 initialBuy = _splitCreateValue(minTokensOut);
        (token, curve,) = PeepsBondingV4Factory(address(factoryContract)).createTokenWithTax(
            msg.sender, name, symbol, metadataHash, metadataUri, launch, tax, specialCodeHash, referrer
        );

        uint256 creationFee = factoryContract.creationFee();
        if (creationFee != 0) {
            _sendEth(PeepsBondingV4Factory(address(factoryContract)).creationFeeRecipient(), creationFee);
        }

        if (initialBuy != 0) {
            tokensOut = _buyWithTax(token, curve, msg.sender, msg.sender, initialBuy, minTokensOut);
            uint256 maxInitial = (IPeepsLaunchToken(token).TOTAL_SUPPLY() * MAX_INITIAL_BUY_BPS) / 10_000;
            if (tokensOut > maxInitial) revert InitialBuySupplyCapExceeded(tokensOut, maxInitial);
            _syncDividendShares(token, msg.sender, msg.sender);
            _sweepProtocolFees(curve);
            _tryAutoGraduate(curve, msg.sender);
        }
    }

    function createToken(
        string calldata,
        string calldata,
        bytes32,
        string calldata,
        IPeepsCurveFactory.LaunchConfig calldata,
        uint256,
        uint256
    ) external payable override returns (address, address, uint256) {
        revert InvalidTaxConfig();
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
        tokensOut = _buyWithTax(token, curve, msg.sender, recipient, msg.value, minTokensOut);
        _syncDividendShares(token, msg.sender, recipient);
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
        return _sellWithTax(token, tokenAmount, recipient, minEthOut);
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
        return _sellWithTax(token, tokenAmount, recipient, minEthOut);
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
        if (taxStore.hasTax(token)) {
            IPeepsV4Factory.V4TaxLaunchConfig memory tax = taxStore.taxConfig(token);
            tokensOut = tokensOut - (tokensOut * tax.buyTaxBps) / 10_000;
        }
        fee = platformFee + curveFee;
        if (acceptedEthGross != 0) acceptedEthGross += platformFee;
    }

    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        override
        returns (uint256 ethOut, uint256 fee)
    {
        uint256 sellAmount = tokenAmount;
        if (taxStore.hasTax(token)) {
            IPeepsV4Factory.V4TaxLaunchConfig memory tax = taxStore.taxConfig(token);
            sellAmount = tokenAmount - (tokenAmount * tax.sellTaxBps) / 10_000;
        }
        uint256 curveFee;
        (ethOut, curveFee) = IPeepsBondingCurve(_curveOf(token)).quoteSell(sellAmount);
        uint256 platformFee = _platformFeeAmount(ethOut);
        ethOut -= platformFee;
        fee = curveFee + platformFee;
    }

    function _buyWithTax(
        address token,
        address curve,
        address trader,
        address recipient,
        uint256 value,
        uint256 minTokensOut
    ) private returns (uint256 tokensOut) {
        uint256 netValue = _takePlatformSwapFee(value, trader);
        if (netValue == 0) revert InvalidMsgValue();
        (uint256 grossOut,,) = IPeepsBondingCurve(curve).buy{value: netValue}(trader, address(this), trader, 0);
        uint256 netOut = _applyTokenTax(token, grossOut, true);
        if (netOut < minTokensOut) revert SlippageExceeded(netOut, minTokensOut);
        IERC20(token).safeTransfer(recipient, netOut);
        return netOut;
    }

    function _sellWithTax(address token, uint256 tokenAmount, address recipient, uint256 minEthOut)
        private
        returns (uint256 ethOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        address curve = _curveOf(token);
        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        uint256 sellAmount = _applyTokenTax(token, tokenAmount, false);
        IERC20(token).safeTransfer(curve, sellAmount);
        uint256 grossEth;
        (grossEth,) = IPeepsBondingCurve(curve).sell(msg.sender, address(this), sellAmount, 0);
        ethOut = _takePlatformSwapFee(grossEth, msg.sender);
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);
        _sendEth(recipient, ethOut);
        _syncDividendShares(token, msg.sender, recipient);
        _sweepProtocolFees(curve);
    }

    function _applyTokenTax(address token, uint256 amount, bool isBuy) private returns (uint256 net) {
        if (!taxStore.hasTax(token) || amount == 0) return amount;
        IPeepsV4Factory.V4TaxLaunchConfig memory tax = taxStore.taxConfig(token);
        uint16 bps = isBuy ? tax.buyTaxBps : tax.sellTaxBps;
        uint256 taxAmt = (amount * bps) / 10_000;
        if (taxAmt == 0) return amount;
        net = amount - taxAmt;

        uint256 toFunds = (taxAmt * tax.fundsBps) / 10_000;
        uint256 toBurn = (taxAmt * tax.burnBps) / 10_000;
        uint256 toDiv = (taxAmt * tax.dividendBps) / 10_000;
        uint256 toLiq = taxAmt - toFunds - toBurn - toDiv;

        if (toFunds != 0) IERC20(token).safeTransfer(tax.taxRecipient, toFunds);
        if (toBurn != 0) IERC20(token).safeTransfer(DEAD, toBurn);
        if (toDiv != 0) _notifyDividend(token, toDiv);
        if (toLiq != 0) _contributeVirtualLp(token, toLiq);
    }

    /// @dev Instant distributor — holders claim via `PeepsV4DividendDistributor.claim` pre- and post-grad.
    function _notifyDividend(address token, uint256 amount) private {
        address dist = dividendDistributor;
        if (dist == address(0)) {
            // Fallback: park at tax recipient if distributor not wired.
            IPeepsV4Factory.V4TaxLaunchConfig memory tax = taxStore.taxConfig(token);
            IERC20(token).safeTransfer(tax.taxRecipient, amount);
            return;
        }
        IERC20(token).safeTransfer(dist, amount);
        try IPeepsBondingDividendDistributor(dist).notifyTaxDividend(token, token, amount) {}
        catch {
            revert DividendNotifyFailed();
        }
    }

    /// @dev Send liquidity-tax tokens to the curve without increasing sellable `_realTokenReserves`
    ///      (same pattern as the reserved LP tranche). Migrator mints the full inventory into Uni LP.
    function _contributeVirtualLp(address token, uint256 amount) private {
        address curve = factoryContract.curveOf(token);
        if (curve == address(0)) {
            pendingLiquidityTax[token] += amount;
            return;
        }
        IERC20(token).safeTransfer(curve, amount);
    }

    function _syncDividendShares(address token, address a0, address a1) private {
        address dist = dividendDistributor;
        if (dist == address(0) || !taxStore.hasTax(token)) return;
        IPeepsV4Factory.V4TaxLaunchConfig memory tax = taxStore.taxConfig(token);
        if (tax.dividendBps == 0) return;
        try IPeepsBondingDividendDistributor(dist).syncShares(token, a0, a1) {} catch {}
    }

    function _splitCreateValue(uint256 minTokensOut) private view returns (uint256 initialBuy) {
        uint256 creationFee = factoryContract.creationFee();
        if (msg.value < creationFee) revert InvalidMsgValue();
        unchecked {
            initialBuy = msg.value - creationFee;
        }
        if (initialBuy == 0 && minTokensOut != 0) revert InvalidMsgValue();
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
