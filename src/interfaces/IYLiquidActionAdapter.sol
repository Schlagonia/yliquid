// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IYLiquidActionAdapter {
    struct ActionCall {
        address target;
        uint256 value;
        bytes data;
    }
}
