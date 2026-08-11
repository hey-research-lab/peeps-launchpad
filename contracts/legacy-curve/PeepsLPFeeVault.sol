// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsLPFeeVault} from "./interfaces/IPeepsLPFeeVault.sol";
import {IPeepsCurveFactory} from "./interfaces/IPeepsCurveFactory.sol";
import {IPeepsBondingCurve} from "./interfaces/IPeepsBondingCurve.sol";
import {INonfungiblePositionManager} from "src/interfaces/external/INonfungiblePositionManager.sol";
import {IWETH9} from "src/interfaces/external/IWETH9.sol";
import {
    ZeroAddress,
    NotPositionManager,
    NotMigrator,
    NotCreator,
    NothingToClaim,
    EthTransferFailed
} from "./errors/PeepsErrors.sol";

/// @title PeepsLPFeeVault — locked LP principal; V3 fees split creator / protocol
/// @notice Creator LP fees use a pull model so `collect` never reverts when the fee recipient
///         is a contract that cannot accept native ETH. The protocol share (100% − creator share)
///         routes 20% to marketing, 20% to buybacks, and the remainder to treasury.
contract PeepsLPFeeVault is IPeepsLPFeeVault, IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Share of the protocol LP-fee slice sent to marketing / buybacks (bps of protocol amount).
    uint16 internal constant PROTOCOL_MARKETING_BPS = 2000;
    uint16 internal constant PROTOCOL_BUYBACK_BPS = 2000;

    address public immutable override positionManager;
    address public immutable override treasury;
    address public immutable override marketingWallet;
    address public immutable override buybackWallet;
    address public immutable override factory;

    mapping(uint256 => address) public positionToken;
    mapping(address => uint256) public override tokenPosition;
    mapping(address => uint256) public override accruedCreatorEth;
    mapping(address => uint256) public override accruedCreatorTokens;

    constructor(
        address positionManager_,
        address treasury_,
        address marketingWallet_,
        address buybackWallet_,
        address factory_
    ) {
        if (
            positionManager_ == address(0) || treasury_ == address(0) || marketingWallet_ == address(0)
                || buybackWallet_ == address(0) || factory_ == address(0)
        ) {
            revert ZeroAddress();
        }
        positionManager = positionManager_;
        treasury = treasury_;
        marketingWallet = marketingWallet_;
        buybackWallet = buybackWallet_;
        factory = factory_;
    }

    function registerPosition(uint256 tokenId, address launchToken) external {
        if (msg.sender != IPeepsCurveFactory(factory).migrator()) revert NotMigrator();
        if (launchToken == address(0)) revert ZeroAddress();
        positionToken[tokenId] = launchToken;
        tokenPosition[launchToken] = tokenId;
    }

    function collectForToken(address launchToken) external override returns (uint256 amount0, uint256 amount1) {
        uint256 tokenId = tokenPosition[launchToken];
        if (tokenId == 0) revert ZeroAddress();
        return _collect(tokenId);
    }

    function collect(uint256 tokenId) external override returns (uint256 amount0, uint256 amount1) {
        return _collect(tokenId);
    }

    function _collect(uint256 tokenId) internal nonReentrant returns (uint256 amount0, uint256 amount1) {
        address launchToken = positionToken[tokenId];
        if (launchToken == address(0)) revert ZeroAddress();

        (amount0, amount1) = INonfungiblePositionManager(positionManager).collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        address curve = IPeepsCurveFactory(factory).curveOf(launchToken);
        uint16 creatorShare = IPeepsBondingCurve(curve).postGradCreatorShareBps();
        address weth = IPeepsCurveFactory(factory).weth();

        bool tokenIs0 = launchToken < weth;
        uint256 wethAmt = tokenIs0 ? amount1 : amount0;
        uint256 tokenAmt = tokenIs0 ? amount0 : amount1;

        uint256 ethToCreator;
        uint256 ethToProtocol;
        uint256 tokenToCreator;
        uint256 tokenToProtocol;

        if (wethAmt > 0) {
            IWETH9(weth).withdraw(wethAmt);
            ethToCreator = (wethAmt * creatorShare) / 10_000;
            ethToProtocol = wethAmt - ethToCreator;
            if (ethToCreator > 0) accruedCreatorEth[launchToken] += ethToCreator;
            if (ethToProtocol > 0) _routeProtocolEth(ethToProtocol);
        }

        if (tokenAmt > 0) {
            tokenToCreator = (tokenAmt * creatorShare) / 10_000;
            tokenToProtocol = tokenAmt - tokenToCreator;
            if (tokenToCreator > 0) accruedCreatorTokens[launchToken] += tokenToCreator;
            if (tokenToProtocol > 0) _routeProtocolTokens(launchToken, tokenToProtocol);
        }

        emit FeesCollected(launchToken, tokenId, ethToCreator, ethToProtocol, tokenToCreator, tokenToProtocol);
    }

    function _routeProtocolEth(uint256 amount) internal {
        uint256 toMarketing = (amount * PROTOCOL_MARKETING_BPS) / 10_000;
        uint256 toBuyback = (amount * PROTOCOL_BUYBACK_BPS) / 10_000;
        uint256 toTreasury = amount - toMarketing - toBuyback;

        _sendEth(marketingWallet, toMarketing);
        _sendEth(buybackWallet, toBuyback);
        _sendEth(treasury, toTreasury);
    }

    function _routeProtocolTokens(address launchToken, uint256 amount) internal {
        uint256 toMarketing = (amount * PROTOCOL_MARKETING_BPS) / 10_000;
        uint256 toBuyback = (amount * PROTOCOL_BUYBACK_BPS) / 10_000;
        uint256 toTreasury = amount - toMarketing - toBuyback;

        if (toMarketing > 0) IERC20(launchToken).safeTransfer(marketingWallet, toMarketing);
        if (toBuyback > 0) IERC20(launchToken).safeTransfer(buybackWallet, toBuyback);
        if (toTreasury > 0) IERC20(launchToken).safeTransfer(treasury, toTreasury);
    }

    function _sendEth(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
    }

    function claimCreatorLpFees(address launchToken)
        external
        override
        nonReentrant
        returns (uint256 ethClaimed, uint256 tokenClaimed)
    {
        address curve = IPeepsCurveFactory(factory).curveOf(launchToken);
        if (curve == address(0)) revert ZeroAddress();
        if (msg.sender != IPeepsBondingCurve(curve).feeRecipient()) revert NotCreator();

        ethClaimed = accruedCreatorEth[launchToken];
        tokenClaimed = accruedCreatorTokens[launchToken];
        if (ethClaimed == 0 && tokenClaimed == 0) revert NothingToClaim();

        accruedCreatorEth[launchToken] = 0;
        accruedCreatorTokens[launchToken] = 0;

        if (ethClaimed > 0) {
            (bool ok,) = msg.sender.call{value: ethClaimed}("");
            if (!ok) revert EthTransferFailed();
        }
        if (tokenClaimed > 0) IERC20(launchToken).safeTransfer(msg.sender, tokenClaimed);

        emit CreatorLpFeesClaimed(launchToken, msg.sender, ethClaimed, tokenClaimed);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data)
        external
        override
        returns (bytes4)
    {
        if (msg.sender != address(positionManager)) revert NotPositionManager();
        if (data.length >= 32) {
            address launchToken = abi.decode(data, (address));
            positionToken[tokenId] = launchToken;
            tokenPosition[launchToken] = tokenId;
        }
        return IERC721Receiver.onERC721Received.selector;
    }

    receive() external payable {}
}
