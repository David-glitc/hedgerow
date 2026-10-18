// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {Pot, IPotFactoryView, ITreasuryFee} from "../Pot.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice New deployment only. No early exits; cancellation refunds principal.
contract PotV2 is Pot {
    using SafeERC20 for IERC20;
    uint256 public constant CREATOR_FEE_BPS = 3000;
    uint256 public creatorFeesPaid;
    uint256 public creationFees;
    event CreatorFeePaid(address indexed creator, uint256 amount);
    constructor(address owner_, address creator_, address usdg_, address factory_, address card_, uint256 goal_, uint256 duration_, uint256 min_, uint256 entry_, uint256 fee_)
        Pot(owner_, creator_, usdg_, factory_, card_, goal_, duration_, min_, entry_, fee_) {}
    address public instantMinter;
    function setInstantMinter(address minter) external onlyFactory {
        require(status == Status.Funding && participantCount == 0 && minter != address(0), "V2: instant minter");
        instantMinter = minter;
    }
    function _deposit(address payer, address beneficiary, uint256 amount) internal override returns (uint256) {
        if (instantMinter != address(0)) require(payer == instantMinter && beneficiary == instantMinter, "V2: solo minter");
        return super._deposit(payer, beneficiary, amount);
    }
    function earlyExit(uint256) external pure override returns (uint256) { revert("V2: refund only on cancellation"); }
    function recordCreationFee(uint256 amount) external onlyFactory {
        require(status == Status.Funding && creationFees == 0 && amount > 0, "V2: creation fee");
        require(IERC20(usdg).balanceOf(address(this)) >= totalDeposited + totalEntryFees + amount, "V2: fee not funded");
        creationFees = amount;
    }
    function feesOwed() public view override returns (uint256) { return super.feesOwed() + creationFees; }
    function sweepFees() external override nonReentrant returns (uint256 amount) {
        require(status == Status.Purchased || status == Status.Revealed, "Pot: early");
        amount = feesOwed() - feesSwept;
        _split(amount);
    }
    function sweepCancelledFees() external override nonReentrant returns (uint256 amount) {
        require(status == Status.Cancelled, "Pot: cancelled");
        amount = totalEntryFees + creationFees - feesSwept;
        require(IERC20(usdg).balanceOf(address(this)) >= totalDeposited + amount, "V2: principal protected");
        _split(amount);
    }
    function _split(uint256 amount) private {
        require(amount > 0, "Pot: fees");
        address sink = IPotFactoryView(factory).treasury();
        require(sink != address(0) && IERC20(usdg).balanceOf(address(this)) >= amount, "V2: fees unavailable");
        feesSwept += amount;
        uint256 creatorPart = (feesSwept * CREATOR_FEE_BPS) / 10000 - creatorFeesPaid;
        creatorFeesPaid += creatorPart;
        uint256 protocolPart = amount - creatorPart;
        if (creatorPart > 0) IERC20(usdg).safeTransfer(creator, creatorPart);
        if (protocolPart > 0) { IERC20(usdg).forceApprove(sink, protocolPart); ITreasuryFee(sink).depositFeeUSDG(protocolPart); }
        emit CreatorFeePaid(creator, creatorPart);
        emit FeesSwept(sink, protocolPart);
    }
}
