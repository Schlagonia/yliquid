// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IYLiquidRateModel} from "./interfaces/IYLiquidRateModel.sol";

contract YLiquidRateModel is IYLiquidRateModel {
    address public governance;
    uint256 public baseRateBps;
    uint256 public overdueGraceSeconds;
    uint256 public overdueStepBps;

    event GovernanceUpdated(address indexed governance);
    event BaseRateBpsUpdated(uint256 baseRateBps);
    event OverdueGraceSecondsUpdated(uint256 overdueGraceSeconds);
    event OverdueStepBpsUpdated(uint256 overdueStepBps);

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(
        uint256 baseRateBps_,
        uint256 overdueGraceSeconds_,
        uint256 overdueStepBps_
    ) {
        require(overdueGraceSeconds_ > 0, "zero overdue grace");
        governance = msg.sender;
        baseRateBps = baseRateBps_;
        overdueGraceSeconds = overdueGraceSeconds_;
        overdueStepBps = overdueStepBps_;
    }

    function setGovernance(address governance_) external onlyGovernance {
        require(governance_ != address(0), "zero governance");
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    function setBaseRateBps(uint256 baseRateBps_) external onlyGovernance {
        baseRateBps = baseRateBps_;
        emit BaseRateBpsUpdated(baseRateBps_);
    }

    function setOverdueGraceSeconds(uint256 overdueGraceSeconds_) external onlyGovernance {
        require(overdueGraceSeconds_ > 0, "zero overdue grace");
        overdueGraceSeconds = overdueGraceSeconds_;
        emit OverdueGraceSecondsUpdated(overdueGraceSeconds_);
    }

    function setOverdueStepBps(uint256 overdueStepBps_) external onlyGovernance {
        overdueStepBps = overdueStepBps_;
        emit OverdueStepBpsUpdated(overdueStepBps_);
    }

    function borrowRateBps(uint256 riskPremiumBps, uint256 elapsedSeconds, uint256 expectedSeconds)
        external
        view
        returns (uint256)
    {
        uint256 overduePremium = _overduePremium(elapsedSeconds, expectedSeconds);
        return baseRateBps + riskPremiumBps + overduePremium;
    }

    function _overduePremium(uint256 elapsedSeconds, uint256 expectedSeconds) internal view returns (uint256) {
        if (elapsedSeconds <= expectedSeconds) return 0;

        uint256 overdueSeconds = elapsedSeconds - expectedSeconds;
        if (overdueSeconds <= overdueGraceSeconds) {
            return overdueStepBps;
        }

        // Piecewise exponential approximation: double penalty every grace window after initial grace.
        uint256 windows = (overdueSeconds - overdueGraceSeconds) / overdueGraceSeconds;
        uint256 multiplier = uint256(1) << windows;
        return overdueStepBps * multiplier;
    }
}
