// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VRFConsumerBaseV2} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {Treasury} from "./Treasury.sol";

contract PackManager is VRFConsumerBaseV2, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Rarity { Common, Uncommon, Rare, Legendary }

    struct DropEntry {
        Rarity rarity;
        uint64 weight;
        address token;
        uint64 minAmount;
        uint64 maxAmount;
    }

    struct TierConfig {
        string name;
        uint256 price;
        bool active;
    }

    struct PackResult {
        address user;
        address token;
        uint256 amount;
        Rarity rarity;
        bool resolved;
        bool claimed;
        bool buybackTaken;
        uint256 createdAt;
    }

    address public immutable usdg;
    address public treasury;
    address public buybackVault;
    address public vrfCoordinator;

    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 250000;
    uint16 public requestConfirmations = 3;

    TierConfig[] public tiers;
    mapping(uint256 => DropEntry[]) public dropTables;
    mapping(uint256 => uint256) public tierRevenue;

    mapping(uint256 => uint256) private _vrfToPackId;
    mapping(uint256 => uint256) private _vrfToTierId;
    mapping(uint256 => address) private _vrfToUser;
    uint256 private _nextPackId = 1;
    mapping(uint256 => PackResult) public packResults;

    uint256 public packClaimTimeout = 1 hours;

    event PackPurchased(uint256 indexed packId, address indexed user, uint256 indexed tierId);
    event PackOpened(uint256 indexed packId, address indexed user, Rarity rarity, address token, uint256 amount);
    event PackClaimed(uint256 indexed packId, address indexed user);
    event PackBuybackTaken(uint256 indexed packId, address indexed user);
    event PackExpired(uint256 indexed packId);
    event TierCreated(uint256 indexed tierId, string name, uint256 price);
    event TierUpdated(uint256 indexed tierId, uint256 price, bool active);
    event DropTableSet(uint256 indexed tierId);
    event TreasuryUpdated(address treasury);
    event BuybackVaultUpdated(address buybackVault);
    event VRFConfigSet(bytes32 keyHash, uint64 subId, uint32 gasLimit);
    event PackClaimTimeoutUpdated(uint256 timeout);

    constructor(
        address _usdg,
        address _treasury,
        address _buybackVault,
        address _vrfCoordinator,
        address _owner
    ) VRFConsumerBaseV2(_vrfCoordinator) Ownable(_owner) {
        usdg = _usdg;
        treasury = _treasury;
        buybackVault = _buybackVault;
        vrfCoordinator = _vrfCoordinator;
    }

    function createTier(string calldata name, uint256 price) external onlyOwner returns (uint256 tierId) {
        tierId = tiers.length;
        tiers.push(TierConfig({name: name, price: price, active: true}));
        emit TierCreated(tierId, name, price);
    }

    function updateTier(uint256 tierId, uint256 price, bool active) external onlyOwner {
        require(tierId < tiers.length, "PackManager: invalid tier");
        tiers[tierId].price = price;
        tiers[tierId].active = active;
        emit TierUpdated(tierId, price, active);
    }

    function setDropTable(uint256 tierId, DropEntry[] calldata entries) external onlyOwner {
        require(tierId < tiers.length, "PackManager: invalid tier");
        delete dropTables[tierId];
        uint64 totalWeight;
        for (uint256 i = 0; i < entries.length; i++) {
            dropTables[tierId].push(entries[i]);
            totalWeight += entries[i].weight;
        }
        require(totalWeight > 0, "PackManager: zero weight");
        emit DropTableSet(tierId);
    }

    function setVRFConfig(bytes32 _keyHash, uint64 _subId, uint32 _gasLimit) external onlyOwner {
        keyHash = _keyHash;
        subscriptionId = _subId;
        callbackGasLimit = _gasLimit;
        emit VRFConfigSet(_keyHash, _subId, _gasLimit);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function setBuybackVault(address _buybackVault) external onlyOwner {
        buybackVault = _buybackVault;
        emit BuybackVaultUpdated(_buybackVault);
    }

    function setPackClaimTimeout(uint256 timeout) external onlyOwner {
        packClaimTimeout = timeout;
        emit PackClaimTimeoutUpdated(timeout);
    }

    function getTierCount() external view returns (uint256) {
        return tiers.length;
    }

    function getDropTable(uint256 tierId) external view returns (DropEntry[] memory) {
        return dropTables[tierId];
    }

    function openPack(uint256 tierId) external whenNotPaused nonReentrant returns (uint256 packId) {
        require(tierId < tiers.length, "PackManager: invalid tier");
        TierConfig storage tier = tiers[tierId];
        require(tier.active, "PackManager: tier inactive");

        IERC20(usdg).safeTransferFrom(msg.sender, address(this), tier.price);

        tierRevenue[tierId] += tier.price;

        uint256 requestId = VRFCoordinatorV2Interface(vrfCoordinator).requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            3
        );

        packId = _nextPackId++;
        _vrfToPackId[requestId] = packId;
        _vrfToTierId[requestId] = tierId;
        _vrfToUser[requestId] = msg.sender;

        packResults[packId] = PackResult({
            user: msg.sender,
            token: address(0),
            amount: 0,
            rarity: Rarity.Common,
            resolved: false,
            claimed: false,
            buybackTaken: false,
            createdAt: block.timestamp
        });

        emit PackPurchased(packId, msg.sender, tierId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        uint256 packId = _vrfToPackId[requestId];
        require(packId != 0, "PackManager: unknown request");
        require(!packResults[packId].resolved, "PackManager: already resolved");

        uint256 tierId = _vrfToTierId[requestId];
        DropEntry[] storage entries = dropTables[tierId];
        require(entries.length > 0, "PackManager: no drop table");

        uint256 roll = randomWords[0] % _totalWeight(tierId);
        uint256 cumulative;
        uint256 selectedIndex;

        for (uint256 i = 0; i < entries.length; i++) {
            cumulative += entries[i].weight;
            if (roll < cumulative) {
                selectedIndex = i;
                break;
            }
        }

        DropEntry memory selected = entries[selectedIndex];

        uint256 tokenAmount = selected.minAmount;
        if (selected.maxAmount > selected.minAmount) {
            tokenAmount += randomWords[1] % (selected.maxAmount - selected.minAmount + 1);
        }

        Treasury(treasury).distribute(selected.token, address(this), tokenAmount);

        PackResult storage result = packResults[packId];
        result.token = selected.token;
        result.amount = tokenAmount;
        result.rarity = selected.rarity;
        result.resolved = true;

        emit PackOpened(packId, result.user, selected.rarity, selected.token, tokenAmount);
    }

    function _totalWeight(uint256 tierId) private view returns (uint256) {
        DropEntry[] storage entries = dropTables[tierId];
        uint256 total;
        for (uint256 i = 0; i < entries.length; i++) {
            total += entries[i].weight;
        }
        return total;
    }

    function claimPack(uint256 packId) external nonReentrant {
        PackResult storage result = packResults[packId];
        require(result.user == msg.sender, "PackManager: not your pack");
        require(result.resolved, "PackManager: not resolved");
        require(!result.claimed, "PackManager: already claimed");
        require(!result.buybackTaken, "PackManager: buyback taken");

        result.claimed = true;
        IERC20(result.token).safeTransfer(msg.sender, result.amount);
        emit PackClaimed(packId, msg.sender);
    }

    function acceptBuyback(uint256 packId) external nonReentrant {
        PackResult storage result = packResults[packId];
        require(result.user == msg.sender, "PackManager: not your pack");
        require(result.resolved, "PackManager: not resolved");
        require(!result.claimed, "PackManager: already claimed");
        require(!result.buybackTaken, "PackManager: buyback already taken");

        result.buybackTaken = true;
        IERC20(result.token).safeTransfer(buybackVault, result.amount);
        emit PackBuybackTaken(packId, msg.sender);
    }

    function expirePack(uint256 packId) external onlyOwner {
        PackResult storage result = packResults[packId];
        require(result.resolved, "PackManager: not resolved");
        require(!result.claimed, "PackManager: already claimed");
        require(!result.buybackTaken, "PackManager: buyback taken");
        require(block.timestamp > result.createdAt + packClaimTimeout, "PackManager: not expired");

        result.buybackTaken = true;
        IERC20(result.token).safeTransfer(treasury, result.amount);
        emit PackExpired(packId);
    }

    function withdrawUSDG(uint256 amount) external onlyOwner {
        IERC20(usdg).safeTransfer(msg.sender, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }
}
