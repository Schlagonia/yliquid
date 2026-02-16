// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidRateModel {
    function borrowRateBps(uint256 riskPremiumBps, uint256 elapsedSeconds, uint256 expectedSeconds)
        external
        view
        returns (uint256);
}
