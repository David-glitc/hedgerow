// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VRFConsumerBaseV2} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {Pot} from "./Pot.sol";
import {PotCard} from "./PotCard.sol";

contract RevealEngine is VRFConsumerBaseV2, Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant OWNERSHIP_ONE = 1e18;
    uint256 public constant MULT_FLOOR = 5_000;
    uint256 public constant MULT_CEIL = 20_000;
    uint256 public constant MULT_SPAN = MULT_CEIL - MULT_FLOOR + 1;

    PotCard public immutable card;
    address public immutable vrfCoordinator;

    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 2_500_000;
    uint16 public requestConfirmations = 3;

    mapping(uint256 => address) public requestToPot;
    mapping(address => uint256) public potRequestId;
    mapping(address => bool) public revealRequested;
    mapping(address => bool) public operators;

    IERC20 public luckToken;
    uint256 public luckThreshold = 1000e18;
    uint256 public luckBoostBps = 2500;
    mapping(address => uint256) public luckEscrow;
    mapping(address => uint256) public luckLockBlock;

    event VRFConfigSet(bytes32 keyHash, uint64 subId, uint32 gasLimit);
    event LuckTokenSet(address token, uint256 threshold, uint256 boostBps);
    event LuckLocked(address indexed account, uint256 amount, uint256 total);
    event LuckUnlocked(address indexed account, uint256 amount, uint256 total);
    event RevealRequested(address indexed pot, uint256 requestId);
    event RevealFulfilled(address indexed pot, uint256 totalOwnership);
    event OperatorUpdated(address indexed operator, bool allowed);

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner() || operators[msg.sender], "Reveal: auth");
        _;
    }

    constructor(address owner_, address card_, address vrfCoordinator_)
        VRFConsumerBaseV2(vrfCoordinator_)
        Ownable(owner_)
    {
        require(card_ != address(0) && vrfCoordinator_ != address(0), "Reveal: zero");
        card = PotCard(card_);
        vrfCoordinator = vrfCoordinator_;
    }

    function setVRFConfig(bytes32 keyHash_, uint64 subId_, uint32 gasLimit_) external onlyOwner {
        keyHash = keyHash_;
        subscriptionId = subId_;
        callbackGasLimit = gasLimit_;
        emit VRFConfigSet(keyHash_, subId_, gasLimit_);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setLuckToken(address token, uint256 threshold, uint256 boostBps) external onlyOwner {
        require(boostBps <= 10_000, "Reveal: boost");
        luckToken = IERC20(token);
        luckThreshold = threshold;
        luckBoostBps = boostBps;
        emit LuckTokenSet(token, threshold, boostBps);
    }

    function lockLuck(uint256 amount) external {
        require(address(luckToken) != address(0) && amount > 0, "Reveal: luck");
        luckToken.safeTransferFrom(msg.sender, address(this), amount);
        luckEscrow[msg.sender] += amount;
        luckLockBlock[msg.sender] = block.number;
        emit LuckLocked(msg.sender, amount, luckEscrow[msg.sender]);
    }

    function unlockLuck(uint256 amount) external {
        require(block.number > luckLockBlock[msg.sender], "Reveal: same block");
        require(luckEscrow[msg.sender] >= amount && amount > 0, "Reveal: escrow");
        luckEscrow[msg.sender] -= amount;
        luckToken.safeTransfer(msg.sender, amount);
        emit LuckUnlocked(msg.sender, amount, luckEscrow[msg.sender]);
    }

    function isLuckEligible(address account) public view returns (bool) {
        if (address(luckToken) == address(0) || luckThreshold == 0 || account == address(0)) {
            return false;
        }
        return luckEscrow[account] >= luckThreshold;
    }

    function requestReveal(address pot) external onlyOwnerOrOperator returns (uint256 requestId) {
        Pot p = Pot(pot);
        require(p.status() == Pot.Status.Purchased, "Reveal: purchased");
        require(!revealRequested[pot], "Reveal: requested");
        require(card.potTokenCount(pot) > 0, "Reveal: cards");

        requestId = VRFCoordinatorV2Interface(vrfCoordinator).requestRandomWords(
            keyHash, subscriptionId, requestConfirmations, callbackGasLimit, 1
        );
        requestToPot[requestId] = pot;
        potRequestId[pot] = requestId;
        revealRequested[pot] = true;

        emit RevealRequested(pot, requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        address pot = requestToPot[requestId];
        require(pot != address(0), "Reveal: request");
        _allocate(pot, randomWords[0]);
    }

    function allocateWithSeed(address, uint256) external pure {
        revert("BOT port: fixed future block entropy only");
    }

    function _allocate(address pot, uint256 seed) private {
        uint256[] memory tokenIds = card.potTokenIds(pot);
        uint256 n = tokenIds.length;
        require(n > 0 && n <= OWNERSHIP_ONE, "Reveal: n");

        uint256[] memory raw = new uint256[](n);
        uint256[] memory multipliers = new uint256[](n);
        uint256 rawSum;

        for (uint256 i = 0; i < n; i++) {
            PotCard.CardData memory c = card.getCard(tokenIds[i]);
            uint256 roll = uint256(keccak256(abi.encode(seed, i, tokenIds[i])));
            uint256 mult = MULT_FLOOR + (roll % MULT_SPAN);
            address owner_ = card.ownerOf(tokenIds[i]);
            if (c.luckLocked && isLuckEligible(owner_)) {
                uint256 boosted = mult + ((mult * luckBoostBps) / 10_000);
                if (boosted > MULT_CEIL) boosted = MULT_CEIL;
                mult = boosted;
            }
            multipliers[i] = mult;
            raw[i] = c.depositAmount * mult;
            rawSum += raw[i];
        }
        require(rawSum > 0, "Reveal: raw");

        uint256[] memory weights = new uint256[](n);
        uint256 assigned;
        for (uint256 i = 0; i < n; i++) {
            weights[i] = (raw[i] * OWNERSHIP_ONE) / rawSum;
            if (weights[i] == 0) weights[i] = 1;
            assigned += weights[i];
        }

        if (assigned != OWNERSHIP_ONE) {
            uint256 maxIdx;
            uint256 maxRaw;
            for (uint256 i = 0; i < n; i++) {
                if (raw[i] > maxRaw) {
                    maxRaw = raw[i];
                    maxIdx = i;
                }
            }
            if (assigned > OWNERSHIP_ONE) {
                uint256 overflow = assigned - OWNERSHIP_ONE;
                require(weights[maxIdx] > overflow, "Reveal: floor");
                weights[maxIdx] -= overflow;
            } else {
                weights[maxIdx] += OWNERSHIP_ONE - assigned;
            }
        }

        uint256 total;
        for (uint256 i = 0; i < n; i++) {
            require(weights[i] > 0, "Reveal: weight");
            PotCard.Rarity rarity = weights[i] >= 4e17 ? PotCard.Rarity.Legendary
                : weights[i] >= 2e17 ? PotCard.Rarity.Epic
                : weights[i] >= 8e16 ? PotCard.Rarity.Rare : PotCard.Rarity.Common;
            card.commitIdentitySeed(tokenIds[i], keccak256(abi.encode(seed, i, tokenIds[i])));
            card.revealCard(tokenIds[i], weights[i], rarity);
            total += weights[i];
        }
        require(total == OWNERSHIP_ONE, "Reveal: sum");

        Pot(pot).markRevealed();
        emit RevealFulfilled(pot, total);
    }

    function _rarityFromMultiplier(uint256 multBps) private pure returns (PotCard.Rarity) {
        if (multBps >= 16_000) return PotCard.Rarity.Legendary;
        if (multBps >= 12_000) return PotCard.Rarity.Epic;
        if (multBps >= 9_000) return PotCard.Rarity.Rare;
        return PotCard.Rarity.Common;
    }
}
