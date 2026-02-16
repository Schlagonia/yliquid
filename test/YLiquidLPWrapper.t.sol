// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YLiquidLPWrapper} from "../src/YLiquidLPWrapper.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {Mock4626} from "./mocks/Mock4626.sol";

contract YLiquidLPWrapperTest is Test {
    MockERC20 internal asset;
    Mock4626 internal vault;
    YLiquidLPWrapper internal wrapper;

    address internal lp = address(0xBEEF);

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);

        asset = new MockERC20("Mock USDC", "mUSDC", 6);
        vault = new Mock4626(address(asset));
        wrapper = new YLiquidLPWrapper(address(asset), address(vault), 20);

        vm.label(address(this), "YLiquidLPWrapperTest");
        vm.label(lp, "LP");
        vm.label(address(asset), "MockUSDC");
        vm.label(address(vault), "Mock4626");
        vm.label(address(wrapper), "YLiquidLPWrapper");

        asset.mint(lp, 1_000_000);
    }

    function test_DepositAndCooldownWithdraw() external {
        vm.startPrank(lp);
        asset.approve(address(wrapper), type(uint256).max);

        uint256 shares = wrapper.deposit(100_000, lp);
        assertEq(shares, 100_000);
        assertEq(wrapper.balanceOf(lp), 100_000);

        uint256 requestId = wrapper.requestWithdraw(40_000);

        vm.expectRevert(bytes("cooldown"));
        wrapper.claimWithdraw(requestId);

        vm.warp(block.timestamp + 21);
        uint256 assetsOut = wrapper.claimWithdraw(requestId);

        assertEq(assetsOut, 40_000);
        assertEq(asset.balanceOf(lp), 940_000);
        vm.stopPrank();
    }
}
