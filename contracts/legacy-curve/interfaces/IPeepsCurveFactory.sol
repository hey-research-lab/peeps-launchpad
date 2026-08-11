// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IPeepsCurveFactory — token+curve deployer with per-token furnace burn economics
interface IPeepsCurveFactory {
    /// @notice Graduation cap preset — $35k FDV target (Cap35k tier).
    enum GraduationCap {
        Cap5k,
        Cap10k,
        Cap35k
    }

    /// @notice Per-launch options chosen by the creator in the PeepsRouter.
    struct LaunchConfig {
        GraduationCap graduationCap;
        /// @dev Fixed creator share of post-graduation V3 LP fees — 4000 bps (40%).
        uint16 postGradCreatorShareBps;
        /// @dev Optional anti-snipe window (90s, 1% supply cap per wallet; creator exempt).
        bool antiSnipe;
    }

    struct CurveParameters {
        address token;
        address router;
        address migrator;
        address creator;
        address feeRecipient;
        uint256 virtualEth0;
        uint256 virtualToken0;
        uint256 curveSupply;
        uint256 lpTranche;
        uint256 graduationEth;
        uint16 tradeFeeBps;
        uint16 creatorFeeBps;
        uint16 protocolFeeBps;
        uint16 furnaceFeeBps;
        uint16 postGradCreatorShareBps;
        uint256 graduationFee;
        uint256 callerReward;
        uint64 earlyWindowSeconds;
        uint128 maxEarlyBuyWei;
        bool antiSnipeEnabled;
    }

    struct FactoryConfig {
        address treasury;
        uint16 tradeFeeBps;
        uint16 creatorFeeBps;
        uint16 protocolFeeBps;
        uint16 furnaceFeeBps;
        uint256 creationFee;
        uint256 graduationFee;
        uint256 callerReward;
        uint64 earlyWindowSeconds;
        uint128 maxEarlyBuyWei;
        bool pauseCreates;
        bool pauseBuys;
        uint128 perTokenEthCap;
        uint128 globalEthCap;
        uint256 graduationEthCap5k;
        uint256 graduationEthCap10k;
        uint256 graduationEthCap35k;
    }

    event TokenCreated(
        address indexed token,
        address indexed curve,
        address indexed creator,
        string name,
        string symbol,
        bytes32 metadataHash,
        string metadataUri,
        address pool,
        GraduationCap graduationCap,
        uint16 postGradCreatorShareBps
    );

    event TreasuryUpdated(address indexed newTreasury);
    event TradeFeeUpdated(uint16 newBps);
    event CreationFeeUpdated(uint256 newFee);
    event GraduationFeeUpdated(uint256 newFee);
    event CallerRewardUpdated(uint256 newReward);
    event AntiSniperUpdated(uint64 windowSeconds, uint128 maxEarlyBuyWei);
    event CapsUpdated(uint128 perTokenEthCap, uint128 globalEthCap);
    event PauseCreatesSet(bool paused);
    event PauseBuysSet(bool paused);
    event PeepsRouterSet(address router);
    event MigratorSet(address migrator);
    event V3SwapRouterSet(address router);

    function createToken(
        address creator,
        string calldata name,
        string calldata symbol,
        bytes32 metadataHash,
        string calldata metadataUri,
        LaunchConfig calldata launch
    ) external returns (address token, address curve, address pool);

    function recordEthDelta(int256 delta) external;
    function curveParameters() external view returns (CurveParameters memory);
    function curveOf(address token) external view returns (address);
    function tokenOf(address curve) external view returns (address);
    function isCurve(address account) external view returns (bool);
    function config() external view returns (FactoryConfig memory);
    function globalCurveEth() external view returns (uint256);
    function MAX_TRADE_FEE_BPS() external view returns (uint16);
    function router() external view returns (address);
    function migrator() external view returns (address);
    function v3SwapRouter() external view returns (address);
    function weth() external view returns (address);
    function treasury() external view returns (address);
    function creationFee() external view returns (uint256);
    function pauseCreates() external view returns (bool);
    function pauseBuys() external view returns (bool);
    function perTokenEthCap() external view returns (uint128);
    function globalEthCap() external view returns (uint128);
    function graduationEthForCap(GraduationCap cap) external view returns (uint256);

    function setPauseCreates(bool paused) external;
    function setPauseBuys(bool paused) external;
    function setTreasury(address newTreasury) external;
    function setTradeFeeBps(uint16 newBps) external;
    function setCreationFee(uint256 newFee) external;
    function setGraduationFee(uint256 newFee) external;
    function setCallerReward(uint256 newReward) external;
    function setAntiSniper(uint64 windowSeconds, uint128 maxEarlyBuyWei) external;
    function setCaps(uint128 perTokenEthCap_, uint128 globalEthCap_) external;
    function setPeepsRouter(address router_) external;
    function setMigrator(address migrator_) external;
    function setV3SwapRouter(address router_) external;
}
