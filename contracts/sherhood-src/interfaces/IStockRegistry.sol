// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IStockRegistry {
    struct TokenInfo {
        bool allowed;
        string symbol;
        uint24 defaultPoolFee;
    }

    function isAllowed(address token) external view returns (bool);
    function getToken(address token) external view returns (TokenInfo memory);
    function getTokenList() external view returns (address[] memory);
}
