// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {Pot} from "./Pot.sol";

interface ITreasuryFeeSink {
    function depositFeeUSDG(uint256 amount) external;
}

/// @title EntryRouter — pay with ETH/WETH, auto-swap to USDG, skim fee, join pot
contract EntryRouter is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable usdg;
    address public immutable weth;
    address public swapRouter;
    address public treasury;
    address public factory;

    /// @notice Fee skimmed from swapped USDG before pot deposit (max 10%).
    uint256 public routerFeeBps = 50; // 0.5%
    uint256 public constant MAX_FEE_BPS = 1000;
    uint24 public wethUsdgPoolFee = 500; // 0.05% default; owner can tune

    event SwapRouterUpdated(address router);
    event TreasuryUpdated(address treasury);
    event FactoryUpdated(address factory);
    event FeeUpdated(uint256 bps);
    event PoolFeeUpdated(uint24 fee);
    event EnteredWithEth(
        address indexed user,
        address indexed pot,
        uint256 ethIn,
        uint256 usdgOut,
        uint256 routerFee,
        uint256 depositAmount,
        uint256 tokenId
    );
    event EnteredWithWeth(
        address indexed user,
        address indexed pot,
        uint256 wethIn,
        uint256 usdgOut,
        uint256 routerFee,
        uint256 depositAmount,
        uint256 tokenId
    );

    constructor(
        address owner_,
        address usdg_,
        address weth_,
        address swapRouter_,
        address treasury_,
        address factory_
    ) Ownable(owner_) {
        require(usdg_ != address(0) && weth_ != address(0), "Entry: zero");
        usdg = usdg_;
        weth = weth_;
        swapRouter = swapRouter_;
        treasury = treasury_;
        factory = factory_;
    }

    receive() external payable {
        require(msg.sender == weth, "Entry: eth");
    }

    function withdrawETH(address to, uint256 amount) external onlyOwner {
        require(to != address(0), "Entry: zero");
        (bool ok,) = to.call{value: amount}("");
        require(ok, "Entry: eth send");
    }

    function setSwapRouter(address router_) external onlyOwner {
        swapRouter = router_;
        emit SwapRouterUpdated(router_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setFactory(address factory_) external onlyOwner {
        factory = factory_;
        emit FactoryUpdated(factory_);
    }

    function setRouterFeeBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_FEE_BPS, "Entry: fee high");
        routerFeeBps = bps;
        emit FeeUpdated(bps);
    }

    function setWethUsdgPoolFee(uint24 fee) external onlyOwner {
        wethUsdgPoolFee = fee;
        emit PoolFeeUpdated(fee);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Wrap ETH → swap to USDG → skim fee → deposit into pot (card to msg.sender).
    function depositWithETH(address pot, uint256 minUsdgOut)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        require(msg.value > 0, "Entry: zero eth");
        IWETH(weth).deposit{value: msg.value}();
        tokenId = _swapAndDeposit(msg.sender, pot, msg.value, minUsdgOut, true);
    }

    /// @notice Pull WETH → swap to USDG → skim fee → deposit into pot.
    function depositWithWETH(address pot, uint256 amountIn, uint256 minUsdgOut)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 tokenId)
    {
        require(amountIn > 0, "Entry: zero weth");
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amountIn);
        tokenId = _swapAndDeposit(msg.sender, pot, amountIn, minUsdgOut, false);
    }

    function _swapAndDeposit(
        address user,
        address pot,
        uint256 amountIn,
        uint256 minUsdgOut,
        bool fromEth
    ) private returns (uint256 tokenId) {
        require(factory != address(0) && IFactoryPots(factory).isPot(pot), "Entry: bad pot");
        require(treasury != address(0), "Entry: no treasury");

        IERC20(weth).forceApprove(swapRouter, 0);
        IERC20(weth).forceApprove(swapRouter, amountIn);

        uint256 usdgOut = ISwapRouter02(swapRouter).exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: weth,
                tokenOut: usdg,
                fee: wethUsdgPoolFee,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: minUsdgOut,
                sqrtPriceLimitX96: 0
            })
        );

        uint256 routerFee = (usdgOut * routerFeeBps) / 10_000;
        uint256 net = usdgOut - routerFee;
        uint256 potEntry = Pot(pot).entryFee();
        require(net > potEntry, "Entry: cannot cover entry");
        uint256 depositAmount = net - potEntry;
        require(depositAmount >= Pot(pot).minDeposit(), "Entry: below min");

        if (routerFee > 0) {
            IERC20(usdg).forceApprove(treasury, 0);
            IERC20(usdg).forceApprove(treasury, routerFee);
            ITreasuryFeeSink(treasury).depositFeeUSDG(routerFee);
        }

        uint256 pull = depositAmount + potEntry;
        IERC20(usdg).forceApprove(pot, 0);
        IERC20(usdg).forceApprove(pot, pull);
        tokenId = Pot(pot).depositFor(user, depositAmount);

        if (fromEth) {
            emit EnteredWithEth(user, pot, amountIn, usdgOut, routerFee, depositAmount, tokenId);
        } else {
            emit EnteredWithWeth(user, pot, amountIn, usdgOut, routerFee, depositAmount, tokenId);
        }
    }
}

interface IFactoryPots {
    function isPot(address pot) external view returns (bool);
}
