// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {IPeepsRouter} from "./interfaces/IPeepsRouter.sol";
import {IPeepsCurveFactory} from "./interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "./interfaces/IPeepsBondingCurve.sol";
import {IPeepsLaunchToken} from "./interfaces/IPeepsLaunchToken.sol";

import {
    CreatesPaused,
    BuysPaused,
    UnknownToken,
    InvalidMsgValue,
    DeadlineExpired,
    ZeroAddress,
    EthTransferFailed,
    InitialBuySupplyCapExceeded
} from "./errors/PeepsErrors.sol";

/// @title PeepsRouter — single user entrypoint for PEEPS (spec §6.5, §7; contracts.md §2.4)
/// @notice Thin by design: deadline + pause guards + fund plumbing + permit. ALL economics live in
///         the {PeepsBondingCurve}; the PeepsRouter computes NO fee and takes NO caller-supplied fee (spec
///         §4.1). It has no owner and holds no persistent ETH — every value path is forwarded to a
///         curve (or, for the creation fee, straight to the live treasury) within the same call.
///
/// @dev Load-bearing engineering decisions (recorded for the peeps-security gate):
///
///      1. **Provably pause-free sell path (spec §6.5, THE headline guarantee).** `sell` /
///         `sellWithPermit` read NO pause flag — grep this contract: the tokens `pauseBuys` /
///         `pauseCreates` / `CreatesPaused` / `BuysPaused` appear ONLY inside `createToken` /
///         `buy`, never on a sell path, and the curve's `sell` reads no factory pause state either
///         (see {PeepsBondingCurve}). Combined with the §12.25 pull-payment model (no trade path calls
///         the treasury), a seller can always exit regardless of admin action or a hostile treasury.
///         Proven end-to-end by the PeepsRouter pause-matrix test (both pauses on + reverting treasury).
///
///      2. **Deadline on EVERY trade path, including the permit variant (spec §6.5, hard rule
///         §10).** A `checkDeadline` modifier fronts `createToken`, `buy`, `sell` AND
///         `sellWithPermit`. For `sellWithPermit` the deadline is enforced INDEPENDENTLY of the
///         EIP-2612 permit: the try/catch tolerates a front-run permit (proceed on a pre-existing
///         allowance), which would otherwise let a stale-but-still-approved sell bypass a
///         signature-expiry-only deadline. Making the trade deadline a standalone guard closes that
///         gap. Alternative weighed: rely on the permit's own `deadline` — rejected because the
///         try/catch deliberately swallows a reverting permit, so it cannot be the sole deadline.
///
///      3. **`nonReentrant` on all four externals + CEI; ETH only ever leaves via the curve.**
///         The PeepsRouter keeps no mutable state (only the immutable `factory`), so its own reentrancy
///         surface is nil, but the guard still hardens the create→buy and sell→ETH-payout callbacks:
///         a malicious `recipient`/`refundTo`/creator re-entering the PeepsRouter hits this guard. Chosen
///         the storage-based OZ v5 `ReentrancyGuard` over the transient variant to make no
///         EIP-1153/ArbOS availability assumption (matches {PeepsBondingCurve}, finding T-3). Token pulls
///         use SafeERC20; the seller's tokens are moved straight to the curve (never parked here).
contract PeepsRouter is IPeepsRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Creator initial buy at launch may receive at most 5% of total token supply.
    uint16 internal constant MAX_INITIAL_BUY_BPS = 500;

    /// @notice The deployed {PeepsCurveFactory}. Sole storage slot — immutable. The PeepsRouter reads all live
    ///         config (fees, pauses, treasury, registry) from here at call time; it owns nothing
    ///         settable. Exposed as `address` via the {IPeepsRouter-factory} getter below.
    IPeepsCurveFactory public immutable factoryContract;

    /// @param factory_ The deployed {PeepsCurveFactory} (must be non-zero).
    constructor(IPeepsCurveFactory factory_) {
        if (address(factory_) == address(0)) revert ZeroAddress();
        factoryContract = factory_;
    }

    /// @notice Reverts once the block timestamp passes `deadline` (spec §6.5). Timestamp-based —
    ///         never the L1-estimating block-height opcode (spec §2).
    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    /// @inheritdoc IPeepsRouter
    function factory() external view override returns (address) {
        return address(factoryContract);
    }

    /// @inheritdoc IPeepsRouter
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
        if (factoryContract.pauseCreates()) revert CreatesPaused();

        uint256 initialBuy = _splitCreateValue(minTokensOut);
        (token, curve) = _deploy(name, symbol, metadataHash, metadataUri, launch);

        uint256 creationFee = factoryContract.creationFee();
        if (creationFee != 0) _sendEth(factoryContract.treasury(), creationFee);

        if (initialBuy != 0) {
            (tokensOut,,) =
                IPeepsBondingCurve(curve).buy{value: initialBuy}(msg.sender, msg.sender, msg.sender, minTokensOut);
            uint256 maxInitial = (IPeepsLaunchToken(token).TOTAL_SUPPLY() * MAX_INITIAL_BUY_BPS) / 10_000;
            if (tokensOut > maxInitial) revert InitialBuySupplyCapExceeded(tokensOut, maxInitial);
            _tryAutoGraduate(curve, msg.sender);
        }
    }

    function _deploy(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        IPeepsCurveFactory.LaunchConfig calldata launch
    ) private returns (address token, address curve) {
        (token, curve,) = factoryContract.createToken(msg.sender, name, symbol, metadataHash, metadataUri, launch);
    }

    /// @dev Validate `msg.value` against the live creation fee and return the leftover initial-buy
    ///      amount. A slippage floor with no actual buy is a caller error (§5.3 anti-self-snipe).
    function _splitCreateValue(uint256 minTokensOut) private view returns (uint256 initialBuy) {
        uint256 creationFee = factoryContract.creationFee();
        if (msg.value < creationFee) revert InvalidMsgValue();
        unchecked {
            initialBuy = msg.value - creationFee;
        }
        if (initialBuy == 0 && minTokensOut != 0) revert InvalidMsgValue();
    }

    /// @inheritdoc IPeepsRouter
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
        address curve = _curveOf(token);
        // refundTo = msg.sender (the payer) receives any graduation-clamp refund (contracts.md §2.4).
        (tokensOut,,) = IPeepsBondingCurve(curve).buy{value: msg.value}(msg.sender, recipient, msg.sender, minTokensOut);
        _tryAutoGraduate(curve, msg.sender);
    }

    /// @inheritdoc IPeepsRouter
    /// @dev Provably pause-free (decision #1): reads no pause flag; the curve's `sell` reads none
    ///      either. The seller's tokens are pulled straight into the curve, then `sell` is invoked.
    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        return _sell(token, tokenAmount, recipient, minEthOut);
    }

    /// @inheritdoc IPeepsRouter
    /// @dev Also pause-free. The trade deadline is enforced by `checkDeadline` INDEPENDENTLY of the
    ///      permit (decision #2). The permit is best-effort (try/catch) so a front-run permit that
    ///      already set the allowance does not brick the sell (spec §5.7).
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
        // Best-effort: if someone already submitted this permit (front-run griefing) or the
        // allowance is otherwise sufficient, the sell still proceeds. `deadline` doubles as the
        // permit deadline; the trade-level `checkDeadline` above guarantees freshness regardless.
        try IERC20Permit(token).permit(msg.sender, address(this), tokenAmount, deadline, v, r, s) {} catch {}
        return _sell(token, tokenAmount, recipient, minEthOut);
    }

    // ──────────────────────────────── Views ────────────────────────────────────

    /// @inheritdoc IPeepsRouter
    function quoteBuy(address token, uint256 ethInGross)
        external
        view
        override
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedEthGross, uint256 refund)
    {
        return IPeepsBondingCurve(_curveOf(token)).quoteBuy(ethInGross);
    }

    /// @inheritdoc IPeepsRouter
    function quoteSell(address token, uint256 tokenAmount)
        external
        view
        override
        returns (uint256 ethOut, uint256 fee)
    {
        return IPeepsBondingCurve(_curveOf(token)).quoteSell(tokenAmount);
    }

    // ─────────────────────────────── Internal ──────────────────────────────────

    /// @dev Shared sell body for `sell` and `sellWithPermit`. Pulls the tokens from the seller
    ///      directly into the curve (SafeERC20 — never parked in the PeepsRouter), then calls
    ///      `curve.sell` forwarding `msg.sender` as `trader`. Reads no pause flag, calls no treasury.
    function _sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut)
        private
        returns (uint256 ethOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        address curve = _curveOf(token);
        IERC20(token).safeTransferFrom(msg.sender, curve, tokenAmount);
        (ethOut,) = IPeepsBondingCurve(curve).sell(msg.sender, recipient, tokenAmount, minEthOut);
    }

    /// @dev Resolve a token's curve or revert {UnknownToken}.
    function _curveOf(address token) private view returns (address curve) {
        curve = factoryContract.curveOf(token);
        if (curve == address(0)) revert UnknownToken();
    }

    /// @dev Best-effort permissionless graduation in the same tx as the cap-crossing buy. If the
    ///      migrator reverts (e.g. pool griefing), the buy still succeeds and sellers can exit
    ///      during `ReadyToGraduate`. Forwards the caller reward to `rewardTo` (the buyer).
    function _tryAutoGraduate(address curve, address rewardTo) private {
        if (IPeepsBondingCurve(curve).phase() != IPeepsBondingCurve.Phase.ReadyToGraduate) return;

        uint256 balBefore = address(this).balance;
        try IPeepsBondingCurve(curve).graduate() {
            uint256 reward = address(this).balance - balBefore;
            if (reward != 0) _sendEth(rewardTo, reward);
        } catch {}
    }

    /// @dev Low-level ETH send with a typed revert (spec §5.4 — custom errors, no revert strings).
    ///      Used only for the creation fee (never on a trade path).
    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    /// @dev Accepts graduation caller rewards forwarded from curves during `_tryAutoGraduate`.
    receive() external payable {}
}
