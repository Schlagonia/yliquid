// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IMorpho} from "../interfaces/IMorpho.sol";
import {IYLiquidAdapterCallbackReceiver} from "../interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IYLiquidManagedAdapter} from "../interfaces/IYLiquidManagedAdapter.sol";
import {ITokenizedStrategy} from "@tokenized-strategy/interfaces/ITokenizedStrategy.sol";

contract MorphoGenericReceiver is IYLiquidAdapterCallbackReceiver {
    using SafeERC20 for IERC20;

    uint8 internal constant PHASE_OPEN = 1;

    struct OpenCallbackData {
        IMorpho.MarketParams marketParams;
        uint256 collateralAmount;
    }

    IMorpho public immutable MORPHO;
    address public immutable ADAPTER;

    constructor(address morpho_, address adapter_) {
        require(morpho_ != address(0), "zero morpho");
        require(adapter_ != address(0), "zero adapter");

        MORPHO = IMorpho(morpho_);
        ADAPTER = adapter_;
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
        require(msg.sender == ADAPTER, "not adapter");
        require(phase == PHASE_OPEN, "unsupported phase");
        require(owner != address(0), "zero owner");
        require(amount > 0, "zero amount");

        OpenCallbackData memory openData = abi.decode(data, (OpenCallbackData));

        require(openData.marketParams.loanToken != address(0), "zero loan asset");
        require(openData.marketParams.collateralToken != address(0), "zero collateral asset");
        require(collateralAmount > 0, "zero collateral");
        require(token == openData.marketParams.loanToken, "loan asset mismatch");
        require(MORPHO.isAuthorized(owner, address(this)), "not authorized by owner");

        IERC20(token).forceApprove(address(MORPHO), amount);
        MORPHO.repay(openData.marketParams, amount, 0, owner, bytes(""));

        IERC20 collateralAsset = IERC20(openData.marketParams.collateralToken);
        uint256 collateralBefore = collateralAsset.balanceOf(address(this));
        MORPHO.withdrawCollateral(openData.marketParams, collateralAmount, owner, address(this));
        uint256 withdrawn = collateralAsset.balanceOf(address(this)) - collateralBefore;
        require(withdrawn > 0, "zero withdrawn");

        collateralAsset.forceApprove(ADAPTER, withdrawn);
    }

    function rescue(address token) external {
        address market = IYLiquidManagedAdapter(ADAPTER).MARKET();
        address management = ITokenizedStrategy(market).management();
        require(msg.sender == management, "not management");

        IERC20(token).safeTransfer(management, IERC20(token).balanceOf(address(this)));
    }
}
