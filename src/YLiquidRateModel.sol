// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IYLiquidRateModel} from "./interfaces/IYLiquidRateModel.sol";

contract YLiquidRateModel is IYLiquidRateModel {
    uint256 public immutable baseRateBps;
    uint256 public immutable overdueGraceSeconds;
    uint256 public immutable overdueStepBps;

    constructor(
        uint256 baseRateBps_,
        uint256 overdueGraceSeconds_,
        uint256 overdueStepBps_
    ) {
        require(overdueGraceSeconds_ > 0, "zero overdue grace");
        baseRateBps = baseRateBps_;
        overdueGraceSeconds = overdueGraceSeconds_;
        overdueStepBps = overdueStepBps_;
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
