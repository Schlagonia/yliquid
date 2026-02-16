// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IVault} from "@yearn-vaults/interfaces/IVault.sol";
import {IVaultFactory} from "@yearn-vaults/interfaces/IVaultFactory.sol";
import {Roles} from "@yearn-vaults/interfaces/Roles.sol";
import {YLiquidRateModel} from "../src/YLiquidRateModel.sol";
import {YLiquidMarket} from "../src/YLiquidMarket.sol";
import {SUSDeAdapter} from "../src/adapters/SUSDeAdapter.sol";
import {WstETHUnwindAdapter} from "../src/adapters/WstETHUnwindAdapter.sol";
import {AaveGenericReceiver} from "../src/receivers/AaveGenericReceiver.sol";

contract DeployYLiquid is Script {
    // -------------------------------------------------------------------------
    // EDIT THESE VALUES BEFORE DEPLOYING
    // -------------------------------------------------------------------------

    bool internal constant USE_FACTORY = true;

    // Existing vault mode (USE_FACTORY = false)
    address internal constant EXISTING_YEARN_VAULT = address(0);

    // Factory mode (USE_FACTORY = true)
    address internal constant VAULT_FACTORY = 0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F;
    string internal constant VAULT_NAME = "yLiquid WETH Vault";
    string internal constant VAULT_SYMBOL = "ylWETH";
    address internal constant VAULT_ROLE_MANAGER = address(0x1b5f15DCb82d25f91c65b53CEe151E8b9fBdD271); // set this
    uint256 internal constant VAULT_PROFIT_MAX_UNLOCK_TIME = 1 days;

    // Market
    address internal constant MARKET_ASSET = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant IDLE_STRATEGY = address(0xc56413869c6CDf96496f2b1eF801fEDBdFA7dDB0); // optional
    string internal constant NFT_NAME = "yLiquid WETHPosition";
    string internal constant NFT_SYMBOL = "yLPWETH";
    uint256 internal constant BASE_RATE_BPS = 1_000;
    uint256 internal constant OVERDUE_GRACE_SECONDS = 1 days;
    uint256 internal constant OVERDUE_STEP_BPS = 10;

    // Optional SUSDe adapter (set address(0) to skip)
    address internal constant SUSDE_ADDRESS = address(0);
    uint256 internal constant SUSDE_MIN_RATE_WAD = 1.05e18;
    uint32 internal constant SUSDE_RISK_PREMIUM_BPS = 0;

    // Optional wstETH unwind adapter (set address(0) to skip)
    address internal constant WSTETH_ADDRESS = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    uint256 internal constant WSTETH_MIN_RATE_WAD = 1.1e18;
    uint64 internal constant WSTETH_MAX_DURATION_SECONDS = 7 days; // 0 = adapter default
    uint32 internal constant WSTETH_RISK_PREMIUM_BPS = 0;

    // Optional Aave generic receiver (requires WSTETH_ADDRESS != 0)
    address internal constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;

    // -------------------------------------------------------------------------

    struct DeployResult {
        address vault;
        address rateModel;
        address market;
        address susdeAdapter;
        address wstEthAdapter;
        address aaveReceiver;
    }

    function run() external returns (DeployResult memory result) {
        _validateConfig();

        vm.startBroadcast();

        address yearnVault = USE_FACTORY ? _deployVault() : EXISTING_YEARN_VAULT;
        result = _deployAndConfigure(yearnVault);

        vm.stopBroadcast();
    }

    function _deployVault() internal returns (address yearnVault) {
        yearnVault = IVaultFactory(VAULT_FACTORY).deploy_new_vault(
            MARKET_ASSET, VAULT_NAME, VAULT_SYMBOL, VAULT_ROLE_MANAGER, VAULT_PROFIT_MAX_UNLOCK_TIME
        );
    }

    function _deployAndConfigure(address yearnVault) internal returns (DeployResult memory result) {
        YLiquidRateModel rateModel =
            new YLiquidRateModel(BASE_RATE_BPS, OVERDUE_GRACE_SECONDS, OVERDUE_STEP_BPS);

        YLiquidMarket market = new YLiquidMarket(MARKET_ASSET, yearnVault, address(rateModel), NFT_NAME, NFT_SYMBOL);

        _configureVault(yearnVault, address(market), IDLE_STRATEGY);

        result.vault = yearnVault;
        result.rateModel = address(rateModel);
        result.market = address(market);

        if (SUSDE_ADDRESS != address(0)) {
            SUSDeAdapter susdeAdapter =
                new SUSDeAdapter(address(market), MARKET_ASSET, SUSDE_ADDRESS, SUSDE_MIN_RATE_WAD);
            market.setAdapterAllowed(address(susdeAdapter), true);
            market.setAdapterRiskPremium(address(susdeAdapter), SUSDE_RISK_PREMIUM_BPS);
            result.susdeAdapter = address(susdeAdapter);
        }

        if (WSTETH_ADDRESS != address(0)) {
            WstETHUnwindAdapter wstEthAdapter =
                new WstETHUnwindAdapter(address(market), MARKET_ASSET, WSTETH_ADDRESS, WSTETH_MIN_RATE_WAD);
            if (WSTETH_MAX_DURATION_SECONDS > 0) {
                wstEthAdapter.setMaxDurationSeconds(WSTETH_MAX_DURATION_SECONDS);
            }
            market.setAdapterAllowed(address(wstEthAdapter), true);
            market.setAdapterRiskPremium(address(wstEthAdapter), WSTETH_RISK_PREMIUM_BPS);
            result.wstEthAdapter = address(wstEthAdapter);

            if (AAVE_POOL != address(0)) {
                result.aaveReceiver = address(new AaveGenericReceiver(AAVE_POOL, address(wstEthAdapter)));
            }
        }

        console2.log("vault:", result.vault);
        console2.log("rateModel:", result.rateModel);
        console2.log("market:", result.market);
        console2.log("susdeAdapter:", result.susdeAdapter);
        console2.log("wstEthAdapter:", result.wstEthAdapter);
        console2.log("aaveReceiver:", result.aaveReceiver);
    }

    function _configureVault(address yearnVault, address market, address idleStrategy) internal {
        IVault vault = IVault(yearnVault);

        vault.set_role(market, Roles.DEBT_MANAGER);
        vault.set_role(VAULT_ROLE_MANAGER, Roles.ALL);

        if (vault.strategies(market).activation == 0) {
            vault.add_strategy(market);
        }
        vault.update_max_debt_for_strategy(market, type(uint256).max);

        if (idleStrategy != address(0)) {
            if (vault.strategies(idleStrategy).activation == 0) {
                vault.add_strategy(idleStrategy);
            }
            vault.update_max_debt_for_strategy(idleStrategy, type(uint256).max);
            YLiquidMarket(market).setIdleStrategy(idleStrategy);
        }
    }

    function _validateConfig() internal pure {
        require(MARKET_ASSET != address(0), "zero market asset");
        require(bytes(NFT_NAME).length != 0, "empty nft name");
        require(bytes(NFT_SYMBOL).length != 0, "empty nft symbol");
        require(OVERDUE_GRACE_SECONDS > 0, "zero overdue grace");

        if (USE_FACTORY) {
            require(VAULT_FACTORY != address(0), "zero factory");
            require(VAULT_ROLE_MANAGER != address(0), "zero role manager");
            require(bytes(VAULT_NAME).length != 0, "empty vault name");
            require(bytes(VAULT_SYMBOL).length != 0, "empty vault symbol");
        } else {
            require(EXISTING_YEARN_VAULT != address(0), "zero existing vault");
        }

        if (AAVE_POOL != address(0)) {
            require(WSTETH_ADDRESS != address(0), "aave pool requires wsteth adapter");
        }
    }
}
