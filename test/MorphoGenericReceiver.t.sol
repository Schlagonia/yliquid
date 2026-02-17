// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {IMorpho} from "../src/interfaces/IMorpho.sol";
import {MorphoGenericReceiver} from "../src/receivers/MorphoGenericReceiver.sol";

contract MockMorpho is IMorpho {
    using SafeERC20 for IERC20;

    mapping(address => mapping(address => bool)) public override isAuthorized;
    mapping(bytes32 => MarketParams) internal _marketParamsById;
    mapping(bytes32 => mapping(address => Position)) internal _positions;

    address internal _lastRepayOnBehalf;
    uint256 internal _lastRepayAssets;
    address internal _lastWithdrawOnBehalf;
    uint256 internal _lastWithdrawAssets;
    address internal _lastWithdrawReceiver;
    address internal _lastLoanToken;
    address internal _lastCollateralToken;

    function setAuthorization(address authorized, bool authorizedState) external {
        isAuthorized[msg.sender][authorized] = authorizedState;
    }

    function idToMarketParams(bytes32 id) external view returns (MarketParams memory marketParams) {
        return _marketParamsById[id];
    }

    function position(bytes32 id, address user) external view returns (Position memory) {
        return _positions[id][user];
    }

    function supplyCollateral(MarketParams memory, uint256 assets, address onBehalf, bytes memory) external {
        _positions[bytes32(0)][onBehalf].collateral += uint128(assets);
    }

    function borrow(MarketParams memory, uint256 assets, uint256, address onBehalf, address)
        external
        returns (uint256 assetsBorrowed, uint256 sharesBorrowed)
    {
        _positions[bytes32(0)][onBehalf].borrowShares += uint128(assets);
        assetsBorrowed = assets;
        sharesBorrowed = assets;
    }

    function repay(MarketParams memory marketParams, uint256 assets, uint256, address onBehalf, bytes memory)
        external
        returns (uint256 assetsRepaid, uint256 sharesRepaid)
    {
        IERC20(marketParams.loanToken).safeTransferFrom(msg.sender, address(this), assets);

        _lastLoanToken = marketParams.loanToken;
        _lastRepayOnBehalf = onBehalf;
        _lastRepayAssets = assets;

        assetsRepaid = assets;
        sharesRepaid = assets;
    }

    function withdrawCollateral(MarketParams memory marketParams, uint256 assets, address onBehalf, address receiver)
        external
    {
        require(msg.sender == onBehalf || isAuthorized[onBehalf][msg.sender], "not authorized");

        IERC20(marketParams.collateralToken).safeTransfer(receiver, assets);

        _lastCollateralToken = marketParams.collateralToken;
        _lastWithdrawOnBehalf = onBehalf;
        _lastWithdrawAssets = assets;
        _lastWithdrawReceiver = receiver;
    }

    function lastRepayOnBehalf() external view returns (address) {
        return _lastRepayOnBehalf;
    }

    function lastRepayAssets() external view returns (uint256) {
        return _lastRepayAssets;
    }

    function lastWithdrawOnBehalf() external view returns (address) {
        return _lastWithdrawOnBehalf;
    }

    function lastWithdrawAssets() external view returns (uint256) {
        return _lastWithdrawAssets;
    }

    function lastWithdrawReceiver() external view returns (address) {
        return _lastWithdrawReceiver;
    }

    function lastLoanToken() external view returns (address) {
        return _lastLoanToken;
    }

    function lastCollateralToken() external view returns (address) {
        return _lastCollateralToken;
    }
}

contract MorphoGenericReceiverTest is Test {
    uint8 internal constant PHASE_OPEN = 1;

    uint256 internal constant REPAY_AMOUNT = 5 ether;
    uint256 internal constant COLLATERAL_AMOUNT = 7 ether;

    address internal constant OWNER = address(0xB0B);
    address internal constant ADAPTER = address(0xA11CE);

    MockERC20 internal loanAsset;
    MockERC20 internal collateralAsset;
    MockMorpho internal morpho;
    MorphoGenericReceiver internal receiver;
    IMorpho.MarketParams internal marketParams;

    function setUp() external {
        loanAsset = new MockERC20("Loan Asset", "LOAN", 18);
        collateralAsset = new MockERC20("Collateral Asset", "COLL", 18);
        morpho = new MockMorpho();
        receiver = new MorphoGenericReceiver(address(morpho), ADAPTER);

        marketParams = IMorpho.MarketParams({
            loanToken: address(loanAsset),
            collateralToken: address(collateralAsset),
            oracle: address(0x1111),
            irm: address(0x2222),
            lltv: 8e17
        });

        loanAsset.mint(address(receiver), REPAY_AMOUNT);
        collateralAsset.mint(address(morpho), COLLATERAL_AMOUNT);

        vm.prank(OWNER);
        morpho.setAuthorization(address(receiver), true);
    }

    function test_CallbackRepaysAndWithdrawsAndApprovesAdapter() external {
        bytes memory data =
            abi.encode(MorphoGenericReceiver.OpenCallbackData({marketParams: marketParams, collateralAmount: COLLATERAL_AMOUNT}));

        vm.prank(ADAPTER);
        receiver.onYLiquidAdapterCallback(PHASE_OPEN, OWNER, address(loanAsset), REPAY_AMOUNT, COLLATERAL_AMOUNT, data);

        assertEq(loanAsset.balanceOf(address(morpho)), REPAY_AMOUNT, "repay amount mismatch");
        assertEq(collateralAsset.balanceOf(address(receiver)), COLLATERAL_AMOUNT, "collateral not received");
        assertEq(collateralAsset.allowance(address(receiver), ADAPTER), COLLATERAL_AMOUNT, "adapter allowance mismatch");

        assertEq(morpho.lastLoanToken(), address(loanAsset), "loan token mismatch");
        assertEq(morpho.lastRepayOnBehalf(), OWNER, "repay onBehalf mismatch");
        assertEq(morpho.lastRepayAssets(), REPAY_AMOUNT, "repaid assets mismatch");
        assertEq(morpho.lastCollateralToken(), address(collateralAsset), "collateral token mismatch");
        assertEq(morpho.lastWithdrawOnBehalf(), OWNER, "withdraw onBehalf mismatch");
        assertEq(morpho.lastWithdrawAssets(), COLLATERAL_AMOUNT, "withdrawn assets mismatch");
        assertEq(morpho.lastWithdrawReceiver(), address(receiver), "withdraw receiver mismatch");
    }

    function test_RevertsWhenOwnerDidNotAuthorizeReceiver() external {
        vm.prank(OWNER);
        morpho.setAuthorization(address(receiver), false);

        bytes memory data =
            abi.encode(MorphoGenericReceiver.OpenCallbackData({marketParams: marketParams, collateralAmount: COLLATERAL_AMOUNT}));

        vm.expectRevert("not authorized by owner");
        vm.prank(ADAPTER);
        receiver.onYLiquidAdapterCallback(PHASE_OPEN, OWNER, address(loanAsset), REPAY_AMOUNT, COLLATERAL_AMOUNT, data);
    }
}
