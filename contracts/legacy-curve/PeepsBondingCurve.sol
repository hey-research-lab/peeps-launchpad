// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPeepsBondingCurve} from "./interfaces/IPeepsBondingCurve.sol";
import {IPeepsCurveFactory} from "./interfaces/IPeepsCurveFactory.sol";
import {IPeepsV3Migrator} from "./interfaces/IPeepsV3Migrator.sol";
import {PeepsCurveMath} from "./libs/PeepsCurveMath.sol";

import {
    NotPeepsRouter,
    NotCreator,
    NotTrading,
    NotReady,
    NotGraduated,
    ZeroAmount,
    SlippageExceeded,
    EarlyBuyCapExceeded,
    PerTokenCapExceeded,
    EthTransferFailed,
    NothingToClaim,
    InvalidMsgValue
} from "./errors/PeepsErrors.sol";

/// @title PeepsBondingCurve — virtual-reserve CPAMM with creator / protocol / furnace fee split
/// @notice Every trade accrues fees in-contract (pull model). Creator 1.00%, protocol 0.40%,
///         furnace 0.10% (1.50% total). The furnace slice buys the launched token from the curve
///         and sends it to `0xdead` via `executeFurnaceBurn()` — a per-token deflation flywheel.
contract PeepsBondingCurve is IPeepsBondingCurve, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 private constant BPS_DENOMINATOR = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable factory;
    address public immutable router;
    address public immutable migrator;

    address public immutable override token;
    address public immutable override creator;
    address public immutable override feeRecipient;
    address public immutable override protocolTreasury;

    uint256 public immutable override VIRTUAL_ETH_0;
    uint256 public immutable override VIRTUAL_TOKEN_0;
    uint256 public immutable override CURVE_SUPPLY;
    uint256 public immutable override LP_TOKEN_TRANCHE;
    uint256 public immutable override GRADUATION_ETH;
    uint16 public immutable override TRADE_FEE_BPS;
    uint16 public immutable override CREATOR_FEE_BPS;
    uint16 public immutable override PROTOCOL_FEE_BPS;
    uint16 public immutable override FURNACE_FEE_BPS;
    uint16 public immutable override postGradCreatorShareBps;
    uint256 public immutable override GRADUATION_FEE;
    uint256 public immutable override CALLER_REWARD;
    uint64 public immutable override EARLY_WINDOW_END;
    uint128 public immutable override MAX_EARLY_BUY;
    uint64 public immutable override createdAt;

    uint256 internal _virtualEthReserves;
    uint256 internal _virtualTokenReserves;
    uint256 internal _realEthReserves;
    uint256 internal _realTokenReserves;

    uint256 public override accruedProtocolFees;
    uint256 public override accruedFurnaceFees;
    uint256 public override accruedCreatorFees;
    uint256 public override totalFurnaceBurned;
    Phase public override phase;

    constructor() {
        factory = msg.sender;
        IPeepsCurveFactory.CurveParameters memory p = IPeepsCurveFactory(msg.sender).curveParameters();

        token = p.token;
        router = p.router;
        migrator = p.migrator;
        creator = p.creator;
        feeRecipient = p.feeRecipient;
        protocolTreasury = IPeepsCurveFactory(msg.sender).treasury();

        VIRTUAL_ETH_0 = p.virtualEth0;
        VIRTUAL_TOKEN_0 = p.virtualToken0;
        CURVE_SUPPLY = p.curveSupply;
        LP_TOKEN_TRANCHE = p.lpTranche;
        GRADUATION_ETH = p.graduationEth;
        TRADE_FEE_BPS = p.tradeFeeBps;
        CREATOR_FEE_BPS = p.creatorFeeBps;
        PROTOCOL_FEE_BPS = p.protocolFeeBps;
        FURNACE_FEE_BPS = p.furnaceFeeBps;
        postGradCreatorShareBps = p.postGradCreatorShareBps;
        GRADUATION_FEE = p.graduationFee;
        CALLER_REWARD = p.callerReward;

        uint64 nowTs = uint64(block.timestamp);
        createdAt = nowTs;
        if (p.antiSnipeEnabled) {
            EARLY_WINDOW_END = nowTs + p.earlyWindowSeconds;
            MAX_EARLY_BUY = p.maxEarlyBuyWei;
        } else {
            EARLY_WINDOW_END = 0;
            MAX_EARLY_BUY = type(uint128).max;
        }

        _virtualEthReserves = p.virtualEth0;
        _virtualTokenReserves = p.virtualToken0;
        _realTokenReserves = p.curveSupply;
        phase = Phase.Trading;
    }

    function buy(address trader, address recipient, address refundTo, uint256 minTokensOut)
        external
        payable
        override
        nonReentrant
        returns (uint256 tokensOut, uint256 acceptedEthGross, uint256 fee)
    {
        if (msg.sender != router) revert NotPeepsRouter();
        if (phase != Phase.Trading) revert NotTrading();
        uint256 grossIn = msg.value;
        if (grossIn == 0) revert ZeroAmount();

        if (EARLY_WINDOW_END != 0 && block.timestamp < EARLY_WINDOW_END && trader != creator && grossIn > MAX_EARLY_BUY) {
            revert EarlyBuyCapExceeded(grossIn, MAX_EARLY_BUY);
        }

        uint16 bps = TRADE_FEE_BPS;
        fee = (grossIn * bps) / BPS_DENOMINATOR;
        uint256 net = grossIn - fee;

        uint256 remaining = GRADUATION_ETH - _realEthReserves;
        uint256 refund;
        if (net > remaining) {
            net = remaining;
            acceptedEthGross = Math.ceilDiv(net * BPS_DENOMINATOR, BPS_DENOMINATOR - bps);
            fee = acceptedEthGross - net;
            refund = grossIn - acceptedEthGross;
        } else {
            acceptedEthGross = grossIn;
        }

        uint256 newRealEth = _realEthReserves + net;
        if (newRealEth > IPeepsCurveFactory(factory).perTokenEthCap()) revert PerTokenCapExceeded();
        IPeepsCurveFactory(factory).recordEthDelta(int256(net));

        tokensOut = PeepsCurveMath.buyTokensOut(_virtualEthReserves, _virtualTokenReserves, net);
        uint256 realTok = _realTokenReserves;
        if (tokensOut > realTok) tokensOut = realTok;
        if (tokensOut < minTokensOut) revert SlippageExceeded(tokensOut, minTokensOut);

        _virtualEthReserves += net;
        _virtualTokenReserves -= tokensOut;
        _realEthReserves = newRealEth;
        _realTokenReserves = realTok - tokensOut;
        _accrueFees(acceptedEthGross);
        bool crossed = newRealEth == GRADUATION_ETH;
        if (crossed) phase = Phase.ReadyToGraduate;

        if (refund != 0) _sendEth(refundTo, refund);
        IERC20(token).safeTransfer(recipient, tokensOut);

        emit Trade(
            trader, true, acceptedEthGross, tokensOut, fee, _virtualEthReserves, _virtualTokenReserves, _realEthReserves
        );
        if (crossed) emit GraduationReady(_realEthReserves);
    }

    function sell(address trader, address recipient, uint256 tokenAmount, uint256 minEthOut)
        external
        override
        nonReentrant
        returns (uint256 ethOut, uint256 fee)
    {
        if (msg.sender != router) revert NotPeepsRouter();
        if (phase != Phase.Trading && phase != Phase.ReadyToGraduate) revert NotTrading();
        if (tokenAmount == 0) revert ZeroAmount();

        uint256 ethOutGross = PeepsCurveMath.sellEthOut(_virtualEthReserves, _virtualTokenReserves, tokenAmount);
        fee = (ethOutGross * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        ethOut = ethOutGross - fee;
        if (ethOut < minEthOut) revert SlippageExceeded(ethOut, minEthOut);

        _virtualTokenReserves += tokenAmount;
        _virtualEthReserves -= ethOutGross;
        _realTokenReserves += tokenAmount;
        _realEthReserves -= ethOutGross;
        _accrueFees(ethOutGross);
        IPeepsCurveFactory(factory).recordEthDelta(-int256(ethOutGross));
        _syncPhaseAfterSell();
        _sendEth(recipient, ethOut);

        emit Trade(
            trader, false, ethOutGross, tokenAmount, fee, _virtualEthReserves, _virtualTokenReserves, _realEthReserves
        );
    }

    function sweepProtocolFees() external override nonReentrant returns (uint256 swept) {
        swept = accruedProtocolFees;
        if (swept == 0) revert NothingToClaim();
        accruedProtocolFees = 0;
        // New bonding stacks set treasury = PeepsBondingFeeSink (wraps WETH → fee router + referrals).
        // Legacy EOA/treasury contracts fall back to a plain ETH transfer.
        (bool ok,) = protocolTreasury.call{value: swept}(
            abi.encodeWithSignature("onCurveProtocolFees(address,uint256)", token, swept)
        );
        if (!ok) _sendEth(protocolTreasury, swept);
        emit FeesSwept(protocolTreasury, swept);
    }

    function executeFurnaceBurn(uint256 minTokensOut) external override nonReentrant returns (uint256 tokensBurned) {
        if (phase == Phase.Graduated) revert NotTrading();
        uint256 ethBudget = accruedFurnaceFees;
        if (ethBudget == 0) revert NothingToClaim();
        tokensBurned = _burnFurnaceAccrual(minTokensOut);
    }

    function _burnFurnaceAccrual(uint256 minTokensOut) internal returns (uint256 tokensBurned) {
        uint256 accrued = accruedFurnaceFees;
        if (accrued == 0) return 0;

        uint256 ethBudget = accrued;
        if (phase == Phase.Trading) {
            uint256 remaining = GRADUATION_ETH - _realEthReserves;
            if (ethBudget > remaining) ethBudget = remaining;
            if (ethBudget == 0) return 0;
        } else if (phase != Phase.ReadyToGraduate) {
            return 0;
        }

        accruedFurnaceFees = accrued - ethBudget;

        tokensBurned = PeepsCurveMath.buyTokensOut(_virtualEthReserves, _virtualTokenReserves, ethBudget);
        uint256 realTok = _realTokenReserves;
        if (tokensBurned > realTok) tokensBurned = realTok;
        if (tokensBurned < minTokensOut) revert SlippageExceeded(tokensBurned, minTokensOut);

        _virtualEthReserves += ethBudget;
        _virtualTokenReserves -= tokensBurned;
        _realTokenReserves = realTok - tokensBurned;

        if (phase == Phase.Trading) {
            _realEthReserves += ethBudget;
            IPeepsCurveFactory(factory).recordEthDelta(int256(ethBudget));
            if (_realEthReserves == GRADUATION_ETH) phase = Phase.ReadyToGraduate;
        }

        IERC20(token).safeTransfer(DEAD, tokensBurned);
        totalFurnaceBurned += tokensBurned;
        emit FurnaceBurned(ethBudget, tokensBurned);
    }

    function claimCreatorFees() external override nonReentrant returns (uint256 claimed) {
        if (msg.sender != feeRecipient) revert NotCreator();
        claimed = accruedCreatorFees;
        if (claimed == 0) revert NothingToClaim();
        accruedCreatorFees = 0;
        _sendEth(feeRecipient, claimed);
        emit CreatorFeesClaimed(feeRecipient, claimed);
    }

    function sweepFees() external returns (uint256 swept) {
        return this.sweepProtocolFees();
    }

    function accruedFees() external view returns (uint256) {
        return accruedProtocolFees;
    }

    function graduate() external override nonReentrant {
        if (phase != Phase.ReadyToGraduate) revert NotReady();

        _burnFurnaceAccrual(0);

        uint256 gradEth = _realEthReserves;
        phase = Phase.Graduated;
        _realEthReserves = 0;
        _realTokenReserves = 0;
        IPeepsCurveFactory(factory).recordEthDelta(-int256(gradEth));

        _sendEth(msg.sender, CALLER_REWARD);

        IERC20 t = IERC20(token);
        t.safeTransfer(migrator, t.balanceOf(address(this)));

        uint256 reserved = accruedProtocolFees + accruedFurnaceFees + accruedCreatorFees;
        uint256 ethForMigrator = address(this).balance - reserved;
        IPeepsV3Migrator(migrator).migrate{value: ethForMigrator}(token);
    }

    function quoteBuy(uint256 ethInGross)
        external
        view
        override
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedEthGross, uint256 refund)
    {
        if (phase != Phase.Trading || ethInGross == 0) return (0, 0, 0, 0);
        uint16 bps = TRADE_FEE_BPS;
        fee = (ethInGross * bps) / BPS_DENOMINATOR;
        uint256 net = ethInGross - fee;
        uint256 remaining = GRADUATION_ETH - _realEthReserves;
        if (net > remaining) {
            net = remaining;
            acceptedEthGross = Math.ceilDiv(net * BPS_DENOMINATOR, BPS_DENOMINATOR - bps);
            fee = acceptedEthGross - net;
            refund = ethInGross - acceptedEthGross;
        } else {
            acceptedEthGross = ethInGross;
        }
        tokensOut = PeepsCurveMath.buyTokensOut(_virtualEthReserves, _virtualTokenReserves, net);
        uint256 realTok = _realTokenReserves;
        if (tokensOut > realTok) tokensOut = realTok;
    }

    function quoteSell(uint256 tokenAmount) external view override returns (uint256 ethOut, uint256 fee) {
        if ((phase != Phase.Trading && phase != Phase.ReadyToGraduate) || tokenAmount == 0) return (0, 0);
        uint256 gross = PeepsCurveMath.sellEthOut(_virtualEthReserves, _virtualTokenReserves, tokenAmount);
        fee = (gross * TRADE_FEE_BPS) / BPS_DENOMINATOR;
        ethOut = gross - fee;
    }

    function reserves()
        external
        view
        override
        returns (uint256 virtualEth, uint256 virtualToken, uint256 realEth, uint256 realToken)
    {
        return (_virtualEthReserves, _virtualTokenReserves, _realEthReserves, _realTokenReserves);
    }

    function graduationProgressBps() external view override returns (uint256) {
        if (GRADUATION_ETH == 0) return 0;
        return _realEthReserves >= GRADUATION_ETH ? 10_000 : (_realEthReserves * 10_000) / GRADUATION_ETH;
    }

    function _accrueFees(uint256 grossAmount) internal {
        accruedCreatorFees += (grossAmount * CREATOR_FEE_BPS) / BPS_DENOMINATOR;
        accruedProtocolFees += (grossAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        accruedFurnaceFees += (grossAmount * FURNACE_FEE_BPS) / BPS_DENOMINATOR;
    }

    /// @dev If a sell during `ReadyToGraduate` pulls real ETH below the cap, reopen Trading so
    ///      holders are never stranded while graduation is pending.
    function _syncPhaseAfterSell() internal {
        if (phase == Phase.ReadyToGraduate && _realEthReserves < GRADUATION_ETH) {
            phase = Phase.Trading;
        }
    }

    function _sendEth(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    receive() external payable {}
}
