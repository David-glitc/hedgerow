// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PotCard} from "./PotCard.sol";

interface IPotFactoryView {
    function mintCard(address to, uint256 depositAmount) external returns (uint256 tokenId);
    function paused() external view returns (bool);
    function treasury() external view returns (address);
}

interface ITreasuryFee {
    function depositFeeUSDG(uint256 amount) external;
}

contract Pot is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Status {
        Funding,
        Closed,
        Purchased,
        Revealed,
        Cancelled
    }

    struct Holding {
        address token;
        uint256 amount;
    }

    uint256 public constant OWNERSHIP_ONE = 1e18;
    uint256 public constant MAX_HOLDINGS = 8;
    uint256 public constant EARLY_EXIT_FEE_BPS = 500;
    uint256 public constant EARLY_EXIT_COOLDOWN = 1 hours;

    address public immutable usdg;
    address public immutable factory;
    uint256 public immutable fundingGoal;
    uint256 public immutable deadline;
    uint256 public immutable minDeposit;
    uint256 public immutable entryFee;
    uint256 public immutable protocolFeeBps;
    address public immutable creator;

    PotCard public immutable card;
    address public assetManager;
    address public revealEngine;
    address public entryRouter;

    Status public status;
    uint256 public totalDeposited;
    uint256 public totalEntryFees;
    uint256 public participantCount;
    uint256 public feesSwept;
    uint256 public claimCount;
    bool public purchasePulled;

    Holding[] private _holdings;
    mapping(address => uint256) public lastEarlyExitAt;

    event Deposited(address indexed user, uint256 amount, uint256 entryFeePaid, uint256 indexed tokenId);
    event EarlyExited(
        address indexed user, uint256 indexed tokenId, uint256 depositAmount, uint256 fee, uint256 refund
    );
    event Closed(uint256 totalDeposited, uint256 participantCount);
    event PotCancelled(uint256 totalDeposited, uint256 participantCount);
    event Refunded(address indexed user, uint256 indexed tokenId, uint256 amount);
    event Purchased(address[] tokens, uint256[] amounts);
    event Revealed();
    event FeesSwept(address indexed treasury, uint256 amount);
    event Claimed(address indexed user, uint256 indexed tokenId, address[] tokens, uint256[] payouts);
    event AssetManagerSet(address assetManager);
    event RevealEngineSet(address revealEngine);
    event EntryRouterSet(address entryRouter);
    event DustSwept(address indexed token, address indexed to, uint256 amount);

    modifier onlyFactory() {
        require(msg.sender == factory, "Pot: factory");
        _;
    }

    modifier onlyAssetManager() {
        require(msg.sender == assetManager, "Pot: assets");
        _;
    }

    modifier onlyRevealEngine() {
        require(msg.sender == revealEngine, "Pot: reveal");
        _;
    }

    modifier whenFactoryNotPaused() {
        require(!IPotFactoryView(factory).paused(), "Pot: paused");
        _;
    }

    constructor(
        address owner_,
        address creator_,
        address usdg_,
        address factory_,
        address card_,
        uint256 fundingGoal_,
        uint256 duration_,
        uint256 minDeposit_,
        uint256 entryFee_,
        uint256 protocolFeeBps_
    ) Ownable(owner_) {
        require(usdg_ != address(0) && factory_ != address(0) && card_ != address(0), "Pot: zero");
        require(creator_ != address(0), "Pot: creator");
        require(fundingGoal_ > 0 && duration_ > 0, "Pot: params");
        require(protocolFeeBps_ <= 2000, "Pot: fee");

        usdg = usdg_;
        factory = factory_;
        creator = creator_;
        card = PotCard(card_);
        fundingGoal = fundingGoal_;
        deadline = block.timestamp + duration_;
        minDeposit = minDeposit_;
        entryFee = entryFee_;
        protocolFeeBps = protocolFeeBps_;
        status = Status.Funding;
    }

    function setAssetManager(address assetManager_) external onlyFactory {
        assetManager = assetManager_;
        emit AssetManagerSet(assetManager_);
    }

    function setRevealEngine(address revealEngine_) external onlyFactory {
        revealEngine = revealEngine_;
        emit RevealEngineSet(revealEngine_);
    }

    function setEntryRouter(address entryRouter_) external onlyFactory {
        entryRouter = entryRouter_;
        emit EntryRouterSet(entryRouter_);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function holdingsCount() external view returns (uint256) {
        return _holdings.length;
    }

    function holdingAt(uint256 index) external view returns (address token, uint256 amount) {
        Holding storage h = _holdings[index];
        return (h.token, h.amount);
    }

    function getHoldings() external view returns (address[] memory tokens, uint256[] memory amounts) {
        uint256 n = _holdings.length;
        tokens = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _holdings[i].token;
            amounts[i] = _holdings[i].amount;
        }
    }

    function deposit(uint256 amount)
        external
        nonReentrant
        whenNotPaused
        whenFactoryNotPaused
        returns (uint256 tokenId)
    {
        return _deposit(msg.sender, msg.sender, amount);
    }

    function depositFor(address beneficiary, uint256 amount)
        external
        nonReentrant
        whenNotPaused
        whenFactoryNotPaused
        returns (uint256 tokenId)
    {
        require(msg.sender == entryRouter, "Pot: router");
        require(beneficiary != address(0), "Pot: beneficiary");
        return _deposit(msg.sender, beneficiary, amount);
    }

    function _deposit(address payer, address beneficiary, uint256 amount) internal virtual returns (uint256 tokenId) {
        require(status == Status.Funding, "Pot: funding");
        require(block.timestamp < deadline, "Pot: deadline");
        require(amount >= minDeposit, "Pot: min");
        require(totalDeposited + amount <= fundingGoal, "Pot: goal");

        uint256 fee = entryFee;
        IERC20(usdg).safeTransferFrom(payer, address(this), amount + fee);

        totalDeposited += amount;
        if (fee > 0) totalEntryFees += fee;

        tokenId = IPotFactoryView(factory).mintCard(beneficiary, amount);
        participantCount += 1;
        emit Deposited(beneficiary, amount, fee, tokenId);

        if (totalDeposited == fundingGoal) {
            _close();
        }
    }

    function close() external nonReentrant whenNotPaused {
        require(status == Status.Funding, "Pot: funding");
        require(totalDeposited >= fundingGoal || block.timestamp >= deadline, "Pot: ready");
        require(participantCount > 0, "Pot: empty");
        _close();
    }

    function cancel() external nonReentrant whenNotPaused whenFactoryNotPaused {
        require(status == Status.Funding, "Pot: funding");
        require(block.timestamp >= deadline, "Pot: expired");
        require(totalDeposited < fundingGoal, "Pot: goal met");
        status = Status.Cancelled;
        emit PotCancelled(totalDeposited, participantCount);
    }

    function refund(uint256 tokenId) external nonReentrant returns (uint256 amount) {
        require(status == Status.Cancelled, "Pot: cancelled");
        require(card.ownerOf(tokenId) == msg.sender, "Pot: owner");

        PotCard.CardData memory c = card.getCard(tokenId);
        require(c.pot == address(this), "Pot: pot");
        require(!c.revealed && !c.claimed, "Pot: locked");

        amount = c.depositAmount;
        require(amount > 0 && totalDeposited >= amount, "Pot: acct");

        totalDeposited -= amount;
        participantCount -= 1;

        card.burnForEarlyExit(tokenId);
        IERC20(usdg).safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, tokenId, amount);
    }

    function sweepCancelledFees() external virtual nonReentrant returns (uint256 amount) {
        require(status == Status.Cancelled, "Pot: cancelled");
        address treasury = IPotFactoryView(factory).treasury();
        require(treasury != address(0), "Pot: treasury");

        amount = totalEntryFees - feesSwept;
        require(amount > 0, "Pot: fees");

        uint256 bal = IERC20(usdg).balanceOf(address(this));
        uint256 available = bal > totalDeposited ? bal - totalDeposited : 0;
        if (amount > available) amount = available;
        require(amount > 0, "Pot: locked");

        feesSwept += amount;
        IERC20(usdg).forceApprove(treasury, 0);
        IERC20(usdg).forceApprove(treasury, amount);
        ITreasuryFee(treasury).depositFeeUSDG(amount);
        emit FeesSwept(treasury, amount);
    }

    function earlyExit(uint256 tokenId)
        external
        virtual
        nonReentrant
        whenNotPaused
        whenFactoryNotPaused
        returns (uint256 refundAmt)
    {
        require(status == Status.Funding, "Pot: funding");
        require(card.ownerOf(tokenId) == msg.sender, "Pot: owner");
        {
            uint256 last = lastEarlyExitAt[msg.sender];
            require(last == 0 || block.timestamp >= last + EARLY_EXIT_COOLDOWN, "Pot: cooldown");
        }

        PotCard.CardData memory c = card.getCard(tokenId);
        require(c.pot == address(this), "Pot: pot");
        require(!c.revealed && !c.claimed, "Pot: locked");

        uint256 depositAmount = c.depositAmount;
        require(depositAmount > 0 && totalDeposited >= depositAmount && participantCount > 0, "Pot: acct");

        uint256 fee = (depositAmount * EARLY_EXIT_FEE_BPS) / 10_000;
        refundAmt = depositAmount - fee;

        totalDeposited -= depositAmount;
        participantCount -= 1;
        lastEarlyExitAt[msg.sender] = block.timestamp;

        card.burnForEarlyExit(tokenId);

        address treasury = IPotFactoryView(factory).treasury();
        if (fee > 0) {
            require(treasury != address(0), "Pot: treasury");
            IERC20(usdg).forceApprove(treasury, 0);
            IERC20(usdg).forceApprove(treasury, fee);
            ITreasuryFee(treasury).depositFeeUSDG(fee);
        }
        if (refundAmt > 0) {
            IERC20(usdg).safeTransfer(msg.sender, refundAmt);
        }

        emit EarlyExited(msg.sender, tokenId, depositAmount, fee, refundAmt);
    }

    function previewEarlyExit(uint256 tokenId)
        external
        view
        returns (uint256 depositAmount, uint256 fee, uint256 refundAmt)
    {
        PotCard.CardData memory c = card.getCard(tokenId);
        if (c.pot != address(this) || c.revealed || c.claimed) {
            return (0, 0, 0);
        }
        depositAmount = c.depositAmount;
        fee = (depositAmount * EARLY_EXIT_FEE_BPS) / 10_000;
        refundAmt = depositAmount - fee;
    }

    function _close() private {
        status = Status.Closed;
        emit Closed(totalDeposited, participantCount);
    }

    function protocolFeeOwed() public view returns (uint256) {
        return (totalDeposited * protocolFeeBps) / 10_000;
    }

    function feesOwed() public view virtual returns (uint256) {
        return protocolFeeOwed() + totalEntryFees;
    }

    function pullForPurchase() external onlyAssetManager returns (uint256 swapAmount, uint256 protocolFee) {
        require(status == Status.Closed, "Pot: closed");
        require(!purchasePulled, "Pot: pulled");
        purchasePulled = true;
        protocolFee = protocolFeeOwed();
        swapAmount = totalDeposited - protocolFee;
        if (swapAmount > 0) {
            IERC20(usdg).safeTransfer(msg.sender, swapAmount);
        }
    }

    function markPurchased(address[] calldata tokens, uint256[] calldata amounts) external onlyAssetManager {
        require(status == Status.Closed && purchasePulled, "Pot: state");
        require(tokens.length > 0 && tokens.length == amounts.length && tokens.length <= MAX_HOLDINGS, "Pot: holdings");

        delete _holdings;
        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0) && amounts[i] > 0, "Pot: holding");
            _holdings.push(Holding(tokens[i], amounts[i]));
        }

        status = Status.Purchased;
        emit Purchased(tokens, amounts);
    }

    function markRevealed() external onlyRevealEngine {
        require(status == Status.Purchased, "Pot: purchased");
        status = Status.Revealed;
        emit Revealed();
    }

    function sweepFees() external virtual nonReentrant returns (uint256 amount) {
        require(status == Status.Purchased || status == Status.Revealed, "Pot: early");
        amount = feesOwed() - feesSwept;
        require(amount > 0, "Pot: fees");
        address treasury = IPotFactoryView(factory).treasury();
        require(treasury != address(0), "Pot: treasury");

        uint256 bal = IERC20(usdg).balanceOf(address(this));
        if (amount > bal) amount = bal;
        require(amount > 0, "Pot: bal");

        feesSwept += amount;
        IERC20(usdg).forceApprove(treasury, 0);
        IERC20(usdg).forceApprove(treasury, amount);
        ITreasuryFee(treasury).depositFeeUSDG(amount);
        emit FeesSwept(treasury, amount);
    }

    function claim(uint256 tokenId)
        external
        nonReentrant
        whenNotPaused
        whenFactoryNotPaused
        returns (uint256[] memory payouts)
    {
        require(status == Status.Revealed, "Pot: revealed");
        require(card.ownerOf(tokenId) == msg.sender, "Pot: owner");

        PotCard.CardData memory c = card.getCard(tokenId);
        require(c.pot == address(this) && c.revealed && !c.claimed, "Pot: card");

        uint256 n = _holdings.length;
        require(n > 0, "Pot: holdings");

        address[] memory tokens = new address[](n);
        payouts = new uint256[](n);
        uint256 totalPayout;

        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _holdings[i].token;
            payouts[i] = (_holdings[i].amount * c.ownershipWeight) / OWNERSHIP_ONE;
            if (payouts[i] > 0) {
                totalPayout += payouts[i];
                IERC20(_holdings[i].token).safeTransfer(msg.sender, payouts[i]);
            }
        }
        require(totalPayout > 0, "Pot: payout");

        card.burnForClaim(tokenId);
        claimCount += 1;
        emit Claimed(msg.sender, tokenId, tokens, payouts);
    }

    function sweepAssetDust(address to) external onlyOwner {
        require(status == Status.Revealed && claimCount == participantCount, "Pot: claims");
        require(to != address(0), "Pot: zero");

        for (uint256 i = 0; i < _holdings.length; i++) {
            address token = _holdings[i].token;
            uint256 bal = IERC20(token).balanceOf(address(this));
            if (bal > 0) {
                IERC20(token).safeTransfer(to, bal);
                emit DustSwept(token, to, bal);
            }
        }
    }

    function fundingProgressBps() external view returns (uint256) {
        return (totalDeposited * 10_000) / fundingGoal;
    }

    function derivedShare(uint256 tokenId) external view returns (uint256 share, bool revealed, bool claimed) {
        PotCard.CardData memory c = card.getCard(tokenId);
        if (c.pot != address(this)) return (0, c.revealed, c.claimed);
        if (c.claimed) return (0, true, true);
        if (c.revealed) return (c.ownershipWeight, true, false);
        if (totalDeposited == 0) return (0, false, false);
        return ((c.depositAmount * OWNERSHIP_ONE) / totalDeposited, false, false);
    }

    function previewClaim(uint256 tokenId) external view returns (address[] memory tokens, uint256[] memory payouts) {
        PotCard.CardData memory c = card.getCard(tokenId);
        if (!c.revealed || c.claimed || c.pot != address(this)) {
            return (new address[](0), new uint256[](0));
        }
        uint256 n = _holdings.length;
        tokens = new address[](n);
        payouts = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            tokens[i] = _holdings[i].token;
            payouts[i] = (_holdings[i].amount * c.ownershipWeight) / OWNERSHIP_ONE;
        }
    }
}
