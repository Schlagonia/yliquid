// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IwstETH is IERC20 {
    function wrap(uint256 stEthAmount) external returns (uint256);
    function unwrap(uint256 wstEthAmount) external returns (uint256);
    function getWstETHByStETH(uint256 stEthAmount) external view returns (uint256);
    function getStETHByWstETH(uint256 wstEthAmount) external view returns (uint256);
}
