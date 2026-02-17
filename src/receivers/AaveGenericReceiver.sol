// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAavePool} from "../interfaces/IAavePool.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

interface IYLiquidMarketAdapterRegistry {
    function allowedAdapters(address adapter) external view returns (bool);
}

contract AaveGenericReceiver is IYLiquidAdapterCallbackReceiver {
    using SafeERC20 for IERC20;

    uint8 internal constant PHASE_OPEN = 1;
    uint256 internal constant REPAY_RATE_MODE = 2;

    struct OpenCallbackData {
        address collateralAsset;
        address collateralAToken;
        uint256 collateralAmount;
    }

    IAavePool public immutable POOL;
    address public immutable MARKET;

    constructor(address pool_, address market_) {
        require(pool_ != address(0), "zero pool");
        require(market_ != address(0), "zero market");

        POOL = IAavePool(pool_);
        MARKET = market_;
    }

    function onYLiquidAdapterCallback(
        uint8 phase,
        address owner,
        address token,
        uint256 amount,
        uint256 collateralAmount,
        bytes calldata data
    )
        external
        override
    {
        require(IYLiquidMarketAdapterRegistry(MARKET).allowedAdapters(msg.sender), "adapter not approved");
        require(phase == PHASE_OPEN, "unsupported phase");
        require(owner != address(0), "zero owner");
        require(amount > 0, "zero amount");

        OpenCallbackData memory openData = abi.decode(data, (OpenCallbackData));

        require(openData.collateralAsset != address(0), "zero collateral asset");
        require(openData.collateralAToken != address(0), "zero collateral atoken");
        require(collateralAmount > 0, "zero collateral");

        IERC20(token).forceApprove(address(POOL), amount);
        POOL.repay(token, amount, REPAY_RATE_MODE, owner);

        IERC20(openData.collateralAToken).safeTransferFrom(owner, address(this), collateralAmount);

        uint256 withdrawn = POOL.withdraw(openData.collateralAsset, collateralAmount, address(this));
        require(withdrawn > 0, "zero withdrawn");

        IERC20(openData.collateralAsset).forceApprove(msg.sender, withdrawn);
    }

    function rescue(address token) external {
        address management = ITokenizedStrategy(MARKET).management();
        require(msg.sender == management, "not management");

        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }
}
