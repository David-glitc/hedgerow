// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapRouter02} from "./interfaces/ISwapRouter02.sol";
import {Pot} from "./Pot.sol";
import {IStockRegistry} from "./interfaces/IStockRegistry.sol";

contract AssetManager is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable usdg;
    address public swapRouter;
    address public stockRegistry;
    mapping(address => bool) public operators;

    uint256 public defaultPickCount = 3;
    uint256 public minPickCount = 2;
    uint256 public maxPickCount = 5;
    uint256 public purchaseDelayBlocks = 2;
    mapping(address => uint256) public purchaseCommitBlock;
    bool public seededPurchaseEnabled = true;

    event SwapRouterUpdated(address router);
    event StockRegistryUpdated(address registry);
    event PickBoundsUpdated(uint256 minPick, uint256 maxPick, uint256 defaultPick);
    event OperatorUpdated(address indexed operator, bool allowed);
    event PurchaseDelaySet(uint256 blocks_);
    event SeededPurchaseSet(bool enabled);
    event PurchaseCommitted(address indexed pot, uint256 commitBlock);
    event PotPurchased(address indexed pot, address[] tokens, uint256[] usdgIn, uint256[] assetOut, uint256 seed);

    modifier onlyOwnerOrOperator() {
        require(msg.sender == owner() || operators[msg.sender], "AM: auth");
        _;
    }

    constructor(address owner_, address usdg_, address swapRouter_) Ownable(owner_) {
        require(usdg_ != address(0), "AM: usdg");
        usdg = usdg_;
        swapRouter = swapRouter_;
    }

    function setSwapRouter(address router_) external onlyOwner {
        swapRouter = router_;
        emit SwapRouterUpdated(router_);
    }

    function setStockRegistry(address registry_) external onlyOwner {
        stockRegistry = registry_;
        emit StockRegistryUpdated(registry_);
    }

    function setPickBounds(uint256 minPick, uint256 maxPick, uint256 defaultPick) external onlyOwner {
        require(minPick > 0 && minPick <= maxPick && defaultPick >= minPick && defaultPick <= maxPick, "AM: bounds");
        minPickCount = minPick;
        maxPickCount = maxPick;
        defaultPickCount = defaultPick;
        emit PickBoundsUpdated(minPick, maxPick, defaultPick);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        operators[operator] = allowed;
        emit OperatorUpdated(operator, allowed);
    }

    function setPurchaseDelay(uint256 blocks_) external onlyOwner {
        require(blocks_ >= 1 && blocks_ <= 250, "AM: delay");
        purchaseDelayBlocks = blocks_;
        emit PurchaseDelaySet(blocks_);
    }

    function setSeededPurchaseEnabled(bool enabled) external onlyOwner {
        seededPurchaseEnabled = enabled;
        emit SeededPurchaseSet(enabled);
    }

    function commitPurchase(address pot) external onlyOwnerOrOperator {
        require(Pot(pot).status() == Pot.Status.Closed, "AM: not closed");
        uint256 cb = purchaseCommitBlock[pot];
        require(cb == 0 || block.number - cb > 256, "AM: committed");
        purchaseCommitBlock[pot] = block.number;
        emit PurchaseCommitted(pot, block.number);
    }

    function purchase(address pot, uint256 pickCount, uint256[] calldata minOutPerLeg)
        external
        onlyOwnerOrOperator
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        uint256 cb = purchaseCommitBlock[pot];
        require(cb != 0, "AM: no commit");
        require(block.number > cb + purchaseDelayBlocks, "AM: early");
        require(block.number - cb <= 256, "AM: expired");

        bytes32 bh = blockhash(cb);
        require(bh != bytes32(0), "AM: entropy");
        uint256 seed = uint256(keccak256(abi.encode(bh, pot)));

        address[] memory picked = _resolvePicks(seed, pickCount);
        require(minOutPerLeg.length == picked.length, "AM: mins");

        uint256[] memory minOut = new uint256[](minOutPerLeg.length);
        for (uint256 i = 0; i < minOutPerLeg.length; i++) {
            require(minOutPerLeg[i] > 0, "AM: zero min");
            minOut[i] = minOutPerLeg[i];
        }
        amountsOut = _executePurchase(pot, seed, picked, minOut);
    }

    function purchaseWithSeed(address pot, uint256 seed, uint256 pickCount, uint256 amountOutMinimum)
        external
        onlyOwnerOrOperator
        nonReentrant
        returns (uint256[] memory amountsOut)
    {
        require(seededPurchaseEnabled, "AM: seeded off");
        address[] memory picked = _resolvePicks(seed, pickCount);
        uint256 n = picked.length;
        uint256[] memory minOut = new uint256[](n);
        if (amountOutMinimum > 0 && n > 0) {
            uint256 per = amountOutMinimum / n;
            uint256 rem = amountOutMinimum - per * n;
            for (uint256 i = 0; i < n; i++) {
                minOut[i] = per + (i == 0 ? rem : 0);
            }
        }
        amountsOut = _executePurchase(pot, seed, picked, minOut);
    }

    function _resolvePicks(uint256 seed, uint256 pickCount) private view returns (address[] memory picked) {
        require(stockRegistry != address(0), "AM: registry");
        address[] memory list = IStockRegistry(stockRegistry).getTokenList();
        uint256 listLen = list.length;
        require(listLen > 0, "AM: empty");

        if (pickCount == 0) pickCount = defaultPickCount;
        if (pickCount < minPickCount) pickCount = minPickCount;
        if (pickCount > maxPickCount) pickCount = maxPickCount;
        if (pickCount > listLen) pickCount = listLen;

        picked = _pickTokens(list, seed, pickCount);
        require(picked.length > 0, "AM: picks");
    }

    function _executePurchase(address pot, uint256 seed, address[] memory picked, uint256[] memory minOut)
        private
        returns (uint256[] memory amountsOut)
    {
        Pot p = Pot(pot);
        require(p.status() == Pot.Status.Closed, "AM: not closed");

        uint256 pickedLen = picked.length;
        (uint256 swapAmount,) = p.pullForPurchase();
        require(swapAmount > 0, "AM: empty");

        uint256 perLeg = swapAmount / pickedLen;
        uint256 remainder = swapAmount - (perLeg * pickedLen);

        address[] memory tokens = new address[](pickedLen);
        amountsOut = new uint256[](pickedLen);
        uint256[] memory usdgIn = new uint256[](pickedLen);

        IERC20(usdg).forceApprove(swapRouter, 0);
        IERC20(usdg).forceApprove(swapRouter, swapAmount);

        for (uint256 i = 0; i < pickedLen; i++) {
            uint256 legIn = perLeg + (i == 0 ? remainder : 0);
            IStockRegistry.TokenInfo memory info = IStockRegistry(stockRegistry).getToken(picked[i]);
            require(info.allowed, "AM: token");

            amountsOut[i] = ISwapRouter02(swapRouter).exactInputSingle(
                ISwapRouter02.ExactInputSingleParams({
                    tokenIn: usdg,
                    tokenOut: picked[i],
                    fee: info.defaultPoolFee,
                    recipient: pot,
                    amountIn: legIn,
                    amountOutMinimum: minOut[i],
                    sqrtPriceLimitX96: 0
                })
            );

            tokens[i] = picked[i];
            usdgIn[i] = legIn;
        }

        p.markPurchased(tokens, amountsOut);
        emit PotPurchased(pot, tokens, usdgIn, amountsOut, seed);
    }

    function _pickTokens(address[] memory list, uint256 seed, uint256 pickCount)
        private
        pure
        returns (address[] memory picked)
    {
        uint256 listLen = list.length;
        if (pickCount > listLen) pickCount = listLen;
        picked = new address[](pickCount);
        bool[] memory used = new bool[](listLen);
        uint256 pickedLen;

        for (uint256 attempt = 0; pickedLen < pickCount && attempt < listLen * 3; attempt++) {
            uint256 idx = uint256(keccak256(abi.encode(seed, attempt))) % listLen;
            if (!used[idx]) {
                used[idx] = true;
                picked[pickedLen++] = list[idx];
            }
        }
        if (pickedLen < pickCount) {
            for (uint256 i = 0; i < listLen && pickedLen < pickCount; i++) {
                if (!used[i]) {
                    used[i] = true;
                    picked[pickedLen++] = list[i];
                }
            }
        }
        require(pickedLen == pickCount, "AM: picks");
    }
}
