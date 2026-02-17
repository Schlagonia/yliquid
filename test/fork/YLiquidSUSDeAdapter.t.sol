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
import {SUSDeAdapter} from "../../src/adapters/SUSDeAdapter.sol";
import {IAavePool} from "../../src/interfaces/IAavePool.sol";
import {IYLiquidAdapterCallbackReceiver} from "../../src/interfaces/IYLiquidAdapterCallbackReceiver.sol";

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

contract SUSDeAaveReceiver is IYLiquidAdapterCallbackReceiver {
    uint8 internal constant PHASE_OPEN_USDC = 1;
    uint8 internal constant PHASE_SETTLE_USDE = 2;

    IAavePool public immutable POOL;
    address public immutable ADAPTER;
    address public immutable USDC;
    address public immutable USDE;
    address public immutable SUSDE;

    bool public sawOpenCallback;
    bool public sawSettleCallback;

    constructor(address pool_, address adapter_, address usdc_, address usde_, address sUSDe_) {
        POOL = IAavePool(pool_);
        ADAPTER = adapter_;
        USDC = usdc_;
        USDE = usde_;
        SUSDE = sUSDe_;
    }

    function bootstrapAavePosition(uint256 collateralSUSDe, uint256 borrowUsdc, address sink) external {
        _forceApprove(SUSDE, address(POOL), collateralSUSDe);
        POOL.supply(SUSDE, collateralSUSDe, address(this), 0);
        if (borrowUsdc > 0) {
            POOL.borrow(USDC, borrowUsdc, 2, 0, address(this));
        }

        if (sink != address(0)) {
            IERC20(USDC).transfer(sink, IERC20(USDC).balanceOf(address(this)));
        }
    }

    function onYLiquidAdapterCallback(
        uint8 phase,
        address,
        address token,
        uint256 amount,
        uint256 collateralAmount,
        bytes calldata data
    )
        external
        override
    {
        require(msg.sender == ADAPTER, "not adapter");

        if (phase == PHASE_OPEN_USDC) {
            sawOpenCallback = true;
            require(token == USDC, "bad token");
            require(amount > 0, "bad amount");

            _forceApprove(SUSDE, ADAPTER, collateralAmount);
            return;
        }

        if (phase == PHASE_SETTLE_USDE) {
            sawSettleCallback = true;
            require(token == USDE, "bad token");
            require(amount > 0, "bad amount");

            uint256 repayUsdc = abi.decode(data, (uint256));
            require(IERC20(USDC).balanceOf(address(this)) >= repayUsdc, "insufficient usdc");
            _forceApprove(USDC, ADAPTER, repayUsdc);
            return;
        }

        revert("unsupported phase");
    }

    function _forceApprove(address token, address spender, uint256 amount) internal {
        IERC20(token).approve(spender, 0);
        IERC20(token).approve(spender, amount);
    }
}

contract YLiquidSUSDeAdapterForkTest is Test {
    address internal constant FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address internal constant USDE = 0x4c9EDD5852cd905f086C759E8383e09bff1E68B3;
    address internal constant SUSDE = 0x9D39A5DE30e57443BfF2A8307A4256c8797A3497;

    uint256 internal constant IDLE_SEED_USDC = 2_000_000e6;
    uint256 internal constant PRINCIPAL_USDC = 10_000e6;
    uint256 internal constant BOOTSTRAP_COLLATERAL_SUSDE = 30_000e18;
    uint256 internal constant LOCKED_SUSDE = 29_500e18;

    IVault internal vault;
    YLiquidRateModel internal rateModel;
    YLiquidMarket internal market;
    IdleHoldStrategy internal idleStrategy;
    SUSDeAdapter internal adapter;
    SUSDeAaveReceiver internal receiver;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);
        vm.makePersistent(address(this));

        address vaultAddr =
            IVaultFactory(FACTORY).deploy_new_vault(USDC, "yLiquid sUSDe Aave Fork Vault", "ylSUSDE", address(this), 7 days);
        vault = IVault(vaultAddr);

        rateModel = new YLiquidRateModel(0, 1, 0);
        market = new YLiquidMarket(USDC, vaultAddr, address(rateModel), "yLiquid Position", "yLPOS");
        idleStrategy = new IdleHoldStrategy(USDC, "yLiquid Idle Strategy");
        adapter = new SUSDeAdapter(address(market), 1.1e18);
        receiver = new SUSDeAaveReceiver(AAVE_POOL, address(adapter), USDC, USDE, SUSDE);
        _labelAddresses();

        _configureVault();
        _configureMarket();
        _bootstrapReceiverAavePosition();
    }

    function testFork_OpenCooldownAndSettleThroughAave() external {
        bytes memory openCallbackData = abi.encode(LOCKED_SUSDE);

        uint256 tokenId = market.openPosition(
            PRINCIPAL_USDC, address(adapter), address(receiver), LOCKED_SUSDE, openCallbackData
        );

        assertTrue(receiver.sawOpenCallback(), "open callback missing");
        (,,,, uint64 cooldownEnd, SUSDeAdapter.Status status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(SUSDeAdapter.Status.Open), "position not open");
        vm.warp(uint256(cooldownEnd) + 1);

        uint256 owed = market.quoteDebt(tokenId);
        bytes memory settleCallbackData = abi.encode(owed);
        market.settleAndRepay(tokenId, address(receiver), settleCallbackData);

        assertTrue(receiver.sawSettleCallback(), "settle callback missing");
        (,,,,, status) = adapter.positions(tokenId);
        assertEq(uint8(status), uint8(SUSDeAdapter.Status.Closed), "adapter position still open");
        assertEq(market.totalPrincipalActive(), 0, "market principal not cleared");

        IVault.StrategyParams memory marketParams = vault.strategies(address(market));
        IVault.StrategyParams memory idleParams = vault.strategies(address(idleStrategy));
        assertEq(marketParams.current_debt, 0, "market debt should be zero");
        assertEq(idleParams.current_debt, IDLE_SEED_USDC, "idle debt should be restored");
    }

    function testFork_SettleBeforeCooldownReverts() external {
        bytes memory openCallbackData = abi.encode(LOCKED_SUSDE);

        uint256 tokenId = market.openPosition(
            PRINCIPAL_USDC, address(adapter), address(receiver), LOCKED_SUSDE, openCallbackData
        );

        bytes memory settleCallbackData = abi.encode(PRINCIPAL_USDC);
        vm.expectRevert();
        market.settleAndRepay(tokenId, address(receiver), settleCallbackData);
    }

    function _configureVault() internal {
        vault.set_role(address(this), Roles.ALL);
        vault.set_role(address(market), Roles.DEBT_MANAGER);
        vault.set_deposit_limit(type(uint256).max);

        vault.add_strategy(address(idleStrategy));
        vault.update_max_debt_for_strategy(address(idleStrategy), type(uint256).max);
        vault.add_strategy(address(market));
        vault.update_max_debt_for_strategy(address(market), type(uint256).max);

        deal(USDC, address(this), IDLE_SEED_USDC, true);
        IERC20(USDC).approve(address(vault), IDLE_SEED_USDC);
        vault.deposit(IDLE_SEED_USDC, address(this));
        vault.update_debt(address(idleStrategy), IDLE_SEED_USDC);
    }

    function _configureMarket() internal {
        market.setIdleStrategy(address(idleStrategy));
        market.setAdapterAllowed(address(adapter), true);
        market.setAdapterRiskPremium(address(adapter), 0);
    }

    function _bootstrapReceiverAavePosition() internal {
        deal(SUSDE, address(receiver), BOOTSTRAP_COLLATERAL_SUSDE, true);
        receiver.bootstrapAavePosition(BOOTSTRAP_COLLATERAL_SUSDE, 0, address(0));
        deal(SUSDE, address(receiver), LOCKED_SUSDE, true);
        deal(USDC, address(receiver), PRINCIPAL_USDC * 2, true);
    }

    function _labelAddresses() internal {
        vm.label(address(this), "YLiquidSUSDeAdapterForkTest");
        vm.label(FACTORY, "YearnVaultFactoryV3");
        vm.label(AAVE_POOL, "AaveV3Pool");
        vm.label(USDC, "USDC");
        vm.label(USDE, "USDe");
        vm.label(SUSDE, "sUSDe");
        vm.label(address(vault), "YLiquidVault");
        vm.label(address(rateModel), "YLiquidRateModel");
        vm.label(address(market), "YLiquidMarketStrategy");
        vm.label(address(idleStrategy), "IdleHoldStrategy");
        vm.label(address(adapter), "SUSDeAdapter");
        vm.label(address(receiver), "SUSDeAaveReceiver");
    }
}
