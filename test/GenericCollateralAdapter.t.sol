// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockYLiquidCollateralOracle} from "./mocks/MockYLiquidCollateralOracle.sol";
import {MockGenericAdapterReceiver} from "./mocks/MockGenericAdapterReceiver.sol";
import {GenericCollateralAdapter} from "../src/adapters/GenericCollateralAdapter.sol";
import {IYLiquidAdapter} from "../src/interfaces/IYLiquidAdapter.sol";

contract MockAdapterMarket {
    struct PositionMeta {
        address owner;
        uint64 expectedEndTime;
    }

    address public immutable asset;
    address public immutable management;
    mapping(uint256 => PositionMeta) public meta;

    constructor(address asset_) {
        asset = asset_;
        management = msg.sender;
    }

    function setPositionMeta(uint256 tokenId, address owner, uint64 expectedEndTime) external {
        meta[tokenId] = PositionMeta({owner: owner, expectedEndTime: expectedEndTime});
    }

    function positionOwner(uint256 tokenId) external view returns (address) {
        return meta[tokenId].owner;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            address asset_,
            address adapter,
            uint128 principal,
            uint32 riskPremiumBps,
            uint64 startTime,
            uint64 expectedEndTime,
            uint8 state
        )
    {
        asset_ = asset;
        adapter = address(0);
        principal = 0;
        riskPremiumBps = 0;
        startTime = 0;
        expectedEndTime = meta[tokenId].expectedEndTime;
        state = 0;
    }

    function callExecuteOpen(
        GenericCollateralAdapter adapter,
        uint256 tokenId,
        address owner,
        uint256 amount,
        address collateralToken,
        uint256 collateralAmount,
        address receiver,
        bytes calldata callbackData
    )
        external
        returns (uint64)
    {
        return adapter.executeOpen(tokenId, owner, amount, collateralToken, collateralAmount, receiver, callbackData);
    }

}

contract GenericCollateralAdapterTest is Test {
    address internal constant OWNER = address(0xA11CE);

    uint256 internal constant PRINCIPAL = 5 ether;
    uint256 internal constant COLLATERAL = 10 ether;

    MockERC20 internal loanAsset;
    MockERC20 internal collateralAsset;
    MockYLiquidCollateralOracle internal oracle;
    MockAdapterMarket internal market;
    GenericCollateralAdapter internal adapter;
    MockGenericAdapterReceiver internal receiver;

    function setUp() external {
        loanAsset = new MockERC20("Loan", "LOAN", 18);
        collateralAsset = new MockERC20("Collateral", "COLL", 18);
        oracle = new MockYLiquidCollateralOracle();
        oracle.setRate(address(collateralAsset), 2e18);

        market = new MockAdapterMarket(address(loanAsset));
        adapter = new GenericCollateralAdapter(address(market), address(loanAsset));
        receiver = new MockGenericAdapterReceiver(address(adapter), address(loanAsset), address(collateralAsset));

        adapter.setCollateralConfig(address(collateralAsset), true, address(oracle), 5e17);
    }

    function test_OpenRevertsForDisabledCollateral() external {
        adapter.setCollateralConfig(address(collateralAsset), false, address(0), 0);

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.expectRevert("collateral blocked");
        market.callExecuteOpen(
            adapter,
            1,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(receiver),
            callbackData
        );
    }

    function test_OpenRevertsWhenOracleCallFails() external {
        oracle.setShouldRevert(true);

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.expectRevert("oracle failure");
        market.callExecuteOpen(
            adapter,
            1,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(receiver),
            callbackData
        );
    }

    function test_OpenRevertsWhenOracleQuoteIsZero() external {
        oracle.setRate(address(collateralAsset), 0);

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.expectRevert("insolvent position");
        market.callExecuteOpen(
            adapter,
            1,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(receiver),
            callbackData
        );
    }

    function test_OpenRevertsWhenLtvUnhealthy() external {
        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), 4 ether);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.expectRevert("insolvent position");
        market.callExecuteOpen(
            adapter,
            1,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            4 ether,
            address(receiver),
            callbackData
        );
    }

    function test_ConfigUpdatesAffectOpenChecksImmediately() external {
        adapter.setCollateralConfig(address(collateralAsset), true, address(oracle), 2e17);

        uint256 tokenId = 1;
        market.setPositionMeta(tokenId, OWNER, uint64(block.timestamp + 7 days));

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        vm.expectRevert("insolvent position");
        market.callExecuteOpen(
            adapter,
            tokenId,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(receiver),
            callbackData
        );
    }

    function test_PositionViewReflectsProxyCollateralBalance() external {
        uint256 tokenId = _openDefaultPosition();
        market.setPositionMeta(tokenId, OWNER, uint64(block.timestamp + 3 days));

        IYLiquidAdapter.PositionView memory viewData = adapter.positionView(tokenId);
        assertEq(viewData.owner, OWNER, "owner mismatch");
        assertEq(viewData.loanAsset, address(loanAsset), "loan asset mismatch");
        assertEq(viewData.collateralAsset, address(collateralAsset), "collateral asset mismatch");
        assertEq(viewData.collateralAmount, COLLATERAL, "collateral mismatch");
        assertEq(viewData.referenceId, 0, "reference id mismatch");
        assertEq(uint8(viewData.status), uint8(IYLiquidAdapter.PositionStatus.Open), "status mismatch");
    }

    function test_OpenAllowsZeroReceiverWhenCallbackNotNeeded() external {
        uint256 tokenId = 1;
        market.setPositionMeta(tokenId, OWNER, uint64(block.timestamp + 7 days));

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(OWNER, COLLATERAL);
        vm.prank(OWNER);
        collateralAsset.approve(address(adapter), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        market.callExecuteOpen(
            adapter,
            tokenId,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(0),
            callbackData
        );

        assertEq(loanAsset.balanceOf(OWNER), PRINCIPAL, "owner did not receive principal");
        assertEq(loanAsset.balanceOf(address(receiver)), 0, "receiver should be unused");
    }

    function test_OpenRevertsWithZeroReceiverAndCalldata() external {
        uint256 tokenId = 1;
        market.setPositionMeta(tokenId, OWNER, uint64(block.timestamp + 7 days));

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(OWNER, COLLATERAL);
        vm.prank(OWNER);
        collateralAsset.approve(address(adapter), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("x")})
        );

        vm.expectRevert("open zero receiver data");
        market.callExecuteOpen(
            adapter,
            tokenId,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(0),
            callbackData
        );
    }

    function _openDefaultPosition() internal returns (uint256 tokenId) {
        tokenId = 1;
        market.setPositionMeta(tokenId, OWNER, uint64(block.timestamp + 7 days));

        loanAsset.mint(address(adapter), PRINCIPAL);
        collateralAsset.mint(address(receiver), COLLATERAL);

        bytes memory callbackData = abi.encode(
            GenericCollateralAdapter.OpenCallbackData({receiverData: bytes("")})
        );

        market.callExecuteOpen(
            adapter,
            tokenId,
            OWNER,
            PRINCIPAL,
            address(collateralAsset),
            COLLATERAL,
            address(receiver),
            callbackData
        );
    }
}
