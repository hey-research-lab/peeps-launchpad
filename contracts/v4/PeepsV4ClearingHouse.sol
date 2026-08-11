// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPeepsV4Factory} from "./interfaces/IPeepsV4Factory.sol";
import {IPeepsV4Registry} from "./interfaces/IPeepsV4Registry.sol";
import {ZeroAddress, ClearingSettleInvalid} from "./errors/PeepsV4Errors.sol";

interface IPeepsV4SwapRouterBuy {
    function buy(address token, address recipient, uint256 minTokensOut, uint256 deadline)
        external
        payable
        returns (uint256 tokensOut);
}

/// @title PeepsV4ClearingHouse — uniform clearing price for Instant V4 (option 1)
/// @notice During `CLEARING_SECONDS`, buys commit ETH here. After the window, `settle`
///         executes one pool buy and pays tokens pro-rata — same price for every committer.
contract PeepsV4ClearingHouse is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_COMMITTERS = 200;

    error ClearingNotActive();
    error ClearingStillActive();
    error AlreadySettled();
    error TooManyCommitters();
    error ZeroCommit();
    error NotConfigured();

    event ClearingCommitted(address indexed token, address indexed beneficiary, uint256 ethIn, uint256 totalEth);
    event ClearingSettled(address indexed token, uint256 ethTotal, uint256 tokensOut, uint256 committers);

    IPeepsV4Registry public immutable registry;
    IPeepsV4Factory public immutable factoryContract;
    address public swapRouter;

    mapping(address token => uint256) public totalEth;
    mapping(address token => mapping(address => uint256)) public ethOf;
    mapping(address token => address[]) internal _committers;
    mapping(address token => mapping(address => bool)) internal _listed;
    mapping(address token => bool) public settled;

    constructor(address owner_, address registry_, address factory_) Ownable(owner_) {
        if (registry_ == address(0) || factory_ == address(0)) revert ZeroAddress();
        registry = IPeepsV4Registry(registry_);
        factoryContract = IPeepsV4Factory(factory_);
    }

    function setSwapRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        swapRouter = router_;
    }

    function committerCount(address token) external view returns (uint256) {
        return _committers[token].length;
    }

    function commit(address token, address beneficiary) external payable nonReentrant {
        if (beneficiary == address(0)) revert ZeroAddress();
        if (msg.value == 0) revert ZeroCommit();
        if (!registry.clearingActive(token)) revert ClearingNotActive();

        if (!_listed[token][beneficiary]) {
            if (_committers[token].length >= MAX_COMMITTERS) revert TooManyCommitters();
            _listed[token][beneficiary] = true;
            _committers[token].push(beneficiary);
        }
        ethOf[token][beneficiary] += msg.value;
        totalEth[token] += msg.value;
        emit ClearingCommitted(token, beneficiary, msg.value, totalEth[token]);
    }

    /// @notice After the clearing window: one pool buy, then pro-rata token payout.
    function settle(address token) external nonReentrant {
        if (swapRouter == address(0)) revert NotConfigured();
        uint64 end = registry.clearingEnd(token);
        if (end == 0) revert ClearingSettleInvalid();
        if (block.timestamp < end) revert ClearingStillActive();
        if (settled[token]) revert AlreadySettled();

        settled[token] = true;
        uint256 ethTotal = totalEth[token];
        if (ethTotal == 0) {
            emit ClearingSettled(token, 0, 0, 0);
            return;
        }

        uint256 tokensOut =
            IPeepsV4SwapRouterBuy(swapRouter).buy{value: ethTotal}(token, address(this), 0, block.timestamp + 1);

        address[] storage list = _committers[token];
        uint256 n = list.length;
        for (uint256 i = 0; i < n; i++) {
            address user = list[i];
            uint256 ethShare = ethOf[token][user];
            if (ethShare == 0) continue;
            uint256 tokShare = (tokensOut * ethShare) / ethTotal;
            if (tokShare == 0) continue;
            IERC20(token).safeTransfer(user, tokShare);
        }

        uint256 dust = IERC20(token).balanceOf(address(this));
        if (dust != 0) {
            IERC20(token).safeTransfer(factoryContract.treasury(), dust);
        }

        emit ClearingSettled(token, ethTotal, tokensOut, n);
    }

    receive() external payable {}
}
