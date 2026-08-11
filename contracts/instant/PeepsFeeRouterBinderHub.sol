// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IPeepsProtocolFeeRouterBinder {
    function redeemSpecialOffer(bytes32 codeHash, address token, address creator) external;

    function createSpecialOffer(
        bytes32 codeHash,
        uint8 plan,
        address referrer,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal,
        uint32 maxUses,
        uint64 expiresAt
    ) external;

    function updateSpecialOffer(bytes32 codeHash, uint32 maxUses, bool enabled, uint64 expiresAt)
        external;

    function setTokenPlan(address token, uint8 plan, address referrer, address creator) external;

    function setTokenPlanCustom(
        address token,
        address referrer,
        address creator,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal
    ) external;

    function setTraderReferrer(address trader, address referrer) external;
}

/**
 * @title PeepsFeeRouterBinderHub
 * @notice Drop-in binder for an existing PeepsProtocolFeeRouter so Instant / bonding
 *         factories can redeem specials and bind Normal refs without redeploying the
 *         router (offers stay put).
 * @dev Owner of the fee router must `setBinder(hub)`. Admin EOA keeps offer writes.
 *      Instant V4 factory may redeem. Bonding factories may redeem + setTokenPlan.
 */
contract PeepsFeeRouterBinderHub is Ownable2Step {
    error ZeroAddress();
    error NotAuthorized();

    event AdminUpdated(address indexed admin);
    event InstantV4FactoryUpdated(address indexed factory);
    event PlanFactoryUpdated(address indexed factory, bool enabled);

    IPeepsProtocolFeeRouterBinder public immutable feeRouter;
    address public admin;
    address public instantV4Factory;
    mapping(address factory => bool) public planFactory;

    constructor(address owner_, address feeRouter_, address admin_) Ownable(owner_) {
        if (feeRouter_ == address(0) || admin_ == address(0)) revert ZeroAddress();
        feeRouter = IPeepsProtocolFeeRouterBinder(feeRouter_);
        admin = admin_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin && msg.sender != owner()) revert NotAuthorized();
        _;
    }

    function setAdmin(address admin_) external onlyOwner {
        if (admin_ == address(0)) revert ZeroAddress();
        admin = admin_;
        emit AdminUpdated(admin_);
    }

    function setInstantV4Factory(address factory_) external onlyOwner {
        instantV4Factory = factory_;
        emit InstantV4FactoryUpdated(factory_);
    }

    function setPlanFactory(address factory_, bool enabled) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        planFactory[factory_] = enabled;
        emit PlanFactoryUpdated(factory_, enabled);
    }

    function redeemSpecialOffer(bytes32 codeHash, address token, address creator) external {
        if (
            msg.sender != admin && msg.sender != owner() && msg.sender != instantV4Factory
                && !planFactory[msg.sender]
        ) {
            revert NotAuthorized();
        }
        feeRouter.redeemSpecialOffer(codeHash, token, creator);
    }

    function createSpecialOffer(
        bytes32 codeHash,
        uint8 plan,
        address referrer,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal,
        uint32 maxUses,
        uint64 expiresAt
    ) external onlyAdmin {
        feeRouter.createSpecialOffer(
            codeHash, plan, referrer, refBpsOfTotal, creatorBonusBpsOfTotal, maxUses, expiresAt
        );
    }

    function updateSpecialOffer(bytes32 codeHash, uint32 maxUses, bool enabled, uint64 expiresAt)
        external
        onlyAdmin
    {
        feeRouter.updateSpecialOffer(codeHash, maxUses, enabled, expiresAt);
    }

    function setTokenPlan(address token, uint8 plan, address referrer, address creator) external {
        if (msg.sender != admin && msg.sender != owner() && !planFactory[msg.sender]) {
            revert NotAuthorized();
        }
        feeRouter.setTokenPlan(token, plan, referrer, creator);
    }

    function setTokenPlanCustom(
        address token,
        address referrer,
        address creator,
        uint16 refBpsOfTotal,
        uint16 creatorBonusBpsOfTotal
    ) external {
        if (msg.sender != admin && msg.sender != owner() && !planFactory[msg.sender]) {
            revert NotAuthorized();
        }
        feeRouter.setTokenPlanCustom(
            token, referrer, creator, refBpsOfTotal, creatorBonusBpsOfTotal
        );
    }

    function setTraderReferrer(address trader, address referrer) external onlyAdmin {
        feeRouter.setTraderReferrer(trader, referrer);
    }
}
