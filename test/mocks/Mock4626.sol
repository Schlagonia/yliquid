// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Mock4626 {
    struct StrategyParams {
        uint256 activation;
        uint256 last_report;
        uint256 current_debt;
        uint256 max_debt;
    }

    IERC20 public immutable underlying;

    mapping(address => uint256) public shareBalance;
    uint256 public totalShares;
    mapping(address => uint256) public strategyDebt;
    mapping(address => StrategyParams) internal _strategyParams;

    address public lastDebtStrategy;
    uint256 public lastDebtTarget;

    constructor(address asset_) {
        underlying = IERC20(asset_);
    }

    function balanceOf(address account) external view returns (uint256) {
        return shareBalance[account];
    }

    function asset() external view returns (address) {
        return address(underlying);
    }

    function update_debt(address strategy, uint256 targetDebt) external returns (uint256) {
        lastDebtStrategy = strategy;
        lastDebtTarget = targetDebt;

        uint256 currentDebt = strategyDebt[strategy];
        if (targetDebt > currentDebt) {
            uint256 deltaIncrease = targetDebt - currentDebt;
            // In tests, only msg.sender strategy receives real token movements.
            if (strategy == msg.sender) {
                underlying.transfer(strategy, deltaIncrease);
            }
        } else if (targetDebt < currentDebt) {
            uint256 deltaDecrease = currentDebt - targetDebt;
            // Real Yearn can pull debt without ERC20 allowance mechanics.
            // Local tests optionally emulate pull if allowance exists.
            if (strategy == msg.sender) {
                uint256 allowed = underlying.allowance(strategy, address(this));
                if (allowed >= deltaDecrease) {
                    underlying.transferFrom(strategy, address(this), deltaDecrease);
                }
            }
        }

        strategyDebt[strategy] = targetDebt;
        if (_strategyParams[strategy].activation == 0) {
            _strategyParams[strategy].activation = block.timestamp;
            _strategyParams[strategy].max_debt = type(uint256).max;
        }
        _strategyParams[strategy].last_report = block.timestamp;
        _strategyParams[strategy].current_debt = targetDebt;
        return targetDebt;
    }

    function strategies(address strategy) external view returns (StrategyParams memory) {
        return _strategyParams[strategy];
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets;
        underlying.transferFrom(msg.sender, address(this), assets);
        shareBalance[receiver] += shares;
        totalShares += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assetsOut) {
        require(owner == msg.sender, "owner only");
        shareBalance[owner] -= shares;
        totalShares -= shares;
        assetsOut = shares;
        underlying.transfer(receiver, assetsOut);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        require(owner == msg.sender, "owner only");
        shares = assets;
        shareBalance[owner] -= shares;
        totalShares -= shares;
        underlying.transfer(receiver, assets);
    }

    function convertToShares(uint256 assets) external pure returns (uint256) {
        return assets;
    }

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares;
    }

    function totalAssets() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function totalIdle() external view returns (uint256) {
        return underlying.balanceOf(address(this));
    }

    function maxRedeem(address) external pure returns (uint256) {
        return type(uint256).max;
    }
}
