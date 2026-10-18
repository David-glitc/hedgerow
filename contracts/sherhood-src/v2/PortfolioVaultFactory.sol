// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PortfolioVault} from "./PortfolioVault.sol";

/// @notice Community vault registry with fixed infrastructure and creator ownership.
contract PortfolioVaultFactory {
    address public immutable collateral;
    address public immutable treasury;
    address public immutable oracle;
    address public immutable registry;
    address public immutable router;
    address public immutable decisionFactory;
    mapping(address=>bool) public isVault;
    address[] public vaults;
    event VaultCreated(address indexed vault,address indexed creator);
    constructor(address collateral_,address treasury_,address oracle_,address registry_,address router_,address decisionFactory_) {
        require(collateral_!=address(0)&&treasury_!=address(0)&&oracle_!=address(0)&&registry_!=address(0)&&router_!=address(0)&&decisionFactory_!=address(0),"Factory: config");
        collateral=collateral_;treasury=treasury_;oracle=oracle_;registry=registry_;router=router_;decisionFactory=decisionFactory_;
    }
    function create() external returns(address vault) {
        vault=address(new PortfolioVault(msg.sender,msg.sender,collateral,treasury,oracle,registry,router,decisionFactory));isVault[vault]=true;vaults.push(vault);emit VaultCreated(vault,msg.sender);
    }
    function getVaults() external view returns(address[] memory){return vaults;}
}
