// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Two conditional CPMMs: portfolio shares / settlement collateral.
/// Rebalance = branch 0; keep = branch 1. Each deposit mints a complete pair.
/// Passing proposals remain unsettled until the vault confirms execution.
contract DecisionMarket is ReentrancyGuard {
    using SafeERC20 for IERC20;
    struct Pool { uint256 cash; uint256 shares; uint256 cumulative; uint256 volume; }
    struct Position { uint256[2] cash; uint256[2] shares; }
    IERC20 public immutable collateral;
    IERC20 public immutable portfolio;
    address public immutable vault;
    address public immutable proposer;
    bytes32 public immutable proposalHash;
    uint256 public immutable opensAt;
    uint256 public immutable closesAt;
    uint256 public immutable executionDelay;
    uint256 public immutable executionDeadline;
    uint256 public immutable thresholdBps;
    uint256 public immutable minVolume;
    uint256 public constant FEE_BPS = 30;
    Pool[2] public pools;
    mapping(address => Position) private positions;
    uint256 public lastUpdate;
    bool public seeded;
    bool public decided;
    bool public passed;
    bool public settled;
    bool public cancelled;
    bool public liquidityRedeemed;
    address public liquidityOwner;
    uint256 public passTwap;
    uint256 public keepTwap;
    event Split(address indexed user, uint256 cash, uint256 shares);
    event Merged(address indexed user, uint256 cash, uint256 shares);
    event Traded(address indexed user, uint8 branch, bool buy, uint256 input, uint256 output);
    event Decided(bool passed, uint256 passTwap, uint256 keepTwap);
    event Settled(bool rebalanceExecuted, bool cancelled);
    event Redeemed(address indexed user, uint256 cash, uint256 shares);

    constructor(address collateral_, address portfolio_, address vault_, address proposer_, bytes32 hash_, uint256 opens_, uint256 duration_, uint256 delay_, uint256 threshold_, uint256 minVolume_) {
        require(collateral_ != address(0) && portfolio_ != address(0) && collateral_ != portfolio_, "Market: tokens");
        require(vault_ == portfolio_ && proposer_ != address(0) && hash_ != bytes32(0), "Market: identity");
        require(opens_ >= block.timestamp + 1 hours && duration_ >= 6 hours && duration_ <= 7 days, "Market: window");
        require(delay_ >= 1 hours && delay_ <= 7 days && threshold_ >= 100 && threshold_ <= 2000 && minVolume_ > 0, "Market: bounds");
        collateral = IERC20(collateral_); portfolio = IERC20(portfolio_); vault = vault_; proposer = proposer_; proposalHash = hash_;
        opensAt = opens_; closesAt = opens_ + duration_; executionDelay = delay_; executionDeadline = closesAt + delay_ + 2 days;
        thresholdBps = threshold_; minVolume = minVolume_; lastUpdate = opens_;
    }
    function seedLiquidity(uint256 cash, uint256 shares) external nonReentrant {
        require(msg.sender == proposer && !seeded && block.timestamp < opensAt, "Market: seed");
        require(cash > 0 && shares > 0 && cash <= type(uint128).max && shares <= type(uint128).max, "Market: liquidity");
        _receive(collateral, cash); _receive(portfolio, shares);
        pools[0] = Pool(cash, shares, 0, 0); pools[1] = Pool(cash, shares, 0, 0);
        seeded = true; liquidityOwner = msg.sender;
    }
    function split(uint256 cash, uint256 shares) external nonReentrant {
        require(seeded && block.timestamp < closesAt && !decided, "Market: closed");
        require(cash > 0 || shares > 0, "Market: amount");
        if (cash > 0) _receive(collateral, cash);
        if (shares > 0) _receive(portfolio, shares);
        for (uint256 i; i < 2; i++) { positions[msg.sender].cash[i] += cash; positions[msg.sender].shares[i] += shares; }
        emit Split(msg.sender, cash, shares);
    }
    function merge(uint256 cash, uint256 shares) external nonReentrant {
        require(!settled && (cash > 0 || shares > 0), "Market: merge");
        for (uint256 i; i < 2; i++) { positions[msg.sender].cash[i] -= cash; positions[msg.sender].shares[i] -= shares; }
        if (cash > 0) collateral.safeTransfer(msg.sender, cash);
        if (shares > 0) portfolio.safeTransfer(msg.sender, shares);
        emit Merged(msg.sender, cash, shares);
    }
    function quote(uint8 branch, bool buy, uint256 input) public view returns (uint256 output) {
        require(branch < 2 && input > 0 && input <= type(uint128).max, "Market: quote");
        Pool memory p = pools[branch];
        uint256 effective = Math.mulDiv(input, 10000 - FEE_BPS, 10000);
        output = buy ? Math.mulDiv(p.shares, effective, p.cash + effective) : Math.mulDiv(p.cash, effective, p.shares + effective);
    }
    function trade(uint8 branch, bool buy, uint256 input, uint256 minOutput, uint256 deadline) external nonReentrant returns (uint256 output) {
        require(seeded && block.timestamp >= opensAt && block.timestamp < closesAt && !decided, "Market: not open");
        require(block.timestamp <= deadline, "Market: expired");
        output = quote(branch, buy, input);
        require(output >= minOutput && output > 0, "Market: slippage");
        _accrue();
        Pool storage p = pools[branch]; Position storage user = positions[msg.sender];
        if (buy) { user.cash[branch] -= input; user.shares[branch] += output; p.cash += input; p.shares -= output; p.volume += input; }
        else { user.shares[branch] -= input; user.cash[branch] += output; p.shares += input; p.cash -= output; p.volume += output; }
        require(p.cash <= type(uint128).max && p.shares <= type(uint128).max, "Market: reserve cap");
        emit Traded(msg.sender, branch, buy, input, output);
    }
    function decide() external nonReentrant {
        require(block.timestamp >= closesAt && !decided, "Market: decision");
        decided = true;
        if (!seeded || pools[0].volume < minVolume || pools[1].volume < minVolume) {
            cancelled = true; settled = true; emit Settled(false, true); return;
        }
        _accrue();
        passTwap = pools[0].cumulative / (closesAt - opensAt);
        keepTwap = pools[1].cumulative / (closesAt - opensAt);
        passed = passTwap > Math.mulDiv(keepTwap, 10000 + thresholdBps, 10000);
        if (!passed) { settled = true; emit Settled(false, false); }
        emit Decided(passed, passTwap, keepTwap);
    }
    function confirmExecution() external {
        require(msg.sender == vault && decided && passed && !settled && block.timestamp >= closesAt + executionDelay && block.timestamp <= executionDeadline, "Market: execution");
        settled = true; emit Settled(true, false);
    }
    function expire() external {
        require(decided && passed && !settled && block.timestamp > executionDeadline, "Market: expiry");
        // A passing decision that could not execute is void; neither branch wins.
        cancelled = true; settled = true; emit Settled(false, true);
    }
    function position(address user) external view returns (uint256[2] memory cash, uint256[2] memory shares) { return (positions[user].cash, positions[user].shares); }
    function redeem() external nonReentrant returns (uint256 cash, uint256 shares) {
        require(settled, "Market: unsettled");
        Position memory p = positions[msg.sender]; delete positions[msg.sender];
        cash = cancelled ? (p.cash[0] + p.cash[1]) / 2 : p.cash[passed ? 0 : 1];
        shares = cancelled ? (p.shares[0] + p.shares[1]) / 2 : p.shares[passed ? 0 : 1];
        if (cash > 0) collateral.safeTransfer(msg.sender, cash);
        if (shares > 0) portfolio.safeTransfer(msg.sender, shares);
        emit Redeemed(msg.sender, cash, shares);
    }
    function redeemLiquidity() external nonReentrant returns (uint256 cash, uint256 shares) {
        require(settled && seeded && msg.sender == liquidityOwner && !liquidityRedeemed, "Market: LP");
        liquidityRedeemed = true;
        cash = cancelled ? (pools[0].cash + pools[1].cash) / 2 : pools[passed ? 0 : 1].cash;
        shares = cancelled ? (pools[0].shares + pools[1].shares) / 2 : pools[passed ? 0 : 1].shares;
        collateral.safeTransfer(msg.sender, cash); portfolio.safeTransfer(msg.sender, shares);
    }
    function prices() external view returns (uint256 passPrice, uint256 keepPrice) {
        if (!seeded) return (0,0);
        return (Math.mulDiv(pools[0].cash, 1e18, pools[0].shares), Math.mulDiv(pools[1].cash, 1e18, pools[1].shares));
    }
    function _accrue() private {
        uint256 time = block.timestamp < closesAt ? block.timestamp : closesAt;
        if (time <= lastUpdate) return;
        for (uint256 i; i < 2; i++) pools[i].cumulative += Math.mulDiv(pools[i].cash, 1e18, pools[i].shares) * (time - lastUpdate);
        lastUpdate = time;
    }
    function _receive(IERC20 token, uint256 amount) private {
        uint256 before = token.balanceOf(address(this)); token.safeTransferFrom(msg.sender, address(this), amount);
        require(token.balanceOf(address(this)) - before == amount, "Market: transfer tax unsupported");
    }
}

/// @notice Separate deployer keeps portfolio vault runtime below EIP-170.
contract DecisionMarketFactory {
    mapping(address => bool) public isMarket;
    event MarketCreated(address indexed market, address indexed vault, bytes32 indexed proposalHash);
    function create(address collateral, address proposer, bytes32 proposalHash, uint256 opensAt, uint256 duration, uint256 delay, uint256 threshold, uint256 minVolume) external returns (address market) {
        market = address(new DecisionMarket(collateral, msg.sender, msg.sender, proposer, proposalHash, opensAt, duration, delay, threshold, minVolume));
        isMarket[market] = true; emit MarketCreated(market, msg.sender, proposalHash);
    }
}
