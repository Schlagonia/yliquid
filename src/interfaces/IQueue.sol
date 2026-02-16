// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IQueue {
    function claimWithdrawal(uint256 requestId) external;

    function requestWithdrawals(uint256[] calldata amounts, address owner) external returns (uint256[] memory requestIds);

    function safeTransferFrom(address from, address to, uint256 requestId) external;

    function getWithdrawalRequests(address owner) external view returns (uint256[] memory);

    function MAX_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);

    function MIN_STETH_WITHDRAWAL_AMOUNT() external view returns (uint256);
}
