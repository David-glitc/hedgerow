// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface ITreasuryFeeSink {
    function depositFeeUSDG(uint256 amount) external;
}

interface ICardState {
    function cards(uint256 tokenId)
        external
        view
        returns (
            address pot,
            uint256 depositAmount,
            uint256 ownershipWeight,
            uint8 rarity,
            bool revealed,
            bool claimed,
            bool luckLocked
        );
}

contract CardMarketplace is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Listing {
        address seller;
        uint256 price;
        bool active;
    }

    IERC721 public immutable card;
    address public immutable usdg;
    address public treasury;

    uint256 public royaltyBps = 250;
    uint256 public constant MAX_ROYALTY_BPS = 1000;

    mapping(uint256 => Listing) public listings;
    uint256 public listingCount;
    uint256[] private _activeTokenIds;
    mapping(uint256 => uint256) private _activeIndex;

    event Listed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event Cancelled(uint256 indexed tokenId, address indexed seller);
    event Sold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 royalty);
    event RoyaltyUpdated(uint256 bps);
    event TreasuryUpdated(address treasury);

    constructor(address owner_, address card_, address usdg_, address treasury_) Ownable(owner_) {
        require(card_ != address(0) && usdg_ != address(0), "Market: zero");
        card = IERC721(card_);
        usdg = usdg_;
        treasury = treasury_;
    }

    function setTreasury(address treasury_) external onlyOwner {
        treasury = treasury_;
        emit TreasuryUpdated(treasury_);
    }

    function setRoyaltyBps(uint256 bps) external onlyOwner {
        require(bps <= MAX_ROYALTY_BPS, "Market: royalty");
        royaltyBps = bps;
        emit RoyaltyUpdated(bps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function list(uint256 tokenId, uint256 price) external nonReentrant whenNotPaused {
        require(price > 0, "Market: price");
        require(card.ownerOf(tokenId) == msg.sender, "Market: owner");
        require(
            card.getApproved(tokenId) == address(this) || card.isApprovedForAll(msg.sender, address(this)),
            "Market: approve"
        );
        require(!listings[tokenId].active, "Market: listed");
        require(!_isClaimed(tokenId), "Market: claimed");

        listings[tokenId] = Listing({seller: msg.sender, price: price, active: true});
        _activeIndex[tokenId] = _activeTokenIds.length + 1;
        _activeTokenIds.push(tokenId);
        listingCount += 1;

        emit Listed(tokenId, msg.sender, price);
    }

    function cancel(uint256 tokenId) external nonReentrant {
        Listing storage L = listings[tokenId];
        require(L.active, "Market: listed");
        require(L.seller == msg.sender || msg.sender == owner(), "Market: seller");
        _delist(tokenId);
        emit Cancelled(tokenId, L.seller);
    }

    function buy(uint256 tokenId) external nonReentrant whenNotPaused {
        Listing memory L = listings[tokenId];
        require(L.active, "Market: listed");
        require(card.ownerOf(tokenId) == L.seller, "Market: moved");
        require(msg.sender != L.seller, "Market: self");
        require(!_isClaimed(tokenId), "Market: claimed");

        uint256 royalty = (L.price * royaltyBps) / 10_000;
        uint256 proceeds = L.price - royalty;

        IERC20(usdg).safeTransferFrom(msg.sender, L.seller, proceeds);
        if (royalty > 0) {
            require(treasury != address(0), "Market: treasury");
            IERC20(usdg).safeTransferFrom(msg.sender, address(this), royalty);
            IERC20(usdg).forceApprove(treasury, 0);
            IERC20(usdg).forceApprove(treasury, royalty);
            ITreasuryFeeSink(treasury).depositFeeUSDG(royalty);
        }

        card.safeTransferFrom(L.seller, msg.sender, tokenId);
        _delist(tokenId);

        emit Sold(tokenId, L.seller, msg.sender, L.price, royalty);
    }

    function _isClaimed(uint256 tokenId) private view returns (bool claimed) {
        (,,,,, claimed,) = ICardState(address(card)).cards(tokenId);
    }

    function _delist(uint256 tokenId) private {
        Listing storage L = listings[tokenId];
        require(L.active, "Market: listed");
        L.active = false;
        listingCount -= 1;

        uint256 idxPlus = _activeIndex[tokenId];
        if (idxPlus > 0) {
            uint256 idx = idxPlus - 1;
            uint256 last = _activeTokenIds.length - 1;
            if (idx != last) {
                uint256 moved = _activeTokenIds[last];
                _activeTokenIds[idx] = moved;
                _activeIndex[moved] = idx + 1;
            }
            _activeTokenIds.pop();
            _activeIndex[tokenId] = 0;
        }
    }

    function getActiveListings() external view returns (uint256[] memory tokenIds, Listing[] memory items) {
        uint256 n = _activeTokenIds.length;
        tokenIds = new uint256[](n);
        items = new Listing[](n);
        for (uint256 i = 0; i < n; i++) {
            uint256 id = _activeTokenIds[i];
            tokenIds[i] = id;
            items[i] = listings[id];
        }
    }

    function activeListingCount() external view returns (uint256) {
        return _activeTokenIds.length;
    }

    function isListedActive(uint256 tokenId) external view returns (bool) {
        return listings[tokenId].active;
    }
}
