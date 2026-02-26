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
import {WeETHUnwindAdapter} from "../../src/adapters/WeETHUnwindAdapter.sol";
import {MorphoGenericReceiver} from "../../src/receivers/MorphoGenericReceiver.sol";
import {IMorpho} from "../../src/interfaces/IMorpho.sol";
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

contract YLiquidWeETHMorphoReceiverForkTest is Test {
    address internal constant FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address internal constant WEETH = 0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee;
    address internal constant EETH = 0x35fA164735182de50811E8e2E824cFb9B6118ac2;
    bytes32 internal constant MORPHO_MARKET_ID =
        0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7;

    uint256 internal constant IDLE_SEED_WETH = 50 ether;
    uint256 internal constant PRINCIPAL_WETH = 0.25 ether;
    uint256 internal constant LOCKED_WEETH = 1 ether;
    uint256 internal constant OWNER_COLLATERAL_WEETH = 3 ether;
    uint256 internal constant OWNER_INITIAL_DEBT_WETH = 1 ether;
    uint256 internal constant MIN_RATE_WAD = 1.01e18;

    address internal constant OWNER = 0x361311795A7b9D9b358e072bd7c4A9CD9F0B9508;

    IVault internal vault;
    IMorpho internal morpho;
    IMorpho.MarketParams internal morphoMarketParams;
    YLiquidRateModel internal rateModel;
    YLiquidMarket internal market;
    IdleHoldStrategy internal idleStrategy;
    WeETHUnwindAdapter internal adapter;
    MorphoGenericReceiver internal receiver;

    function setUp() external {
        string memory rpc = vm.envString("ETH_RPC_URL");
        vm.createSelectFork(rpc);
        vm.makePersistent(address(this));

        morpho = IMorpho(MORPHO);
        morphoMarketParams = morpho.idToMarketParams(MORPHO_MARKET_ID);
        require(morphoMarketParams.loanToken == WETH, "market loan token mismatch");
        require(morphoMarketParams.collateralToken == WEETH, "market collateral token mismatch");

        address vaultAddr =
            IVaultFactory(FACTORY).deploy_new_vault(WETH, "yLiquid weETH Morpho Fork Vault", "ylWEETH", address(this), 7 days);
        vault = IVault(vaultAddr);

        rateModel = new YLiquidRateModel(0, 1, 0);
        market = new YLiquidMarket(WETH, vaultAddr, address(rateModel), "yLiquid Position", "yLPOS");
        idleStrategy = new IdleHoldStrategy(WETH, "yLiquid Idle Strategy");
        adapter = new WeETHUnwindAdapter(address(market), MIN_RATE_WAD);
        receiver = new MorphoGenericReceiver(MORPHO, address(market));

        _configureVault();
        _configureMarket();
        _bootstrapOwnerBorrowerPosition();
    }

    function testFork_OpenPosition_UsesMorphoReceiverAndRequestsWeETHWithdrawal() external {
        IMorpho.Position memory ownerPositionBefore = morpho.position(MORPHO_MARKET_ID, OWNER);
        assertGt(ownerPositionBefore.borrowShares, 0, "owner has no borrow");
        assertGe(ownerPositionBefore.collateral, LOCKED_WEETH, "owner has no collateral");

        bytes memory callbackData = abi.encode(
            MorphoGenericReceiver.OpenCallbackData({marketParams: morphoMarketParams, collateralAmount: LOCKED_WEETH})
        );

        uint256 tokenId;
        vm.prank(OWNER);
        tokenId = market.openPosition(
            PRINCIPAL_WETH,
            address(adapter),
            address(receiver),
            WEETH,
            LOCKED_WEETH,
            callbackData
        );

        IMorpho.Position memory ownerPositionAfter = morpho.position(MORPHO_MARKET_ID, OWNER);
        assertLt(ownerPositionAfter.borrowShares, ownerPositionBefore.borrowShares, "owner debt not reduced");
        assertEq(
            uint256(ownerPositionBefore.collateral) - uint256(ownerPositionAfter.collateral),
            LOCKED_WEETH,
            "owner collateral not withdrawn"
        );

        assertEq(IERC20(WEETH).balanceOf(address(receiver)), 0, "receiver weeth dust");

        (
            AdapterProxy proxy,
            uint128 principal,
            uint128 locked,
            uint256 requestId,
            WeETHUnwindAdapter.Status status
        ) = adapter.positions(tokenId);

        assertEq(principal, PRINCIPAL_WETH, "principal mismatch");
        assertEq(locked, LOCKED_WEETH, "locked mismatch");
        assertGt(requestId, 0, "missing request id");
        assertEq(uint8(status), uint8(WeETHUnwindAdapter.Status.Open), "position not open");
        assertEq(IERC20(WEETH).balanceOf(address(proxy)), 0, "proxy weeth dust");
        assertLe(IERC20(EETH).balanceOf(address(proxy)), 1, "proxy eeth dust");
    }

    function testFork_OpenPosition_RevertsWithoutMorphoAuthorization() external {
        vm.prank(OWNER);
        morpho.setAuthorization(address(receiver), false);

        bytes memory callbackData = abi.encode(
            MorphoGenericReceiver.OpenCallbackData({marketParams: morphoMarketParams, collateralAmount: LOCKED_WEETH})
        );

        vm.expectRevert("not authorized by owner");
        vm.prank(OWNER);
        market.openPosition(
            PRINCIPAL_WETH,
            address(adapter),
            address(receiver),
            WEETH,
            LOCKED_WEETH,
            callbackData
        );
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
        deal(WEETH, OWNER, OWNER_COLLATERAL_WEETH, false);

        vm.startPrank(OWNER);
        IERC20(WEETH).approve(MORPHO, OWNER_COLLATERAL_WEETH);
        morpho.supplyCollateral(morphoMarketParams, OWNER_COLLATERAL_WEETH, OWNER, bytes(""));
        morpho.borrow(morphoMarketParams, OWNER_INITIAL_DEBT_WETH, 0, OWNER, OWNER);
        morpho.setAuthorization(address(receiver), true);
        vm.stopPrank();
    }
}
