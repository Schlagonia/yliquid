// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseStrategy} from "@tokenized-strategy/BaseStrategy.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {YLiquidMarket} from "../../src/YLiquidMarket.sol";
import {YLiquidRateModel} from "../../src/YLiquidRateModel.sol";
import {WstETHUnwindAdapter} from "../../src/adapters/WstETHUnwindAdapter.sol";
import {AaveGenericReceiver} from "../../src/receivers/AaveGenericReceiver.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {IAavePoolAddressesProvider} from "../../src/interfaces/IAavePoolAddressesProvider.sol";
import {IAaveProtocolDataProvider} from "../../src/interfaces/IAaveProtocolDataProvider.sol";
import {IQueue} from "../../src/interfaces/IQueue.sol";
import {IwstETH} from "../../src/interfaces/IwstETH.sol";
import {AdapterProxy} from "../../src/adapters/AdapterProxy.sol";

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

contract AaveGenericReceiverWstETHForkTest is Test {
    address internal constant FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address internal constant WITHDRAWAL_QUEUE = 0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1;

    uint256 internal constant IDLE_SEED_WETH = 500 ether;
    uint256 internal constant PRINCIPAL_WETH = 7 ether;
    uint256 internal constant LOCKED_WSTETH = 7 ether;
    uint256 internal constant OWNER_COLLATERAL_WSTETH = 20 ether;
    uint256 internal constant OWNER_INITIAL_DEBT_WETH = 8 ether;
    uint256 internal constant VARIABLE_RATE_MODE = 2;

    address internal constant OWNER = address(0xB0B);

    IVault internal vault;
    YLiquidRateModel internal rateModel;
    YLiquidMarket internal market;
    IdleHoldStrategy internal idleStrategy;
    WstETHUnwindAdapter internal adapter;
    AaveGenericReceiver internal receiver;
    address internal aWstETH;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);
        vm.makePersistent(address(this));

        address vaultAddr =
            IVaultFactory(FACTORY).deploy_new_vault(WETH, "yLiquid Generic Receiver Fork Vault", "ylGR", address(this), 7 days);
        vault = IVault(vaultAddr);

        rateModel = new YLiquidRateModel(0, 1, 0);
        market = new YLiquidMarket(WETH, vaultAddr, address(rateModel), "yLiquid Position", "yLPOS");
        idleStrategy = new IdleHoldStrategy(WETH, "yLiquid Idle Strategy");
        adapter = new WstETHUnwindAdapter(address(market), 1.01e18);
        receiver = new AaveGenericReceiver(AAVE_POOL, address(market));
        aWstETH = _resolveAaveAToken(WSTETH);
        require(aWstETH != address(0), "zero awsteth");
        _labelAddresses();

        _configureVault();
        _configureMarket();
        _bootstrapOwnerBorrowerPosition();
    }

    function testFork_E2E_DeleverWithGenericReceiverAndSimulatedClaim() external {
        uint256 ownerATokenBefore = IERC20(aWstETH).balanceOf(OWNER);
        uint256 ownerDebtBaseBefore = _ownerDebtBase();
        uint256 ownerWethBefore = IERC20(WETH).balanceOf(OWNER);
        assertGt(ownerATokenBefore, LOCKED_WSTETH, "owner has no aToken collateral");
        assertGt(ownerDebtBaseBefore, 0, "owner has no debt");

        bytes memory callbackData = abi.encode(
            AaveGenericReceiver.OpenCallbackData({
                collateralAsset: WSTETH,
                collateralAToken: aWstETH,
                collateralAmount: LOCKED_WSTETH
            })
        );

        uint256 tokenId;
        vm.prank(OWNER);
        tokenId = market.openPosition(
            PRINCIPAL_WETH,
            address(adapter),
            address(receiver),
            WSTETH,
            LOCKED_WSTETH,
            callbackData
        );

        uint256 ownerATokenAfter = IERC20(aWstETH).balanceOf(OWNER);
        uint256 ownerDebtBaseAfterOpen = _ownerDebtBase();

        assertLt(ownerDebtBaseAfterOpen, ownerDebtBaseBefore, "owner debt not reduced");
        assertApproxEqAbs(ownerATokenBefore - ownerATokenAfter, LOCKED_WSTETH, 2);
        assertEq(IERC20(aWstETH).balanceOf(address(receiver)), 0, "receiver aToken dust");
        assertEq(IERC20(WSTETH).balanceOf(address(receiver)), 0, "receiver collateral dust");

        (
            AdapterProxy proxy,
            uint128 principal,
            uint128 locked,
            uint256 requestId,
            WstETHUnwindAdapter.Status status
        ) = adapter.positions(tokenId);
        vm.label(address(proxy), "WstETHUnwindProxy");
        assertEq(principal, PRINCIPAL_WETH, "principal mismatch");
        assertEq(locked, LOCKED_WSTETH, "locked mismatch");
        assertGt(requestId, 0, "request id");
        assertEq(uint8(status), uint8(WstETHUnwindAdapter.Status.Open), "position not open");
        assertEq(IERC20(WSTETH).balanceOf(address(proxy)), 0, "proxy wsteth dust");

        vm.warp(block.timestamp + 8 days);

        // Simulate finalized claim delivery from the withdrawal queue.
        uint256 claimedEth = IwstETH(WSTETH).getStETHByWstETH(LOCKED_WSTETH);
        vm.deal(address(proxy), claimedEth);
        vm.mockCall(
            WITHDRAWAL_QUEUE,
            abi.encodeCall(IQueue.claimWithdrawal, (requestId)),
            abi.encode()
        );

        uint256 owed = market.quoteDebt(tokenId);
        vm.prank(OWNER);
        market.settleAndRepay(tokenId, address(receiver), bytes(""));

        (proxy,,, requestId, status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(WstETHUnwindAdapter.Status.Closed), "position not closed");
        assertEq(market.totalPrincipalActive(), 0, "principal active");
        assertEq(IERC20(WETH).balanceOf(address(proxy)), 0, "proxy weth dust");
        assertEq(IERC20(WETH).balanceOf(OWNER) - ownerWethBefore, claimedEth - owed, "owner surplus");

        IVault.StrategyParams memory marketParams = vault.strategies(address(market));
        IVault.StrategyParams memory idleParams = vault.strategies(address(idleStrategy));
        assertEq(marketParams.current_debt, 0, "market debt should be zero");
        assertEq(idleParams.current_debt, IDLE_SEED_WETH, "idle debt should be restored");
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

    function _bootstrapOwnerBorrowerPosition() internal {
        deal(WSTETH, OWNER, OWNER_COLLATERAL_WSTETH, false);

        vm.startPrank(OWNER);
        IERC20(WSTETH).approve(AAVE_POOL, OWNER_COLLATERAL_WSTETH);
        IAavePool(AAVE_POOL).supply(WSTETH, OWNER_COLLATERAL_WSTETH, OWNER, 0);
        IAavePool(AAVE_POOL).borrow(WETH, OWNER_INITIAL_DEBT_WETH, VARIABLE_RATE_MODE, 0, OWNER);
        IERC20(aWstETH).approve(address(receiver), LOCKED_WSTETH);
        vm.stopPrank();
    }

    function _ownerDebtBase() internal view returns (uint256 debtBase) {
        (, debtBase, , , , ) = IAavePool(AAVE_POOL).getUserAccountData(OWNER);
    }

    function _resolveAaveAToken(address underlying) internal view returns (address aToken) {
        address addressesProvider = IAavePool(AAVE_POOL).ADDRESSES_PROVIDER();
        address dataProvider = IAavePoolAddressesProvider(addressesProvider).getPoolDataProvider();
        (aToken,,) = IAaveProtocolDataProvider(dataProvider).getReserveTokensAddresses(underlying);
    }

    function _labelAddresses() internal {
        vm.label(address(this), "AaveGenericReceiverWstETHForkTest");
        vm.label(FACTORY, "YearnVaultFactoryV3");
        vm.label(AAVE_POOL, "AaveV3Pool");
        vm.label(WETH, "WETH");
        vm.label(WSTETH, "wstETH");
        vm.label(aWstETH, "aWstETH");
        vm.label(WITHDRAWAL_QUEUE, "LidoWithdrawalQueue");
        vm.label(OWNER, "BorrowerOwner");
        vm.label(address(vault), "YLiquidVault");
        vm.label(address(rateModel), "YLiquidRateModel");
        vm.label(address(market), "YLiquidMarketStrategy");
        vm.label(address(idleStrategy), "IdleHoldStrategy");
        vm.label(address(adapter), "WstETHUnwindAdapter");
        vm.label(address(receiver), "AaveGenericReceiver");
    }
}
