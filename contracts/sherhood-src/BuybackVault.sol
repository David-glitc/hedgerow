// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AggregatorV3Interface} from "chainlink-brownie-contracts/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

contract BuybackVault is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable usdg;
    address public treasury;
    uint256 public buybackPercentage = 85;

    mapping(address => address) public priceFeeds;

    event BuybackAccepted(address indexed user, address indexed token, uint256 tokenAmount, uint256 usdgAmount);
    event PriceFeedSet(address indexed token, address indexed feed);
    event BuybackPercentageUpdated(uint256 percentage);
    event TreasuryUpdated(address treasury);

    constructor(address _usdg, address _treasury, address _owner) Ownable(_owner) {
        usdg = _usdg;
        treasury = _treasury;
    }

    function setPriceFeed(address token, address feed) external onlyOwner {
        priceFeeds[token] = feed;
        emit PriceFeedSet(token, feed);
    }

    function setBuybackPercentage(uint256 percentage) external onlyOwner {
        require(percentage <= 100, "BuybackVault: invalid percentage");
        buybackPercentage = percentage;
        emit BuybackPercentageUpdated(percentage);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    function getTokenPrice(address token) public view returns (uint256 price, uint8 decimals) {
        address feed = priceFeeds[token];
        require(feed != address(0), "BuybackVault: no price feed");
        AggregatorV3Interface priceFeed = AggregatorV3Interface(feed);
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        require(answer > 0, "BuybackVault: invalid price");
        require(updatedAt > block.timestamp - 1 hours, "BuybackVault: stale");
        require(answeredInRound >= roundId, "BuybackVault: round incomplete");
        price = uint256(answer);
        decimals = priceFeed.decimals();
    }

    function calculateBuyback(address token, uint256 tokenAmount) public view returns (uint256 usdgAmount) {
        (uint256 price, uint8 priceDecimals) = getTokenPrice(token);
        uint8 tokenDecimals = IERC20Metadata(token).decimals();
        usdgAmount = tokenAmount * price * buybackPercentage / (10 ** tokenDecimals) / 100;
        if (priceDecimals < 18) {
            usdgAmount = usdgAmount * (10 ** (18 - priceDecimals));
        } else if (priceDecimals > 18) {
            usdgAmount = usdgAmount / (10 ** (priceDecimals - 18));
        }
    }

    function acceptBuyback(address token, uint256 tokenAmount) external nonReentrant {
        uint256 usdgAmount = calculateBuyback(token, tokenAmount);
        require(usdgAmount > 0, "BuybackVault: zero buyback");
        require(IERC20(usdg).balanceOf(address(this)) >= usdgAmount, "BuybackVault: insufficient USDG");

        IERC20(token).safeTransferFrom(msg.sender, treasury, tokenAmount);
        IERC20(usdg).safeTransfer(msg.sender, usdgAmount);

        emit BuybackAccepted(msg.sender, token, tokenAmount, usdgAmount);
    }

    function withdrawToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(msg.sender, amount);
    }

    function withdrawUSDG(uint256 amount) external onlyOwner {
        IERC20(usdg).safeTransfer(msg.sender, amount);
    }

    function depositUSDG(uint256 amount) external onlyOwner {
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);
    }
}
