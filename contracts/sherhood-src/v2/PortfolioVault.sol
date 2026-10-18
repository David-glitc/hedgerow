// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IStockRegistry} from "../interfaces/IStockRegistry.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";
import {DecisionMarket, DecisionMarketFactory} from "./DecisionMarket.sol";

interface IPortfolioOracle { function value(address token, uint256 amount) external view returns (uint256 dollars18); }
interface IFeed { function decimals() external view returns(uint8); function latestRoundData() external view returns(uint80,int256,uint256,uint256,uint80); }

/// @notice Fixed feed configuration. Values in USD with 18 decimals; stale feeds revert.
contract PortfolioOracle is IPortfolioOracle {
    mapping(address=>address) public feeds;
    uint256 public immutable maxAge;
    constructor(address[] memory tokens, address[] memory feeds_, uint256 maxAge_) {
        require(tokens.length == feeds_.length && maxAge_ > 0 && maxAge_ <= 1 days, "Oracle: config");
        maxAge = maxAge_;
        for(uint256 i;i<tokens.length;i++){require(tokens[i]!=address(0)&&feeds_[i]!=address(0)&&feeds[tokens[i]]==address(0),"Oracle: feed");feeds[tokens[i]]=feeds_[i];}
    }
    function value(address token, uint256 amount) external view returns(uint256) {
        IFeed feed=IFeed(feeds[token]);require(address(feed)!=address(0),"Oracle: missing");
        (uint80 round,int256 price,,uint256 updated,uint80 answered)=feed.latestRoundData();
        require(price>0&&updated>0&&updated<=block.timestamp&&block.timestamp-updated<=maxAge&&answered>=round,"Oracle: stale");
        uint8 tokenDecimals=IERC20Metadata(token).decimals(); uint8 feedDecimals=feed.decimals();
        require(tokenDecimals<=18&&feedDecimals<=18,"Oracle: decimals");
        return Math.mulDiv(amount,uint256(price)*10**(18-feedDecimals),10**tokenDecimals);
    }
}

/// @notice Separate fungible community vault. Legacy NFT pools are not upgradeable.
/// Shares redeem pro rata in kind. Only an approved market can execute a committed plan.
contract PortfolioVault is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    IERC20 public immutable collateral;
    IPortfolioOracle public immutable oracle;
    IStockRegistry public immutable registry;
    ISwapRouter02 public immutable router;
    DecisionMarketFactory public immutable marketFactory;
    uint8 public immutable collateralDecimals;
    address[] public holdings;
    DecisionMarket public activeMarket;
    uint256 public totalCreatorFees;
    address public immutable creator;
    uint256 public constant DEPOSIT_FEE_BPS=100;
    address public immutable treasury;
    event Deposited(address indexed user,uint256 amount,uint256 shares);
    event Redeemed(address indexed user,uint256 shares);
    event Rebalanced(address indexed market,bytes32 indexed planHash);
    event DecisionOpened(address indexed market,bytes32 indexed planHash);

    struct Plan {
        address[] tokens;
        uint16[] weightsBps;
        uint256[] minSellOut;
        uint256[] minBuyOut;
        uint256 deadline;
    }
    constructor(address owner_,address creator_,address collateral_,address treasury_,address oracle_,address registry_,address router_,address factory_)
        ERC20("Sherhood Community Share","SHRC") Ownable(owner_)
    {
        require(creator_!=address(0)&&treasury_!=address(0)&&collateral_!=address(0)&&oracle_!=address(0)&&registry_!=address(0)&&router_!=address(0)&&factory_!=address(0),"Vault: config");
        creator=creator_;treasury=treasury_;collateral=IERC20(collateral_);oracle=IPortfolioOracle(oracle_);registry=IStockRegistry(registry_);router=ISwapRouter02(router_);marketFactory=DecisionMarketFactory(factory_);
        collateralDecimals=IERC20Metadata(collateral_).decimals();require(collateralDecimals<=18,"Vault: decimals");
    }
    function totalValue() public view returns(uint256 nav) {
        nav=oracle.value(address(collateral),collateral.balanceOf(address(this)));
        for(uint256 i;i<holdings.length;i++)nav+=oracle.value(holdings[i],IERC20(holdings[i]).balanceOf(address(this)));
    }
    function getHoldings() external view returns(address[] memory){return holdings;}
    function previewDeposit(uint256 amount) external view returns(uint256 shares){
        uint256 net=amount-Math.mulDiv(amount,DEPOSIT_FEE_BPS,10000);
        uint256 value=oracle.value(address(collateral),net);
        return totalSupply()==0?value:Math.mulDiv(value,totalSupply(),totalValue());
    }
    function deposit(uint256 amount,uint256 minShares) external nonReentrant returns(uint256 shares) {
        require(amount>0,"Vault: amount");
        // Blocks dilution/manipulation of the outstanding portfolio during a decision.
        require(address(activeMarket)==address(0)||activeMarket.settled(),"Vault: decision active");
        uint256 supply=totalSupply(); uint256 nav=totalValue(); uint256 fee=Math.mulDiv(amount,DEPOSIT_FEE_BPS,10000);
        uint256 net=amount-fee;
        uint256 depositValue=oracle.value(address(collateral),net);
        shares=supply==0?depositValue:Math.mulDiv(depositValue,supply,nav);
        require(shares>=minShares&&shares>0,"Vault: slippage");
        uint256 before=collateral.balanceOf(address(this));collateral.safeTransferFrom(msg.sender,address(this),amount);require(collateral.balanceOf(address(this))-before==amount,"Vault: transfer tax");
        uint256 creatorFee=fee*30/100;totalCreatorFees+=creatorFee;
        if(creatorFee>0)collateral.safeTransfer(creator,creatorFee);if(fee>creatorFee)collateral.safeTransfer(treasury,fee-creatorFee);
        _mint(msg.sender,shares);emit Deposited(msg.sender,amount,shares);
    }
    function redeem(uint256 shares) external nonReentrant {
        require(shares>0,"Vault: amount");uint256 supply=totalSupply();_burn(msg.sender,shares);
        uint256 cash=Math.mulDiv(collateral.balanceOf(address(this)),shares,supply);if(cash>0)collateral.safeTransfer(msg.sender,cash);
        for(uint256 i;i<holdings.length;i++){IERC20 token=IERC20(holdings[i]);uint256 amount=Math.mulDiv(token.balanceOf(address(this)),shares,supply);if(amount>0)token.safeTransfer(msg.sender,amount);}
        emit Redeemed(msg.sender,shares);
    }
    function planHash(Plan calldata plan) public pure returns(bytes32) {return keccak256(abi.encode(plan));}
    function openDecision(Plan calldata plan,uint256 opens,uint256 duration,uint256 delay,uint256 threshold,uint256 minVolume) external onlyOwner returns(address market) {
        require(totalSupply()>0&&(address(activeMarket)==address(0)||activeMarket.settled()),"Vault: active");
        require(threshold>=100&&minVolume>0,"Vault: thresholds");
        require(plan.deadline>=opens+duration+delay&&plan.deadline<=opens+duration+delay+2 days,"Vault: deadline");
        _validate(plan);
        market=marketFactory.create(address(collateral),msg.sender,planHash(plan),opens,duration,delay,threshold,minVolume);activeMarket=DecisionMarket(market);
        emit DecisionOpened(market,planHash(plan));
    }
    function execute(Plan calldata plan) external nonReentrant {
        DecisionMarket market=activeMarket;require(address(market)!=address(0)&&market.decided()&&market.passed()&&!market.settled(),"Vault: decision");
        require(block.timestamp>=market.closesAt()+market.executionDelay()&&block.timestamp<=market.executionDeadline()&&block.timestamp<=plan.deadline,"Vault: timing");
        require(planHash(plan)==market.proposalHash(),"Vault: plan hash");_validate(plan);
        // All swap minimums were committed before markets opened. Reverts are atomic.
        for(uint256 i;i<holdings.length;i++){
            address token=holdings[i];uint256 amount=IERC20(token).balanceOf(address(this));
            if(amount>0){IERC20(token).forceApprove(address(router),amount);router.exactInputSingle(ISwapRouter02.ExactInputSingleParams(token,address(collateral),registry.getToken(token).defaultPoolFee,address(this),amount,plan.minSellOut[i],0));IERC20(token).forceApprove(address(router),0);}
        }
        uint256 budget=collateral.balanceOf(address(this));delete holdings;
        for(uint256 i;i<plan.tokens.length;i++){
            uint256 spend=Math.mulDiv(budget,plan.weightsBps[i],10000);require(spend>0,"Vault: dust");collateral.forceApprove(address(router),spend);
            router.exactInputSingle(ISwapRouter02.ExactInputSingleParams(address(collateral),plan.tokens[i],registry.getToken(plan.tokens[i]).defaultPoolFee,address(this),spend,plan.minBuyOut[i],0));collateral.forceApprove(address(router),0);holdings.push(plan.tokens[i]);
        }
        market.confirmExecution();emit Rebalanced(address(market),market.proposalHash());
    }
    function _validate(Plan calldata plan) private view {
        require(plan.tokens.length>0&&plan.tokens.length<=8&&plan.tokens.length==plan.weightsBps.length&&plan.tokens.length==plan.minBuyOut.length&&plan.minSellOut.length==holdings.length,"Vault: plan shape");
        uint256 total;
        for(uint256 i;i<plan.tokens.length;i++){require(plan.tokens[i]!=address(collateral)&&registry.isAllowed(plan.tokens[i])&&plan.weightsBps[i]>0&&plan.minBuyOut[i]>0,"Vault: token");oracle.value(plan.tokens[i],10**IERC20Metadata(plan.tokens[i]).decimals());for(uint256 j;j<i;j++)require(plan.tokens[i]!=plan.tokens[j],"Vault: duplicate");total+=plan.weightsBps[i];}
        for(uint256 i;i<plan.minSellOut.length;i++)require(plan.minSellOut[i]>0,"Vault: sell minimum");
        require(total==10000,"Vault: weights");
    }
}
