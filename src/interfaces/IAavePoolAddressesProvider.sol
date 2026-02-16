// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAavePoolAddressesProvider {
    function getPoolDataProvider() external view returns (address);
}
