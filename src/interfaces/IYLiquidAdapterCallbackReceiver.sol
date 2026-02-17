// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidAdapterCallbackReceiver {
    function onYLiquidAdapterCallback(
        uint8 phase,
        address owner,
        address token,
        uint256 amount,
        uint256 collateralAmount,
        bytes calldata data
    )
        external;
}
