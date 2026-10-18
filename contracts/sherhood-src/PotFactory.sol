pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pot} from "./Pot.sol";
import {PotCard} from "./PotCard.sol";

interface ITreasuryFeeSink {
    function depositFeeUSDG(uint256 amount) external;
}

contract PotFactory is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    PotCard public immutable card;
    address public immutable usdg;

    address public assetManager;
    address public revealEngine;
    address public treasury;
    address public entryRouter;
    address public stockRegistry;

    uint256 public creationFee;
    uint256 public defaultProtocolFeeBps = 100;
    uint256 public maxProtocolFeeBps = 2000;
    uint256 public minFundingGoal = 1e18;
    uint256 public maxDuration = 365 days;
    uint256 public minDuration = 1 hours;

    address[] public pots;
    mapping(address => bool) public isPot;
    mapping(address => address) public potCreator;

    uint256 public totalDepositVolume;
    uint256 public depositCount;
    uint256 public uniqueDepositors;
    mapping(address => bool) public hasDeposited;

    event PotCreated(
        address indexed pot,
        address indexed creator,
        uint256 fundingGoal,
        uint256 deadline,
        uint256 minDeposit,
        uint256 entryFee,
        uint256 protocolFeeBps,
        bool community
    );
    event AssetManagerUpdated(address assetManager);
    event RevealEngineUpdated(address revealEngine);
    event TreasuryUpdated(address treasury);
    event EntryRouterUpdated(address entryRouter);
    event StockRegistryUpdated(address registry);
    event CreationFeeUpdated(uint256 fee);
    event FeeParamsUpdated(uint256 defaultProtocolFeeBps, uint256 maxProtocolFeeBps);

    constructor(address owner_, address usdg_, address card_) Ownable(owner_) {
        require(usdg_ != address(0) && card_ != address(0), "PotFactory: zero");
        usdg = usdg_;
        card = PotCard(card_);
    }

    function setAssetManager(address assetManager_) external onlyOwner {
        assetManager = assetManager_;
        emit AssetManagerUpdated(assetManager_);
    }

    function setRevealEngine(address revealEngine_) external onlyOwner {
        revealEngine = revealEngine_;
        emit RevealEngineUpdated(revealEngine_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setEntryRouter(address entryRouter_) external onlyOwner {
        entryRouter = entryRouter_;
        emit EntryRouterUpdated(entryRouter_);
    }

    function setStockRegistry(address registry_) external onlyOwner {
        stockRegistry = registry_;
        emit StockRegistryUpdated(registry_);
    }

    function setCreationFee(uint256 fee_) external onlyOwner {
        creationFee = fee_;
        emit CreationFeeUpdated(fee_);
    }

    function setFeeParams(uint256 defaultBps_, uint256 maxBps_) external onlyOwner {
        require(maxBps_ <= 2000, "PotFactory: max too high");
        require(defaultBps_ <= maxBps_, "PotFactory: default>max");
        defaultProtocolFeeBps = defaultBps_;
        maxProtocolFeeBps = maxBps_;
        emit FeeParamsUpdated(defaultBps_, maxBps_);
    }

    function setDurationBounds(uint256 minD, uint256 maxD) external onlyOwner {
        require(minD > 0 && minD < maxD, "PotFactory: bad duration");
        minDuration = minD;
        maxDuration = maxD;
    }

    function setMinFundingGoal(uint256 goal_) external onlyOwner {
        require(goal_ > 0, "PotFactory: zero");
        minFundingGoal = goal_;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function createPot(
        uint256 fundingGoal,
        uint256 duration,
        uint256 minDeposit,
        uint256 entryFee,
        uint256 protocolFeeBps
    ) external onlyOwner whenNotPaused returns (address) {
        return _create(msg.sender, fundingGoal, duration, minDeposit, entryFee, protocolFeeBps, false);
    }

    function createCommunityPot(
        uint256 fundingGoal,
        uint256 duration,
        uint256 minDeposit,
        uint256 entryFee,
        uint256 protocolFeeBps
    ) external virtual nonReentrant whenNotPaused returns (address) {
        require(treasury != address(0), "PotFactory: no treasury");
        if (creationFee > 0 && msg.sender != owner()) {
            IERC20(usdg).safeTransferFrom(msg.sender, address(this), creationFee);
            IERC20(usdg).forceApprove(treasury, 0);
            IERC20(usdg).forceApprove(treasury, creationFee);
            ITreasuryFeeSink(treasury).depositFeeUSDG(creationFee);
        }
        return _create(msg.sender, fundingGoal, duration, minDeposit, entryFee, protocolFeeBps, true);
    }

    function _create(
        address creator,
        uint256 fundingGoal,
        uint256 duration,
        uint256 minDeposit,
        uint256 entryFee,
        uint256 protocolFeeBps,
        bool community
    ) internal returns (address potAddr) {
        require(assetManager != address(0) && revealEngine != address(0), "PotFactory: not wired");
        require(fundingGoal >= minFundingGoal, "PotFactory: goal low");
        require(duration >= minDuration && duration <= maxDuration, "PotFactory: duration");
        require(minDeposit > 0 && minDeposit <= fundingGoal, "PotFactory: minDeposit");
        if (protocolFeeBps == 0) protocolFeeBps = defaultProtocolFeeBps;
        require(protocolFeeBps <= maxProtocolFeeBps, "PotFactory: fee high");

        Pot pot = _deployPot(creator, fundingGoal, duration, minDeposit, entryFee, protocolFeeBps);
        potAddr = address(pot);
        pot.setAssetManager(assetManager);
        pot.setRevealEngine(revealEngine);
        if (entryRouter != address(0)) pot.setEntryRouter(entryRouter);
        isPot[potAddr] = true;
        potCreator[potAddr] = creator;
        pots.push(potAddr);
        emit PotCreated(potAddr, creator, fundingGoal, pot.deadline(), minDeposit, entryFee, protocolFeeBps, community);
    }

    function _deployPot(address creator, uint256 fundingGoal, uint256 duration, uint256 minDeposit, uint256 entryFee, uint256 protocolFeeBps) internal virtual returns (Pot) {
        return new Pot(
            owner(),
            creator,
            usdg,
            address(this),
            address(card),
            fundingGoal,
            duration,
            minDeposit,
            entryFee,
            protocolFeeBps
        );
    }

    function mintCard(address to, uint256 depositAmount) external returns (uint256 tokenId) {
        require(isPot[msg.sender], "PotFactory: only pot");
        totalDepositVolume += depositAmount;
        depositCount += 1;
        if (!hasDeposited[to]) {
            hasDeposited[to] = true;
            uniqueDepositors += 1;
        }
        bool luckLocked;
        if (revealEngine != address(0)) {
            (bool ok, bytes memory data) =
                revealEngine.staticcall(abi.encodeWithSignature("isLuckEligible(address)", to));
            require(ok && data.length >= 32, "PotFactory: luck");
            luckLocked = abi.decode(data, (bool));
        }
        tokenId = card.mintUnrevealed(to, msg.sender, depositAmount, luckLocked);
    }

    function potCount() external view returns (uint256) {
        return pots.length;
    }

    function getPots() external view returns (address[] memory) {
        return pots;
    }

    function protocolStats()
        external
        view
        returns (uint256 pools, uint256 depositVolume, uint256 deposits, uint256 users)
    {
        return (pots.length, totalDepositVolume, depositCount, uniqueDepositors);
    }
}
