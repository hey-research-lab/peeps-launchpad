// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IPeepsV4Factory} from "./IPeepsV4Factory.sol";

interface IPeepsV4Registry {
    event V4PoolInitialized(address indexed token, bytes32 indexed poolId, bool preExisting);
    event V4Seeded(
        address indexed token,
        address indexed factory,
        bytes32 indexed poolId,
        uint256 ethIn,
        uint256 tokensIn,
        uint64 seededAt
    );
    event V4TaxConfigSet(address indexed token, IPeepsV4Factory.V4TaxLaunchConfig config);

    function initializePool(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax)
        external
        returns (bytes32 poolId);

    /// @dev Instant seed: factory sends tokens; mints locked one-sided (token-only) V4 LP.
    function instantSeed(address token) external payable returns (uint256 tokenId, uint128 liquidity);

    /// @dev Factory-only: open the anti-bundle commit window after optional creator initial buy.
    function startUniformClearing(address token) external;

    /// @dev Stored Instant one-sided range for graduation / tax compound sizing.
    function positionRange(address token) external view returns (int24 tickLower, int24 tickUpper);

    function antiSnipeActive(address token) external view returns (bool);
    function clearingActive(address token) external view returns (bool);
    function launchBlock(address token) external view returns (uint64);
    function clearingEnd(address token) external view returns (uint64);
    function restrictedBuys(address token, address trader) external view returns (uint256);
    function recordRestrictedBuy(address token, address trader, uint256 tokensOut) external;
    function ANTI_SNIPE_BLOCKS() external view returns (uint32);
    function MAX_WALLET_BPS() external view returns (uint16);
    function MAX_TX_BPS() external view returns (uint16);
    function CLEARING_SECONDS() external view returns (uint64);
    function clearingHouse() external view returns (address);
    function swapRouter() external view returns (address);

    function taxConfig(address token) external view returns (IPeepsV4Factory.V4TaxLaunchConfig memory);

    /// @dev Bonding→V4 migrator: register Instant tax + init dynamic-fee tax-hook pool (no Instant seed).
    function setTaxForBondingLaunch(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax)
        external
        returns (bytes32 poolId);

    /// @dev Timestamp when Instant seed completed (tax pool live). Not product "graduation".
    function seededAt(address token) external view returns (uint64);
    function poolIdOf(address token) external view returns (bytes32);
    function positionTokenId(address token) external view returns (uint256);
    function hook() external view returns (address);
    /// @dev True only while minting via PositionManager (anti-farmer bypass).
    function liquidityGateOpen(address token) external view returns (bool);
    function lpFeeVault() external view returns (address);
    function dividendDistributor() external view returns (address);
    function factory() external view returns (address);
    function poolManager() external view returns (address);
    function positionManager() external view returns (address);
    function weth() external view returns (address);
    function SQRT_PRICE_TOKEN0_X96() external view returns (uint160);
    function SQRT_PRICE_TOKEN1_X96() external view returns (uint160);
    /// @dev LP vault compounds tax liquidity through PositionManager during anti-farmer window.
    function setLiquidityGateForVault(address token, bool open) external;
}
