// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {PotFactory} from "../PotFactory.sol";
import {Pot} from "../Pot.sol";
import {PotV2} from "./PotV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Uses native settlement-token units (USDG on RH has 6 decimals).
contract PotFactoryV2 is PotFactory {
    using SafeERC20 for IERC20;
    constructor(address owner_, address usdg_, address card_) PotFactory(owner_, usdg_, card_) {
        uint8 decimals = IERC20Metadata(usdg_).decimals();
        require(decimals <= 18, "V2: decimals");
        minFundingGoal = 10 ** decimals;
        creationFee = 5 * 10 ** decimals;
    }
    function createInstantPot(uint256 amount) external nonReentrant whenNotPaused returns (address pool) {
        uint256 unit = 10 ** IERC20Metadata(usdg).decimals();
        require(amount >= unit * 5 && amount <= unit * 1000, "V2: instant amount");
        pool = _create(msg.sender, amount, minDuration, amount, 0, 0, false);
        PotV2(pool).setInstantMinter(msg.sender);
    }
    function createCommunityPot(uint256 goal, uint256 duration, uint256 minDeposit, uint256 entry, uint256 fee)
        external override nonReentrant whenNotPaused returns (address pool)
    {
        require(treasury != address(0), "PotFactory: no treasury");
        pool = _create(msg.sender, goal, duration, minDeposit, entry, fee, true);
        if (creationFee > 0 && msg.sender != owner()) {
            IERC20(usdg).safeTransferFrom(msg.sender, pool, creationFee);
            PotV2(pool).recordCreationFee(creationFee);
        }
    }
    function _deployPot(address creator, uint256 goal, uint256 duration, uint256 minDeposit, uint256 entry, uint256 fee) internal override returns (Pot) {
        return new PotV2(owner(), creator, usdg, address(this), address(card), goal, duration, minDeposit, entry, fee);
    }
}
