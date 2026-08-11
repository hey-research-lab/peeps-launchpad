// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPeepsCurveFactory} from "../legacy-curve/interfaces/IPeepsCurveFactory.sol";
import {IPeepsV3Migrator} from "../legacy-curve/interfaces/IPeepsV3Migrator.sol";
import {IPeepsV4Factory} from "../v4/interfaces/IPeepsV4Factory.sol";
import {PeepsBondingV4Token} from "./PeepsBondingV4Token.sol";
import {PeepsBondingV4TaxStore} from "./PeepsBondingV4TaxStore.sol";
import {PeepsBondingCurve} from "../legacy-curve/PeepsBondingCurve.sol";
import {InvalidTaxConfig} from "../v4/errors/PeepsV4Errors.sol";

interface IPeepsBondingFeeRouter {
    enum Plan {
        None,
        Normal,
        FullCut,
        CreatorBoost,
        Custom
    }

    function redeemSpecialOffer(bytes32 codeHash, address token, address creator) external;
    function setTokenPlan(address token, Plan plan, address referrer, address creator) external;
}

import {
    NotPeepsRouter,
    NotCurve,
    AlreadyInitialized,
    ZeroAddress,
    InvalidName,
    InvalidSymbol,
    ZeroMetadataHash,
    InvalidMetadataUri,
    GraduationUnfundable,
    CreatesPaused,
    FeeAboveCap,
    CapExceeded,
    InvalidLaunchConfig
} from "../legacy-curve/errors/PeepsErrors.sol";

/// @title PeepsBondingV4Factory — bonding create with Instant-style token tax at launch
/// @notice Deploys clean {PeepsBondingV4Token} + curve; tax is stored in {PeepsBondingV4TaxStore}
///         for curve-phase router taxation and migrator → Instant V4 tax hook registration.
contract PeepsBondingV4Factory is IPeepsCurveFactory, Ownable2Step {
    /// @notice Instant-aligned: 1% trade fee → 70% creator / 30% protocol (of notional: 70 + 30 bps).
    uint16 public constant CREATOR_FEE_BPS = 70;
    uint16 public constant PROTOCOL_FEE_BPS = 30;
    uint16 public constant FURNACE_FEE_BPS = 0;
    uint16 public constant DEFAULT_TRADE_FEE_BPS = 100;
    uint16 public constant POST_GRAD_CREATOR_SHARE_BPS = 7000;
    uint16 public constant MIN_POST_GRAD_CREATOR_SHARE_BPS = POST_GRAD_CREATOR_SHARE_BPS;
    uint16 public constant MAX_POST_GRAD_CREATOR_SHARE_BPS = POST_GRAD_CREATOR_SHARE_BPS;

    uint16 public constant override MAX_TRADE_FEE_BPS = 300;

    /// @notice Same fixed create fee as Instant V3 / Instant V4 (0.00025 ETH).
    uint256 public constant INSTANT_ALIGNED_LAUNCH_FEE = 0.00025 ether;

    address public immutable override weth;
    address public immutable taxStore;
    uint256 internal immutable _virtualEth0;
    uint256 internal immutable _virtualToken0;
    uint256 internal immutable _curveSupply;
    uint256 internal immutable _lpTranche;
    /// @notice Single graduation threshold (Pons-parity 4.2 ETH on next deploy).
    uint256 internal immutable _graduationEth;

    uint256 public immutable maxCreationFee;
    uint256 public immutable maxGraduationFee;
    uint256 public immutable maxCallerReward;

    address public override router;
    address public override migrator;
    address public override v3SwapRouter;
    address public override treasury;
    address public protocolFeeRecipient;
    /// @dev PeepsProtocolFeeRouter — special redeem + Normal referral plan on create.
    address public feeRouter;
    /// @dev Instant PeepsV4DividendDistributor — configure at create when dividendBps > 0.
    address public dividendDistributor;

    uint16 public tradeFeeBps;
    uint256 public override creationFee;
    uint256 public graduationFee;
    uint256 public callerReward;
    uint64 public earlyWindowSeconds;
    uint128 public maxEarlyBuyWei;

    bool public override pauseCreates;
    bool public override pauseBuys;
    uint128 public override perTokenEthCap;
    uint128 public override globalEthCap;
    uint256 public override globalCurveEth;

    mapping(address token => address curve) public override curveOf;
    mapping(address curve => address token) public override tokenOf;
    mapping(address account => bool) public override isCurve;

    uint256 public tokenCounter;
    CurveParameters internal _stagedParams;

    struct FactoryInit {
        address weth;
        address treasury;
        address initialOwner;
        address taxStore;
        uint256 virtualEth0;
        uint256 virtualToken0;
        uint256 curveSupply;
        uint256 lpTranche;
        uint256 graduationEth;
        uint256 creationFee;
        uint256 maxCreationFee;
        uint256 graduationFee;
        uint256 maxGraduationFee;
        uint256 callerReward;
        uint256 maxCallerReward;
        uint64 earlyWindowSeconds;
        uint128 maxEarlyBuyWei;
        uint128 perTokenEthCap;
        uint128 globalEthCap;
    }

    constructor(FactoryInit memory p) Ownable(p.initialOwner) {
        if (p.weth == address(0) || p.treasury == address(0) || p.taxStore == address(0)) {
            revert ZeroAddress();
        }
        if (p.virtualEth0 == 0 || p.virtualToken0 == 0) revert ZeroAddress();
        if (p.curveSupply + p.lpTranche != 1_000_000_000e18) revert ZeroAddress();
        if (p.graduationEth == 0) revert ZeroAddress();
        if (p.creationFee > p.maxCreationFee || p.graduationFee > p.maxGraduationFee) revert FeeAboveCap();
        if (p.callerReward > p.maxCallerReward) revert FeeAboveCap();
        if (p.maxCallerReward + p.maxGraduationFee >= p.graduationEth) revert GraduationUnfundable();

        weth = p.weth;
        treasury = p.treasury;
        taxStore = p.taxStore;
        _virtualEth0 = p.virtualEth0;
        _virtualToken0 = p.virtualToken0;
        _curveSupply = p.curveSupply;
        _lpTranche = p.lpTranche;
        _graduationEth = p.graduationEth;

        maxCreationFee = p.maxCreationFee;
        maxGraduationFee = p.maxGraduationFee;
        maxCallerReward = p.maxCallerReward;

        tradeFeeBps = DEFAULT_TRADE_FEE_BPS;
        creationFee = p.creationFee == 0 ? INSTANT_ALIGNED_LAUNCH_FEE : p.creationFee;
        if (creationFee > maxCreationFee) revert FeeAboveCap();
        graduationFee = p.graduationFee;
        callerReward = p.callerReward;
        earlyWindowSeconds = p.earlyWindowSeconds;
        maxEarlyBuyWei = p.maxEarlyBuyWei;
        perTokenEthCap = p.perTokenEthCap;
        globalEthCap = p.globalEthCap;
        protocolFeeRecipient = p.treasury;
    }

    function creationFeeRecipient() public view returns (address) {
        return protocolFeeRecipient != address(0) ? protocolFeeRecipient : treasury;
    }

    modifier onlyPeepsRouter() {
        if (msg.sender != router) revert NotPeepsRouter();
        _;
    }

    modifier onlyCurve() {
        if (!isCurve[msg.sender]) revert NotCurve();
        _;
    }

    /// @dev Bonding V4 requires Instant-style tax — use {createTokenWithTax}.
    function createToken(
        address,
        string calldata,
        string calldata,
        bytes32,
        string calldata,
        LaunchConfig calldata
    ) external pure override returns (address, address, address) {
        revert InvalidTaxConfig();
    }

    error FeeRouterNotSet();
    error SpecialRedeemFailed();
    error ReferralBindFailed();
    error DividendConfigureFailed();

    event FeeRouterUpdated(address indexed feeRouter);
    event DividendDistributorUpdated(address indexed distributor);

    /// @notice Create bonding→V4 token with Instant tax + optional referral/special plan.
    /// @param specialCodeHash keccak256(code); bytes32(0) = none. Wins over `referrer`.
    /// @param referrer Normal plan referrer when no special; address(0) = no plan.
    function createTokenWithTax(
        address creator,
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        LaunchConfig calldata launch,
        IPeepsV4Factory.V4TaxLaunchConfig calldata tax,
        bytes32 specialCodeHash,
        address referrer
    ) external onlyPeepsRouter returns (address token, address curve, address pool) {
        _validateCreate(name, symbol, metadataHash, metadataUri, launch);
        GraduationCap cap = launch.graduationCap;
        uint16 shareBps = POST_GRAD_CREATOR_SHARE_BPS;
        if (launch.postGradCreatorShareBps != shareBps) revert InvalidLaunchConfig();
        bool antiSnipe = launch.antiSnipe;

        if (specialCodeHash != bytes32(0) && feeRouter == address(0)) revert FeeRouterNotSet();

        bytes32 salt = keccak256(abi.encode(creator, tokenCounter));
        token = address(new PeepsBondingV4Token(name, symbol, metadataHash, _computeCurveAddress(salt)));
        curve = _deployCurve(salt, token, creator, cap, shareBps, antiSnipe);
        pool = IPeepsV3Migrator(migrator).initializePool(token);
        PeepsBondingV4TaxStore(taxStore).configureTax(token, tax);
        _configureDividends(token, tax);
        _bindReferralPlan(token, creator, specialCodeHash, referrer);
        _registerLaunch(token, curve, creator, name, symbol, metadataHash, metadataUri, pool, cap, shareBps);
    }

    function _configureDividends(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax) internal {
        if (tax.dividendBps == 0) return;
        address dist = dividendDistributor;
        if (dist == address(0)) revert DividendConfigureFailed();
        (bool ok,) = dist.call(
            abi.encodeWithSignature("configureToken(address,uint256)", token, tax.minDividendBalance)
        );
        if (!ok) revert DividendConfigureFailed();
    }

    function _bindReferralPlan(address token, address creator, bytes32 specialCodeHash, address referrer)
        internal
    {
        address router_ = feeRouter;
        if (router_ == address(0)) return;

        if (specialCodeHash != bytes32(0)) {
            try IPeepsBondingFeeRouter(router_).redeemSpecialOffer(specialCodeHash, token, creator) {}
            catch {
                revert SpecialRedeemFailed();
            }
            return;
        }

        if (referrer != address(0)) {
            try IPeepsBondingFeeRouter(router_).setTokenPlan(
                token, IPeepsBondingFeeRouter.Plan.Normal, referrer, creator
            ) {} catch {
                revert ReferralBindFailed();
            }
        }
    }

    function setFeeRouter(address feeRouter_) external onlyOwner {
        if (feeRouter_ == address(0)) revert ZeroAddress();
        feeRouter = feeRouter_;
        emit FeeRouterUpdated(feeRouter_);
    }

    function setDividendDistributor(address distributor_) external onlyOwner {
        if (distributor_ == address(0)) revert ZeroAddress();
        dividendDistributor = distributor_;
        emit DividendDistributorUpdated(distributor_);
    }

    function _deployCurve(
        bytes32 salt,
        address token,
        address creator,
        GraduationCap cap,
        uint16 shareBps,
        bool antiSnipe
    ) internal returns (address curve) {
        _stagedParams = CurveParameters({
            token: token,
            router: router,
            migrator: migrator,
            creator: creator,
            feeRecipient: creator,
            virtualEth0: _virtualEth0,
            virtualToken0: _virtualToken0,
            curveSupply: _curveSupply,
            lpTranche: _lpTranche,
            graduationEth: graduationEthForCap(cap),
            tradeFeeBps: tradeFeeBps,
            creatorFeeBps: CREATOR_FEE_BPS,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            furnaceFeeBps: FURNACE_FEE_BPS,
            postGradCreatorShareBps: shareBps,
            graduationFee: graduationFee,
            callerReward: callerReward,
            earlyWindowSeconds: earlyWindowSeconds,
            maxEarlyBuyWei: maxEarlyBuyWei,
            antiSnipeEnabled: antiSnipe
        });
        curve = address(new PeepsBondingCurve{salt: salt}());
        assert(curve == _computeCurveAddress(salt));
        delete _stagedParams;
    }

    function _registerLaunch(
        address token,
        address curve,
        address creator,
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        address pool,
        GraduationCap cap,
        uint16 shareBps
    ) internal {
        curveOf[token] = curve;
        tokenOf[curve] = token;
        isCurve[curve] = true;
        unchecked {
            ++tokenCounter;
        }
        emit TokenCreated(token, curve, creator, name, symbol, metadataHash, metadataUri, pool, cap, shareBps);
    }

    function _validateCreate(
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        LaunchConfig calldata launch
    ) internal view {
        if (pauseCreates) revert CreatesPaused();
        if (migrator == address(0)) revert ZeroAddress();
        uint256 len = bytes(name).length;
        if (len == 0 || len > 32) revert InvalidName();
        len = bytes(symbol).length;
        if (len == 0 || len > 10) revert InvalidSymbol();
        if (metadataHash == bytes32(0)) revert ZeroMetadataHash();
        len = bytes(metadataUri).length;
        if (len == 0 || len > 256) revert InvalidMetadataUri();
        if (
            launch.postGradCreatorShareBps < MIN_POST_GRAD_CREATOR_SHARE_BPS
                || launch.postGradCreatorShareBps > MAX_POST_GRAD_CREATOR_SHARE_BPS
        ) revert InvalidLaunchConfig();
        // Single graduation tier — LaunchConfig.graduationCap kept for ABI compat; ignored.
        if (uint8(launch.graduationCap) > uint8(GraduationCap.Cap35k)) revert InvalidLaunchConfig();
    }

    function _computeCurveAddress(bytes32 salt) internal view returns (address) {
        return Create2.computeAddress(salt, keccak256(type(PeepsBondingCurve).creationCode), address(this));
    }

    function recordEthDelta(int256 delta) external override onlyCurve {
        if (delta > 0) {
            uint256 added = uint256(delta);
            uint256 updated = globalCurveEth + added;
            if (updated > globalEthCap) revert CapExceeded();
            globalCurveEth = updated;
        } else if (delta < 0) {
            uint256 removed = uint256(-delta);
            uint256 current = globalCurveEth;
            unchecked {
                globalCurveEth = removed >= current ? 0 : current - removed;
            }
        }
    }

    function curveParameters() external view override returns (CurveParameters memory) {
        return _stagedParams;
    }

    function graduationEthForCap(GraduationCap) public view override returns (uint256) {
        return _graduationEth;
    }

    function config() external view override returns (FactoryConfig memory) {
        return FactoryConfig({
            treasury: treasury,
            tradeFeeBps: tradeFeeBps,
            creatorFeeBps: CREATOR_FEE_BPS,
            protocolFeeBps: PROTOCOL_FEE_BPS,
            furnaceFeeBps: FURNACE_FEE_BPS,
            creationFee: creationFee,
            graduationFee: graduationFee,
            callerReward: callerReward,
            earlyWindowSeconds: earlyWindowSeconds,
            maxEarlyBuyWei: maxEarlyBuyWei,
            pauseCreates: pauseCreates,
            pauseBuys: pauseBuys,
            perTokenEthCap: perTokenEthCap,
            globalEthCap: globalEthCap,
            // Interface still exposes three slots — all equal (single tier).
            graduationEthCap5k: _graduationEth,
            graduationEthCap10k: _graduationEth,
            graduationEthCap35k: _graduationEth
        });
    }

    function setPauseCreates(bool paused) external override onlyOwner {
        pauseCreates = paused;
        emit PauseCreatesSet(paused);
    }

    function setPauseBuys(bool paused) external override onlyOwner {
        pauseBuys = paused;
        emit PauseBuysSet(paused);
    }

    function setTreasury(address newTreasury) external override onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    event ProtocolFeeRecipientUpdated(address indexed recipient);

    function setProtocolFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(recipient);
    }

    function setTradeFeeBps(uint16 newBps) external override onlyOwner {
        if (newBps > MAX_TRADE_FEE_BPS) revert FeeAboveCap();
        tradeFeeBps = newBps;
        emit TradeFeeUpdated(newBps);
    }

    function setCreationFee(uint256 newFee) external override onlyOwner {
        if (newFee > maxCreationFee) revert FeeAboveCap();
        creationFee = newFee;
        emit CreationFeeUpdated(newFee);
    }

    function setGraduationFee(uint256 newFee) external override onlyOwner {
        if (newFee > maxGraduationFee) revert FeeAboveCap();
        graduationFee = newFee;
        emit GraduationFeeUpdated(newFee);
    }

    function setCallerReward(uint256 newReward) external override onlyOwner {
        if (newReward > maxCallerReward) revert FeeAboveCap();
        callerReward = newReward;
        emit CallerRewardUpdated(newReward);
    }

    function setAntiSniper(uint64 windowSeconds, uint128 maxEarlyBuyWei_) external override onlyOwner {
        earlyWindowSeconds = windowSeconds;
        maxEarlyBuyWei = maxEarlyBuyWei_;
        emit AntiSniperUpdated(windowSeconds, maxEarlyBuyWei_);
    }

    function setCaps(uint128 perTokenEthCap_, uint128 globalEthCap_) external override onlyOwner {
        perTokenEthCap = perTokenEthCap_;
        globalEthCap = globalEthCap_;
        emit CapsUpdated(perTokenEthCap_, globalEthCap_);
    }

    function setPeepsRouter(address router_) external override onlyOwner {
        if (router != address(0)) revert AlreadyInitialized();
        if (router_ == address(0)) revert ZeroAddress();
        router = router_;
        emit PeepsRouterSet(router_);
    }

    function setMigrator(address migrator_) external override onlyOwner {
        if (migrator != address(0)) revert AlreadyInitialized();
        if (migrator_ == address(0)) revert ZeroAddress();
        migrator = migrator_;
        emit MigratorSet(migrator_);
    }

    function setV3SwapRouter(address router_) external override onlyOwner {
        if (v3SwapRouter != address(0)) revert AlreadyInitialized();
        if (router_ == address(0)) revert ZeroAddress();
        v3SwapRouter = router_;
        emit V3SwapRouterSet(router_);
    }
}
