// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {YLiquidMarket} from "../src/YLiquidMarket.sol";
import {YLiquidRateModel} from "../src/YLiquidRateModel.sol";
import {GenericCollateralAdapter} from "../src/adapters/GenericCollateralAdapter.sol";
import {Mock4626} from "./mocks/Mock4626.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYLiquidCollateralOracle} from "./mocks/MockYLiquidCollateralOracle.sol";
import {MockGenericAdapterReceiver} from "./mocks/MockGenericAdapterReceiver.sol";

contract YLiquidMarketGenericAdapterTest is Test {
    address internal constant OWNER = address(0xA11CE);
    address internal constant IDLE_STRATEGY = address(0x1D13);

    uint256 internal constant VAULT_SEED = 500 ether;
    uint256 internal constant PRINCIPAL = 5 ether;
    uint256 internal constant COLLATERAL = 10 ether;

    MockERC20 internal loanAsset;
    MockERC20 internal collateralAsset;
    Mock4626 internal vault;
    YLiquidRateModel internal rateModel;
    YLiquidMarket internal market;
    MockYLiquidCollateralOracle internal oracle;
    GenericCollateralAdapter internal adapter;
    MockGenericAdapterReceiver internal receiver;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);

        loanAsset = new MockERC20("Loan", "LOAN", 18);
        collateralAsset = new MockERC20("Collateral", "COLL", 18);
        vault = new Mock4626(address(loanAsset));
        rateModel = new YLiquidRateModel(0, 1 days, 0);
        market = new YLiquidMarket(address(loanAsset), address(vault), address(rateModel), "yLiquid Position", "yLPOS");
        oracle = new MockYLiquidCollateralOracle();
        oracle.setRate(address(collateralAsset), 2e18);
        adapter = new GenericCollateralAdapter(address(market), address(loanAsset));
        receiver = new MockGenericAdapterReceiver(address(adapter), address(loanAsset), address(collateralAsset));

        adapter.setMaxDurationSeconds(1 days);
        adapter.setCollateralConfig(address(collateralAsset), true, address(oracle), 5e17);

        loanAsset.mint(address(this), VAULT_SEED);
        loanAsset.approve(address(vault), VAULT_SEED);
        vault.deposit(VAULT_SEED, address(this));

        vault.update_debt(IDLE_STRATEGY, 0);
        market.setIdleStrategy(IDLE_STRATEGY);
        market.setAdapterAllowed(address(adapter), true);
        market.setAdapterRiskPremium(address(adapter), 0);

        vm.label(address(market), "YLiquidMarket");
        vm.label(address(adapter), "GenericCollateralAdapter");
        vm.label(address(receiver), "MockGenericAdapterReceiver");
    }

    function test_SettleAndRepayClosesAndSweepsCollateralToOwner() external {
        uint256 tokenId = _openPosition();

        uint256 ownerCollateralBefore = collateralAsset.balanceOf(OWNER);
        vm.prank(OWNER);
        market.settleAndRepay(tokenId, address(receiver), bytes(""));

        (,,,, GenericCollateralAdapter.Status status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(GenericCollateralAdapter.Status.Closed), "adapter not closed");
        assertEq(collateralAsset.balanceOf(OWNER), ownerCollateralBefore + COLLATERAL, "owner collateral not swept");
        assertEq(market.totalPrincipalActive(), 0, "principal not cleared");
    }

    function test_ForceCloseSupportsPartialRecoveryAndSweepsCollateral() external {
        uint256 tokenId = _openPosition();

        receiver.drainLoan(address(0xD00D), 4 ether);
        vm.warp(block.timestamp + 2 days);

        uint256 ownerCollateralBefore = collateralAsset.balanceOf(OWNER);
        market.forceClose(tokenId, address(receiver), bytes(""));

        (,,,,,, YLiquidMarket.PositionState state) = market.positions(tokenId);
        assertEq(uint8(state), uint8(YLiquidMarket.PositionState.Defaulted), "position not defaulted");
        assertEq(collateralAsset.balanceOf(OWNER), ownerCollateralBefore + COLLATERAL, "owner collateral not swept");
    }

    function test_OpenAndSettleWithZeroReceiver() external {
        collateralAsset.mint(OWNER, COLLATERAL);
        vm.prank(OWNER);
        collateralAsset.approve(address(adapter), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        uint256 tokenId;
        vm.prank(OWNER);
        tokenId = market.openPosition(
            PRINCIPAL,
            address(adapter),
            address(0),
            address(collateralAsset),
            COLLATERAL,
            callbackData
        );

        assertEq(loanAsset.balanceOf(OWNER), PRINCIPAL, "owner did not receive principal");
        assertEq(loanAsset.balanceOf(address(receiver)), 0, "receiver should be unused");

        vm.prank(OWNER);
        loanAsset.approve(address(adapter), type(uint256).max);

        vm.prank(OWNER);
        market.settleAndRepay(tokenId, address(0), bytes(""));

        (,,,, GenericCollateralAdapter.Status status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(GenericCollateralAdapter.Status.Closed), "adapter not closed");
    }

    function test_OpenRevertsWithZeroReceiverAndCalldata() external {
        collateralAsset.mint(OWNER, COLLATERAL);
        vm.prank(OWNER);
        collateralAsset.approve(address(adapter), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("x")})
        );

        vm.expectRevert("open zero receiver data");
        vm.prank(OWNER);
        market.openPosition(
            PRINCIPAL,
            address(adapter),
            address(0),
            address(collateralAsset),
            COLLATERAL,
            callbackData
        );
    }

    function _openPosition() internal returns (uint256 tokenId) {
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.prank(OWNER);
        tokenId = market.openPosition(
            PRINCIPAL,
            address(adapter),
            address(receiver),
            address(collateralAsset),
            COLLATERAL,
            callbackData
        );
    }
}
