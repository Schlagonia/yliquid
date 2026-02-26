# yLiquid Agent Integration Guide

This is the shortest path for an agent to integrate with yLiquid as a borrower.
Focus: `WstETHUnwindAdapter` and `WeETHUnwindAdapter` using your own receiver contract.

## 1) What You Are Integrating

yLiquid lets you borrow `WETH` from `YLiquidMarket` against adapter-specific collateral flows.

For unwind adapters:
- Open:
  - market sends `WETH` principal to your receiver
  - your receiver prepares collateral and approves adapter
  - adapter pulls collateral into its proxy and starts async withdrawal request
- Settle:
  - adapter claims underlying `ETH`, wraps to `WETH`, repays market
  - surplus goes to position owner

Core entrypoints:
- `YLiquidMarket.openPosition(principal, adapter, receiver, collateralToken, collateralAmount, callbackData)`
- `YLiquidMarket.settleAndRepay(tokenId, receiver, callbackData)`
- `YLiquidMarket.forceClose(tokenId, receiver, callbackData)` (management only)

## 2) Strategy Shape (Discount Capture)

The strategy is simple:
1. Borrow `WETH`.
2. Buy collateral exposure below par (for example `stETH`/`wstETH` or `eETH`/`weETH` dislocation).
3. Post required collateral token to adapter (`wstETH` or `weETH`).
4. Adapter queues redemption to underlying `ETH`.
5. When claimable, settle and repay debt.
6. Keep spread: `claimed ETH (as WETH) - debt owed - fees/slippage`.

If your edge is fake, the position becomes a slow liquidation cosplay. Price your borrow clock honestly.

## 3) Contracts and Invariants You Must Respect

- Receiver must implement `IYLiquidAdapterCallbackReceiver`.
- Receiver must trust only the expected adapter:
  - `require(msg.sender == ADAPTER, "not adapter");`
- Unwind adapters require non-zero receiver on open.
- Supported collateral tokens:
  - `WstETHUnwindAdapter`: `collateralToken == WSTETH`
  - `WeETHUnwindAdapter`: `collateralToken == WEETH`
- Min-rate checks happen inside adapters (`minRateWad > 1e18`).
- `settleAndRepay` succeeds only if full owed amount reaches market.
  - If claim < owed, settle reverts (`insolvent settle` in market).
- `forceClose` can happen only by market management and only after delay.

## 4) Receiver Contract: Minimal Template

Your receiver only needs to handle open callback (`phase == 1`) for these adapters.

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IYLiquidAdapterCallbackReceiver} from "../src/interfaces/IYLiquidAdapterCallbackReceiver.sol";
import {IwstETH} from "../src/interfaces/IwstETH.sol";
import {IWeETH} from "../src/interfaces/IWeETH.sol";

contract CooldownReceiver is IYLiquidAdapterCallbackReceiver {
    uint8 internal constant PHASE_OPEN = 1;

    address public immutable ADAPTER;
    address public immutable OWNER;
    IERC20 public immutable WETH;
    IERC20 public immutable STETH;
    IERC20 public immutable EETH;
    IwstETH public immutable WSTETH;
    IWeETH public immutable WEETH;

    enum Mode {
        WstEth,
        WeEth
    }

    struct OpenData {
        Mode mode;
        uint256 minOut;
        bytes swapData; // route instructions for your DEX executor
    }

    constructor(
        address adapter,
        address owner,
        address weth,
        address steth,
        address eeth,
        address wsteth,
        address weeth
    ) {
        ADAPTER = adapter;
        OWNER = owner;
        WETH = IERC20(weth);
        STETH = IERC20(steth);
        EETH = IERC20(eeth);
        WSTETH = IwstETH(wsteth);
        WEETH = IWeETH(weeth);
    }

    function onYLiquidAdapterCallback(
        uint8 phase,
        address owner,
        address token,
        uint256 amount,
        uint256 collateralAmount,
        bytes calldata data
    ) external override {
        require(msg.sender == ADAPTER, "not adapter");
        require(phase == PHASE_OPEN, "bad phase");
        require(owner == OWNER, "bad owner");
        require(token == address(WETH), "bad token");
        require(amount > 0, "zero amount");

        OpenData memory od = abi.decode(data, (OpenData));

        if (od.mode == Mode.WstEth) {
            // 1) swap WETH -> stETH (your venue logic, using od.swapData)
            // 2) wrap stETH -> wstETH
            uint256 wstBal = WSTETH.balanceOf(address(this));
            require(wstBal >= collateralAmount && wstBal >= od.minOut, "insufficient wstETH");
            IERC20(address(WSTETH)).approve(ADAPTER, 0);
            IERC20(address(WSTETH)).approve(ADAPTER, collateralAmount);
            return;
        }

        // Mode.WeEth:
        // 1) swap WETH -> eETH or weETH (your venue logic)
        // 2) if eETH path, wrap eETH -> weETH
        uint256 weBal = WEETH.balanceOf(address(this));
        require(weBal >= collateralAmount && weBal >= od.minOut, "insufficient weETH");
        IERC20(address(WEETH)).approve(ADAPTER, 0);
        IERC20(address(WEETH)).approve(ADAPTER, collateralAmount);
    }
}
```

## 5) Open Flow (Agent Runbook)

1. Pick adapter:
   - `WstETHUnwindAdapter` for Lido queue path
   - `WeETHUnwindAdapter` for EtherFi queue path
2. Estimate `collateralAmount` needed for your principal and expected slippage.
3. Build receiver `callbackData` (your `OpenData` struct).
4. Call:

```solidity
tokenId = market.openPosition(
    principal,
    adapter,
    receiver,
    collateralToken,   // WSTETH or WEETH
    collateralAmount,
    callbackData
);
```

5. Store `tokenId` and read:
   - `market.positions(tokenId)` for timing and state
   - `adapter.positionView(tokenId).referenceId` for queue request id

## 6) Settle Flow

When queue withdrawal is claimable:

```solidity
market.settleAndRepay(tokenId, address(0), bytes(""));
```

For current unwind adapters, settle receiver/callback payload are ignored.

## 7) PnL and Risk Controls

Track this before opening:
- projected `amountOwed` at expected settle time
- expected underlying claim from queued redemption
- all swap/MEV/gas costs

Basic edge check:
- open only if `expectedClaim - expectedDebt - totalCosts > minProfit`

Failure modes:
- collateral bought too expensively -> no spread
- queue delay extends hold time -> debt grows
- claimable amount < debt -> settle fails, management can later force-close

## 8) Mainnet Constants (Hardcoded in Adapters)

- `WETH`: `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`
- `WSTETH`: `0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0`
- `STETH`: `0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84`
- `Lido Withdrawal Queue`: `0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1`
- `WEETH`: `0xCd5fE23C85820F7B72D0926FC9b05b43E359b7ee`
- `EETH`: `0x35fA164735182de50811E8e2E824cFb9B6118ac2`
- `EtherFi Liquidity Pool`: `0x308861A430be4cce5502d0A12724771Fc6DaF216`
- `EtherFi Withdraw Request NFT`: `0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c`

## 9) Integration Checklist

- [ ] receiver validates `msg.sender == adapter`
- [ ] receiver validates `token == WETH` and `phase == 1`
- [ ] receiver always grants adapter collateral allowance after conversion
- [ ] bot records `tokenId`, expected end time, and adapter `referenceId`
- [ ] bot retries settle only when claim likely available
- [ ] bot monitors debt growth with `market.quoteDebt(tokenId)`
- [ ] bot has kill-switch if spread collapses
