// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IEtherFiWithdrawRequestNFT {
    function claimWithdraw(uint256 tokenId) external;
}
