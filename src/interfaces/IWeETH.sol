// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IWeETH is IERC20 {
    function wrap(uint256 eEthAmount) external returns (uint256);
    function unwrap(uint256 weEthAmount) external returns (uint256);
    function getWeETHByeETH(uint256 eEthAmount) external view returns (uint256);
    function getEETHByWeETH(uint256 weEthAmount) external view returns (uint256);
}
