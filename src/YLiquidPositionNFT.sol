// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract YLiquidPositionNFT {
    string public name;
    string public symbol;
    address public immutable market;

    uint256 internal _nextTokenId;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    error NotMarket();
    error InvalidReceiver();
    error NotAuthorized();
    error TokenDoesNotExist();

    modifier onlyMarket() {
        if (msg.sender != market) revert NotMarket();
        _;
    }

    constructor(string memory name_, string memory symbol_, address market_) {
        name = name_;
        symbol = symbol_;
        market = market_;
        _nextTokenId = 1;
    }

    function mint(address to) external onlyMarket returns (uint256 tokenId) {
        if (to == address(0)) revert InvalidReceiver();

        tokenId = _nextTokenId++;
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;

        emit Transfer(address(0), to, tokenId);
    }

    function burn(uint256 tokenId) external onlyMarket {
        address owner = _ownerOf[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();

        delete _ownerOf[tokenId];
        delete _tokenApprovals[tokenId];
        _balanceOf[owner] -= 1;

        emit Transfer(owner, address(0), tokenId);
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _ownerOf[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist();
        return owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert InvalidReceiver();
        return _balanceOf[owner];
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        if (_ownerOf[tokenId] == address(0)) revert TokenDoesNotExist();
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        if (msg.sender != owner && !_operatorApprovals[owner][msg.sender]) revert NotAuthorized();

        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        if (to == address(0)) revert InvalidReceiver();

        address owner = ownerOf(tokenId);
        if (owner != from) revert NotAuthorized();

        bool isApproved = msg.sender == owner || _tokenApprovals[tokenId] == msg.sender
            || _operatorApprovals[owner][msg.sender];
        if (!isApproved) revert NotAuthorized();

        delete _tokenApprovals[tokenId];
        _ownerOf[tokenId] = to;
        _balanceOf[from] -= 1;
        _balanceOf[to] += 1;

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        transferFrom(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata) external {
        transferFrom(from, to, tokenId);
    }
}
