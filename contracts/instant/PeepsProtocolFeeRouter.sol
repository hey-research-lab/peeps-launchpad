// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title PeepsProtocolFeeRouter
 * @notice Receives Instant locker protocol LP fees (the 30% bucket) and splits
 *         them per token plan. On-chain special offers (hashed codes) + custom
 *         bps. Pull-claim for referrers / creator top-ups / platform.
 *
 * Preset plans (of total LP fees, via the 30% protocol bucket):
 * - None:         70 / 0 / 30
 * - Normal:       70 / 5 / 25
 * - FullCut:      70 / 30 / 0
 * - CreatorBoost: 80 / 20 / 0
 * - Custom:       70+bonus / ref / rest  (ref+bonus ≤ 30% of total)
 *
 * Locker calls `notifyFees` after collectFees. Launch ETH fee → `platform`.
 */
contract PeepsProtocolFeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 internal constant BPS = 10_000;
    /// @dev Protocol bucket is 30% of total LP fees.
    uint16 internal constant PROTOCOL_BUCKET_BPS = 3_000;

    enum Plan {
        None,
        Normal,
        FullCut,
        CreatorBoost,
        Custom
    }

    struct TokenPlan {
        Plan plan;
        address referrer;
        address creator;
        /// @dev Only for Custom: shares of the protocol free balance (sum ≤ 10000).
        uint16 customRefBps;
        uint16 customCreatorBps;
        bool set;
    }

    struct SpecialOffer {
        bool exists;
        bool enabled;
        Plan plan;
        address referrer;
        /// @dev Custom only: bps of *total* LP fees (ref + creatorBonus ≤ 3000).
        uint16 refBpsOfTotal;
        uint16 creatorBonusBpsOfTotal;
        uint32 maxUses;
        uint32 usedCount;
        uint64 expiresAt;
    }

    error ZeroAddress();
    error PlanAlreadySet();
    error NotBinder();
    error NothingToClaim();
    error InvalidPlan();
    error EthTransferFailed();
    error ReferrerAlreadySet();
    error SelfReferral();
    error OfferExists();
    error OfferNotFound();
    error OfferDisabled();
    error OfferExpired();
    error OfferExhausted();
    error InvalidBps();
    error InvalidMaxUses();
    error InsufficientFreeBalance();
    error NotBinderOrFactory();

    event BinderUpdated(address indexed binder);
    event PlatformUpdated(address indexed platform);
    event InstantV4FactoryUpdated(address indexed factory);
    event BondingFactoryUpdated(address indexed factory);
    event PlanFactoryUpdated(address indexed factory, bool enabled);
    event LaunchFeeForwarded(uint256 amount);
    event TraderReferrerSet(address indexed trader, address indexed referrer);
    event TokenPlanSet(
        address indexed token,
        Plan plan,
        address indexed referrer,
        address indexed creator,
        uint16 customRefBps,
        uint16 customCreatorBps
    );
    event SpecialOfferCreated(
        bytes32 indexed codeHash,
        Plan plan,
        address indexed referrer,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal,
        uint32 maxUses,
        uint64 expiresAt
    );
    event SpecialOfferUpdated(bytes32 indexed codeHash, uint32 maxUses, bool enabled, uint64 expiresAt);
    event SpecialOfferRedeemed(
        bytes32 indexed codeHash, address indexed token, address indexed creator, uint32 usedCount
    );
    event Distributed(
        address indexed token,
        address asset,
        uint256 referrerAmount,
        uint256 creatorAmount,
        uint256 platformAmount
    );
    event Claimed(address indexed account, address indexed asset, uint256 amount);

    address public binder;
    address public platform;
    /// @dev Instant V4 factory may redeem specials atomically inside createTokenV4.
    address public instantV4Factory;
    /// @dev Bonding V3/V4 factory may redeem specials / set Normal plans atomically on create.
    address public bondingFactory;
    /// @dev Extra factories authorized for redeem / setTokenPlan (e.g. second bonding stack).
    mapping(address factory => bool) public planFactory;

    mapping(address token => TokenPlan plan) public plans;
    mapping(address account => mapping(address asset => uint256 amount)) public claimable;
    mapping(address asset => uint256 amount) public reserved;

    mapping(address trader => address referrer) public traderReferrer;
    mapping(address trader => bool set) public traderReferrerSet;

    mapping(bytes32 codeHash => SpecialOffer offer) public specialOffers;

    constructor(address initialOwner, address platform_, address binder_) Ownable(initialOwner) {
        if (platform_ == address(0)) revert ZeroAddress();
        platform = platform_;
        binder = binder_ == address(0) ? initialOwner : binder_;
    }

    receive() external payable {
        if (msg.value == 0) return;
        (bool ok,) = platform.call{value: msg.value}("");
        if (!ok) revert EthTransferFailed();
        emit LaunchFeeForwarded(msg.value);
    }

    modifier onlyBinder() {
        if (msg.sender != binder && msg.sender != owner()) revert NotBinder();
        _;
    }

    modifier onlyBinderOrFactory() {
        if (
            msg.sender != binder && msg.sender != owner() && msg.sender != instantV4Factory
                && msg.sender != bondingFactory && !planFactory[msg.sender]
        ) {
            revert NotBinderOrFactory();
        }
        _;
    }

    function setBinder(address binder_) external onlyOwner {
        if (binder_ == address(0)) revert ZeroAddress();
        binder = binder_;
        emit BinderUpdated(binder_);
    }

    function setPlatform(address platform_) external onlyOwner {
        if (platform_ == address(0)) revert ZeroAddress();
        platform = platform_;
        emit PlatformUpdated(platform_);
    }

    function setInstantV4Factory(address factory_) external onlyOwner {
        // address(0) clears factory-auth (admin/binder-only redeem).
        instantV4Factory = factory_;
        emit InstantV4FactoryUpdated(factory_);
    }

    function setBondingFactory(address factory_) external onlyOwner {
        // address(0) clears factory-auth.
        bondingFactory = factory_;
        emit BondingFactoryUpdated(factory_);
    }

    function setPlanFactory(address factory_, bool enabled) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        planFactory[factory_] = enabled;
        emit PlanFactoryUpdated(factory_, enabled);
    }

    function setTraderReferrer(address trader, address referrer) external onlyBinder {
        if (trader == address(0) || referrer == address(0)) revert ZeroAddress();
        if (trader == referrer) revert SelfReferral();
        if (traderReferrerSet[trader]) revert ReferrerAlreadySet();
        traderReferrerSet[trader] = true;
        traderReferrer[trader] = referrer;
        emit TraderReferrerSet(trader, referrer);
    }

    /**
     * @notice Create an on-chain special offer. `codeHash = keccak256(bytes(code))`.
     * @param plan FullCut | CreatorBoost | Custom
     * @param refBpsOfTotal Custom: referrer % of total LP in bps (e.g. 1000 = 10%). Presets: 0.
     * @param creatorBonusBpsOfTotal Custom: extra creator % of total from protocol bucket. Presets: 0.
     */
    function createSpecialOffer(
        bytes32 codeHash,
        Plan plan,
        address referrer,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal,
        uint32 maxUses,
        uint64 expiresAt
    ) external onlyBinder {
        if (codeHash == bytes32(0)) revert InvalidPlan();
        if (specialOffers[codeHash].exists) revert OfferExists();
        if (referrer == address(0)) revert ZeroAddress();
        if (maxUses == 0) revert InvalidMaxUses();
        if (plan != Plan.FullCut && plan != Plan.CreatorBoost && plan != Plan.Custom) {
            revert InvalidPlan();
        }
        if (plan == Plan.Custom) {
            _validateCustomTotalBps(refBpsOfTotal, creatorBonusBpsOfTotal);
        } else {
            refBpsOfTotal = 0;
            creatorBonusBpsOfTotal = 0;
        }

        specialOffers[codeHash] = SpecialOffer({
            exists: true,
            enabled: true,
            plan: plan,
            referrer: referrer,
            refBpsOfTotal: refBpsOfTotal,
            creatorBonusBpsOfTotal: creatorBonusBpsOfTotal,
            maxUses: maxUses,
            usedCount: 0,
            expiresAt: expiresAt
        });

        emit SpecialOfferCreated(
            codeHash, plan, referrer, refBpsOfTotal, creatorBonusBpsOfTotal, maxUses, expiresAt
        );
    }

    function updateSpecialOffer(bytes32 codeHash, uint32 maxUses, bool enabled, uint64 expiresAt)
        external
        onlyBinder
    {
        SpecialOffer storage o = specialOffers[codeHash];
        if (!o.exists) revert OfferNotFound();
        if (maxUses < o.usedCount) revert InvalidMaxUses();
        o.maxUses = maxUses;
        o.enabled = enabled;
        o.expiresAt = expiresAt;
        emit SpecialOfferUpdated(codeHash, maxUses, enabled, expiresAt);
    }

    /**
     * @notice Redeem a special offer for an Instant token (one use). Sets token plan + trader referrer.
     * @dev Callable by binder/owner (V3 CREATE2 prebind) or Instant V4 factory (atomic create).
     */
    function redeemSpecialOffer(bytes32 codeHash, address token, address creator)
        external
        onlyBinderOrFactory
        nonReentrant
    {
        _redeemSpecialOffer(codeHash, token, creator);
    }

    function _redeemSpecialOffer(bytes32 codeHash, address token, address creator) internal {
        if (token == address(0) || creator == address(0)) revert ZeroAddress();
        if (plans[token].set) revert PlanAlreadySet();

        SpecialOffer storage o = specialOffers[codeHash];
        if (!o.exists) revert OfferNotFound();
        if (!o.enabled) revert OfferDisabled();
        if (o.expiresAt != 0 && block.timestamp > o.expiresAt) revert OfferExpired();
        if (o.usedCount >= o.maxUses) revert OfferExhausted();
        if (o.referrer == creator) revert SelfReferral();

        unchecked {
            o.usedCount += 1;
        }

        if (o.plan == Plan.Custom) {
            (uint16 refBps, uint16 creatorBps) =
                _totalBpsToProtocolBps(o.refBpsOfTotal, o.creatorBonusBpsOfTotal);
            _writePlan(token, Plan.Custom, o.referrer, creator, refBps, creatorBps);
        } else {
            _writePlan(token, o.plan, o.referrer, creator, 0, 0);
        }

        if (!traderReferrerSet[creator]) {
            traderReferrerSet[creator] = true;
            traderReferrer[creator] = o.referrer;
            emit TraderReferrerSet(creator, o.referrer);
        }

        emit SpecialOfferRedeemed(codeHash, token, creator, o.usedCount);
    }

    function setTokenPlan(address token, Plan plan, address referrer, address creator)
        external
        onlyBinderOrFactory
    {
        if (token == address(0)) revert ZeroAddress();
        if (plans[token].set) revert PlanAlreadySet();
        if (plan == Plan.Custom) revert InvalidPlan();

        if (plan == Plan.None) {
            if (referrer != address(0)) revert InvalidPlan();
            _writePlan(token, Plan.None, address(0), address(0), 0, 0);
            return;
        }
        if (referrer == address(0)) revert ZeroAddress();
        if (referrer == creator) revert SelfReferral();
        if (plan == Plan.CreatorBoost && creator == address(0)) revert ZeroAddress();
        _writePlan(token, plan, referrer, creator, 0, 0);
    }

    /// @notice Bind a custom split: bps of *total* LP fees (ref + creatorBonus ≤ 3000).
    function setTokenPlanCustom(
        address token,
        address referrer,
        address creator,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal
    ) external onlyBinder {
        if (token == address(0) || referrer == address(0) || creator == address(0)) {
            revert ZeroAddress();
        }
        if (referrer == creator) revert SelfReferral();
        if (plans[token].set) revert PlanAlreadySet();
        _validateCustomTotalBps(refBpsOfTotal, creatorBonusBpsOfTotal);
        (uint16 refBps, uint16 creatorBps) =
            _totalBpsToProtocolBps(refBpsOfTotal, creatorBonusBpsOfTotal);
        _writePlan(token, Plan.Custom, referrer, creator, refBps, creatorBps);
    }

    /// @notice Attribute all unreserved free balance under `launchToken`'s plan (ops recovery).
    function distribute(address launchToken, address token0, address token1)
        external
        nonReentrant
    {
        TokenPlan memory p = _planOrNone(launchToken);
        _distributeAsset(launchToken, p, token0, type(uint256).max);
        if (token1 != token0) _distributeAsset(launchToken, p, token1, type(uint256).max);
    }

    /// @notice Attribute exact protocol amounts just transferred by the locker (no cross-token mix).
    function notifyFees(
        address launchToken,
        address token0,
        address token1,
        uint256 amount0,
        uint256 amount1
    ) external nonReentrant {
        TokenPlan memory p = _planOrNone(launchToken);
        _distributeAsset(launchToken, p, token0, amount0);
        if (token1 != token0) _distributeAsset(launchToken, p, token1, amount1);
    }

    function claim(address asset) external nonReentrant returns (uint256 amount) {
        amount = claimable[msg.sender][asset];
        if (amount == 0) revert NothingToClaim();
        claimable[msg.sender][asset] = 0;
        reserved[asset] -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit Claimed(msg.sender, asset, amount);
    }

    function claimMany(address[] calldata assets) external nonReentrant {
        uint256 len = assets.length;
        for (uint256 i; i < len; ++i) {
            address asset = assets[i];
            uint256 amount = claimable[msg.sender][asset];
            if (amount == 0) continue;
            claimable[msg.sender][asset] = 0;
            reserved[asset] -= amount;
            IERC20(asset).safeTransfer(msg.sender, amount);
            emit Claimed(msg.sender, asset, amount);
        }
    }

    function skimToPlatform(address asset) external onlyOwner nonReentrant {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 free = bal - reserved[asset];
        if (free == 0) return;
        IERC20(asset).safeTransfer(platform, free);
    }

    function _writePlan(
        address token,
        Plan plan,
        address referrer,
        address creator,
        uint16 customRefBps,
        uint16 customCreatorBps
    ) private {
        plans[token] = TokenPlan({
            plan: plan,
            referrer: referrer,
            creator: creator,
            customRefBps: customRefBps,
            customCreatorBps: customCreatorBps,
            set: true
        });
        emit TokenPlanSet(token, plan, referrer, creator, customRefBps, customCreatorBps);
    }

    function _validateCustomTotalBps(uint16 refBpsOfTotal, uint16 creatorBonusBpsOfTotal)
        private
        pure
    {
        if (uint256(refBpsOfTotal) + uint256(creatorBonusBpsOfTotal) > PROTOCOL_BUCKET_BPS) {
            revert InvalidBps();
        }
        if (refBpsOfTotal == 0 && creatorBonusBpsOfTotal == 0) revert InvalidBps();
    }

    function _totalBpsToProtocolBps(uint16 refBpsOfTotal, uint16 creatorBonusBpsOfTotal)
        private
        pure
        returns (uint16 refBps, uint16 creatorBps)
    {
        // protocolShare = totalBps * 10000 / 3000
        refBps = uint16((uint256(refBpsOfTotal) * BPS) / PROTOCOL_BUCKET_BPS);
        creatorBps = uint16((uint256(creatorBonusBpsOfTotal) * BPS) / PROTOCOL_BUCKET_BPS);
        if (uint256(refBps) + uint256(creatorBps) > BPS) revert InvalidBps();
    }

    function _planOrNone(address launchToken) private view returns (TokenPlan memory p) {
        p = plans[launchToken];
        if (!p.set) {
            p = TokenPlan({
                plan: Plan.None,
                referrer: address(0),
                creator: address(0),
                customRefBps: 0,
                customCreatorBps: 0,
                set: true
            });
        }
    }

    /// @param amountCap Exact amount to attribute, or `type(uint256).max` for all free balance.
    function _distributeAsset(
        address launchToken,
        TokenPlan memory p,
        address asset,
        uint256 amountCap
    ) private {
        if (asset == address(0) || amountCap == 0) return;
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 free = bal - reserved[asset];
        if (free == 0) return;

        uint256 amount = amountCap == type(uint256).max ? free : amountCap;
        if (amount > free) revert InsufficientFreeBalance();

        uint256 refAmt;
        uint256 creatorAmt;
        uint256 platAmt;

        if (p.plan == Plan.None) {
            platAmt = amount;
        } else if (p.plan == Plan.Normal) {
            refAmt = (amount * 5) / 30;
            platAmt = amount - refAmt;
        } else if (p.plan == Plan.FullCut) {
            refAmt = amount;
        } else if (p.plan == Plan.CreatorBoost) {
            refAmt = (amount * 20) / 30;
            creatorAmt = amount - refAmt;
        } else {
            // Custom
            refAmt = (amount * p.customRefBps) / BPS;
            creatorAmt = (amount * p.customCreatorBps) / BPS;
            platAmt = amount - refAmt - creatorAmt;
        }

        if (refAmt != 0) {
            claimable[p.referrer][asset] += refAmt;
            reserved[asset] += refAmt;
        }
        if (creatorAmt != 0) {
            claimable[p.creator][asset] += creatorAmt;
            reserved[asset] += creatorAmt;
        }
        if (platAmt != 0) {
            claimable[platform][asset] += platAmt;
            reserved[asset] += platAmt;
        }

        emit Distributed(launchToken, asset, refAmt, creatorAmt, platAmt);
    }
}
