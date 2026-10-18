// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISwapRouter02} from "../interfaces/ISwapRouter02.sol";

interface ITestnetStockRouter {
    function quoteUSDGForToken(address token, uint256 amount) external view returns (uint256);
    function quoteTokenForUSDG(address token, uint256 amount) external view returns (uint256);
    function swapExactUSDGForToken(address token, uint256 amount, uint256 minOut, address recipient) external returns (uint256);
    function swapExactTokenForUSDG(address token, uint256 amount, uint256 minOut, address recipient) external returns (uint256);
}

/// @notice Routes Sherhood purchases to the existing funded testnet stock router.
/// No tokens, liquidity or prices are fabricated by this adapter.
contract TestnetSwapAdapter is ISwapRouter02, ReentrancyGuard {
    using SafeERC20 for IERC20;
    address public immutable settlement;
    ITestnetStockRouter public immutable router;
    constructor(address settlement_, address router_) {
        require(block.chainid == 46630, "Adapter: testnet only");
        require(settlement_.code.length > 0 && router_.code.length > 0, "Adapter: missing contract");
        settlement = settlement_;
        router = ITestnetStockRouter(router_);
    }
    function exactInputSingle(ExactInputSingleParams calldata p) external payable nonReentrant returns (uint256 amountOut) {
        require(msg.value == 0 && p.sqrtPriceLimitX96 == 0 && p.amountIn > 0, "Adapter: parameters");
        require(p.tokenIn == settlement || p.tokenOut == settlement, "Adapter: settlement pair");
        IERC20(p.tokenIn).safeTransferFrom(msg.sender, address(this), p.amountIn);
        IERC20(p.tokenIn).forceApprove(address(router), p.amountIn);
        uint256 quote = p.tokenIn == settlement ? router.quoteUSDGForToken(p.tokenOut, p.amountIn) : router.quoteTokenForUSDG(p.tokenIn, p.amountIn);
        uint256 minOut = quote * 99 / 100;
        if (p.amountOutMinimum > minOut) minOut = p.amountOutMinimum;
        require(minOut > 0, "Adapter: zero quote");
        if (p.tokenIn == settlement) amountOut = router.swapExactUSDGForToken(p.tokenOut, p.amountIn, minOut, p.recipient);
        else amountOut = router.swapExactTokenForUSDG(p.tokenIn, p.amountIn, minOut, p.recipient);
        IERC20(p.tokenIn).forceApprove(address(router), 0);
    }
}
