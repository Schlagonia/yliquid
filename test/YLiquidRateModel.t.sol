// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YLiquidRateModel} from "../src/YLiquidRateModel.sol";

contract YLiquidRateModelTest is Test {
    YLiquidRateModel internal rateModel;
    address internal outsider = address(0xBEEF);

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);

        rateModel = new YLiquidRateModel(
            200, // base
            50, // overdue grace seconds
            25 // overdue step
        );

        vm.label(address(rateModel), "YLiquidRateModel");
        vm.label(address(this), "YLiquidRateModelTest");
    }

    function test_RateIncludesBaseAndPremiumWhenOnTime() external view {
        uint256 rate = rateModel.borrowRateBps(50, 10, 1_000);
        assertEq(rate, 250);
    }

    function test_RateAddsOverduePenalty() external view {
        uint256 onTime = rateModel.borrowRateBps(50, 100, 100);
        uint256 overdue = rateModel.borrowRateBps(50, 180, 100);
        assertGt(overdue, onTime);
    }

    function test_GovernanceCanSetAllValues() external {
        rateModel.setBaseRateBps(300);
        rateModel.setOverdueGraceSeconds(100);
        rateModel.setOverdueStepBps(40);

        assertEq(rateModel.baseRateBps(), 300);
        assertEq(rateModel.overdueGraceSeconds(), 100);
        assertEq(rateModel.overdueStepBps(), 40);
    }

    function test_OnlyGovernanceCanSetValues() external {
        vm.prank(outsider);
        vm.expectRevert(bytes("not governance"));
        rateModel.setBaseRateBps(1);

        vm.prank(outsider);
        vm.expectRevert(bytes("not governance"));
        rateModel.setOverdueGraceSeconds(1);

        vm.prank(outsider);
        vm.expectRevert(bytes("not governance"));
        rateModel.setOverdueStepBps(1);
    }

    function test_SetOverdueGraceSecondsRejectsZero() external {
        vm.expectRevert(bytes("zero overdue grace"));
        rateModel.setOverdueGraceSeconds(0);
    }

    function test_GovernanceCanRotate() external {
        rateModel.setGovernance(outsider);
        assertEq(rateModel.governance(), outsider);

        vm.prank(outsider);
        rateModel.setBaseRateBps(321);
        assertEq(rateModel.baseRateBps(), 321);
    }
}
