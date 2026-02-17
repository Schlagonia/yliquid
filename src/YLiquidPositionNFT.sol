// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract YLiquidPositionNFT {
    string public name;
    string public symbol;
    address public immutable MARKET;

    uint256 internal _nextTokenId;

    mapping(uint256 => address) private _ownerOf;
    mapping(address => uint256) private _balanceOf;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    modifier onlyMarket() {
        require(msg.sender == MARKET, "not market");
        _;
    }

    constructor(string memory name_, string memory symbol_, address market_) {
        name = name_;
        symbol = symbol_;
        MARKET = market_;
        _nextTokenId = 1;
    }

    function mint(address to) external onlyMarket returns (uint256 tokenId) {
        require(to != address(0), "invalid receiver");

        tokenId = _nextTokenId++;
        _ownerOf[tokenId] = to;
        _balanceOf[to] += 1;

        emit Transfer(address(0), to, tokenId);
    }

    function burn(uint256 tokenId) external onlyMarket {
        address owner = _ownerOf[tokenId];
        require(owner != address(0), "token does not exist");

        delete _ownerOf[tokenId];
        delete _tokenApprovals[tokenId];
        _balanceOf[owner] -= 1;

        emit Transfer(owner, address(0), tokenId);
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address owner = _ownerOf[tokenId];
        require(owner != address(0), "token does not exist");
        return owner;
    }

    function balanceOf(address owner) external view returns (uint256) {
        require(owner != address(0), "invalid receiver");
        return _balanceOf[owner];
    }

    function getApproved(uint256 tokenId) external view returns (address) {
        require(_ownerOf[tokenId] != address(0), "token does not exist");
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address to, uint256 tokenId) external {
        address owner = ownerOf(tokenId);
        require(msg.sender == owner || _operatorApprovals[owner][msg.sender], "not authorized");

        _tokenApprovals[tokenId] = to;
        emit Approval(owner, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(to != address(0), "invalid receiver");

        address owner = ownerOf(tokenId);
        require(owner == from, "not authorized");

        bool isApproved = msg.sender == owner || _tokenApprovals[tokenId] == msg.sender
            || _operatorApprovals[owner][msg.sender];
        require(isApproved, "not authorized");

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
