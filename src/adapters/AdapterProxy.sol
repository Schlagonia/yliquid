// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";

contract AdapterProxy {
    using Address for address;

    struct Call {
        address target;
        uint256 value;
        bytes data;
    }

    address public immutable ADAPTER;

    constructor(address adapter_) {
        ADAPTER = adapter_;
    }

    receive() external payable {}
    
    function execute(Call[] calldata calls) external returns (bytes[] memory results) {
        require(msg.sender == ADAPTER, "not adapter");

        results = new bytes[](calls.length);
        for (uint256 i = 0; i < calls.length; i++) {
            results[i] = calls[i].target.functionCallWithValue(calls[i].data, calls[i].value);
        }
    }
}