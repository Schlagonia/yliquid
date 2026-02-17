// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.24;

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IYLiquidManagedAdapter} from "../interfaces/IYLiquidManagedAdapter.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

contract AdapterProxy is IERC721Receiver {
    using Address for address;
    using SafeERC20 for IERC20;

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

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
