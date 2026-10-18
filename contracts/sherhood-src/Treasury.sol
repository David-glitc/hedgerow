// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title Treasury — protocol fee sink (creation, entry, AUM/protocol bps)
contract Treasury is Ownable {
    using SafeERC20 for IERC20;

    address public immutable usdg;
    address public distributor;

    uint256 public feesCollectedUSDG;
    mapping(address => uint256) public feesCollectedByToken;

    event TokenDeposited(address indexed token, uint256 amount);
    event TokenDistributed(address indexed token, address indexed to, uint256 amount);
    event USDGDeposited(uint256 amount);
    event USDGWithdrawn(address indexed to, uint256 amount);
    event FeeCollected(address indexed from, address indexed token, uint256 amount);
    event DistributorUpdated(address distributor);

    constructor(address _usdg, address _owner) Ownable(_owner) {
        require(_usdg != address(0), "Treasury: zero usdg");
        usdg = _usdg;
    }

    function setDistributor(address _distributor) external onlyOwner {
        distributor = _distributor;
        emit DistributorUpdated(_distributor);
    }

    /// @notice Pull USDG fees from caller (Pot / PotFactory after approve).
    function depositFeeUSDG(uint256 amount) external {
        require(amount > 0, "Treasury: zero");
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);
        feesCollectedUSDG += amount;
        feesCollectedByToken[usdg] += amount;
        emit FeeCollected(msg.sender, usdg, amount);
    }

    /// @notice Pull arbitrary ERC20 fee (future royalties / sponsored fees).
    function depositFeeToken(address token, uint256 amount) external {
        require(amount > 0 && token != address(0), "Treasury: bad");
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        feesCollectedByToken[token] += amount;
        if (token == usdg) feesCollectedUSDG += amount;
        emit FeeCollected(msg.sender, token, amount);
    }

    function depositToken(address token, uint256 amount) external onlyOwner {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit TokenDeposited(token, amount);
    }

    function depositUSDG(uint256 amount) external onlyOwner {
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amount);
        emit USDGDeposited(amount);
    }

    function distribute(address token, address to, uint256 amount) external {
        require(msg.sender == distributor, "Treasury: only distributor");
        IERC20(token).safeTransfer(to, amount);
        emit TokenDistributed(token, to, amount);
    }

    function withdrawUSDG(address to, uint256 amount) external onlyOwner {
        IERC20(usdg).safeTransfer(to, amount);
        emit USDGWithdrawn(to, amount);
    }

    function withdrawToken(address token, address to, uint256 amount) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }

    function tokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    function usdgBalance() external view returns (uint256) {
        return IERC20(usdg).balanceOf(address(this));
    }
}
