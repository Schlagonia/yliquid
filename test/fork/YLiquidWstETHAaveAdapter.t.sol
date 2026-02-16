// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {YLiquidMarket} from "../../src/YLiquidMarket.sol";
import {YLiquidRateModel} from "../../src/YLiquidRateModel.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AdapterProxy} from "../../src/adapters/AdapterProxy.sol";
import {WstETHUnwindAdapter} from "../../src/adapters/WstETHUnwindAdapter.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {IQueue} from "../../src/interfaces/IQueue.sol";
import {IYLiquidAdapterCallbackReceiver} from "../../src/interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IwstETH} from "../../src/interfaces/IwstETH.sol";

contract IdleHoldStrategy is BaseStrategy {
    constructor(address asset_, string memory name_) BaseStrategy(asset_, name_) {}

    function _deployFunds(uint256) internal override {}

    function _freeFunds(uint256 amount) internal view override {
        require(asset.balanceOf(address(this)) >= amount, "insufficient idle");
    }

    function _harvestAndReport() internal view override returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function availableWithdrawLimit(address) public view override returns (uint256) {
        return asset.balanceOf(address(this));
    }
}

contract WstETHAaveReceiver is IYLiquidAdapterCallbackReceiver {
    uint8 internal constant PHASE_OPEN_WETH = 1;
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    struct OpenCallbackData {
        uint256 repayAmount;
        uint256 withdrawAmount;
    }

    IAavePool public immutable pool;
    address public immutable adapter;
    address public immutable weth;
    address public immutable wstEth;

    bool public sawOpenCallback;

    constructor(address pool_, address adapter_, address weth_, address wstEth_) {
        pool = IAavePool(pool_);
        adapter = adapter_;
        weth = weth_;
        wstEth = wstEth_;
    }

    function bootstrapAavePosition(uint256 collateralWstEth, uint256 borrowWeth, address sink) external {
        _forceApprove(wstEth, address(pool), collateralWstEth);
        pool.supply(wstEth, collateralWstEth, address(this), 0);
        if (borrowWeth > 0) {
            pool.borrow(weth, borrowWeth, VARIABLE_RATE_MODE, 0, address(this));
        }

        if (sink != address(0)) {
            IERC20(weth).transfer(sink, IERC20(weth).balanceOf(address(this)));
        }
    }

    function onYLiquidAdapterCallback(uint8 phase, address, address token, uint256 amount, bytes calldata data)
        external
        override
    {
        require(msg.sender == adapter, "not adapter");
        require(phase == PHASE_OPEN_WETH, "unsupported phase");
        require(token == weth, "bad token");
        require(amount > 0, "bad amount");

        sawOpenCallback = true;
        OpenCallbackData memory openData = abi.decode(data, (OpenCallbackData));

        if (openData.repayAmount > 0) {
            _forceApprove(weth, address(pool), openData.repayAmount);
            pool.repay(weth, openData.repayAmount, VARIABLE_RATE_MODE, address(this));
        }
        pool.withdraw(wstEth, openData.withdrawAmount, address(this));
        _forceApprove(wstEth, adapter, openData.withdrawAmount);
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amount);
    }
}

contract YLiquidWstETHAaveAdapterForkTest is Test {
    address internal constant FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant STETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address internal constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    address internal constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    uint64 internal constant EXPECTED_DURATION = 3 days;
    uint256 internal constant IDLE_SEED_WETH = 500 ether;
    uint256 internal constant PRINCIPAL_WETH = 5 ether;
    uint256 internal constant BOOTSTRAP_COLLATERAL_WSTETH = 12 ether;
    uint256 internal constant LOCKED_WSTETH = 6 ether;

    IVault internal vault;
    YLiquidRateModel internal rateModel;
    YLiquidMarket internal market;
    IdleHoldStrategy internal idleStrategy;
    WstETHUnwindAdapter internal adapter;
    WstETHAaveReceiver internal receiver;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);

        address vaultAddr =
            IVaultFactory(FACTORY).deploy_new_vault(WETH, "yLiquid wstETH Aave Fork Vault", "ylWSTETH", address(this), 7 days);
        vault = IVault(vaultAddr);

        rateModel = new YLiquidRateModel(0, 1, 0);
        market = new YLiquidMarket(WETH, vaultAddr, address(rateModel), "yLiquid Position", "yLPOS");
        idleStrategy = new IdleHoldStrategy(WETH, "yLiquid Idle Strategy");
        adapter = new WstETHUnwindAdapter(address(market), WETH, WSTETH, 1e18);
        receiver = new WstETHAaveReceiver(AAVE_POOL, address(adapter), WETH, WSTETH);
        _labelAddresses();

        _configureVault();
        _configureMarket();
        _bootstrapReceiverAavePosition();
    }

    function testFork_OpenUnwindAndSettleFromWstETHToWETH() external {
        bytes memory openData = abi.encode(
                    WstETHAaveReceiver.OpenCallbackData({repayAmount: 0, withdrawAmount: LOCKED_WSTETH})
        );

        uint256 tokenId = market.openPosition(PRINCIPAL_WETH, address(adapter), address(receiver), LOCKED_WSTETH, openData);

        assertTrue(receiver.sawOpenCallback(), "open callback missing");
        (AdapterProxy proxy, address positionReceiver, uint128 principal, uint128 locked, uint256 requestId, WstETHUnwindAdapter.Status status) =
            adapter.positions(tokenId);
        vm.label(address(proxy), "WstETHUnwindProxy");
        assertEq(positionReceiver, address(receiver), "receiver mismatch");
        assertEq(principal, PRINCIPAL_WETH, "principal mismatch");
        assertEq(locked, LOCKED_WSTETH, "locked mismatch");
        assertGt(requestId, 0, "request id");
        assertEq(uint8(status), uint8(WstETHUnwindAdapter.Status.Open), "position not open");

        vm.warp(block.timestamp + EXPECTED_DURATION + 1);
        uint256 claimedEth = IwstETH(WSTETH).getStETHByWstETH(LOCKED_WSTETH);
        vm.deal(address(proxy), claimedEth);
        vm.mockCall(
            WITHDRAWAL_QUEUE,
            abi.encodeCall(IQueue.claimWithdrawal, (requestId)),
            abi.encode()
        );

        bytes memory settleData = abi.encode(bytes(""));
        market.settleAndRepay(tokenId, address(receiver), settleData);

        (proxy,,, requestId,, status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(WstETHUnwindAdapter.Status.Closed), "position not closed");
        assertEq(market.totalPrincipalActive(), 0, "market principal not cleared");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy weth balance mismatch");
        assertEq(IERC20(WSTETH).balanceOf(address(proxy)), 0, "proxy wsteth balance mismatch");
   
        IVault.StrategyParams memory marketParams = vault.strategies(address(market));
        IVault.StrategyParams memory idleParams = vault.strategies(address(idleStrategy));
        assertEq(marketParams.current_debt, 0, "market debt should be zero");
        assertEq(idleParams.current_debt, IDLE_SEED_WETH, "idle debt should be restored");
    }

    function testFork_ForceCloseOverdueUnwindsWstETH() external {
        bytes memory openData = abi.encode(
            WstETHAaveReceiver.OpenCallbackData({repayAmount: 0, withdrawAmount: LOCKED_WSTETH})
        );

        uint256 tokenId = market.openPosition(PRINCIPAL_WETH, address(adapter), address(receiver), LOCKED_WSTETH, openData);
        (AdapterProxy proxy,,,, uint256 requestId,) = adapter.positions(tokenId);
        vm.warp(block.timestamp + 11 days);
        uint256 claimedEth = IwstETH(WSTETH).getStETHByWstETH(LOCKED_WSTETH);   
        vm.deal(address(proxy), claimedEth);
        vm.mockCall(
            WITHDRAWAL_QUEUE,
            abi.encodeCall(IQueue.claimWithdrawal, (requestId)),
            abi.encode()
        );

        uint256 governanceBefore = IERC20(WETH).balanceOf(address(this));
        bytes memory forceData = abi.encode(bytes(""));

        market.forceClose(tokenId, address(receiver), forceData);

        uint256 governanceAfter = IERC20(WETH).balanceOf(address(this));
        assertGt(governanceAfter, governanceBefore, "governance bounty missing");
    }

    function testFork_SettleRevertsOnImpossibleMinOut() external {
        bytes memory openData = abi.encode(
            WstETHAaveReceiver.OpenCallbackData({repayAmount: 0, withdrawAmount: LOCKED_WSTETH})
        );

        uint256 tokenId = market.openPosition(PRINCIPAL_WETH, address(adapter), address(receiver), LOCKED_WSTETH, openData);
        bytes memory settleData = abi.encode(bytes(""));

        vm.expectRevert();
        market.settleAndRepay(tokenId, address(receiver), settleData);
    }

    function _configureVault() internal {
        vault.set_role(address(this), Roles.ALL);
        vault.set_role(address(market), Roles.DEBT_MANAGER);
        vault.set_deposit_limit(type(uint256).max);

        vault.add_strategy(address(idleStrategy));
        vault.update_max_debt_for_strategy(address(idleStrategy), type(uint256).max);
        vault.add_strategy(address(market));
        vault.update_max_debt_for_strategy(address(market), type(uint256).max);

        deal(WETH, address(this), IDLE_SEED_WETH, false);
        IERC20(WETH).approve(address(vault), IDLE_SEED_WETH);
        vault.deposit(IDLE_SEED_WETH, address(this));
        vault.update_debt(address(idleStrategy), IDLE_SEED_WETH);
    }

    function _configureMarket() internal {
        market.setIdleStrategy(address(idleStrategy));
        market.setAdapterAllowed(address(adapter), true);
        market.setAdapterRiskPremium(address(adapter), 0);
    }

    function _bootstrapReceiverAavePosition() internal {
        deal(WSTETH, address(receiver), BOOTSTRAP_COLLATERAL_WSTETH, false);
        receiver.bootstrapAavePosition(BOOTSTRAP_COLLATERAL_WSTETH, 0, address(0));
    }

    function _labelAddresses() internal {
        vm.label(address(this), "YLiquidWstETHAaveAdapterForkTest");
        vm.label(FACTORY, "YearnVaultFactoryV3");
        vm.label(AAVE_POOL, "AaveV3Pool");
        vm.label(WETH, "WETH");
        vm.label(WSTETH, "wstETH");
        vm.label(STETH, "stETH");
        vm.label(CURVE_STETH_POOL, "CurveStETHPool");
        vm.label(address(vault), "YLiquidVault");
        vm.label(address(rateModel), "YLiquidRateModel");
        vm.label(address(market), "YLiquidMarketStrategy");
        vm.label(address(idleStrategy), "IdleHoldStrategy");
        vm.label(address(adapter), "WstETHUnwindAdapter");
        vm.label(address(receiver), "WstETHAaveReceiver");
    }
}
