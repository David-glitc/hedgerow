// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockPriceFeed {
    uint256 private _price;
    uint8 private _decimals;

    constructor(uint256 price, uint8 decimals_) {
        _price = price;
        _decimals = decimals_;
    }

    function setPrice(uint256 price) external {
        _price = price;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (0, int256(_price), 0, 0, 0);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}
