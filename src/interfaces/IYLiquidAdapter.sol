// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidMarketPositionReader {
    function positionOwner(uint256 tokenId) external view returns (address owner);

    function positions(uint256 tokenId)
        external
        view
        returns (
            address asset,
            address adapter,
            uint128 principal,
            uint32 riskPremiumBps,
            uint64 startTime,
            uint64 expectedEndTime,
            uint8 state
        );
}

interface IYLiquidAdapter {
    enum PositionStatus {
        None,
        Open,
        Closed
    }

    struct PositionView {
        address owner;
        address proxy;
        address loanAsset;
        address collateralAsset;
        uint256 principal;
        uint256 collateralAmount;
        uint64 expectedUnlockTime;
        uint256 referenceId;
        PositionStatus status;
    }

    event PositionOpened(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed receiver,
        address asset,
        uint256 amount,
        address collateralAsset,
        uint256 collateralAmount
    );

    event PositionClosed(
        uint256 indexed tokenId,
        address indexed owner,
        address indexed receiver,
        address asset,
        uint256 amount,
        address collateralAsset,
        uint256 collateralAmount
    );

    function executeOpen(
        uint256 tokenId,
        address owner,
        address asset,
        uint256 amount,
        address receiver,
        uint256 collateralAmount,
        bytes calldata callbackData
    )
        external
        returns (uint64 expectedDurationSeconds);

    function executeSettle(
        uint256 tokenId,
        address owner,
        address asset,
        uint256 amountOwed,
        address receiver,
        bytes calldata callbackData
    )
        external
        returns (uint256 amountRepaid);

    function executeForceClose(
        uint256 tokenId,
        address owner,
        address asset,
        uint256 amountOwed,
        address receiver,
        bytes calldata callbackData
    )
        external
        returns (uint256 amountRecovered);

    function positionView(uint256 tokenId) external view returns (PositionView memory);
}
