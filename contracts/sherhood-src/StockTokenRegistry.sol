// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title StockTokenRegistry — allowlist of canonical RH Stock Token / ETF addresses
/// @notice Source of truth for addresses: https://docs.robinhood.com/chain/contracts/
contract StockTokenRegistry is Ownable {
    struct TokenInfo {
        bool allowed;
        string symbol;
        uint24 defaultPoolFee; // Uniswap fee tier hint (e.g. 3000)
    }

    mapping(address => TokenInfo) public tokens;
    address[] public tokenList;

    event TokenSet(address indexed token, bool allowed, string symbol, uint24 defaultPoolFee);

    constructor(address owner_) Ownable(owner_) {}

    function setToken(address token, bool allowed, string calldata symbol, uint24 defaultPoolFee)
        external
        onlyOwner
    {
        require(token != address(0), "Registry: zero");
        TokenInfo storage info = tokens[token];
        if (!info.allowed && allowed) {
            tokenList.push(token);
        }
        info.allowed = allowed;
        info.symbol = symbol;
        info.defaultPoolFee = defaultPoolFee;
        emit TokenSet(token, allowed, symbol, defaultPoolFee);
    }

    function setTokens(
        address[] calldata addrs,
        bool[] calldata allowed,
        string[] calldata symbols,
        uint24[] calldata fees
    ) external onlyOwner {
        require(
            addrs.length == allowed.length && addrs.length == symbols.length && addrs.length == fees.length,
            "Registry: length"
        );
        for (uint256 i = 0; i < addrs.length; i++) {
            address token = addrs[i];
            require(token != address(0), "Registry: zero");
            TokenInfo storage info = tokens[token];
            if (!info.allowed && allowed[i]) {
                tokenList.push(token);
            }
            info.allowed = allowed[i];
            info.symbol = symbols[i];
            info.defaultPoolFee = fees[i];
            emit TokenSet(token, allowed[i], symbols[i], fees[i]);
        }
    }

    function isAllowed(address token) external view returns (bool) {
        return tokens[token].allowed;
    }

    function getToken(address token) external view returns (TokenInfo memory) {
        return tokens[token];
    }

    function tokenCount() external view returns (uint256) {
        return tokenList.length;
    }

    function getTokenList() external view returns (address[] memory) {
        return tokenList;
    }
}
