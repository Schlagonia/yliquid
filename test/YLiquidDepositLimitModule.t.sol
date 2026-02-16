// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YLiquidDepositLimitModule} from "../src/YLiquidDepositLimitModule.sol";

contract MockVaultLimitCaller {
    uint256 public totalAssets;

    function setTotalAssets(uint256 totalAssets_) external {
        totalAssets = totalAssets_;
    }

    function callAvailableDepositLimit(YLiquidDepositLimitModule module, address receiver) external view returns (uint256) {
        return module.available_deposit_limit(receiver);
    }
}

contract YLiquidDepositLimitModuleTest is Test {
    address internal gov = address(0xABCD);
    address internal wrapper = address(0xCAFE);
    YLiquidDepositLimitModule internal module;
    MockVaultLimitCaller internal vaultCaller;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);

        module = new YLiquidDepositLimitModule(gov, wrapper, 1_000_000e6);
        vaultCaller = new MockVaultLimitCaller();

        vm.label(address(this), "YLiquidDepositLimitModuleTest");
        vm.label(gov, "Governance");
        vm.label(wrapper, "Wrapper");
        vm.label(address(module), "YLiquidDepositLimitModule");
        vm.label(address(vaultCaller), "MockVaultLimitCaller");
    }

    function test_OnlyWrapperReceivesDepositLimit() external {
        assertEq(vaultCaller.callAvailableDepositLimit(module, wrapper), 1_000_000e6);
        assertEq(vaultCaller.callAvailableDepositLimit(module, address(this)), 0);
    }

    function test_DepositLimitShrinksWithVaultAssets() external {
        vaultCaller.setTotalAssets(400_000e6);
        assertEq(vaultCaller.callAvailableDepositLimit(module, wrapper), 600_000e6);
    }

    function test_GovernanceCanRotateWrapper() external {
        address nextWrapper = address(0xBEEF);
        vm.label(nextWrapper, "NextWrapper");
        vm.prank(gov);
        module.setWrapper(nextWrapper);

        assertEq(vaultCaller.callAvailableDepositLimit(module, wrapper), 0);
        assertEq(vaultCaller.callAvailableDepositLimit(module, nextWrapper), 1_000_000e6);
    }
}
