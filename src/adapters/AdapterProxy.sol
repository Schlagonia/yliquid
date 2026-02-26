// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IYLiquidActionAdapter} from "../interfaces/IYLiquidActionAdapter.sol";

contract AdapterProxy is IERC721Receiver {
    using Address for address;

    address public immutable ADAPTER;

    constructor(address adapter_) {
        ADAPTER = adapter_;
    }

    receive() external payable {}

    function execute(IYLiquidActionAdapter.ActionCall[] calldata calls) external returns (bytes[] memory results) {
        require(msg.sender == ADAPTER, "not adapter");

        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            results[i] = calls[i].target.functionCallWithValue(calls[i].data, calls[i].value);
        }
    }

    function transferETH(address payable to, uint256 amount) external {
        require(msg.sender == ADAPTER, "not adapter");
        (bool success,) = to.call{value: amount}("");
        require(success, "eth transfer failed");
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
