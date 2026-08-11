// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IPeepsV4Factory — Instant (Pons-style) registry surface for V4 tax stack
interface IPeepsV4Factory {
    enum GraduationCap {
        Cap5k,
        Cap10k,
        Cap35k
    }

    struct LaunchConfig {
        GraduationCap graduationCap;
        uint16 postGradCreatorShareBps;
        /// @dev Instant V3-style early window: 2 blocks, 5% wallet / 5.5% cumulative buy.
        bool antiSnipe;
        /// @dev First CLEARING_SECONDS: buys commit ETH, then settle at one uniform price (pro-rata).
        bool uniformClearing;
    }

    /// @notice Tax / anti-farmer options for Uniswap V4 Instant launches.
    struct V4TaxLaunchConfig {
        LaunchConfig base;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 fundsBps;
        uint16 burnBps;
        uint16 dividendBps;
        uint16 liquidityBps;
        address taxRecipient;
        uint16 antiFarmerDays;
        uint256 minDividendBalance;
    }

    function treasury() external view returns (address);
    function weth() external view returns (address);
    function v4Registry() external view returns (address);

    function creatorOf(address token) external view returns (address);
    function postGradCreatorShareBpsOf(address token) external view returns (uint16);
}
