// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

interface IMarketplaceLock {
    function isListedActive(uint256 tokenId) external view returns (bool);
}

contract PotCard is ERC721, ERC2981, Ownable {
    enum Rarity {
        Unrevealed,
        Common,
        Rare,
        Epic,
        Legendary
    }

    struct CardData {
        address pot;
        uint256 depositAmount;
        uint256 ownershipWeight;
        Rarity rarity;
        bool revealed;
        bool claimed;
        bool luckLocked;
    }

    uint96 public constant DEFAULT_ROYALTY_BPS = 250;

    address public minter;
    address public revealer;
    address public cardMarketplace;
    string private _baseTokenURI;
    string private _contractURI;

    uint256 private _nextTokenId = 1;
    uint256 public totalBurned;
    mapping(uint256 => CardData) public cards;
    mapping(address => uint256[]) private _potTokenIds;

    event MinterUpdated(address minter);
    event RevealerUpdated(address revealer);
    event CardMarketplaceUpdated(address marketplace);
    event ContractURIUpdated(string uri);
    event RoyaltyUpdated(address receiver, uint96 bps);
    event CardMinted(uint256 indexed tokenId, address indexed pot, address indexed to, uint256 depositAmount);
    event CardRevealed(uint256 indexed tokenId, uint256 ownershipWeight, Rarity rarity);
    event CardClaimed(uint256 indexed tokenId);
    event CardBurnedEarlyExit(uint256 indexed tokenId, address indexed pot);

    modifier onlyMinter() {
        require(msg.sender == minter, "Card: minter");
        _;
    }

    modifier onlyRevealer() {
        require(msg.sender == revealer, "Card: revealer");
        _;
    }

    constructor(address owner_) ERC721("Sherhood Card", "SHRCARD") Ownable(owner_) {
        _setDefaultRoyalty(owner_, DEFAULT_ROYALTY_BPS);
    }

    function setRoyalty(address receiver, uint96 bps) external onlyOwner {
        require(receiver != address(0), "Card: zero");
        require(bps <= 1000, "Card: royalty");
        _setDefaultRoyalty(receiver, bps);
        emit RoyaltyUpdated(receiver, bps);
    }

    function setContractURI(string calldata uri) external onlyOwner {
        _contractURI = uri;
        emit ContractURIUpdated(uri);
    }

    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC2981) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address currentOwner = _ownerOf(tokenId);
        if (currentOwner != address(0) && to != address(0) && _isListed(tokenId)) {
            require(msg.sender == cardMarketplace, "Card: listed");
        }
        return super._update(to, tokenId, auth);
    }

    function setMinter(address minter_) external onlyOwner {
        minter = minter_;
        emit MinterUpdated(minter_);
    }

    function setRevealer(address revealer_) external onlyOwner {
        revealer = revealer_;
        emit RevealerUpdated(revealer_);
    }

    function setCardMarketplace(address marketplace_) external onlyOwner {
        cardMarketplace = marketplace_;
        emit CardMarketplaceUpdated(marketplace_);
    }

    function _isListed(uint256 tokenId) internal view returns (bool) {
        address market = cardMarketplace;
        return market != address(0) && IMarketplaceLock(market).isListedActive(tokenId);
    }

    function setBaseURI(string calldata baseURI_) external onlyOwner {
        _baseTokenURI = baseURI_;
    }

    function baseURI() external view returns (string memory) {
        return _baseTokenURI;
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        if (bytes(_baseTokenURI).length == 0) return "";
        return string(abi.encodePacked(_baseTokenURI, Strings.toString(tokenId)));
    }

    function mintUnrevealed(address to, address pot, uint256 depositAmount, bool luckLocked)
        external
        onlyMinter
        returns (uint256 tokenId)
    {
        require(to != address(0) && pot != address(0), "Card: zero");
        require(depositAmount > 0, "Card: amount");

        tokenId = _nextTokenId++;
        cards[tokenId] = CardData({
            pot: pot,
            depositAmount: depositAmount,
            ownershipWeight: 0,
            rarity: Rarity.Unrevealed,
            revealed: false,
            claimed: false,
            luckLocked: luckLocked
        });
        _potTokenIds[pot].push(tokenId);
        _safeMint(to, tokenId);

        emit CardMinted(tokenId, pot, to, depositAmount);
    }

    mapping(uint256 => bytes32) public identitySeed;
    event IdentitySeedCommitted(uint256 indexed tokenId, bytes32 seed);

    function commitIdentitySeed(uint256 tokenId, bytes32 seed) external onlyRevealer {
        require(_ownerOf(tokenId) != address(0) && !cards[tokenId].revealed, "Card: seed state");
        require(identitySeed[tokenId] == bytes32(0) && seed != bytes32(0), "Card: seed locked");
        identitySeed[tokenId] = seed;
        emit IdentitySeedCommitted(tokenId, seed);
    }

    function revealCard(uint256 tokenId, uint256 ownershipWeight, Rarity rarity) external onlyRevealer {
        CardData storage card = cards[tokenId];
        require(_ownerOf(tokenId) != address(0), "Card: none");
        require(!card.revealed, "Card: revealed");
        require(rarity != Rarity.Unrevealed, "Card: rarity");
        require(ownershipWeight > 0, "Card: weight");

        card.ownershipWeight = ownershipWeight;
        card.rarity = rarity;
        card.revealed = true;

        emit CardRevealed(tokenId, ownershipWeight, rarity);
    }

    function burnForClaim(uint256 tokenId) external {
        CardData storage card = cards[tokenId];
        require(msg.sender == card.pot, "Card: pot");
        require(_ownerOf(tokenId) != address(0), "Card: none");
        require(card.revealed && !card.claimed, "Card: state");
        require(!_isListed(tokenId), "Card: listed");

        address pot = card.pot;
        _removePotTokenId(pot, tokenId);
        delete cards[tokenId];
        totalBurned += 1;
        _burn(tokenId);

        emit CardClaimed(tokenId);
    }

    function burnForEarlyExit(uint256 tokenId) external {
        CardData storage card = cards[tokenId];
        require(msg.sender == card.pot, "Card: pot");
        require(_ownerOf(tokenId) != address(0), "Card: none");
        require(!card.revealed && !card.claimed, "Card: state");
        require(!_isListed(tokenId), "Card: listed");

        address pot = card.pot;
        _removePotTokenId(pot, tokenId);
        delete cards[tokenId];
        totalBurned += 1;
        _burn(tokenId);

        emit CardBurnedEarlyExit(tokenId, pot);
    }

    function _removePotTokenId(address pot, uint256 tokenId) private {
        uint256[] storage ids = _potTokenIds[pot];
        uint256 n = ids.length;
        for (uint256 i = 0; i < n; i++) {
            if (ids[i] == tokenId) {
                ids[i] = ids[n - 1];
                ids.pop();
                return;
            }
        }
        revert("Card: index");
    }

    function potTokenIds(address pot) external view returns (uint256[] memory) {
        return _potTokenIds[pot];
    }

    function totalMinted() external view returns (uint256) {
        return _nextTokenId - 1;
    }

    function totalSupply() external view returns (uint256) {
        return _nextTokenId - 1 - totalBurned;
    }

    function potTokenCount(address pot) external view returns (uint256) {
        return _potTokenIds[pot].length;
    }

    function getCard(uint256 tokenId) external view returns (CardData memory) {
        require(_ownerOf(tokenId) != address(0), "Card: none");
        return cards[tokenId];
    }

    function nextTokenId() external view returns (uint256) {
        return _nextTokenId;
    }
}
