# AGENTS.md

## Project Snapshot
- Repo: `yLiquid`
- Domain: non-atomic leverage bridge on top of Yearn V3 vault mechanics.
- Active focus: `WETH` lending with unwind/cooldown adapter routes (`wstETH`, `weETH`, `sUSDe`).

## Current Architecture
- `src/YLiquidMarket.sol`
  - Core lifecycle: open, settle, force-close.
  - Yearn debt-shifting path: idle strategy <-> market strategy via `update_debt`.
- `src/YLiquidRateModel.sol`
  - Rate = `base + riskPremium + overduePremium`.
  - `baseRateBps`, `overdueGraceSeconds`, and `overdueStepBps` are governance-settable.
- `src/adapters/SUSDeAdapter.sol`
  - sUSDe cooldown adapter.
- `src/adapters/WstETHUnwindAdapter.sol`
  - wstETH unwind adapter.
- `src/adapters/WeETHUnwindAdapter.sol`
  - weETH unwind adapter (Ether.fi queue path).
- `src/receivers/AaveGenericReceiver.sol`
  - Stateless callback receiver for owner-backed Aave positions.
- `src/receivers/MorphoGenericReceiver.sol`
  - Stateless callback receiver for owner-backed Morpho positions.
- `src/interfaces/IYLiquidAdapter.sol`
  - Single adapter interface for execution + position view + standardized events.

## Hard Constraints (Do Not Drift)
- Use timestamps for timing logic, not block numbers.
- `IYLiquidAdapterCallbackReceiver` callback signature does **not** include `tokenId`.
- `IYLiquidAdapter` is the only adapter UI/execution interface; do not reintroduce `IYLiquidAdapterUI`.
- Adapter events remain standardized only (`PositionOpened`, `PositionClosed`) with fields:
  - `asset`, `amount`, `collateralAsset`, `collateralAmount`.
- Keep `PositionView` slim:
  - keep `referenceId` as a single numeric field.
  - no `receiver`, `settlementAsset`, `expectedSettlementAmount`, or `expectedSettlementTime`.
- Position ownership is tracked by `YLiquidPositionNFT`; do not reintroduce owner storage in market position state.
- `AaveGenericReceiver` rules:
  - no mutable runtime state variables;
  - owner is provided in callback payload (not constructor-bound);
  - repay rate mode is fixed in code (`2`).
- `MorphoGenericReceiver` rules:
  - no mutable runtime state variables;
  - owner is provided in callback payload (not constructor-bound);
  - owner authorization to receiver must be checked before collateral withdraw.
- Min-rate guardrails:
  - adapter constructor and setter min-rate checks use `> 1e18`.
- Keep logic minimal and deterministic; no unnecessary complexity.

## Removed/Deprecated Components
- Removed and should stay removed unless explicitly requested:
  - `YLiquidLPWrapper`
  - `YLiquidDepositLimitModule`
  - `YLiquidTypes`
  - `IYLiquidAdapterUI`
  - `YLiquidFactory`
  - `AaveLeverageAdapter`
  - `MorphoLeverageAdapter`
  - old Morpho/Aave syrup tests and related mocks

## Test Map
- Unit:
  - `test/YLiquidRateModel.t.sol`
  - `test/MorphoGenericReceiver.t.sol`
- Mainnet fork:
  - `test/fork/YLiquidWstETHAaveAdapter.t.sol`
  - `test/fork/YLiquidSUSDeAdapter.t.sol`
  - `test/fork/AaveGenericReceiverWstETH.t.sol`
  - `test/fork/YLiquidWeETHMorphoReceiver.t.sol`

Run examples:
```bash
forge build
forge test
forge test --match-path test/MorphoGenericReceiver.t.sol
ETH_RPC_URL=<rpc> forge test --match-path test/fork/YLiquidWstETHAaveAdapter.t.sol -vv
ETH_RPC_URL=<rpc> forge test --match-path test/fork/YLiquidSUSDeAdapter.t.sol -vv
ETH_RPC_URL=<rpc> forge test --match-path test/fork/AaveGenericReceiverWstETH.t.sol -vv
ETH_RPC_URL=<rpc> forge test --match-path test/fork/YLiquidWeETHMorphoReceiver.t.sol -vv
```

## Foundry/Env Notes
- `foundry.toml` uses `evm_version = "cancun"`.
- Deploy script: `script/DeployYLiquid.s.sol`
  - network input still comes from `--rpc-url` and `--private-key` at runtime.
  - market/rate/adapter parameters are set directly in script constants.
  - supports optional wiring for `SUSDeAdapter`, `WstETHUnwindAdapter`, `AaveGenericReceiver`, `WeETHUnwindAdapter`, and `MorphoGenericReceiver`.
  - current defaults in script constants:
    - `SUSDE_ADDRESS = address(0)` (sUSDe path disabled by default).
    - `WSTETH_ADDRESS`, `AAVE_POOL`, `WEETH_ADDRESS`, and `MORPHO` are non-zero (paths enabled by default).
    - `IDLE_STRATEGY` is configured to a non-zero address.

## Working Rule
- If requirements are ambiguous, ask for target behavior and request relevant reference code/contracts before implementing.
