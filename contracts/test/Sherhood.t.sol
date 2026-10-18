// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Test} from "forge-std/Test.sol";
import {PotFactoryV2} from "../sherhood-src/v2/PotFactoryV2.sol";
import {PotV2} from "../sherhood-src/v2/PotV2.sol";
import {Pot} from "../sherhood-src/Pot.sol";
import {PotCard} from "../sherhood-src/PotCard.sol";
import {Treasury} from "../sherhood-src/Treasury.sol";
import {StockTokenRegistry} from "../sherhood-src/StockTokenRegistry.sol";
import {MockERC20} from "../sherhood-src/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract PotV2Test is Test {
    MockERC20 cash;PotFactoryV2 factory;PotCard card;Treasury treasury;
    address alice=address(0xA);address manager=address(0xB);address revealer=address(0xC);
    function setUp() public {
        cash=new MockERC20("USDG","USDG",6);card=new PotCard(address(this));treasury=new Treasury(address(cash),address(this));factory=new PotFactoryV2(address(this),address(cash),address(card));card.setMinter(address(factory));factory.setAssetManager(manager);factory.setRevealEngine(revealer);factory.setTreasury(address(treasury));
        vm.mockCall(revealer,abi.encodeWithSignature("isLuckEligible(address)",alice),abi.encode(false));cash.mint(alice,1000e6);
    }
    function _create() internal returns(PotV2 p){vm.startPrank(alice);cash.approve(address(factory),5e6);p=PotV2(factory.createCommunityPot(100e6,1 hours,1e6,1e6,100));cash.approve(address(p),101e6);p.deposit(100e6);vm.stopPrank();}
    function test_instantMinterCannotBeFrontRun() public {
        vm.prank(alice);PotV2 p=PotV2(factory.createInstantPot(5e6));
        assertEq(p.instantMinter(),alice);assertEq(p.creationFees(),0);
        cash.mint(address(0xBAD),5e6);vm.startPrank(address(0xBAD));cash.approve(address(p),5e6);
        vm.expectRevert("V2: solo minter");p.deposit(5e6);vm.stopPrank();
        vm.startPrank(alice);cash.approve(address(p),5e6);uint256 id=p.deposit(5e6);vm.stopPrank();
        assertEq(card.ownerOf(id),alice);assertEq(p.participantCount(),1);assertEq(uint256(p.status()),1);
    }
    function test_instantAcceptsBoundsAndCustomAmounts() public {
        uint256[4] memory amounts = [uint256(5e6), 37420000, 123456789, 1000e6];
        for(uint256 i; i < amounts.length; i++) {
            vm.prank(alice);PotV2 p=PotV2(factory.createInstantPot(amounts[i]));
            assertEq(p.fundingGoal(),amounts[i]);assertEq(p.minDeposit(),amounts[i]);
            assertEq(p.instantMinter(),alice);assertEq(p.creationFees(),0);
            vm.startPrank(alice);cash.approve(address(p),amounts[i]);
            cash.mint(alice,amounts[i]);uint256 id=p.deposit(amounts[i]);vm.stopPrank();
            assertEq(card.ownerOf(id),alice);assertEq(p.participantCount(),1);assertEq(uint256(p.status()),1);
        }
    }
    function test_instantRejectsAmountsOutsideRange() public {
        uint256[5] memory amounts = [uint256(0), 1500000, 2e6, 5e6-1, 1000e6+1];
        for(uint256 i; i < amounts.length; i++) {
            vm.prank(alice);vm.expectRevert("V2: instant amount");factory.createInstantPot(amounts[i]);
        }
    }
    function test_creatorSplitIncludesCreationEntryAndProtocolFees() public {
        PotV2 p=_create();assertEq(p.creationFees(),5e6);assertEq(p.feesOwed(),7e6);vm.prank(manager);p.pullForPurchase();address[] memory tokens=new address[](1);tokens[0]=address(cash);uint256[] memory amounts=new uint256[](1);amounts[0]=99e6;vm.prank(manager);p.markPurchased(tokens,amounts);
        uint256 before=cash.balanceOf(alice);p.sweepFees();assertEq(cash.balanceOf(alice)-before,2100000);assertEq(cash.balanceOf(address(treasury)),4900000);assertEq(p.creatorFeesPaid(),2100000);vm.expectRevert("Pot: fees");p.sweepFees();
    }
    function test_earlyExitDisabledAndCancelledPrincipalProtected() public {
        vm.startPrank(alice);cash.approve(address(factory),5e6);PotV2 p=PotV2(factory.createCommunityPot(100e6,1 hours,1e6,1e6,100));cash.approve(address(p),51e6);uint256 id=p.deposit(50e6);vm.expectRevert("V2: refund only on cancellation");p.earlyExit(id);vm.stopPrank();vm.warp(p.deadline());p.cancel();p.sweepCancelledFees();assertEq(cash.balanceOf(address(p)),50e6);vm.prank(alice);p.refund(id);assertEq(cash.balanceOf(address(p)),0);assertEq(p.creatorFeesPaid(),1800000);
    }
}
