// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC4626} from "./interfaces/IERC4626.sol";

contract YLiquidLPWrapper {
    using SafeERC20 for IERC20;

    struct WithdrawRequest {
        address owner;
        uint256 shares;
        uint256 unlockTimestamp;
        bool claimed;
    }

    IERC20 public immutable asset;
    IERC4626 public immutable yearnVault;
    uint256 public immutable cooldownSeconds;

    uint256 public nextRequestId;
    mapping(uint256 => WithdrawRequest) public requests;
    mapping(address => uint256) public balanceOf;
    uint256 public totalSupply;

    event Deposited(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event WithdrawRequested(uint256 indexed requestId, address indexed owner, uint256 shares, uint256 unlockTimestamp);
    event WithdrawClaimed(uint256 indexed requestId, address indexed owner, uint256 assets, uint256 shares);

    constructor(address asset_, address yearnVault_, uint256 cooldownSeconds_) {
        asset = IERC20(asset_);
        yearnVault = IERC4626(yearnVault_);
        cooldownSeconds = cooldownSeconds_;
        nextRequestId = 1;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        require(receiver != address(0), "bad receiver");
        asset.safeTransferFrom(msg.sender, address(this), assets);
        asset.forceApprove(address(yearnVault), assets);

        shares = yearnVault.deposit(assets, address(this));
        balanceOf[receiver] += shares;
        totalSupply += shares;

        emit Deposited(msg.sender, receiver, assets, shares);
    }

    function requestWithdraw(uint256 shares) external returns (uint256 requestId) {
        require(shares > 0, "zero shares");
        require(balanceOf[msg.sender] >= shares, "insufficient shares");

        balanceOf[msg.sender] -= shares;
        totalSupply -= shares;

        requestId = nextRequestId++;
        requests[requestId] = WithdrawRequest({
            owner: msg.sender,
            shares: shares,
            unlockTimestamp: block.timestamp + cooldownSeconds,
            claimed: false
        });

        emit WithdrawRequested(requestId, msg.sender, shares, block.timestamp + cooldownSeconds);
    }

    function claimWithdraw(uint256 requestId) external returns (uint256 assetsOut) {
        WithdrawRequest storage req = requests[requestId];
        require(req.owner == msg.sender, "not owner");
        require(!req.claimed, "already claimed");
        require(block.timestamp >= req.unlockTimestamp, "cooldown");

        req.claimed = true;
        assetsOut = yearnVault.redeem(req.shares, msg.sender, address(this));

        emit WithdrawClaimed(requestId, msg.sender, assetsOut, req.shares);
    }
}
