// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HedgeFactory} from "../src/hedge/HedgeFactory.sol";
import {HedgeVault} from "../src/hedge/HedgeVault.sol";

contract Tok is ERC20 {uint8 d;constructor(string memory s,uint8 d_) ERC20(s,s){d=d_;} function decimals() public view override returns(uint8){return d;} function mint(address a,uint256 n) external {_mint(a,n);}}
/// @dev Multi-hop router with settable end-to-end rates (1e18 scale), plus a pool registry standing in for the BDEX factory.
contract PathRouter {
    mapping(address=>mapping(address=>uint256)) public rate;mapping(bytes32=>bool) public pools;
    function factory() external view returns(address){return address(this);}
    function setPool(address a,address b,uint24 fee) external {pools[keccak256(abi.encode(a,b,fee))]=true;pools[keccak256(abi.encode(b,a,fee))]=true;}
    function getPool(address a,address b,uint24 fee) external view returns(address){return pools[keccak256(abi.encode(a,b,fee))]?address(this):address(0);}
    function setRate(address a,address b,uint256 r) external {rate[a][b]=r;}
    struct PathParams {bytes path; address recipient; uint256 deadline; uint256 amountIn; uint256 amountOutMinimum;}
    function exactInput(PathParams calldata p) external returns(uint256 out){
        require(block.timestamp<=p.deadline,"Transaction too old");
        bytes memory path=p.path;address a;address b;uint256 n=path.length;
        assembly{a:=shr(96,mload(add(path,32))) b:=shr(96,mload(add(add(path,32),sub(n,20))))}
        ERC20(a).transferFrom(msg.sender,address(this),p.amountIn);out=p.amountIn*rate[a][b]/1e18;
        require(out>=p.amountOutMinimum,"Too little received");Tok(b).mint(p.recipient,out);
    }
}

contract HedgeTest is Test {
    Tok usdt;Tok wbot;Tok ca;PathRouter dex;HedgeFactory factory;
    address creator=address(0xC0);address alice=address(0xA11CE);address bob=address(0xB0B);address carol=address(0xCA);
    function setUp() public {
        usdt=new Tok("USDT",6);wbot=new Tok("WBOT",18);ca=new Tok("CA",18);dex=new PathRouter();
        dex.setPool(address(usdt),address(wbot),3000);dex.setPool(address(wbot),address(ca),10000);
        // 1 USDT (1e6) buys 0.08 WBOT and 0.2 CA; selling reverses at the same price.
        dex.setRate(address(usdt),address(wbot),0.08e30);dex.setRate(address(wbot),address(usdt),12.5e6);
        dex.setRate(address(usdt),address(ca),0.2e30);dex.setRate(address(ca),address(usdt),5e6);
        factory=new HedgeFactory(address(usdt),address(dex));
        for(uint256 i;i<4;i++){address u=[alice,bob,carol,creator][i];usdt.mint(u,1_000e6);}
    }
    function _basket() internal view returns(HedgeVault.Component[] memory c){
        c=new HedgeVault.Component[](3);
        c[0]=HedgeVault.Component(address(wbot),5000,address(0),3000,0);
        c[1]=HedgeVault.Component(address(ca),3000,address(wbot),3000,10000);
        c[2]=HedgeVault.Component(address(usdt),2000,address(0),0,0);
    }
    function _create(HedgeVault.Mode mode,uint64 lockup) internal returns(HedgeVault v){
        HedgeVault.Config memory c=HedgeVault.Config(creator,"Agent Basket","AGB",mode,100e6,uint64(block.timestamp+1 days),lockup,100,300,_basket());
        vm.prank(creator);v=HedgeVault(factory.createVault(c));
    }
    function _dep(HedgeVault v,address u,uint256 n) internal {vm.startPrank(u);usdt.approve(address(v),n);v.deposit(n);vm.stopPrank();}
    function _mins() internal pure returns(uint256[] memory m){m=new uint256[](3);m[0]=1;m[1]=1;m[2]=0;}
    function _launch(HedgeVault.Mode mode,uint64 lockup) internal returns(HedgeVault v){
        v=_create(mode,lockup);_dep(v,alice,60e6);_dep(v,bob,40e6);
        vm.prank(creator);v.finalize(_mins(),block.timestamp);
        vm.prank(alice);v.claimShares();vm.prank(bob);v.claimShares();
    }

    function test_raiseFinalizeClaimAndRedeemInKind() public {
        HedgeVault v=_launch(HedgeVault.Mode.Fixed,0);
        assertEq(usdt.balanceOf(creator),1_000e6+1e6);                       // 1% raise fee on 100 USDT
        assertEq(wbot.balanceOf(address(v)),99e6*5000/10000*0.08e30/1e18);    // 49.5 USDT of WBOT
        assertEq(ca.balanceOf(address(v)),99e6*3000/10000*0.2e30/1e18);       // 29.7 USDT of CA
        assertEq(usdt.balanceOf(address(v)),99e6-49.5e6-29.7e6);              // 20% cash
        assertEq(v.balanceOf(alice),59.4e6);assertEq(v.effectiveSupply(),99e6);assertEq(v.getVotes(alice),59.4e6);
        uint256 w=wbot.balanceOf(address(v));vm.prank(bob);v.redeem(39.6e6);
        assertEq(wbot.balanceOf(bob),w*39.6e6/99e6);assertEq(usdt.balanceOf(bob),960e6+19.8e6*39.6e6/99e6);
        vm.prank(bob);vm.expectRevert();v.claimShares();
    }
    function test_underfundedAndUnfinalizedRaisesRefund() public {
        HedgeVault v=_create(HedgeVault.Mode.Fixed,0);_dep(v,alice,60e6);
        vm.prank(alice);vm.expectRevert(HedgeVault.WrongPhase.selector);v.refund();
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);v.finalize(_mins(),block.timestamp);
        vm.warp(block.timestamp+1 days);vm.prank(alice);v.refund();assertEq(usdt.balanceOf(alice),1_000e6);
        vm.prank(bob);usdt.approve(address(v),1e6);vm.prank(bob);vm.expectRevert(HedgeVault.WrongPhase.selector);v.deposit(1e6);
        // Goal met but the creator never finalizes: refunds open after the finalize window.
        HedgeVault w=_create(HedgeVault.Mode.Fixed,0);_dep(w,alice,100e6);
        vm.prank(alice);vm.expectRevert(HedgeVault.Unauthorized.selector);w.finalize(_mins(),block.timestamp);
        vm.warp(block.timestamp+1 days+3 days+1);
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);w.finalize(_mins(),block.timestamp);
        vm.prank(alice);w.refund();assertEq(usdt.balanceOf(alice),1_000e6);
    }
    function test_lateEntryPaysHigherFeeAndCannotDiluteHolders() public {
        HedgeVault v=_launch(HedgeVault.Mode.Fixed,0);
        vm.startPrank(carol);usdt.approve(address(v),type(uint256).max);
        uint256 shares=v.join(10e6,_mins(),block.timestamp);vm.stopPrank();
        assertEq(usdt.balanceOf(creator),1_001e6+0.3e6);                      // 3% late fee
        assertApproxEqAbs(shares,9.7e6,2);                                    // same prices: 1 share per net USDT
        // Someone pumps CA's price before a join: the joiner gets fewer CA, so fewer shares; holders keep their slice.
        dex.setRate(address(usdt),address(ca),0.1e30);
        uint256 perShareBefore=wbot.balanceOf(address(v))*1e18/v.effectiveSupply();
        vm.prank(carol);uint256 cheap=v.join(10e6,_mins(),block.timestamp);
        assertLt(cheap,shares*7/10);assertGe(wbot.balanceOf(address(v))*1e18/v.effectiveSupply(),perShareBefore);
        uint256[] memory high=_mins();high[0]=1e30;vm.prank(carol);vm.expectRevert(bytes("Too little received"));v.join(10e6,high,block.timestamp);
    }
    function test_lockupAndRedeemToUSDT() public {
        HedgeVault v=_launch(HedgeVault.Mode.Fixed,7 days);
        vm.prank(alice);vm.expectRevert(HedgeVault.WrongPhase.selector);v.redeem(1e6);
        vm.warp(block.timestamp+7 days);
        uint256 before=usdt.balanceOf(alice);vm.prank(alice);vm.expectRevert(HedgeVault.Invalid.selector);v.redeemToCash(59.4e6,_mins(),1e30,block.timestamp);
        vm.prank(alice);uint256 out=v.redeemToCash(59.4e6,_mins(),59e6,block.timestamp);
        assertApproxEqAbs(out,59.4e6,10);assertEq(usdt.balanceOf(alice)-before,out);assertEq(v.balanceOf(alice),0);
    }
    function test_managedRebalanceIsCreatorOnlyAfterLockupAndDelay() public {
        HedgeVault v=_launch(HedgeVault.Mode.Managed,2 days);
        HedgeVault.Component[] memory next=new HedgeVault.Component[](2);
        next[0]=HedgeVault.Component(address(wbot),8000,address(0),3000,0);next[1]=HedgeVault.Component(address(usdt),2000,address(0),0,0);
        vm.prank(creator);vm.expectRevert(HedgeVault.Unauthorized.selector);v.propose(next);
        vm.warp(block.timestamp+2 days);
        vm.prank(alice);vm.expectRevert(HedgeVault.Unauthorized.selector);v.propose(next);
        vm.prank(creator);uint256 id=v.propose(next);
        uint256[] memory sell=_mins();uint256[] memory buy=new uint256[](2);buy[0]=1;
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);v.execute(id,sell,buy,block.timestamp);
        vm.warp(block.timestamp+24 hours);
        vm.prank(alice);vm.expectRevert(HedgeVault.Unauthorized.selector);v.execute(id,sell,buy,block.timestamp);
        vm.prank(creator);v.execute(id,sell,buy,block.timestamp);
        assertEq(ca.balanceOf(address(v)),0);assertEq(v.components().length,2);
        assertApproxEqAbs(wbot.balanceOf(address(v)),99e6*8000/10000*0.08e30/1e18,1e12);
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);v.execute(id,sell,buy,block.timestamp);
    }
    function test_daoVoteNeedsQuorumMajorityAndSnapshot() public {
        HedgeVault v=_launch(HedgeVault.Mode.DAO,0);
        HedgeVault.Component[] memory next=new HedgeVault.Component[](1);next[0]=HedgeVault.Component(address(usdt),10000,address(0),0,0);
        vm.prank(carol);vm.expectRevert(HedgeVault.Unauthorized.selector);v.propose(next);  // no shares
        vm.roll(block.number+1);vm.prank(bob);uint256 id=v.propose(next);
        // Bob votes, then hands his shares to Carol: Carol's snapshot weight is zero, so no double vote.
        vm.prank(bob);v.vote(id,true);vm.prank(bob);v.transfer(carol,39.6e6);
        vm.prank(carol);vm.expectRevert(HedgeVault.Invalid.selector);v.vote(id,true);
        vm.prank(alice);v.vote(id,false);vm.prank(alice);vm.expectRevert(HedgeVault.WrongPhase.selector);v.vote(id,true);
        vm.warp(block.timestamp+48 hours);assertFalse(v.passed(id));                       // 40% for vs 60% against
        uint256[] memory sell=_mins();uint256[] memory buy=new uint256[](1);
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);v.execute(id,sell,buy,block.timestamp);
        vm.roll(block.number+1);vm.prank(alice);uint256 id2=v.propose(next);vm.prank(alice);v.vote(id2,true);
        vm.warp(block.timestamp+48 hours);assertTrue(v.passed(id2));
        vm.prank(creator);v.execute(id2,sell,buy,block.timestamp);
        assertEq(wbot.balanceOf(address(v)),0);assertEq(ca.balanceOf(address(v)),0);assertApproxEqAbs(usdt.balanceOf(address(v)),99e6,10);
        vm.warp(block.timestamp+8 days);assertFalse(v.passed(id2));
    }
    function test_daoQuorumCountsUnclaimedRaiseShares() public {
        HedgeVault v=_create(HedgeVault.Mode.DAO,0);_dep(v,alice,85e6);_dep(v,bob,15e6);
        vm.prank(creator);v.finalize(_mins(),block.timestamp);vm.prank(bob);v.claimShares();   // Alice has not claimed
        HedgeVault.Component[] memory next=new HedgeVault.Component[](1);next[0]=HedgeVault.Component(address(usdt),10000,address(0),0,0);
        vm.roll(block.number+1);vm.prank(bob);uint256 id=v.propose(next);vm.prank(bob);v.vote(id,true);
        vm.warp(block.timestamp+48 hours);assertFalse(v.passed(id));                         // 15% of all shares < 20% quorum
    }
    function test_fixedBasketCannotChangeAndClonesCannotReinitialize() public {
        HedgeVault v=_launch(HedgeVault.Mode.Fixed,0);
        vm.prank(creator);vm.expectRevert(HedgeVault.WrongPhase.selector);v.propose(_basket());
        HedgeVault.Config memory c=HedgeVault.Config(alice,"x","x",HedgeVault.Mode.Fixed,1,0,0,0,0,_basket());
        vm.expectRevert(HedgeVault.Unauthorized.selector);v.initialize(c,address(usdt),address(dex));
        HedgeVault impl=HedgeVault(factory.implementation());vm.expectRevert(HedgeVault.Unauthorized.selector);impl.initialize(c,address(usdt),address(dex));
    }
    function test_factoryRejectsBadBasketsAndTerms() public {
        HedgeVault.Component[] memory c=_basket();
        HedgeVault.Config memory cfg=HedgeVault.Config(creator,"Agent Basket","AGB",HedgeVault.Mode.Fixed,100e6,uint64(block.timestamp+1 days),0,100,300,c);
        vm.expectRevert(bytes("creator must be sender"));factory.createVault(cfg);
        vm.startPrank(creator);
        c[0].weightBps=4000;vm.expectRevert(bytes("weights must total 100%"));factory.createVault(cfg);c[0].weightBps=5000;
        c[1].fee2=500;vm.expectRevert(bytes("no route"));factory.createVault(cfg);c[1].fee2=10000;
        c[2].token=address(wbot);vm.expectRevert(bytes("duplicate token"));factory.createVault(cfg);c[2].token=address(usdt);
        c[1].mid=address(0);vm.expectRevert(bytes("no cash pool"));factory.createVault(cfg);c[1].mid=address(wbot);
        cfg.lateFeeBps=50;vm.expectRevert(bytes("invalid terms"));factory.createVault(cfg);cfg.lateFeeBps=600;vm.expectRevert(bytes("invalid terms"));factory.createVault(cfg);cfg.lateFeeBps=300;
        cfg.raiseEnd=uint64(block.timestamp+31 days);vm.expectRevert(bytes("invalid raise"));factory.createVault(cfg);cfg.raiseEnd=uint64(block.timestamp+1 days);
        factory.createVault(cfg);assertEq(factory.vaultCount(),1);vm.stopPrank();
    }

    /// @dev Mainnet configuration: the cash token is 18-decimal WBOT. Shares follow its decimals and every exit works.
    function test_wbotCashBasket() public {
        HedgeFactory wf=new HedgeFactory(address(wbot),address(dex));
        dex.setRate(address(wbot),address(ca),2.5e18);dex.setRate(address(ca),address(wbot),0.4e18);
        HedgeVault.Component[] memory c=new HedgeVault.Component[](3);
        c[0]=HedgeVault.Component(address(wbot),5000,address(0),0,0);
        c[1]=HedgeVault.Component(address(usdt),2500,address(0),3000,0);
        c[2]=HedgeVault.Component(address(ca),2500,address(0),10000,0);
        vm.prank(creator);HedgeVault v=HedgeVault(wf.createVault(HedgeVault.Config(creator,"BOT Core","CORE",HedgeVault.Mode.Fixed,6e18,uint64(block.timestamp+1 days),0,0,0,c)));
        assertEq(v.decimals(),18);
        address[3] memory us=[alice,bob,carol];
        for(uint256 i;i<3;i++){wbot.mint(us[i],10e18);vm.startPrank(us[i]);wbot.approve(address(v),2e18);v.deposit(2e18);vm.stopPrank();}
        uint256[] memory m=new uint256[](3);m[1]=1;m[2]=1;
        vm.prank(creator);v.finalize(m,block.timestamp);
        assertEq(wbot.balanceOf(address(v)),3e18);assertEq(usdt.balanceOf(address(v)),1.5e18*12.5e6/1e18);assertEq(ca.balanceOf(address(v)),1.5e18*2.5);
        for(uint256 i;i<3;i++){vm.prank(us[i]);v.claimShares();assertEq(v.balanceOf(us[i]),2e18);}
        uint256 w0=wbot.balanceOf(alice);vm.prank(alice);v.redeem(1e18);
        assertEq(wbot.balanceOf(alice)-w0,0.5e18);assertEq(ca.balanceOf(alice),0.625e18);
        uint256 w1=wbot.balanceOf(bob);vm.prank(bob);uint256 out=v.redeemToCash(2e18,m,1.99e18,block.timestamp);
        assertApproxEqAbs(out,2e18,1e6);assertEq(wbot.balanceOf(bob)-w1,out);
    }
}
