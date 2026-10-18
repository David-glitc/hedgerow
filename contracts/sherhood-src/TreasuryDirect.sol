// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title TreasuryDirect — forwards protocol USDG fees straight to the fee wallet.
/// @dev Drop-in replacement for Treasury on PotFactory / EntryRouter / CardMarketplace.
contract TreasuryDirect is Ownable {
    using SafeERC20 for IERC20;

    address public immutable usdg;
    address public immutable feeRecipient;

    uint256 public feesForwardedUSDG;

    event FeeForwarded(address indexed from, uint256 amount);
    event FeeCollected(address indexed from, address indexed token, uint256 amount);

    constructor(address _usdg, address _feeRecipient, address _owner) Ownable(_owner) {
        require(_usdg != address(0) && _feeRecipient != address(0), "TreasuryDirect: zero");
        usdg = _usdg;
        feeRecipient = _feeRecipient;
    }

    function depositFeeUSDG(uint256 amount) external {
        require(amount > 0, "TreasuryDirect: zero");
        IERC20(usdg).safeTransferFrom(msg.sender, feeRecipient, amount);
        feesForwardedUSDG += amount;
        emit FeeCollected(msg.sender, usdg, amount);
        emit FeeForwarded(msg.sender, amount);
    }

    /// @notice Compatibility shim — marketplace may call for non-USDG royalties later.
    function depositFeeToken(address token, uint256 amount) external {
        require(amount > 0 && token != address(0), "TreasuryDirect: bad");
        IERC20(token).safeTransferFrom(msg.sender, feeRecipient, amount);
        emit FeeCollected(msg.sender, token, amount);
        emit FeeForwarded(msg.sender, amount);
    }
}
