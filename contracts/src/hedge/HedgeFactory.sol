// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {HedgeVault} from "./HedgeVault.sol";
import {IBotV3PathRouter,IBotV3Factory} from "../interfaces/IBotV3Router.sol";

/// @notice Deploys Hedgerow hedge vaults: creator-picked USDT baskets bought through BDEX.
contract HedgeFactory {
    uint256 public constant MAX_COMPONENTS = 5;
    uint16 public constant MIN_WEIGHT_BPS = 500;
    uint16 public constant MAX_RAISE_FEE_BPS = 200;
    uint16 public constant MAX_LATE_FEE_BPS = 500;
    uint64 public constant MAX_LOCKUP = 90 days;
    address public immutable implementation;
    address public immutable usdt;
    address public immutable router;
    address public immutable dexFactory;
    address[] public vaults;
    event VaultCreated(uint256 indexed id,address indexed vault,address indexed creator,string name);

    constructor(address usdt_,address router_){
        require(usdt_.code.length>0&&router_.code.length>0,"missing infrastructure");
        usdt=usdt_;router=router_;dexFactory=IBotV3PathRouter(router_).factory();implementation=address(new HedgeVault());
    }
    function vaultCount() external view returns(uint256){return vaults.length;}

    function createVault(HedgeVault.Config calldata c) external returns(address vault){
        require(c.creator==msg.sender,"creator must be sender");
        require(bytes(c.name).length>0&&bytes(c.name).length<=48&&bytes(c.symbol).length>0&&bytes(c.symbol).length<=12,"invalid name");
        require(c.goal>0&&c.raiseEnd>=block.timestamp+1 hours&&c.raiseEnd<=block.timestamp+30 days,"invalid raise");
        require(c.lockup<=MAX_LOCKUP&&c.raiseFeeBps<=MAX_RAISE_FEE_BPS&&c.lateFeeBps<=MAX_LATE_FEE_BPS&&c.lateFeeBps>=c.raiseFeeBps,"invalid terms");
        validate(c.components);
        vault=Clones.clone(implementation);HedgeVault(vault).initialize(c,usdt,router);
        vaults.push(vault);emit VaultCreated(vaults.length-1,vault,msg.sender,c.name);
    }

    /// @notice A basket is 1–5 distinct tokens whose weights sum to 100%, each USDT or reachable through BDEX pools.
    function validate(HedgeVault.Component[] calldata c) public view {
        require(c.length>0&&c.length<=MAX_COMPONENTS,"1-5 tokens");
        uint256 total;
        for(uint256 i;i<c.length;i++){
            require(c[i].weightBps>=MIN_WEIGHT_BPS,"weight below 5%");total+=c[i].weightBps;
            for(uint256 j;j<i;j++)require(c[j].token!=c[i].token,"duplicate token");
            if(c[i].token==usdt){require(c[i].mid==address(0),"cash has no route");continue;}
            require(c[i].token.code.length>0,"not a contract");
            if(c[i].mid==address(0))require(_pool(usdt,c[i].token,c[i].fee1),"no USDT pool");
            else require(c[i].mid!=usdt&&c[i].mid!=c[i].token&&_pool(usdt,c[i].mid,c[i].fee1)&&_pool(c[i].mid,c[i].token,c[i].fee2),"no route");
        }
        require(total==10_000,"weights must total 100%");
    }
    function _pool(address a,address b,uint24 fee) private view returns(bool){address p=IBotV3Factory(dexFactory).getPool(a,b,fee);return p!=address(0)&&p.code.length>0;}
}
