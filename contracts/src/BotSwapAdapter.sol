// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter02} from "../sherhood-src/interfaces/ISwapRouter02.sol";
import {IBotV3Router} from "./interfaces/IBotV3Router.sol";


/// @notice Adapts the original Sherhood Router02 ABI to BDEX's deadline-bearing V3 ABI.
contract BotSwapAdapter is ISwapRouter02, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable router;
    constructor(address router_) { require(router_.code.length > 0, "router missing"); router = router_; }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable nonReentrant returns(uint256 amountOut) {
        require(msg.value == 0 && p.amountIn > 0 && p.amountOutMinimum > 0, "invalid swap");
        IERC20(p.tokenIn).safeTransferFrom(msg.sender,address(this),p.amountIn);
        IERC20(p.tokenIn).forceApprove(router,p.amountIn);
        amountOut = IBotV3Router(router).exactInputSingle(IBotV3Router.Params(p.tokenIn,p.tokenOut,p.fee,p.recipient,block.timestamp,p.amountIn,p.amountOutMinimum,p.sqrtPriceLimitX96));
        IERC20(p.tokenIn).forceApprove(router,0);
    }
}
