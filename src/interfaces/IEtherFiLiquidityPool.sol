// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEtherFiLiquidityPool {
    function requestWithdraw(address recipient, uint256 amount) external returns (uint256 requestId);
}
