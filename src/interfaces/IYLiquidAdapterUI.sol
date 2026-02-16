// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidMarketPositionReader {
    function positions(uint256 tokenId)
        external
        view
        returns (
            address owner,
            address asset,
            address adapter,
            uint128 principal,
            uint32 riskPremiumBps,
            uint64 startTime,
            uint64 expectedEndTime,
            uint8 state
        );
}

interface IYLiquidAdapterUI {
    enum PositionStatus {
        None,
        Open,
        Closed
    }

    enum CloseType {
        Settle,
        ForceClose
    }

    struct PositionView {
        address owner;
        address receiver;
        address proxy;
        address loanAsset;
        address collateralAsset;
        address settlementAsset;
        uint256 principal;
        uint256 collateralAmount;
        uint256 expectedSettlementAmount;
        uint64 expectedUnlockTime;
        uint256 referenceId;
        PositionStatus status;
    }

    event StandardizedPositionOpened(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed receiver,
        address loanAsset,
        address collateralAsset,
        address settlementAsset,
        uint256 principal,
        uint256 collateralAmount,
        uint256 expectedSettlementAmount,
        uint64 expectedUnlockTime,
        uint256 referenceId
    );

    event StandardizedPositionClosed(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed receiver,
        CloseType closeType,
        address settlementAsset,
        uint256 settlementAmount,
        uint256 repaidAmount,
        PositionStatus status
    );

    function positionView(uint256 tokenId) external view returns (PositionView memory);
}

