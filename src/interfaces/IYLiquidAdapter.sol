// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidAdapter {
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
}
