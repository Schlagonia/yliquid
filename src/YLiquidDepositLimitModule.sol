// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract YLiquidDepositLimitModule {
    address public governance;
    address public wrapper;
    uint256 public wrapperDepositLimit;

    event GovernanceUpdated(address indexed governance);
    event WrapperUpdated(address indexed wrapper);
    event WrapperDepositLimitUpdated(uint256 limit);

    modifier onlyGovernance() {
        require(msg.sender == governance, "not governance");
        _;
    }

    constructor(address governance_, address wrapper_, uint256 wrapperDepositLimit_) {
        require(governance_ != address(0), "zero governance");
        governance = governance_;
        wrapper = wrapper_;
        wrapperDepositLimit = wrapperDepositLimit_;
    }

    function setGovernance(address governance_) external onlyGovernance {
        require(governance_ != address(0), "zero governance");
        governance = governance_;
        emit GovernanceUpdated(governance_);
    }

    function setWrapper(address wrapper_) external onlyGovernance {
        wrapper = wrapper_;
        emit WrapperUpdated(wrapper_);
    }

    function setWrapperDepositLimit(uint256 wrapperDepositLimit_) external onlyGovernance {
        wrapperDepositLimit = wrapperDepositLimit_;
        emit WrapperDepositLimitUpdated(wrapperDepositLimit_);
    }

    function available_deposit_limit(address receiver) external view returns (uint256) {
        if (receiver != wrapper) return 0;
        if (wrapperDepositLimit == type(uint256).max) {
            return type(uint256).max;
        }

        (bool ok, bytes memory data) = msg.sender.staticcall(abi.encodeWithSignature("totalAssets()"));
        if (!ok || data.length < 32) {
            return wrapperDepositLimit;
        }

        uint256 totalAssets = abi.decode(data, (uint256));
        if (totalAssets >= wrapperDepositLimit) {
            return 0;
        }

        return wrapperDepositLimit - totalAssets;
    }
}
