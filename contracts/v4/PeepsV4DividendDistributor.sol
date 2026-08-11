// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {ZeroAddress, EthTransferFailed, NothingToClaim} from "./errors/PeepsV4Errors.sol";

/// @title PeepsV4DividendDistributor — Flap-style hold + claim dividends
/// @notice Tax dividends accrue to holders by share. Shares auto-update from live wallet
///         balance (setShare / syncShare) — typically after each PEEPS V4 trade. Holders
///         claim manually. Creator wallets are eligible if they hold above minBalance
///         (treasury tax is a separate funds bucket).
/// @dev Magnified dividend-per-share accounting (same family as Flap / DividendPayingToken).
///      Bonding→V4 curve routers may notify/configure when registered as tax notifiers so
///      dividends work before graduate (same claim path).
contract PeepsV4DividendDistributor is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant MAGNITUDE = 2 ** 128;

    IPeepsV4Registry public immutable registry;
    address public immutable weth;
    /// @dev Bonding curve factory — exclude curve/router inventory from dividend shares.
    address public bondingFactory;
    /// @dev Bonding router (and factory) may notify/configure pre-grad tax dividends.
    mapping(address account => bool) public taxNotifier;

    mapping(address launchToken => uint256) public minBalance;
    mapping(address launchToken => uint256) public totalShares;
    mapping(address launchToken => uint256) public magnifiedDividendPerShareWeth;
    mapping(address launchToken => uint256) public magnifiedDividendPerShareMeme;
    mapping(address launchToken => uint256) public pendingWeth;
    mapping(address launchToken => uint256) public pendingMeme;

    mapping(address launchToken => mapping(address account => uint256)) public shares;
    mapping(address launchToken => mapping(address account => int256)) public magnifiedDividendCorrectionsWeth;
    mapping(address launchToken => mapping(address account => int256)) public magnifiedDividendCorrectionsMeme;
    mapping(address launchToken => mapping(address account => uint256)) public withdrawnWeth;
    mapping(address launchToken => mapping(address account => uint256)) public withdrawnMeme;

    error NotHook();
    error NotRegistry();
    error NotAuthorized();

    event TokenConfigured(address indexed launchToken, uint256 minBalance_);
    event ShareUpdated(address indexed launchToken, address indexed account, uint256 newShares);
    event RewardNotified(address indexed launchToken, address indexed currency, uint256 amount);
    event Claimed(
        address indexed launchToken, address indexed account, uint256 wethAmount, uint256 memeAmount
    );
    event TaxNotifierUpdated(address indexed notifier, bool enabled);
    event BondingFactoryUpdated(address indexed bondingFactory);

    constructor(address registry_, address weth_) {
        if (registry_ == address(0) || weth_ == address(0)) revert ZeroAddress();
        registry = IPeepsV4Registry(registry_);
        weth = weth_;
    }

    receive() external payable {}

    function setTaxNotifier(address notifier, bool enabled) external {
        if (msg.sender != address(registry)) revert NotRegistry();
        if (notifier == address(0)) revert ZeroAddress();
        taxNotifier[notifier] = enabled;
        emit TaxNotifierUpdated(notifier, enabled);
    }

    function setBondingFactory(address bondingFactory_) external {
        if (msg.sender != address(registry)) revert NotRegistry();
        bondingFactory = bondingFactory_;
        emit BondingFactoryUpdated(bondingFactory_);
    }

    /// @dev Registry (Instant create) or bonding factory/router (curve create) wires min balance.
    function configureToken(address launchToken, uint256 minBalance_) external {
        if (msg.sender != address(registry) && !taxNotifier[msg.sender]) revert NotAuthorized();
        if (launchToken == address(0)) revert ZeroAddress();
        minBalance[launchToken] = minBalance_;
        emit TokenConfigured(launchToken, minBalance_);
    }

    /// @dev Hook or bonding tax notifier transfers currency here first, then notifies.
    function notifyTaxDividend(address launchToken, address currency, uint256 amount) external {
        if (msg.sender != registry.hook() && !taxNotifier[msg.sender]) revert NotHook();
        if (launchToken == address(0) || amount == 0) return;

        if (currency == weth) {
            _distributeWeth(launchToken, amount);
        } else if (currency == launchToken) {
            _distributeMeme(launchToken, amount);
        } else {
            return;
        }
        emit RewardNotified(launchToken, currency, amount);
    }

    /// @notice Permissionless Flap-style share sync from live `balanceOf`.
    function syncShare(address launchToken, address account) public {
        _setShare(launchToken, account, IERC20(launchToken).balanceOf(account));
    }

    /// @notice Batch sync (e.g. trader + recipient after a swap).
    function syncShares(address launchToken, address account0, address account1) external {
        syncShare(launchToken, account0);
        if (account1 != account0 && account1 != address(0)) {
            syncShare(launchToken, account1);
        }
    }

    function claim(address launchToken) external nonReentrant returns (uint256 wethOut, uint256 memeOut) {
        // Refresh share from live balance first (covers transfers outside our router).
        syncShare(launchToken, msg.sender);

        wethOut = _withdrawableWeth(launchToken, msg.sender);
        memeOut = _withdrawableMeme(launchToken, msg.sender);
        if (wethOut == 0 && memeOut == 0) revert NothingToClaim();

        if (wethOut != 0) {
            withdrawnWeth[launchToken][msg.sender] += wethOut;
            uint256 ethBal = address(this).balance;
            if (ethBal < wethOut) {
                uint256 need = wethOut - ethBal;
                uint256 wethBal = IERC20(weth).balanceOf(address(this));
                if (wethBal > 0) IWETH9(weth).withdraw(need > wethBal ? wethBal : need);
            }
            _sendEth(msg.sender, wethOut);
        }
        if (memeOut != 0) {
            withdrawnMeme[launchToken][msg.sender] += memeOut;
            IERC20(launchToken).safeTransfer(msg.sender, memeOut);
            // Claiming meme rewards changes balance — resync share.
            syncShare(launchToken, msg.sender);
        }

        emit Claimed(launchToken, msg.sender, wethOut, memeOut);
    }

    function withdrawableWeth(address launchToken, address account) external view returns (uint256) {
        return _withdrawableWeth(launchToken, account);
    }

    function withdrawableMeme(address launchToken, address account) external view returns (uint256) {
        return _withdrawableMeme(launchToken, account);
    }

    function _setShare(address launchToken, address account, uint256 newBalance) internal {
        if (_isExcluded(launchToken, account)) return;

        uint256 minBal = minBalance[launchToken];
        uint256 newShares = newBalance >= minBal ? newBalance : 0;
        uint256 oldShares = shares[launchToken][account];
        if (newShares == oldShares) return;

        if (newShares > oldShares) {
            _mintShares(launchToken, account, newShares - oldShares);
        } else {
            _burnShares(launchToken, account, oldShares - newShares);
        }
        emit ShareUpdated(launchToken, account, newShares);
    }

    /// @dev System / inventory addresses must never receive dividend shares.
    function _isExcluded(address, address account) internal view returns (bool) {
        if (account == address(0) || account == address(this) || account == DEAD()) return true;
        if (account == registry.lpFeeVault() || account == registry.hook()) return true;
        if (account == registry.poolManager() || account == registry.positionManager()) return true;
        if (account == address(registry) || account == registry.factory()) return true;
        if (account == weth) return true;
        address bf = bondingFactory;
        if (bf != address(0)) {
            if (account == bf) return true;
            if (account == IPeepsCurveFactory(bf).router()) return true;
            if (IPeepsCurveFactory(bf).isCurve(account)) return true;
        }
        return false;
    }

    function _mintShares(address launchToken, address account, uint256 amount) internal {
        // Settle pending against old share count first (already in corrections).
        totalShares[launchToken] += amount;
        shares[launchToken][account] += amount;
        magnifiedDividendCorrectionsWeth[launchToken][account] -=
            int256(magnifiedDividendPerShareWeth[launchToken] * amount);
        magnifiedDividendCorrectionsMeme[launchToken][account] -=
            int256(magnifiedDividendPerShareMeme[launchToken] * amount);
        _flushPending(launchToken);
    }

    function _burnShares(address launchToken, address account, uint256 amount) internal {
        totalShares[launchToken] -= amount;
        shares[launchToken][account] -= amount;
        magnifiedDividendCorrectionsWeth[launchToken][account] +=
            int256(magnifiedDividendPerShareWeth[launchToken] * amount);
        magnifiedDividendCorrectionsMeme[launchToken][account] +=
            int256(magnifiedDividendPerShareMeme[launchToken] * amount);
    }

    function _distributeWeth(address launchToken, uint256 amount) internal {
        uint256 supply = totalShares[launchToken];
        if (supply == 0) {
            pendingWeth[launchToken] += amount;
            return;
        }
        uint256 total = amount + pendingWeth[launchToken];
        pendingWeth[launchToken] = 0;
        magnifiedDividendPerShareWeth[launchToken] += (total * MAGNITUDE) / supply;
    }

    function _distributeMeme(address launchToken, uint256 amount) internal {
        uint256 supply = totalShares[launchToken];
        if (supply == 0) {
            pendingMeme[launchToken] += amount;
            return;
        }
        uint256 total = amount + pendingMeme[launchToken];
        pendingMeme[launchToken] = 0;
        magnifiedDividendPerShareMeme[launchToken] += (total * MAGNITUDE) / supply;
    }

    function _flushPending(address launchToken) internal {
        uint256 supply = totalShares[launchToken];
        if (supply == 0) return;
        uint256 pw = pendingWeth[launchToken];
        if (pw != 0) {
            pendingWeth[launchToken] = 0;
            magnifiedDividendPerShareWeth[launchToken] += (pw * MAGNITUDE) / supply;
        }
        uint256 pm = pendingMeme[launchToken];
        if (pm != 0) {
            pendingMeme[launchToken] = 0;
            magnifiedDividendPerShareMeme[launchToken] += (pm * MAGNITUDE) / supply;
        }
    }

    function _withdrawableWeth(address launchToken, address account) internal view returns (uint256) {
        uint256 total = _accumulativeWeth(launchToken, account);
        uint256 withdrawn = withdrawnWeth[launchToken][account];
        return total > withdrawn ? total - withdrawn : 0;
    }

    function _withdrawableMeme(address launchToken, address account) internal view returns (uint256) {
        uint256 total = _accumulativeMeme(launchToken, account);
        uint256 withdrawn = withdrawnMeme[launchToken][account];
        return total > withdrawn ? total - withdrawn : 0;
    }

    function _accumulativeWeth(address launchToken, address account) internal view returns (uint256) {
        uint256 share = shares[launchToken][account];
        int256 accumulated = int256(magnifiedDividendPerShareWeth[launchToken] * share)
            + magnifiedDividendCorrectionsWeth[launchToken][account];
        if (accumulated <= 0) return 0;
        return uint256(accumulated) / MAGNITUDE;
    }

    function _accumulativeMeme(address launchToken, address account) internal view returns (uint256) {
        uint256 share = shares[launchToken][account];
        int256 accumulated = int256(magnifiedDividendPerShareMeme[launchToken] * share)
            + magnifiedDividendCorrectionsMeme[launchToken][account];
        if (accumulated <= 0) return 0;
        return uint256(accumulated) / MAGNITUDE;
    }

    function DEAD() internal pure returns (address) {
        return 0x000000000000000000000000000000000000dEaD;
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }
}
