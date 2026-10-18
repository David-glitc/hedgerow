// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Swap mock (Router02 layout): 1000 USDG → 1 target token.
contract MockSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);
        amountOut = params.amountIn / 1000;
        require(amountOut >= params.amountOutMinimum, "MockSwap: slippage");
        (bool ok,) = params.tokenOut.call(abi.encodeWithSignature("mint(address,uint256)", params.recipient, amountOut));
        require(ok, "MockSwap: mint fail");
    }
}
