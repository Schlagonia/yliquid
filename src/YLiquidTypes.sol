// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

library YLiquidTypes {
    enum PositionState {
        Requested,
        Active,
        ReadyToSettle,
        Closed,
        Defaulted
    }

    struct MarketConfig {
        address asset;
        address yearnVault;
        address idleStrategy4626;
        uint64 cooldownSeconds;
        uint64 maxExpectedSeconds;
        uint64 graceSeconds;
        uint64 maxOverdueSeconds;
        uint32 kinkUtilBps;
        uint32 maxUtilRateBps;
    }

    struct Position {
        address owner;
        address asset;
        address adapter;
        uint128 principal;
        uint32 riskPremiumBps;
        uint64 startTime;
        uint64 expectedEndTime;
        PositionState state;
    }
}
