// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title SherhoodToken ($SHRH) — protocol luck bringer for card reveals
contract SherhoodToken is ERC20, Ownable {
    constructor(address owner_, address treasury_) ERC20("Sherhood", "SHRH") Ownable(owner_) {
        require(treasury_ != address(0), "SHRH: zero treasury");
        _mint(treasury_, 1_000_000_000 * 1e18);
    }
}
