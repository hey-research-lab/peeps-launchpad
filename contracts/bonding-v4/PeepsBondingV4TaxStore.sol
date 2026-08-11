// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {IPeepsV4Factory} from "../v4/interfaces/IPeepsV4Factory.sol";
import {InvalidTaxConfig, NotFactory, ZeroAddress, AlreadyInitialized} from "../v4/errors/PeepsV4Errors.sol";

/// @title PeepsBondingV4TaxStore — creator-set Instant-style tax for bonding→V4 tokens
/// @notice Same bounds as Instant V4: linked buy/sell tax 1%–10%, bucket bps sum to 10000.
///         Used on the curve (router) and registered into {PeepsV4Registry} at migrate.
contract PeepsBondingV4TaxStore is Ownable2Step {
    address public factory;
    address public router;

    mapping(address token => IPeepsV4Factory.V4TaxLaunchConfig) internal _tax;
    mapping(address token => bool) public hasTax;

    event FactorySet(address indexed factory);
    event RouterSet(address indexed router);
    event TaxConfigured(address indexed token, IPeepsV4Factory.V4TaxLaunchConfig config);

    constructor(address owner_) Ownable(owner_) {}

    function setFactory(address factory_) external onlyOwner {
        if (factory_ == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert AlreadyInitialized();
        factory = factory_;
        emit FactorySet(factory_);
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        if (router != address(0)) revert AlreadyInitialized();
        router = router_;
        emit RouterSet(router_);
    }

    function taxConfig(address token) external view returns (IPeepsV4Factory.V4TaxLaunchConfig memory) {
        return _tax[token];
    }

    /// @notice Factory sets tax at bonding V4 create (immutable per token).
    function configureTax(address token, IPeepsV4Factory.V4TaxLaunchConfig calldata tax) external {
        if (msg.sender != factory) revert NotFactory();
        if (token == address(0)) revert ZeroAddress();
        if (hasTax[token]) revert InvalidTaxConfig();
        _validate(tax);
        _tax[token] = tax;
        hasTax[token] = true;
        emit TaxConfigured(token, tax);
    }

    function _validate(IPeepsV4Factory.V4TaxLaunchConfig calldata tax) internal pure {
        if (tax.taxRecipient == address(0)) revert InvalidTaxConfig();
        if (tax.buyTaxBps != tax.sellTaxBps) revert InvalidTaxConfig();
        if (tax.buyTaxBps < 100 || tax.buyTaxBps > 1_000) revert InvalidTaxConfig();
        if (tax.antiFarmerDays > 365) revert InvalidTaxConfig();
        uint256 sum = uint256(tax.fundsBps) + tax.burnBps + tax.dividendBps + tax.liquidityBps;
        if (sum != 10_000) revert InvalidTaxConfig();
    }
}
