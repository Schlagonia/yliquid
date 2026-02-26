// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IYLiquidCollateralOracle} from "../../src/interfaces/IYLiquidCollateralOracle.sol";

contract MockYLiquidCollateralOracle is IYLiquidCollateralOracle {
    uint256 internal constant WAD = 1e18;

    bool public shouldRevert;
    mapping(address => uint256) public ratesWad;

    function setShouldRevert(bool shouldRevert_) external {
        shouldRevert = shouldRevert_;
    }

    function setRate(address collateralToken, uint256 rateWad) external {
        ratesWad[collateralToken] = rateWad;
    }

    function collateralToAsset(address collateralToken, uint256 value) external view returns (uint256 amountInAsset) {
        require(!shouldRevert, "oracle failure");
        uint256 rateWad = ratesWad[collateralToken];
        amountInAsset = Math.mulDiv(value, rateWad, WAD);
    }
}
