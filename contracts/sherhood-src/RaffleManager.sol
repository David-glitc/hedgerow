// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {VRFConsumerBaseV2} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

contract RaffleManager is VRFConsumerBaseV2, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum RoundState { Open, Closed, Resolved, Bought, Complete }

    struct Round {
        address targetToken;
        uint24 swapFee;
        uint256 entryFee;
        uint256 maxEntries;
        uint256 duration;
        uint256 feePercent;
        uint256 maxWinners;
        RoundState state;
        uint256 totalEntries;
        uint256 totalUSDG;
        uint256 tokenAmount;
        uint256 startTime;
        uint256 requestId;
    }

    struct Entry {
        address user;
        bool claimed;
    }

    address public immutable usdg;
    address public immutable vrfCoordinator;
    address public swapRouter;
    Round[] public rounds;
    mapping(uint256 => Entry[]) public entries;
    mapping(uint256 => uint256[]) public winnerIndices;

    bytes32 public keyHash;
    uint64 public subscriptionId;
    uint32 public callbackGasLimit = 500000;
    uint16 public requestConfirmations = 3;

    event RoundCreated(uint256 indexed roundId, address targetToken, uint256 entryFee, uint256 maxEntries, uint256 duration);
    event RoundEntered(uint256 indexed roundId, address indexed user, uint256 entryIndex);
    event RoundClosed(uint256 indexed roundId, uint256 requestId);
    event RoundResolved(uint256 indexed roundId, uint256[] winners);
    event TokensBought(uint256 indexed roundId, address targetToken, uint256 amountIn, uint256 amountOut);
    event WinningsClaimed(uint256 indexed roundId, address indexed user, uint256 amount);
    event SwapRouterUpdated(address router);
    event VRFConfigSet(bytes32 keyHash, uint64 subId, uint32 gasLimit);

    constructor(
        address _usdg,
        address _vrfCoordinator,
        address _swapRouter,
        address _owner
    ) VRFConsumerBaseV2(_vrfCoordinator) Ownable(_owner) {
        usdg = _usdg;
        vrfCoordinator = _vrfCoordinator;
        swapRouter = _swapRouter;
    }

    function createRound(
        address _targetToken,
        uint24 _swapFee,
        uint256 _entryFee,
        uint256 _maxEntries,
        uint256 _duration,
        uint256 _feePercent,
        uint256 _maxWinners
    ) external onlyOwner returns (uint256 roundId) {
        roundId = rounds.length;
        rounds.push(Round({
            targetToken: _targetToken,
            swapFee: _swapFee,
            entryFee: _entryFee,
            maxEntries: _maxEntries,
            duration: _duration,
            feePercent: _feePercent,
            maxWinners: _maxWinners,
            state: RoundState.Open,
            totalEntries: 0,
            totalUSDG: 0,
            tokenAmount: 0,
            startTime: block.timestamp,
            requestId: 0
        }));
        emit RoundCreated(roundId, _targetToken, _entryFee, _maxEntries, _duration);
    }

    function enter(uint256 roundId) external nonReentrant whenNotPaused {
        Round storage round = rounds[roundId];
        require(round.state == RoundState.Open, "Raffle: not open");
        require(round.totalEntries < round.maxEntries, "Raffle: max entries");
        require(block.timestamp < round.startTime + round.duration, "Raffle: time expired");

        IERC20(usdg).safeTransferFrom(msg.sender, address(this), round.entryFee);
        entries[roundId].push(Entry({user: msg.sender, claimed: false}));
        round.totalEntries++;
        round.totalUSDG += round.entryFee;

        emit RoundEntered(roundId, msg.sender, round.totalEntries - 1);
    }

    function closeRound(uint256 roundId) external onlyOwner {
        Round storage round = rounds[roundId];
        require(round.state == RoundState.Open, "Raffle: not open");
        bool timeExpired = block.timestamp >= round.startTime + round.duration;
        bool full = round.totalEntries >= round.maxEntries;
        require(timeExpired || full, "Raffle: not ready");
        require(round.totalEntries >= round.maxWinners, "Raffle: not enough entries");

        round.state = RoundState.Closed;
        uint256 requestId = VRFCoordinatorV2Interface(vrfCoordinator).requestRandomWords(
            keyHash,
            subscriptionId,
            requestConfirmations,
            callbackGasLimit,
            uint32(round.maxWinners)
        );
        round.requestId = requestId;

        emit RoundClosed(roundId, requestId);
    }

    function fulfillRandomWords(uint256 requestId, uint256[] memory randomWords) internal override {
        for (uint256 i = 0; i < rounds.length; i++) {
            if (rounds[i].requestId == requestId) {
                _resolveRound(i, randomWords);
                return;
            }
        }
    }

    function _resolveRound(uint256 roundId, uint256[] memory randomWords) private {
        Round storage round = rounds[roundId];
        round.state = RoundState.Resolved;

        uint256 numWinners = round.maxWinners > round.totalEntries ? round.totalEntries : round.maxWinners;
        uint256[] storage winners = winnerIndices[roundId];

        uint256 usedWords = 0;
        for (uint256 i = 0; i < numWinners; i++) {
            uint256 rand = randomWords[usedWords % randomWords.length];
            usedWords++;
            uint256 idx = rand % round.totalEntries;
            while (_isAlreadyWinner(roundId, idx, winners)) {
                rand = uint256(keccak256(abi.encode(rand, i)));
                idx = rand % round.totalEntries;
            }
            winners.push(idx);
        }

        emit RoundResolved(roundId, winners);
    }

    function _isAlreadyWinner(uint256, uint256 idx, uint256[] storage currentWinners) private view returns (bool) {
        for (uint256 i = 0; i < currentWinners.length; i++) {
            if (currentWinners[i] == idx) return true;
        }
        return false;
    }

    function buyTokens(uint256 roundId, uint256 amountOutMinimum) external onlyOwner nonReentrant {
        Round storage round = rounds[roundId];
        require(round.state == RoundState.Resolved, "Raffle: not resolved");

        uint256 protocolFee = round.totalUSDG * round.feePercent / 10000;
        uint256 swapAmount = round.totalUSDG - protocolFee;

        IERC20(usdg).forceApprove(swapRouter, 0);
        IERC20(usdg).forceApprove(swapRouter, swapAmount);

        uint256 deadline = block.timestamp + 300;
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: usdg,
            tokenOut: round.targetToken,
            fee: round.swapFee,
            recipient: address(this),
            deadline: deadline,
            amountIn: swapAmount,
            amountOutMinimum: amountOutMinimum,
            sqrtPriceLimitX96: 0
        });

        uint256 amountOut = ISwapRouter(swapRouter).exactInputSingle(params);
        round.tokenAmount = amountOut;
        round.state = RoundState.Bought;

        emit TokensBought(roundId, round.targetToken, swapAmount, amountOut);
    }

    function claimWinnings(uint256 roundId, uint256 entryIndex) external nonReentrant {
        Round storage round = rounds[roundId];
        require(round.state == RoundState.Bought, "Raffle: not bought");
        require(entries[roundId][entryIndex].user == msg.sender, "Raffle: not your entry");
        require(!entries[roundId][entryIndex].claimed, "Raffle: already claimed");

        bool isWinner = false;
        for (uint256 i = 0; i < winnerIndices[roundId].length; i++) {
            if (winnerIndices[roundId][i] == entryIndex) {
                isWinner = true;
                break;
            }
        }
        require(isWinner, "Raffle: not a winner");

        entries[roundId][entryIndex].claimed = true;
        uint256 payout = round.tokenAmount / winnerIndices[roundId].length;
        IERC20(round.targetToken).safeTransfer(msg.sender, payout);

        emit WinningsClaimed(roundId, msg.sender, payout);
    }

    function withdrawProtocolUSDG(uint256 roundId) external onlyOwner {
        Round storage round = rounds[roundId];
        require(round.state == RoundState.Bought || round.state == RoundState.Resolved, "Raffle: wrong state");
        uint256 protocolFee = round.totalUSDG * round.feePercent / 10000;
        uint256 balance = IERC20(usdg).balanceOf(address(this));
        uint256 available = protocolFee < balance ? protocolFee : balance;
        IERC20(usdg).safeTransfer(msg.sender, available);
    }

    function setSwapRouter(address _router) external onlyOwner {
        swapRouter = _router;
        emit SwapRouterUpdated(_router);
    }

    function setVRFConfig(bytes32 _keyHash, uint64 _subId, uint32 _gasLimit) external onlyOwner {
        keyHash = _keyHash;
        subscriptionId = _subId;
        callbackGasLimit = _gasLimit;
        emit VRFConfigSet(_keyHash, _subId, _gasLimit);
    }

    function getRoundIds() external view returns (uint256[] memory ids) {
        ids = new uint256[](rounds.length);
        for (uint256 i = 0; i < rounds.length; i++) ids[i] = i;
    }

    function getEntryCount(uint256 roundId) external view returns (uint256) {
        return entries[roundId].length;
    }

    function getWinnerCount(uint256 roundId) external view returns (uint256) {
        return winnerIndices[roundId].length;
    }

    function getRound(uint256 roundId) external view returns (Round memory) {
        return rounds[roundId];
    }

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }
}
