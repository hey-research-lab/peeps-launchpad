// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PeepsGraduatedSwapFees} from "../libs/PeepsGraduatedSwapFees.sol";
import {ZeroAddress, EthTransferFailed} from "../legacy-curve/errors/PeepsErrors.sol";

interface IPeepsTraderReferralLookup {
    function traderReferrer(address trader) external view returns (address);
}

error NothingToClaim();

/// @title PeepsBondingPlatformSwapFee — Instant/aggregator-aligned 0.25% on curve trades
/// @notice Taken by bonding routers on top of the 1% curve fee. Referrer gets 0.05% of notional
///         when `traderReferrer` is set on the fee router; platform keeps 0.20% (or full 0.25%).
abstract contract PeepsBondingPlatformSwapFee is ReentrancyGuard {
    address public immutable platformSwapFeeWallet;
    /// @dev PeepsProtocolFeeRouter (or zero to disable referral split).
    address public immutable referralLookup;

    mapping(address account => uint256 amount) public claimableReferralEth;
    uint256 public reservedReferralEth;

    event BondingSwapFeePaid(
        address indexed trader, uint256 feeTotal, uint256 toPlatform, uint256 toReferrer
    );
    event BondingReferralFeeClaimed(address indexed referrer, uint256 amount);

    constructor(address platformSwapFeeWallet_, address referralLookup_) {
        if (platformSwapFeeWallet_ == address(0)) revert ZeroAddress();
        platformSwapFeeWallet = platformSwapFeeWallet_;
        referralLookup = referralLookup_;
    }

    /// @notice Pull-claim accrued curve-trade referral ETH (0.05% of referred traders' notional).
    function claimReferralEth() external nonReentrant returns (uint256 amount) {
        amount = claimableReferralEth[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableReferralEth[msg.sender] = 0;
        reservedReferralEth -= amount;
        _sendPlatformEth(msg.sender, amount);
        emit BondingReferralFeeClaimed(msg.sender, amount);
    }

    function _platformFeeAmount(uint256 gross) internal pure returns (uint256) {
        return PeepsGraduatedSwapFees.feeAmount(gross);
    }

    /// @dev Take 0.25% from `gross`, route platform/referrer, return net for the curve.
    function _takePlatformSwapFee(uint256 gross, address trader) internal returns (uint256 net) {
        uint256 fee = _platformFeeAmount(gross);
        if (fee == 0) return gross;
        net = gross - fee;
        _routePlatformFee(fee, trader);
    }

    function _routePlatformFee(uint256 feeTotal, address trader) internal {
        if (feeTotal == 0) return;

        address ref;
        if (referralLookup != address(0) && trader != address(0)) {
            try IPeepsTraderReferralLookup(referralLookup).traderReferrer(trader) returns (address r) {
                ref = r;
            } catch {
                ref = address(0);
            }
        }

        if (ref == address(0) || ref == trader) {
            _sendPlatformEth(platformSwapFeeWallet, feeTotal);
            emit BondingSwapFeePaid(trader, feeTotal, feeTotal, 0);
            return;
        }

        uint256 refFee = PeepsGraduatedSwapFees.referralShareOfFee(feeTotal);
        uint256 platFee = feeTotal - refFee;
        if (refFee != 0) {
            claimableReferralEth[ref] += refFee;
            reservedReferralEth += refFee;
        }
        if (platFee != 0) _sendPlatformEth(platformSwapFeeWallet, platFee);
        emit BondingSwapFeePaid(trader, feeTotal, platFee, refFee);
    }

    function _sendPlatformEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
