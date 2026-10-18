// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IBotV3PathRouter} from "../interfaces/IBotV3Router.sol";

/// @notice A creator-designed token basket funded in USDT. Raise first, then trade; late entries pay a higher fee.
/// @dev Deployed as an EIP-1167 clone by HedgeFactory. Shares are priced by the vault's own holdings, never by DEX
///      prices: a late entry buys the basket and receives shares in proportion to the smallest relative increase in
///      any holding, so a manipulated pool price cannot mint extra shares. Shares are ERC20Votes for DAO-mode voting.
contract HedgeVault is ERC20Votes, ReentrancyGuard {
    using SafeERC20 for IERC20;
    enum Mode {Fixed, Managed, DAO}
    enum Phase {Raising, Active, Failed}
    /// @dev `mid` is address(0) for a direct USDT pool, otherwise the hop token (USDT -fee1-> mid -fee2-> token).
    struct Component {address token; uint16 weightBps; address mid; uint24 fee1; uint24 fee2;}
    struct Config {
        address creator; string name; string symbol; Mode mode;
        uint256 goal; uint64 raiseEnd; uint64 lockup; uint16 raiseFeeBps; uint16 lateFeeBps;
        Component[] components;
    }
    /// @dev quorumBase counts unclaimed raise shares too, so a few early claimers cannot pass a proposal alone.
    struct Proposal {address proposer; uint48 snapshot; uint64 start; uint64 end; uint256 forVotes; uint256 againstVotes; uint256 quorumBase; bool executed;}

    uint256 public constant FINALIZE_WINDOW = 3 days;
    uint256 public constant MANAGED_DELAY = 24 hours;
    uint256 public constant VOTING_PERIOD = 48 hours;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint256 public constant QUORUM_BPS = 2000;

    IERC20 public usdt;
    IBotV3PathRouter public router;
    address public factory;
    address public creator;
    Mode public mode;
    Phase public phase;
    uint256 public goal;
    uint64 public raiseEnd;
    uint64 public lockup;
    uint64 public lockupEnd;
    uint16 public raiseFeeBps;
    uint16 public lateFeeBps;
    uint256 public raised;
    /// @dev Raise shares owed but not yet claimed; counted in effectiveSupply so late entries price correctly.
    uint256 public unclaimed;
    mapping(address=>uint256) public deposits;
    string private _vaultName;
    string private _vaultSymbol;
    Component[] private _components;
    Proposal[] private _proposals;
    mapping(uint256=>Component[]) private _proposalComponents;
    mapping(uint256=>mapping(address=>bool)) public hasVoted;

    event Deposited(address indexed user,uint256 amount);
    event Finalized(uint256 raised,uint256 fee);
    event Refunded(address indexed user,uint256 amount);
    event SharesClaimed(address indexed user,uint256 shares);
    event Joined(address indexed user,uint256 amount,uint256 fee,uint256 shares);
    event Redeemed(address indexed user,uint256 shares,bool toUSDT,uint256 usdtOut);
    event Proposed(uint256 indexed id,address indexed proposer,uint64 start,uint64 end);
    event Voted(uint256 indexed id,address indexed voter,bool support,uint256 weight);
    event Rebalanced(uint256 indexed id);

    error Unauthorized();
    error WrongPhase();
    error Invalid();

    constructor() ERC20("","") EIP712("Sherhood Share","1") {factory=address(1);}

    function initialize(Config calldata c,address usdt_,address router_) external {
        if(factory!=address(0))revert Unauthorized();
        factory=msg.sender;creator=c.creator;mode=c.mode;goal=c.goal;raiseEnd=c.raiseEnd;lockup=c.lockup;
        raiseFeeBps=c.raiseFeeBps;lateFeeBps=c.lateFeeBps;_vaultName=c.name;_vaultSymbol=c.symbol;
        usdt=IERC20(usdt_);router=IBotV3PathRouter(router_);
        for(uint256 i;i<c.components.length;i++)_components.push(c.components[i]);
    }

    function name() public view override returns(string memory){return _vaultName;}
    function symbol() public view override returns(string memory){return _vaultSymbol;}
    function decimals() public pure override returns(uint8){return 6;}
    function components() external view returns(Component[] memory){return _components;}
    function proposalCount() external view returns(uint256){return _proposals.length;}
    function proposal(uint256 id) external view returns(Proposal memory p,Component[] memory comps){return (_proposals[id],_proposalComponents[id]);}
    function effectiveSupply() public view returns(uint256){return totalSupply()+unclaimed;}

    /// @notice Every token a share redeems into: the components, plus idle USDT when USDT is not a component.
    function holdings() public view returns(address[] memory tokens,uint256[] memory amounts){
        uint256 n=_components.length;bool cash;
        for(uint256 i;i<n;i++)if(_components[i].token==address(usdt))cash=true;
        tokens=new address[](cash?n:n+1);amounts=new uint256[](tokens.length);
        for(uint256 i;i<n;i++){tokens[i]=_components[i].token;amounts[i]=IERC20(tokens[i]).balanceOf(address(this));}
        if(!cash){tokens[n]=address(usdt);amounts[n]=usdt.balanceOf(address(this));}
    }

    // ---- Raise ----
    function deposit(uint256 amount) external nonReentrant {
        if(phase!=Phase.Raising||block.timestamp>=raiseEnd)revert WrongPhase();
        uint256 got=_pull(usdt,amount);deposits[msg.sender]+=got;raised+=got;emit Deposited(msg.sender,got);
    }
    /// @notice Creator buys the basket once the goal is met. `minOuts` follow component order (ignored for USDT).
    function finalize(uint256[] calldata minOuts,uint256 deadline) external nonReentrant {
        if(msg.sender!=creator)revert Unauthorized();
        if(phase!=Phase.Raising||raised<goal||block.timestamp>uint256(raiseEnd)+FINALIZE_WINDOW)revert WrongPhase();
        phase=Phase.Active;lockupEnd=uint64(block.timestamp)+lockup;
        uint256 fee=raised*raiseFeeBps/10_000;if(fee>0)usdt.safeTransfer(creator,fee);
        unclaimed=raised-fee;_buy(raised-fee,minOuts,deadline);emit Finalized(raised,fee);
    }
    function refundable() public view returns(bool){
        if(phase==Phase.Failed)return true;
        return phase==Phase.Raising&&block.timestamp>=raiseEnd&&(raised<goal||block.timestamp>uint256(raiseEnd)+FINALIZE_WINDOW);
    }
    function refund() external nonReentrant {
        if(!refundable())revert WrongPhase();phase=Phase.Failed;
        uint256 amount=deposits[msg.sender];if(amount==0)revert Invalid();deposits[msg.sender]=0;
        usdt.safeTransfer(msg.sender,amount);emit Refunded(msg.sender,amount);
    }
    function claimable(address user) public view returns(uint256){return phase==Phase.Active?deposits[user]*(10_000-raiseFeeBps)/10_000:0;}
    function claimShares() public {
        uint256 shares=claimable(msg.sender);if(shares==0)revert Invalid();
        deposits[msg.sender]=0;unclaimed-=shares;_mint(msg.sender,shares);emit SharesClaimed(msg.sender,shares);
    }

    // ---- Late entry and exit ----
    function join(uint256 amount,uint256[] calldata minOuts,uint256 deadline) external nonReentrant returns(uint256 shares){
        if(phase!=Phase.Active)revert WrongPhase();
        (,uint256[] memory before)=holdings();uint256 supply=effectiveSupply();
        uint256 got=_pull(usdt,amount);uint256 fee=got*lateFeeBps/10_000;if(fee>0)usdt.safeTransfer(creator,fee);
        _buy(got-fee,minOuts,deadline);
        (,uint256[] memory afterBal)=holdings();
        uint256 ratio=type(uint256).max;bool held;
        for(uint256 i;i<_components.length;i++)if(before[i]>0){held=true;uint256 r=(afterBal[i]-before[i])*1e18/before[i];if(r<ratio)ratio=r;}
        shares=(supply==0||!held)?got-fee:supply*ratio/1e18;
        if(shares==0)revert Invalid();_mint(msg.sender,shares);emit Joined(msg.sender,got,fee,shares);
    }
    function canRedeem() public view returns(bool){return phase==Phase.Active&&block.timestamp>=lockupEnd;}
    /// @notice Burn shares for a pro-rata slice of every holding.
    function redeem(uint256 shares) external nonReentrant {
        (address[] memory tokens,uint256[] memory out)=_burnFor(shares);
        for(uint256 i;i<tokens.length;i++)if(out[i]>0)IERC20(tokens[i]).safeTransfer(msg.sender,out[i]);
        emit Redeemed(msg.sender,shares,false,0);
    }
    /// @notice Burn shares and sell the slice back to USDT. `minOuts` follow component order; `minTotal` bounds the sum.
    function redeemToUSDT(uint256 shares,uint256[] calldata minOuts,uint256 minTotal,uint256 deadline) external nonReentrant returns(uint256 total){
        (address[] memory tokens,uint256[] memory out)=_burnFor(shares);
        for(uint256 i;i<tokens.length;i++){
            if(out[i]==0)continue;
            if(tokens[i]==address(usdt)){total+=out[i];continue;}
            total+=_swap(tokens[i],_reverse(_components[i]),out[i],minOuts[i],deadline);
        }
        if(total<minTotal)revert Invalid();usdt.safeTransfer(msg.sender,total);emit Redeemed(msg.sender,shares,true,total);
    }

    // ---- Basket changes ----
    /// @notice Managed: creator only, after lockup. DAO: creator or any holder with 1% of votes.
    function propose(Component[] calldata next) external returns(uint256 id){
        if(phase!=Phase.Active||mode==Mode.Fixed)revert WrongPhase();
        if(mode==Mode.Managed&&(msg.sender!=creator||block.timestamp<lockupEnd))revert Unauthorized();
        if(mode==Mode.DAO&&msg.sender!=creator&&getVotes(msg.sender)*100<effectiveSupply())revert Unauthorized();
        IHedgeFactory(factory).validate(next);
        id=_proposals.length;uint64 start=uint64(block.timestamp);
        _proposals.push(Proposal(msg.sender,uint48(clock()-1),start,start+uint64(mode==Mode.DAO?VOTING_PERIOD:MANAGED_DELAY),0,0,effectiveSupply(),false));
        for(uint256 i;i<next.length;i++)_proposalComponents[id].push(next[i]);
        emit Proposed(id,msg.sender,start,_proposals[id].end);
    }
    function vote(uint256 id,bool support) external {
        Proposal storage p=_proposals[id];
        if(mode!=Mode.DAO||block.timestamp>=p.end||hasVoted[id][msg.sender])revert WrongPhase();
        uint256 weight=getPastVotes(msg.sender,p.snapshot);if(weight==0)revert Invalid();
        hasVoted[id][msg.sender]=true;if(support)p.forVotes+=weight;else p.againstVotes+=weight;emit Voted(id,msg.sender,support,weight);
    }
    function passed(uint256 id) public view returns(bool){
        Proposal storage p=_proposals[id];
        if(p.executed||block.timestamp<p.end||block.timestamp>uint256(p.end)+EXECUTION_WINDOW)return false;
        if(mode==Mode.Managed)return true;
        return p.forVotes>p.againstVotes&&p.forVotes*10_000>=p.quorumBase*QUORUM_BPS;
    }
    /// @notice Creator sells the current basket to USDT and buys the approved one. Mins follow each basket's order.
    function execute(uint256 id,uint256[] calldata sellMins,uint256[] calldata buyMins,uint256 deadline) external nonReentrant {
        if(msg.sender!=creator)revert Unauthorized();if(!passed(id))revert WrongPhase();
        _proposals[id].executed=true;
        for(uint256 i;i<_components.length;i++){Component memory c=_components[i];if(c.token==address(usdt))continue;
            uint256 bal=IERC20(c.token).balanceOf(address(this));if(bal>0)_swap(c.token,_reverse(c),bal,sellMins[i],deadline);}
        delete _components;Component[] storage next=_proposalComponents[id];
        for(uint256 i;i<next.length;i++)_components.push(next[i]);
        _buy(usdt.balanceOf(address(this)),buyMins,deadline);emit Rebalanced(id);
    }

    // ---- Internals ----
    function _burnFor(uint256 shares) private returns(address[] memory tokens,uint256[] memory out){
        if(!canRedeem())revert WrongPhase();if(shares==0)revert Invalid();
        uint256 supply=effectiveSupply();(tokens,out)=holdings();_burn(msg.sender,shares);
        for(uint256 i;i<out.length;i++)out[i]=out[i]*shares/supply;
    }
    function _buy(uint256 amount,uint256[] calldata minOuts,uint256 deadline) private {
        uint256 n=_components.length;if(minOuts.length!=n)revert Invalid();
        for(uint256 i;i<n;i++){Component memory c=_components[i];if(c.token==address(usdt))continue;
            uint256 part=amount*c.weightBps/10_000;if(part>0)_swap(address(usdt),_path(c),part,minOuts[i],deadline);}
    }
    function _swap(address tokenIn,bytes memory path,uint256 amountIn,uint256 minOut,uint256 deadline) private returns(uint256 out){
        if(minOut==0)revert Invalid();
        IERC20(tokenIn).forceApprove(address(router),amountIn);
        out=router.exactInput(IBotV3PathRouter.PathParams(path,address(this),deadline,amountIn,minOut));
        IERC20(tokenIn).forceApprove(address(router),0);
    }
    function _path(Component memory c) private view returns(bytes memory){
        return c.mid==address(0)?abi.encodePacked(address(usdt),c.fee1,c.token):abi.encodePacked(address(usdt),c.fee1,c.mid,c.fee2,c.token);
    }
    function _reverse(Component memory c) private view returns(bytes memory){
        return c.mid==address(0)?abi.encodePacked(c.token,c.fee1,address(usdt)):abi.encodePacked(c.token,c.fee2,c.mid,c.fee1,address(usdt));
    }
    function _pull(IERC20 token,uint256 amount) private returns(uint256){
        if(amount==0)revert Invalid();uint256 before=token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender,address(this),amount);return token.balanceOf(address(this))-before;
    }
    /// @dev Holders vote with their own balance unless they delegate elsewhere.
    function _update(address from,address to,uint256 value) internal override {
        if(to!=address(0)&&delegates(to)==address(0))_delegate(to,to);
        super._update(from,to,value);
    }
}

interface IHedgeFactory {function validate(HedgeVault.Component[] calldata c) external view;}
