// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IYLiquidRateModel} from "../src/interfaces/IYLiquidRateModel.sol";
import {YLiquidMarketAprOracle} from "../src/oracles/YLiquidMarketAprOracle.sol";

contract MockRateModel is IYLiquidRateModel {
    uint256 public rateBps;

    function setRateBps(uint256 rateBps_) external {
        rateBps = rateBps_;
    }

    function borrowRateBps(uint256 riskPremiumBps, uint256, uint256) external view returns (uint256) {
        return rateBps + riskPremiumBps;
    }
}

contract MockMarketForAprOracle {
    uint256 public totalPrincipalActive;
    uint256 public totalAssets;
    address public rateModel;

    function setState(uint256 totalPrincipalActive_, uint256 totalAssets_) external {
        totalPrincipalActive = totalPrincipalActive_;
        totalAssets = totalAssets_;
    }

    function setRateModel(address rateModel_) external {
        rateModel = rateModel_;
    }
}

contract YLiquidMarketAprOracleTest is Test {
    uint256 internal constant BPS = 10_000;

    MockRateModel internal rateModel;
    MockMarketForAprOracle internal market;
    YLiquidMarketAprOracle internal oracle;

    function setUp() external {
        rateModel = new MockRateModel();
        market = new MockMarketForAprOracle();
        market.setRateModel(address(rateModel));
        oracle = new YLiquidMarketAprOracle();
    }

    function test_ZeroPrincipalActiveReturnsZeroApr() external {
        rateModel.setRateBps(1_200);
        market.setState(0, 100e18);

        uint256 apr = oracle.aprAfterDebtChange(address(market), 0);
        assertEq(apr, 0);
    }

    function test_AprTracksBorrowRateAndUtilization() external {
        // 40% utilized, 12% borrow rate => 4.8% strategy APR.
        rateModel.setRateBps(1_200);
        market.setState(40e18, 100e18);

        uint256 apr = oracle.aprAfterDebtChange(address(market), 0);
        uint256 expected = 1_200 * 4e17 / BPS;
        assertEq(apr, expected);
    }

    function test_AprAfterPositiveDebtDelta() external {
        // Debt increase lowers utilization (and APR).
        rateModel.setRateBps(1_500);
        market.setState(60e18, 100e18);

        uint256 currentApr = oracle.aprAfterDebtChange(address(market), 0);
        uint256 reducedApr = oracle.aprAfterDebtChange(address(market), int256(50e18));

        assertLt(reducedApr, currentApr);
    }

    function test_AprAfterNegativeDebtDelta() external {
        // Debt decrease raises utilization (and APR), up to 100%.
        rateModel.setRateBps(1_500);
        market.setState(60e18, 100e18);

        uint256 currentApr = oracle.aprAfterDebtChange(address(market), 0);
        uint256 increasedApr = oracle.aprAfterDebtChange(address(market), -int256(30e18));

        assertGt(increasedApr, currentApr);
    }

    function test_InvalidLargeNegativeDeltaReturnsZero() external {
        rateModel.setRateBps(1_200);
        market.setState(40e18, 100e18);

        uint256 apr = oracle.aprAfterDebtChange(address(market), -int256(101e18));
        assertEq(apr, 0);
    }

    function test_UsesZeroRiskPremiumInCurrentOracleImplementation() external {
        rateModel.setRateBps(1_000);
        market.setState(50e18, 100e18);

        uint256 apr = oracle.aprAfterDebtChange(address(market), 0);
        uint256 expected = 1_000 * 5e17 / BPS;
        assertEq(apr, expected);
    }
}
