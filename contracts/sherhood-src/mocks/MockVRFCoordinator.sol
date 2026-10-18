// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Minimal VRF coordinator mock for local/devnet simulation.
contract MockVRFCoordinator {
    address public consumer;
    uint256 private _nextRequestId = 1;
    mapping(uint256 => uint32) public numWordsOf;

    function setConsumer(address consumer_) external {
        consumer = consumer_;
    }

    function requestRandomWords(bytes32, uint64, uint16, uint32, uint32 numWords) external returns (uint256 requestId) {
        requestId = _nextRequestId++;
        numWordsOf[requestId] = numWords;
    }

    function fulfill(uint256 requestId, uint256[] memory randomWords) external {
        require(consumer != address(0), "MockVRF: no consumer");
        (bool success,) = consumer.call(
            abi.encodeWithSignature("rawFulfillRandomWords(uint256,uint256[])", requestId, randomWords)
        );
        require(success, "MockVRF: fulfill failed");
    }

    function fulfillWithSeed(uint256 requestId, uint256 seed) external {
        uint32 n = numWordsOf[requestId];
        if (n == 0) n = 1;
        uint256[] memory words = new uint256[](n);
        for (uint32 i = 0; i < n; i++) {
            words[i] = uint256(keccak256(abi.encode(seed, i)));
        }
        this.fulfill(requestId, words);
    }
}
