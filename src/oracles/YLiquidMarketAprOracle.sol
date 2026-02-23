// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";
import {IYLiquidRateModel} from "../interfaces/IYLiquidRateModel.sol";

interface IYLiquidMarketAprReader {
    function totalPrincipalActive() external view returns (uint256);
    function rateModel() external view returns (address);
}

/// @notice APR oracle for YLiquid market strategy.
/// @dev APR is estimated as: borrowRate * utilization.
contract YLiquidMarketAprOracle  {
    uint256 public constant BPS = 10_000;
    uint256 public constant WAD = 1e18;

    function aprAfterDebtChange(address strategy_, int256 delta_) external view returns (uint256) {

        uint256 principalActive = IYLiquidMarketAprReader(strategy_).totalPrincipalActive();
        if (principalActive == 0) return 0;

        uint256 totalAssets = ITokenizedStrategy(strategy_).totalAssets();
        int256 adjustedAssetsSigned = int256(totalAssets) + delta_;
        if (adjustedAssetsSigned <= 0) return 0;
        uint256 adjustedAssets = uint256(adjustedAssetsSigned);

        uint256 utilizationWad = Math.mulDiv(principalActive, WAD, adjustedAssets);
        if (utilizationWad > WAD) utilizationWad = WAD;

        uint256 borrowRateBps = IYLiquidRateModel(IYLiquidMarketAprReader(strategy_).rateModel()).borrowRateBps(
            0, 0, 1
        );

        return Math.mulDiv(borrowRateBps, utilizationWad, BPS);
    }
}
