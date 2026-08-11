// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

/// @title IPeepsBondingCurve — virtual-reserve curve with creator + protocol + furnace fee split
interface IPeepsBondingCurve {
    enum Phase {
        Trading,
        ReadyToGraduate,
        Graduated
    }

    event Trade(
        address indexed trader,
        bool indexed isBuy,
        uint256 ethAmount,
        uint256 tokenAmount,
        uint256 fee,
        uint256 virtualEthReserves,
        uint256 virtualTokenReserves,
        uint256 realEthReserves
    );

    event GraduationReady(uint256 realEthReserves);
    event FeesSwept(address indexed treasury, uint256 amount);
    event FurnaceBurned(uint256 ethIn, uint256 tokensBurned);
    event CreatorFeesClaimed(address indexed recipient, uint256 amount);

    function buy(address trader, address recipient, address refundTo, uint256 minTokensOut)
        external
        payable
        returns (uint256 tokensOut, uint256 acceptedEthGross, uint256 fee);

    function sell(address trader, address recipient, uint256 tokenAmount, uint256 minEthOut)
        external
        returns (uint256 ethOut, uint256 fee);

    function sweepProtocolFees() external returns (uint256 swept);
    function executeFurnaceBurn(uint256 minTokensOut) external returns (uint256 tokensBurned);
    function claimCreatorFees() external returns (uint256 claimed);
    /// @dev Back-compat alias for protocol fee sweep (v1 tests).
    function sweepFees() external returns (uint256 swept);
    function graduate() external;

    function quoteBuy(uint256 ethInGross)
        external
        view
        returns (uint256 tokensOut, uint256 fee, uint256 acceptedEthGross, uint256 refund);

    function quoteSell(uint256 tokenAmount) external view returns (uint256 ethOut, uint256 fee);

    function reserves()
        external
        view
        returns (uint256 virtualEth, uint256 virtualToken, uint256 realEth, uint256 realToken);

    function phase() external view returns (Phase);
    function accruedProtocolFees() external view returns (uint256);
    function accruedFurnaceFees() external view returns (uint256);
    function totalFurnaceBurned() external view returns (uint256);
    function accruedCreatorFees() external view returns (uint256);
    /// @dev Back-compat alias — protocol fees only.
    function accruedFees() external view returns (uint256);
    function createdAt() external view returns (uint64);

    function token() external view returns (address);
    function creator() external view returns (address);
    function feeRecipient() external view returns (address);
    function postGradCreatorShareBps() external view returns (uint16);
    function protocolTreasury() external view returns (address);

    function VIRTUAL_ETH_0() external view returns (uint256);
    function VIRTUAL_TOKEN_0() external view returns (uint256);
    function CURVE_SUPPLY() external view returns (uint256);
    function LP_TOKEN_TRANCHE() external view returns (uint256);
    function GRADUATION_ETH() external view returns (uint256);
    function TRADE_FEE_BPS() external view returns (uint16);
    function CREATOR_FEE_BPS() external view returns (uint16);
    function PROTOCOL_FEE_BPS() external view returns (uint16);
    function FURNACE_FEE_BPS() external view returns (uint16);
    function GRADUATION_FEE() external view returns (uint256);
    function CALLER_REWARD() external view returns (uint256);
    function EARLY_WINDOW_END() external view returns (uint64);
    function MAX_EARLY_BUY() external view returns (uint128);
    function graduationProgressBps() external view returns (uint256);
}
