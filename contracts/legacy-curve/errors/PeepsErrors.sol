// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title PEEPS shared custom errors
/// @notice Free-standing declarations shared across all six contracts. Custom errors only — no
///         revert strings anywhere (contracts.md §2). Transcribed from the per-contract error
///         lists in contracts.md §2.2 (PeepsCurveFactory), §2.3 (PeepsBondingCurve), §2.4 (PeepsRouter),
///         §2.5 (PeepsV3Migrator), §2.6 (PeepsLPFeeVault); deduplicated where the same name appears on
///         more than one contract (NotPeepsRouter, NotCurve, ZeroAddress, CreatesPaused,
///         EthTransferFailed).
/// @dev FROZEN by the tests-as-spec phase: M1 implementations import from this file unchanged.

// ─────────────────────────────── Access control ────────────────────────────────

/// @notice Caller is not the registered PeepsRouter (contracts.md §2.2, §2.3).
error NotPeepsRouter();

/// @notice Caller is not a factory-registered PeepsBondingCurve (contracts.md §2.2, §2.5).
error NotCurve();

/// @notice Caller is not the PeepsCurveFactory (contracts.md §2.5).
error NotFactory();

/// @notice Swap-callback caller is not the in-flight migration's pool (contracts.md §2.5).
error NotPool();

/// @notice ERC721 sender is not the NonfungiblePositionManager (contracts.md §2.6).
error NotPositionManager();

// ─────────────────────────────── Factory (§2.2) ────────────────────────────────

/// @notice One-time setter (setPeepsRouter/setMigrator) called a second time (contracts.md §2.2).
error AlreadyInitialized();

/// @notice Zero address where a non-zero address is required (contracts.md §2.2, §2.4, §2.6).
error ZeroAddress();

/// @notice Token name length outside [1,32] bytes (contracts.md §2.2).
error InvalidName();

/// @notice Token symbol length outside [1,10] bytes (contracts.md §2.2).
error InvalidSymbol();

/// @notice metadataHash == bytes32(0) — the §8.3 integrity commitment is mandatory (contracts.md §2.2).
error ZeroMetadataHash();

/// @notice metadataUri length outside [1,256] bytes (contracts.md §2.2). Distinct from
///         {ZeroMetadataHash} — the URI is the event-only indexer pointer, the hash is the on-chain
///         integrity commitment; conflating their reverts was fixup F-4 (M1-7/M1-8 security gate).
error InvalidMetadataUri();

/// @notice Deploy-time misconfig: the worst-case owner-settable graduation-fee + caller-reward
///         ceilings would meet or exceed the net-of-fee graduation threshold, leaving graduation
///         permanently unfundable (no ETH left for the LP mint). Enforced in the constructor so a
///         misconfigured deploy fails fast rather than shipping a curve that can never graduate
///         (fixup F-3, M1-7/M1-8 security gate; guards spec §12.11 reachability).
error GraduationUnfundable();

/// @notice Launches are paused (`pauseCreates`, spec §6.5 granular pause) (contracts.md §2.2, §2.4).
error CreatesPaused();

/// @notice Admin setter above its code-enforced hard cap (spec §6.4 fee ceilings) (contracts.md §2.2).
error FeeAboveCap();

/// @notice Buy would push global curve ETH beyond `globalEthCap` (beta cap, spec §10 gate 7)
///         (contracts.md §2.2). Never raised on ETH-decreasing operations (sells/graduation).
error CapExceeded();

// ─────────────────────────────── PeepsBondingCurve (§2.3) ───────────────────────────

/// @notice Curve phase != Trading (buy/sell after lock or graduation) (contracts.md §2.3).
error NotTrading();
/// @notice Curve has not graduated yet (V3 swap path).
error NotGraduated();
/// @notice Caller is not the registered PeepsV3SwapRouter.
/// @custom:deprecated No longer used — platform swap fees route directly from PeepsV3SwapRouter.
error NotV3SwapRouter();

/// @notice graduate() called while phase != ReadyToGraduate (contracts.md §2.3).
error NotReady();

/// @notice Zero-amount trade (contracts.md §2.3).
error ZeroAmount();

/// @notice Output below the caller-supplied minimum (spec §6.5 slippage floor) (contracts.md §2.3).
/// @param actual Actual output computed by curve math.
/// @param min    Caller's floor (minTokensOut / minEthOut).
error SlippageExceeded(uint256 actual, uint256 min);

/// @notice Gross buy above `MAX_EARLY_BUY` inside the anti-sniper timestamp window
///         (spec §6.5, mechanism ratified §12.18) (contracts.md §2.3).
/// @param sent Gross ETH sent.
/// @param cap  MAX_EARLY_BUY.
error EarlyBuyCapExceeded(uint256 sent, uint256 cap);

/// @notice Buy would push realEthReserves beyond `perTokenEthCap` (beta cap, spec §10 gate 7)
///         (contracts.md §2.3).
error PerTokenCapExceeded();

/// @notice Low-level ETH `call` failed (contracts.md §2.3, §2.5).
error EthTransferFailed();

// ─────────────────────────────── PeepsRouter (§2.4) ─────────────────────────────────

/// @notice Transaction deadline passed (spec §6.5 deadline on all trade paths) (contracts.md §2.4).
error DeadlineExpired();

/// @notice Token has no registered curve in the factory (contracts.md §2.4).
error UnknownToken();

/// @notice msg.value inconsistent with creationFee/initialBuy expectations (contracts.md §2.4:
///         if initialBuy == 0, minTokensOut MUST be 0).
error InvalidMsgValue();

/// @notice Curve buys are paused (`pauseBuys`, spec §6.5) — sells have NO such error by
///         construction (contracts.md §2.4, §5.3).
error BuysPaused();

/// @notice Caller is not the curve's fee recipient (creator claim path).
error NotCreator();

/// @notice No accrued fees available to claim or sweep.
error NothingToClaim();

/// @notice Caller is not the PeepsV3Migrator (LP vault register path).
error NotMigrator();

/// @notice Invalid graduation cap tier or post-grad creator share at launch.
error InvalidLaunchConfig();

/// @notice Creator initial buy at launch exceeds the supply cap (contracts.md §2.4).
/// @param tokensOut Tokens received from the atomic initial buy.
/// @param cap       Maximum allowed (5% of total supply).
error InitialBuySupplyCapExceeded(uint256 tokensOut, uint256 cap);

// ─────────────────────────────── PeepsV3Migrator (§2.5) ─────────────────────────────

/// @notice Arb-back loop ended outside `targetTick ± TOLERANCE_TICKS`; migration reverts rather
///         than mint into a hostile ratio (spec §6.3.2) (contracts.md §2.5).
/// @param finalTick  Pool tick after the bounded arb-back loop.
/// @param targetTick Deterministic graduation-price tick for this token ordering.
error PoolPriceUnrecoverable(int24 finalTick, int24 targetTick);

/// @notice Arb-back would consume inventory needed by the target-price mint (budget rule,
///         spec §13 O-8 note) (contracts.md §2.5).
error ArbBudgetExceeded();

/// @notice NPM.mint produced less liquidity than the amount-min-enforced expectation
///         (contracts.md §2.5).
error InsufficientLiquidityMinted();
