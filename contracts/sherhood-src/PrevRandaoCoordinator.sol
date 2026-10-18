// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract PrevRandaoCoordinator {
    uint256 public nextRequestId = 1;
    uint256 public immutable minDelayBlocks;
    uint256 public immutable maxDelayBlocks;
    address public owner;
    mapping(address => bool) public fulfillers;
    mapping(uint256 => address) public consumers;
    mapping(uint256 => uint256) public requestBlock;
    mapping(uint256 => uint32) public numWordsOf;
    mapping(uint256 => bool) public fulfilled;

    event RandomWordsRequested(uint256 indexed requestId, address indexed consumer, uint32 numWords);
    event RandomWordsFulfilled(uint256 indexed requestId, uint256 seed);
    event FulfillerUpdated(address indexed fulfiller, bool allowed);
    event OwnerUpdated(address indexed owner);

    modifier onlyOwner() {
        require(msg.sender == owner, "PrevRandao: not owner");
        _;
    }

    constructor(uint256 minDelayBlocks_, uint256 maxDelayBlocks_) {
        require(minDelayBlocks_ >= 1 && minDelayBlocks_ <= 256, "PrevRandao: bad delay");
        require(maxDelayBlocks_ > minDelayBlocks_ && maxDelayBlocks_ <= 256, "PrevRandao: bad max");
        minDelayBlocks = minDelayBlocks_;
        maxDelayBlocks = maxDelayBlocks_;
        owner = msg.sender;
        fulfillers[msg.sender] = true;
        emit OwnerUpdated(msg.sender);
        emit FulfillerUpdated(msg.sender, true);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "PrevRandao: zero");
        owner = newOwner;
        emit OwnerUpdated(newOwner);
    }

    function setFulfiller(address fulfiller, bool allowed) external onlyOwner {
        fulfillers[fulfiller] = allowed;
        emit FulfillerUpdated(fulfiller, allowed);
    }

    function requestRandomWords(bytes32, uint64, uint16, uint32, uint32 numWords)
        external
        returns (uint256 requestId)
    {
        require(numWords > 0 && numWords <= 10, "PrevRandao: numWords");
        requestId = nextRequestId++;
        consumers[requestId] = msg.sender;
        requestBlock[requestId] = block.number;
        numWordsOf[requestId] = numWords;
        emit RandomWordsRequested(requestId, msg.sender, numWords);
    }

    function fulfill(uint256 requestId) external {
        require(fulfillers[msg.sender], "PrevRandao: not fulfiller");
        require(consumers[requestId] != address(0), "PrevRandao: unknown");
        require(!fulfilled[requestId], "PrevRandao: done");
        uint256 rb = requestBlock[requestId];
        require(block.number >= rb + minDelayBlocks, "PrevRandao: too early");
        require(block.number <= rb + maxDelayBlocks, "PrevRandao: too late");

        fulfilled[requestId] = true;
        uint32 n = numWordsOf[requestId];
        uint256[] memory words = new uint256[](n);

        bytes32 bh;
        if (block.number > rb && block.number - rb <= 256) {
            bh = blockhash(rb);
        }
        uint256 seed = uint256(keccak256(abi.encode(block.prevrandao, requestId, rb, bh, consumers[requestId])));
        for (uint32 i = 0; i < n; i++) {
            words[i] = uint256(keccak256(abi.encode(seed, i)));
        }

        (bool ok,) = consumers[requestId].call(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, words)
        );
        require(ok, "PrevRandao: fulfill failed");
        emit RandomWordsFulfilled(requestId, seed);
    }
}
