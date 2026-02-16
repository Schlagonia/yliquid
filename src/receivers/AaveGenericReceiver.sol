// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";

contract AaveGenericReceiver is IYLiquidAdapterCallbackReceiver {
    using SafeERC20 for IERC20;

    uint8 internal constant PHASE_OPEN = 1;
    uint256 internal constant REPAY_RATE_MODE = 2;

    struct OpenCallbackData {
        address collateralAsset;
        address collateralAToken;
        uint256 collateralAmount;
    }

    IAavePool public immutable pool;
    address public immutable adapter;

    constructor(address pool_, address adapter_) {
        require(pool_ != address(0), "zero pool");
        require(adapter_ != address(0), "zero adapter");

        pool = IAavePool(pool_);
        adapter = adapter_;
    }

    function onYLiquidAdapterCallback(uint8 phase, address owner, address token, uint256 amount, bytes calldata data)
        external
        override
    {
        require(msg.sender == adapter, "not adapter");
        require(phase == PHASE_OPEN, "unsupported phase");
        require(owner != address(0), "zero owner");
        require(amount > 0, "zero amount");

        OpenCallbackData memory openData = abi.decode(data, (OpenCallbackData));
        require(openData.collateralAsset != address(0), "zero collateral asset");
        require(openData.collateralAToken != address(0), "zero collateral atoken");
        require(openData.collateralAmount > 0, "zero collateral");

        IERC20(token).forceApprove(address(pool), amount);
        pool.repay(token, amount, REPAY_RATE_MODE, owner);

        IERC20(openData.collateralAToken).safeTransferFrom(owner, address(this), openData.collateralAmount);

        uint256 withdrawn = pool.withdraw(openData.collateralAsset, openData.collateralAmount, address(this));
        require(withdrawn > 0, "zero withdrawn");

        IERC20(openData.collateralAsset).forceApprove(adapter, withdrawn);
    }
}
