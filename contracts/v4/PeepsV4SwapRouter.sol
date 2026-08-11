// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {IWETH9} from "../interfaces/external/IWETH9.sol";
import {
    Currency,
    PoolKey,
    SwapParams,
    IPoolManager,
    IUnlockCallback,
    DYNAMIC_FEE_FLAG,
    MIN_SQRT_RATIO,
    MAX_SQRT_RATIO
} from "./interfaces/external/IUniswapV4.sol";
import {
    UnknownToken,
    InvalidMsgValue,
    DeadlineExpired,
    ZeroAddress,
    EthTransferFailed,
    NotSeeded,
    LaunchBlockBuyBlocked,
    MaxWalletExceeded,
    MaxTxExceeded
} from "./errors/PeepsV4Errors.sol";

/// @title PeepsV4SwapRouter — Instant V4 tax-token execution via PoolManager
/// @notice Platform fee + trader referral are taken by `PeepsAggregatorRouter` (Instant V3 parity).
///         This contract is the V4 execution engine (like SwapRouter02 under aggregator buyV3).
contract PeepsV4SwapRouter is IUnlockCallback, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint24 internal constant POOL_FEE = DYNAMIC_FEE_FLAG;
    int24 internal constant TICK_SPACING = 200;

    IPeepsV4Factory public immutable factoryContract;
    IPoolManager public immutable poolManager;
    IPeepsV4Registry public immutable v4Registry;
    address public immutable weth;

    error NotPoolManager();
    error QuoteResult(uint256 amountOut);
    error BadSwapDelta();
    error ClearingCommitFailed();

    event GraduatedSwap(
        address indexed token,
        address indexed trader,
        bool isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 platformFee
    );

    struct UnlockPayload {
        address token;
        address recipient;
        uint256 amountIn;
        uint256 minAmountOut;
        bool zeroForOne; // true = sell currency0
        bool isQuote;
        bool inputIsWeth;
    }

    constructor(
        IPeepsV4Factory factory_,
        address poolManager_,
        address v4Registry_,
        address weth_,
        address /* platformSwapFeeWallet_ — kept for deploy ABI stability; unused */
    ) {
        if (
            address(factory_) == address(0) || poolManager_ == address(0) || v4Registry_ == address(0)
                || weth_ == address(0)
        ) {
            revert ZeroAddress();
        }
        factoryContract = factory_;
        poolManager = IPoolManager(poolManager_);
        v4Registry = IPeepsV4Registry(v4Registry_);
        weth = weth_;
    }

    receive() external payable {}

    modifier checkDeadline(uint256 deadline) {
        if (block.timestamp > deadline) revert DeadlineExpired();
        _;
    }

    function factory() external view returns (address) {
        return address(factoryContract);
    }

    /// @notice ETH → token. `recipient` is attributed as trader in `GraduatedSwap`.
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 tokensOut)
    {
        if (recipient == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert InvalidMsgValue();
        _requireGraduated(token);

        // Uniform clearing window: commit ETH for later pro-rata settle (same price for all).
        if (v4Registry.clearingActive(token)) {
            address house = v4Registry.clearingHouse();
            if (house == address(0)) revert ZeroAddress();
            (bool ok,) = house.call{value: msg.value}(
                abi.encodeWithSignature("commit(address,address)", token, recipient)
            );
            if (!ok) revert ClearingCommitFailed();
            emit GraduatedSwap(token, recipient, true, msg.value, 0, 0);
            return 0;
        }

        IWETH9(weth).deposit{value: msg.value}();

        bool zeroForOne = weth < token; // weth token0 → sell token0
        tokensOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockPayload({
                        token: token,
                        recipient: recipient,
                        amountIn: msg.value,
                        minAmountOut: minTokensOut,
                        zeroForOne: zeroForOne,
                        isQuote: false,
                        inputIsWeth: true
                    })
                )
            ),
            (uint256)
        );
        _enforceAntiSnipeAfterBuy(token, recipient, tokensOut);
        // Trader = recipient (aggregator passes the user wallet).
        emit GraduatedSwap(token, recipient, true, msg.value, tokensOut, 0);
        _syncDividendShares(token, recipient, msg.sender);
        _tryCompoundTaxLiquidity(token);
    }

    /// @notice Token → ETH. Caller is attributed as trader (direct user sells).
    function sell(address token, uint256 tokenAmount, address recipient, uint256 minEthOut, uint256 deadline)
        external
        nonReentrant
        checkDeadline(deadline)
        returns (uint256 ethOut)
    {
        return _sell(msg.sender, token, tokenAmount, recipient, minEthOut, deadline);
    }

    /// @notice Token → ETH for aggregator wraps. `trader` is attributed in `GraduatedSwap`.
    function sellFor(
        address trader,
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) external nonReentrant checkDeadline(deadline) returns (uint256 ethOut) {
        if (trader == address(0)) revert ZeroAddress();
        return _sell(trader, token, tokenAmount, recipient, minEthOut, deadline);
    }

    function _sell(
        address trader,
        address token,
        uint256 tokenAmount,
        address recipient,
        uint256 minEthOut,
        uint256 deadline
    ) internal returns (uint256 ethOut) {
        deadline; // checked by modifier on external entry
        if (recipient == address(0)) revert ZeroAddress();
        if (tokenAmount == 0) revert InvalidMsgValue();
        _requireGraduated(token);

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokenAmount);

        bool zeroForOne = token < weth; // token token0 → sell token0
        ethOut = abi.decode(
            poolManager.unlock(
                abi.encode(
                    UnlockPayload({
                        token: token,
                        recipient: address(this),
                        amountIn: tokenAmount,
                        minAmountOut: 0,
                        zeroForOne: zeroForOne,
                        isQuote: false,
                        inputIsWeth: false
                    })
                )
            ),
            (uint256)
        );
        IWETH9(weth).withdraw(ethOut);
        if (ethOut < minEthOut) revert InvalidMsgValue();
        _sendEth(recipient, ethOut);
        emit GraduatedSwap(token, trader, false, ethOut, tokenAmount, 0);
        _syncDividendShares(token, trader, recipient);
        _tryCompoundTaxLiquidity(token);
    }

    /// @notice Quote ETH→token for a net ETH input (no platform fee here).
    function quoteBuy(address token, uint256 ethInNet) external returns (uint256 tokensOut, uint256 fee) {
        _requireGraduated(token);
        fee = 0;
        if (ethInNet == 0) return (0, 0);
        // During anti-bundle, buys commit ETH — no spot fill to quote.
        if (v4Registry.clearingActive(token)) return (0, 0);

        bool zeroForOne = weth < token;
        try poolManager.unlock(
            abi.encode(
                UnlockPayload({
                    token: token,
                    recipient: address(this),
                    amountIn: ethInNet,
                    minAmountOut: 0,
                    zeroForOne: zeroForOne,
                    isQuote: true,
                    inputIsWeth: true
                })
            )
        ) {
            revert();
        } catch (bytes memory reason) {
            tokensOut = _decodeQuote(reason);
        }
    }

    /// @notice Quote token→ETH gross (no platform fee here).
    function quoteSell(address token, uint256 tokenAmount) external returns (uint256 ethOut, uint256 fee) {
        _requireGraduated(token);
        fee = 0;
        if (tokenAmount == 0) return (0, 0);
        // Spot sells blocked while the anti-bundle window is open.
        if (v4Registry.clearingActive(token)) return (0, 0);

        bool zeroForOne = token < weth;
        try poolManager.unlock(
            abi.encode(
                UnlockPayload({
                    token: token,
                    recipient: address(this),
                    amountIn: tokenAmount,
                    minAmountOut: 0,
                    zeroForOne: zeroForOne,
                    isQuote: true,
                    inputIsWeth: false
                })
            )
        ) {
            revert();
        } catch (bytes memory reason) {
            ethOut = _decodeQuote(reason);
        }
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        UnlockPayload memory p = abi.decode(data, (UnlockPayload));
        PoolKey memory key = _poolKey(p.token);

        uint160 limit = p.zeroForOne ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
        int256 swapDelta = poolManager.swap(
            key,
            SwapParams({zeroForOne: p.zeroForOne, amountSpecified: -int256(p.amountIn), sqrtPriceLimitX96: limit}),
            ""
        );

        int128 amt0;
        int128 amt1;
        assembly ("memory-safe") {
            amt1 := signextend(15, swapDelta)
            amt0 := sar(128, swapDelta)
        }

        uint256 amountOut;
        if (p.zeroForOne) {
            if (amt1 < 0) revert BadSwapDelta();
            amountOut = uint256(uint128(amt1));
        } else {
            if (amt0 < 0) revert BadSwapDelta();
            amountOut = uint256(uint128(amt0));
        }

        if (p.isQuote) revert QuoteResult(amountOut);

        Currency input = Currency.wrap(p.inputIsWeth ? weth : p.token);
        Currency output = Currency.wrap(p.inputIsWeth ? p.token : weth);
        _settle(input, p.amountIn);
        _take(output, p.recipient, amountOut);
        if (amountOut < p.minAmountOut) revert InvalidMsgValue();
        return abi.encode(amountOut);
    }

    function _settle(Currency currency, uint256 amount) internal {
        address token = Currency.unwrap(currency);
        poolManager.sync(currency);
        IERC20(token).safeTransfer(address(poolManager), amount);
        poolManager.settle();
    }

    function _take(Currency currency, address to, uint256 amount) internal {
        poolManager.take(currency, to, amount);
    }

    function _poolKey(address token) internal view returns (PoolKey memory key) {
        address hook = v4Registry.hook();
        address token0 = token < weth ? token : weth;
        address token1 = token < weth ? weth : token;
        key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: hook
        });
    }

    function _requireGraduated(address token) internal view {
        // Instant V4: live once factory-seeded LP exists.
        if (v4Registry.seededAt(token) == 0) revert NotSeeded();
        if (factoryContract.creatorOf(token) == address(0)) revert UnknownToken();
    }

    /// @dev Instant V3-style: 2 blocks, 5% wallet / 5.5% cumulative buys (creator / clearing house exempt).
    function _enforceAntiSnipeAfterBuy(address token, address trader, uint256 tokensOut) internal {
        if (!v4Registry.antiSnipeActive(token)) return;
        if (trader == factoryContract.creatorOf(token)) return;
        if (trader == v4Registry.clearingHouse()) return;

        uint64 lb = v4Registry.launchBlock(token);
        if (block.number == lb) revert LaunchBlockBuyBlocked(trader);

        uint256 supply = IERC20(token).totalSupply();
        uint256 walletLimit = (supply * uint256(v4Registry.MAX_WALLET_BPS())) / 10_000;
        uint256 txLimit = (supply * uint256(v4Registry.MAX_TX_BPS())) / 10_000;

        uint256 cumulative = v4Registry.restrictedBuys(token, trader) + tokensOut;
        if (cumulative > txLimit) revert MaxTxExceeded(trader, cumulative, txLimit);

        uint256 bal = IERC20(token).balanceOf(trader);
        if (bal > walletLimit) revert MaxWalletExceeded(trader, bal, walletLimit);

        v4Registry.recordRestrictedBuy(token, trader, tokensOut);
    }

    function _syncDividendShares(address token, address account0, address account1) internal {
        address distributor = v4Registry.dividendDistributor();
        if (distributor == address(0)) return;
        (bool ok,) = distributor.call(
            abi.encodeWithSignature("syncShares(address,address,address)", token, account0, account1)
        );
        ok; // best-effort — swap must not revert if dividend sync fails
    }

    function _tryCompoundTaxLiquidity(address token) internal {
        address vault = v4Registry.lpFeeVault();
        if (vault == address(0)) return;
        (bool ok,) = vault.call(abi.encodeWithSignature("compoundTaxLiquidity(address)", token));
        ok; // best-effort — compound can wait until both tax legs exist
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function _decodeQuote(bytes memory reason) internal pure returns (uint256 amount) {
        if (reason.length < 36) return 0;
        bytes4 sel;
        assembly {
            sel := mload(add(reason, 0x20))
        }
        if (sel != QuoteResult.selector) return 0;
        assembly {
            amount := mload(add(reason, 0x24))
        }
    }
}
