// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidCollateralOracle {
    function collateralToAsset(address collateralToken, uint256 value) external view returns (uint256 amountInAsset);
}
