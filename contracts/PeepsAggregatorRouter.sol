// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsAggregatorRouter} from "./interfaces/IPeepsAggregatorRouter.sol";
import {ISwapRouter02} from "./interfaces/external/ISwapRouter02.sol";
import {IQuoterV2} from "./interfaces/external/IQuoterV2.sol";
import {IUniswapV3Factory} from "./interfaces/external/IUniswapV3Factory.sol";
import {IUniswapV2Router02} from "./interfaces/external/IUniswapV2Router02.sol";
import {IFlapPortal} from "./interfaces/external/IFlapPortal.sol";
import {IBowZap} from "./interfaces/external/IBowZap.sol";
import {IWETH9} from "./interfaces/external/IWETH9.sol";

import {
    InvalidMsgValue,
    DeadlineExpired,
    ZeroAddress,
    EthTransferFailed
} from "src/legacy-curve/errors/PeepsErrors.sol";
import {PeepsGraduatedSwapFees} from "./libs/PeepsGraduatedSwapFees.sol";

/// @dev No Uniswap pool for the given token / fee tier.
error AggregatorPoolNotFound();
error NothingToClaim();

/// @notice Optional on-chain trader→referrer lookup (e.g. PeepsProtocolFeeRouter).
interface IPeepsTraderReferralLookup {
    function traderReferrer(address trader) external view returns (address);
}

/// @notice Instant V4 execution engine (no platform fee — fee taken by this aggregator).
interface IPeepsV4SwapRouterExec {
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);

    function sellFor(
        address trader,
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) external returns (uint256 ethOut);

    function quoteBuy(address token, uint256 ethInNet) external returns (uint256 tokensOut, uint256 fee);

    function quoteSell(address token, uint256 tokenAmount) external returns (uint256 ethOut, uint256 fee);
}

/// @title PeepsAggregatorRouter — 0.25% fee on all external RH venue trade paths.
/// @notice Paths: Uni V3 (bow/pons), Uni V2 (flap post-grad), Flap Portal (pre-grad curve),
///         BowZap buy (bow), Peeps Instant V4. Fee is native ETH: with a bound referrer, 0.05%
///         accrues to referrer (pull-claim) and 0.20% to `platformSwapFeeWallet`; otherwise 0.25% platform.
/// @dev Venue addresses + fee wallet + referral lookup are immutable.
contract PeepsAggregatorRouter is IPeepsAggregatorRouter, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 internal constant DEX_V3 = 1;
    uint8 internal constant DEX_V2 = 2;
    uint8 internal constant DEX_FLAP = 3;
    uint8 internal constant DEX_BOW_ZAP = 4;
    uint8 internal constant DEX_V4 = 5;

    ISwapRouter02 internal immutable _v3SwapRouter;
    IQuoterV2 public immutable quoter;
    IUniswapV3Factory public immutable v3Factory;
    IUniswapV2Router02 internal immutable _v2Router;
    IFlapPortal internal immutable _flapPortal;
    IBowZap internal immutable _bowZap;
    IPeepsV4SwapRouterExec internal immutable _v4SwapRouter;
    address public immutable override weth;
    address public immutable override platformSwapFeeWallet;
    /// @dev Zero disables referral splits (100% of fee → platform).
    address public immutable referralLookup;

    mapping(address account => uint256 amount) public claimableReferralEth;
    /// @dev ETH reserved for referral claims (must not be skimmed).
    uint256 public reservedReferralEth;

    constructor(
        address v3SwapRouter_,
        address quoter_,
        address v3Factory_,
        address v2Router_,
        address flapPortal_,
        address bowZap_,
        address weth_,
        address platformSwapFeeWallet_,
        address referralLookup_,
        address v4SwapRouter_
    ) {
        if (
            v3SwapRouter_ == address(0) || quoter_ == address(0) || v3Factory_ == address(0)
                || v2Router_ == address(0) || flapPortal_ == address(0) || bowZap_ == address(0)
                || weth_ == address(0) || platformSwapFeeWallet_ == address(0)
        ) {
            revert ZeroAddress();
        }
        _v3SwapRouter = ISwapRouter02(v3SwapRouter_);
        quoter = IQuoterV2(quoter_);
        v3Factory = IUniswapV3Factory(v3Factory_);
        _v2Router = IUniswapV2Router02(v2Router_);
        _flapPortal = IFlapPortal(flapPortal_);
        _bowZap = IBowZap(bowZap_);
        _v4SwapRouter = IPeepsV4SwapRouterExec(v4SwapRouter_);
        weth = weth_;
        platformSwapFeeWallet = platformSwapFeeWallet_;
        referralLookup = referralLookup_;
    }

    function v3SwapRouter() external view override returns (address) {
        return address(_v3SwapRouter);
    }

    function v2Router() external view override returns (address) {
        return address(_v2Router);
    }

    function flapPortal() external view override returns (address) {
        return address(_flapPortal);
    }

    function bowZap() external view override returns (address) {
        return address(_bowZap);
    }

    function v4SwapRouter() external view override returns (address) {
        return address(_v4SwapRouter);
    }

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    function _requireV4Router() internal view {
        if (address(_v4SwapRouter) == address(0)) revert ZeroAddress();
    }

    // ─── Uniswap V3 (bow / pons) ─────────────────────────────────────────────

    /// @inheritdoc IPeepsAggregatorRouter
    function buyV3(
        address token,
        uint24 poolFee,
        address recipient,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();
        _requireV3Pool(token, poolFee);

        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, true, DEX_V3);

        IWETH9(weth).deposit{value: net}();
        IERC20(weth).forceApprove(address(_v3SwapRouter), net);

        tokensOut = _v3SwapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                fee: poolFee,
                recipient: recipient,
                amountIn: net,
                amountOutMinimum: minTokensOut,
                sqrtPriceLimitX96: 0
            })
        );

        _clearApprove(weth, address(_v3SwapRouter));
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function sellV3(
        address token,
        uint24 poolFee,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) external override nonReentrant checkDeadline(deadline) returns (uint256 ethOut) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();
        _requireV3Pool(token, poolFee);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(_v3SwapRouter), tokenAmount);

        // Delta accounting — do not treat donated/stray ETH as swap proceeds.
        uint256 beforeEth = address(this).balance;

        bytes memory swapData = abi.encodeWithSelector(
            ISwapRouter02.exactInputSingle.selector,
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                fee: poolFee,
                recipient: address(_v3SwapRouter),
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
        _v3SwapRouter.multicall(calls);

        uint256 grossEth = address(this).balance - beforeEth;
        uint256 fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
        if (ethOut < minEthOut) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, false, DEX_V3);
        _sendEth(recipient, ethOut);

        _clearApprove(token, address(_v3SwapRouter));
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteBuyV3(address token, uint24 poolFee, uint256 ethInGross)
        external
        override
        returns (uint256 tokensOut, uint256 fee)
    {
        _requireV3Pool(token, poolFee);
        if (ethInGross == 0) return (0, 0);
        fee = _feeAmount(ethInGross);
        uint256 net = ethInGross - fee;
        if (net == 0) return (0, fee);
        (tokensOut,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: weth,
                tokenOut: token,
                amountIn: net,
                fee: poolFee,
                sqrtPriceLimitX96: 0
            })
        );
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteSellV3(address token, uint24 poolFee, uint256 tokenAmount)
        external
        override
        returns (uint256 ethOut, uint256 fee)
    {
        _requireV3Pool(token, poolFee);
        if (tokenAmount == 0) return (0, 0);
        (uint256 grossEth,,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams({
                tokenIn: token,
                tokenOut: weth,
                amountIn: tokenAmount,
                fee: poolFee,
                sqrtPriceLimitX96: 0
            })
        );
        fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
    }

    // ─── Uniswap V2 (flap post-grad) ─────────────────────────────────────────

    /// @inheritdoc IPeepsAggregatorRouter
    function buyV2(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();

        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, true, DEX_V2);

        uint256 beforeBal = IERC20(token).balanceOf(recipient);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = token;
        _v2Router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: net}(
            minTokensOut, path, recipient, deadline
        );
        tokensOut = IERC20(token).balanceOf(recipient) - beforeBal;
        if (tokensOut < minTokensOut) revert InvalidMsgValue();

        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function sellV2(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) external override nonReentrant checkDeadline(deadline) returns (uint256 ethOut) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(_v2Router), tokenAmount);

        uint256 beforeEth = address(this).balance;
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = weth;
        _v2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), deadline
        );

        uint256 grossEth = address(this).balance - beforeEth;
        uint256 fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
        if (ethOut < minEthOut) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, false, DEX_V2);
        _sendEth(recipient, ethOut);

        _clearApprove(token, address(_v2Router));
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteBuyV2(address token, uint256 ethInGross)
        external
        view
        override
        returns (uint256 tokensOut, uint256 fee)
    {
        if (ethInGross == 0) return (0, 0);
        fee = _feeAmount(ethInGross);
        uint256 net = ethInGross - fee;
        if (net == 0) return (0, fee);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = token;
        uint256[] memory amounts = _v2Router.getAmountsOut(net, path);
        tokensOut = amounts[1];
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteSellV2(address token, uint256 tokenAmount)
        external
        view
        override
        returns (uint256 ethOut, uint256 fee)
    {
        if (tokenAmount == 0) return (0, 0);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = weth;
        uint256[] memory amounts = _v2Router.getAmountsOut(tokenAmount, path);
        uint256 grossEth = amounts[1];
        fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
    }

    // ─── Flap Portal (pre-grad bonding curve) ────────────────────────────────

    /// @inheritdoc IPeepsAggregatorRouter
    function buyFlap(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();

        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, true, DEX_FLAP);

        // Portal credits `msg.sender` (this contract) — forward to user.
        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        tokensOut = _flapPortal.swapExactInput{value: net}(
            IFlapPortal.ExactInputParams({
                inputToken: address(0),
                outputToken: token,
                inputAmount: net,
                minOutputAmount: minTokensOut,
                permitData: ""
            })
        );
        uint256 got = IERC20(token).balanceOf(address(this)) - beforeBal;
        if (got < tokensOut) tokensOut = got;
        if (tokensOut < minTokensOut) revert InvalidMsgValue();
        IERC20(token).safeTransfer(recipient, tokensOut);

        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function sellFlap(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) external override nonReentrant checkDeadline(deadline) returns (uint256 ethOut) {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(_flapPortal), tokenAmount);

        uint256 beforeEth = address(this).balance;
        uint256 grossFromPortal = _flapPortal.swapExactInput(
            IFlapPortal.ExactInputParams({
                inputToken: token,
                outputToken: address(0),
                inputAmount: tokenAmount,
                minOutputAmount: 0,
                permitData: ""
            })
        );
        uint256 grossEth = address(this).balance - beforeEth;
        if (grossEth < grossFromPortal) grossEth = grossFromPortal;

        uint256 fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
        if (ethOut < minEthOut) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, false, DEX_FLAP);
        _sendEth(recipient, ethOut);

        _clearApprove(token, address(_flapPortal));
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteBuyFlap(address token, uint256 ethInGross)
        external
        override
        returns (uint256 tokensOut, uint256 fee)
    {
        if (ethInGross == 0) return (0, 0);
        fee = _feeAmount(ethInGross);
        uint256 net = ethInGross - fee;
        if (net == 0) return (0, fee);
        tokensOut = _flapPortal.quoteExactInput(
            IFlapPortal.QuoteExactInputParams({
                inputToken: address(0), outputToken: token, inputAmount: net
            })
        );
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteSellFlap(address token, uint256 tokenAmount)
        external
        override
        returns (uint256 ethOut, uint256 fee)
    {
        if (tokenAmount == 0) return (0, 0);
        uint256 grossEth = _flapPortal.quoteExactInput(
            IFlapPortal.QuoteExactInputParams({
                inputToken: token, outputToken: address(0), inputAmount: tokenAmount
            })
        );
        fee = _feeAmount(grossEth);
        ethOut = grossEth - fee;
    }

    // ─── BowZap (bow buys; sells stay on sellV3) ─────────────────────────────

    /// @inheritdoc IPeepsAggregatorRouter
    function buyBowZap(
        address token,
        uint24 poolFee,
        address recipient,
        uint256 minTokensOut,
        uint256 deadline
    )
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();

        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, true, DEX_BOW_ZAP);

        uint256 beforeBal = IERC20(token).balanceOf(address(this));
        tokensOut = _bowZap.buy{value: net}(token, poolFee, minTokensOut);
        uint256 got = IERC20(token).balanceOf(address(this)) - beforeBal;
        if (got < tokensOut) tokensOut = got;
        if (tokensOut < minTokensOut) revert InvalidMsgValue();
        IERC20(token).safeTransfer(recipient, tokensOut);

        _sweepResiduals(token);
    }

    // ─── Peeps Instant V4 ────────────────────────────────────────────────────

    /// @inheritdoc IPeepsAggregatorRouter
    function buyV4(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        _requireV4Router();
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();

        uint256 fee = _feeAmount(msg.value);
        uint256 net = msg.value - fee;
        if (net == 0) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, true, DEX_V4);

        tokensOut = _v4SwapRouter.buy{value: net}(token, recipient, minTokensOut, deadline);
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function sellV4(
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    )
        external
        override
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        _requireV4Router();
        if (recipient == address(0) || token == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);
        IERC20(token).forceApprove(address(_v4SwapRouter), tokenAmount);

        uint256 gross = _v4SwapRouter.sellFor(
            msg.sender, token, tokenAmount, address(this), 0, deadline
        );
        _clearApprove(token, address(_v4SwapRouter));

        uint256 fee = _feeAmount(gross);
        ethOut = gross - fee;
        if (ethOut < minEthOut) revert InvalidMsgValue();

        _routePlatformFee(fee);
        emit AggregatorFeePaid(token, msg.sender, fee, false, DEX_V4);
        _sendEth(recipient, ethOut);
        _sweepResiduals(token);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteBuyV4(address token, uint256 ethInGross)
        external
        override
        returns (uint256 tokensOut, uint256 fee)
    {
        _requireV4Router();
        if (ethInGross == 0) return (0, 0);
        fee = _feeAmount(ethInGross);
        uint256 net = ethInGross - fee;
        if (net == 0) return (0, fee);
        (tokensOut,) = _v4SwapRouter.quoteBuy(token, net);
    }

    /// @inheritdoc IPeepsAggregatorRouter
    function quoteSellV4(address token, uint256 tokenAmount)
        external
        override
        returns (uint256 ethOut, uint256 fee)
    {
        _requireV4Router();
        if (tokenAmount == 0) return (0, 0);
        (uint256 gross,) = _v4SwapRouter.quoteSell(token, tokenAmount);
        fee = _feeAmount(gross);
        ethOut = gross - fee;
    }

    /// @inheritdoc IPeepsAggregatorRouter
    /// @dev Permissionless — anyone can forward stuck ETH (`token == 0`) or ERC20 dust to the fee wallet.
    ///      ETH skim never touches `reservedReferralEth`.
    function skim(address token) external override nonReentrant {
        _skimToFee(token);
    }

    /// @notice Pull-claim accrued referral ETH (0.05% of referred traders' Peeps-routed swaps).
    function claimReferralEth() external nonReentrant returns (uint256 amount) {
        amount = claimableReferralEth[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableReferralEth[msg.sender] = 0;
        reservedReferralEth -= amount;
        _sendEth(msg.sender, amount);
        emit AggregatorReferralFeeClaimed(msg.sender, amount);
    }

    receive() external payable {}

    function _requireV3Pool(address token, uint24 poolFee) internal view {
        address pool = v3Factory.getPool(token, weth, poolFee);
        if (pool == address(0)) {
            pool = v3Factory.getPool(weth, token, poolFee);
        }
        if (pool == address(0)) revert AggregatorPoolNotFound();
    }

    function _feeAmount(uint256 gross) internal pure returns (uint256) {
        return PeepsGraduatedSwapFees.feeAmount(gross);
    }

    function _routePlatformFee(uint256 feeTotal) internal {
        if (feeTotal == 0) return;

        address ref;
        if (referralLookup != address(0)) {
            try IPeepsTraderReferralLookup(referralLookup).traderReferrer(msg.sender) returns (address r)
            {
                ref = r;
            } catch {
                ref = address(0);
            }
        }

        if (ref == address(0) || ref == msg.sender) {
            _sendEth(platformSwapFeeWallet, feeTotal);
            return;
        }

        uint256 refFee = PeepsGraduatedSwapFees.referralShareOfFee(feeTotal);
        uint256 platFee = feeTotal - refFee;
        if (refFee != 0) {
            claimableReferralEth[ref] += refFee;
            reservedReferralEth += refFee;
            emit AggregatorReferralFeeAccrued(ref, msg.sender, refFee);
        }
        if (platFee != 0) _sendEth(platformSwapFeeWallet, platFee);
    }

    function _sendEth(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _clearApprove(address token, address spender) internal {
        IERC20(token).forceApprove(spender, 0);
    }

    /// @dev After a trade: push leftover trade-token / WETH / ETH to the fee wallet.
    function _sweepResiduals(address tradeToken) internal {
        if (tradeToken != address(0)) _skimToFee(tradeToken);
        if (tradeToken != weth) _skimToFee(weth);
        _skimToFee(address(0));
    }

    function _skimToFee(address token) internal {
        if (token == address(0)) {
            uint256 ethBal = address(this).balance;
            uint256 free = ethBal - reservedReferralEth;
            if (free == 0) return;
            _sendEth(platformSwapFeeWallet, free);
            emit DustSkimmed(address(0), free);
            return;
        }
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) return;
        IERC20(token).safeTransfer(platformSwapFeeWallet, bal);
        emit DustSkimmed(token, bal);
    }
}
