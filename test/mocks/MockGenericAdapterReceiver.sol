// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYLiquidAdapterCallbackReceiver} from "../../src/interfaces/IYLiquidAdapterCallbackReceiver.sol";

contract MockGenericAdapterReceiver is IYLiquidAdapterCallbackReceiver {
    uint8 internal constant PHASE_OPEN = 1;
    uint8 internal constant PHASE_SETTLE = 2;
    uint8 internal constant PHASE_FORCE_CLOSE = 3;

    address public immutable ADAPTER;
    IERC20 public immutable LOAN_ASSET;
    IERC20 public immutable COLLATERAL_ASSET;

    uint256 public settleApprovalAmount;
    uint256 public forceCloseApprovalAmount;

    constructor(address adapter_, address loanAsset_, address collateralAsset_) {
        ADAPTER = adapter_;
        LOAN_ASSET = IERC20(loanAsset_);
        COLLATERAL_ASSET = IERC20(collateralAsset_);

        settleApprovalAmount = type(uint256).max;
        forceCloseApprovalAmount = type(uint256).max;
    }

    function setSettleApprovalAmount(uint256 amount) external {
        settleApprovalAmount = amount;
    }

    function setForceCloseApprovalAmount(uint256 amount) external {
        forceCloseApprovalAmount = amount;
    }

    function drainLoan(address receiver, uint256 amount) external {
        LOAN_ASSET.transfer(receiver, amount);
    }

    function onYLiquidAdapterCallback(
        uint8 phase,
        address,
        address token,
        uint256 amount,
        uint256 collateralAmount,
        bytes calldata
    )
        external
    {
        require(msg.sender == ADAPTER, "not adapter");

        if (phase == PHASE_OPEN) {
            require(token == address(LOAN_ASSET), "bad token");
            COLLATERAL_ASSET.approve(ADAPTER, 0);
            COLLATERAL_ASSET.approve(ADAPTER, collateralAmount);
            return;
        }

        if (phase == PHASE_SETTLE) {
            require(token == address(LOAN_ASSET), "bad token");
            uint256 approveAmount = settleApprovalAmount == type(uint256).max ? amount : settleApprovalAmount;
            LOAN_ASSET.approve(ADAPTER, 0);
            LOAN_ASSET.approve(ADAPTER, approveAmount);
            return;
        }

        if (phase == PHASE_FORCE_CLOSE) {
            require(token == address(LOAN_ASSET), "bad token");
            uint256 approveAmount = forceCloseApprovalAmount == type(uint256).max ? amount : forceCloseApprovalAmount;
            LOAN_ASSET.approve(ADAPTER, 0);
            LOAN_ASSET.approve(ADAPTER, approveAmount);
            return;
        }

        revert("bad phase");
    }
}
