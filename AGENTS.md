# AGENTS.md

## Project Snapshot
- Repo: `yLiquid`
- Domain: non-atomic leverage bridge on top of Yearn V3 vault mechanics.
- Active focus: `WETH/wstETH` unwind flow and `sUSDe` cooldown flow.

## Current Architecture
- `src/YLiquidMarket.sol`
  - Core lifecycle: open, settle, force-close.
  - Yearn debt-shifting path: idle strategy <-> market strategy via `update_debt`.
- `src/YLiquidRateModel.sol`
  - Rate = `base + riskPremium + overduePremium`.
  - No utilization-based adjustment.
- `src/YLiquidLPWrapper.sol`
  - Wrapper around ERC4626 vault flow with timestamp cooldown logic.
- `src/YLiquidDepositLimitModule.sol`
  - Deposit-limit guard module (wrapper-only pattern).
- `src/adapters/SUSDeAdapter.sol`
  - sUSDe cooldown adapter.
- `src/adapters/WstETHUnwindAdapter.sol`
  - wstETH unwind adapter.
- `src/receivers/AaveGenericReceiver.sol`
  - Stateless callback receiver for owner-backed Aave positions.

## Hard Constraints (Do Not Drift)
- Use timestamps for timing logic, not block numbers.
- `IYLiquidAdapterCallbackReceiver` callback signature does **not** include `tokenId`.
- `AaveGenericReceiver` rules:
  - no mutable runtime state variables;
  - owner is provided in callback payload (not constructor-bound);
  - repay rate mode is fixed in code (`2`).
- Keep logic minimal and deterministic; no unnecessary complexity.

## Removed/Deprecated Components
- Removed and should stay removed unless explicitly requested:
  - `YLiquidFactory`
  - `AaveLeverageAdapter`
  - `MorphoLeverageAdapter`
  - old Morpho/Aave syrup tests and related mocks

## Test Map
- Unit:
  - `test/YLiquidRateModel.t.sol`
  - `test/YLiquidLPWrapper.t.sol`
  - `test/YLiquidDepositLimitModule.t.sol`
- Mainnet fork:
  - `test/fork/YLiquidWstETHAaveAdapter.t.sol`
  - `test/fork/YLiquidSUSDeAdapter.t.sol`
  - `test/fork/AaveGenericReceiverWstETH.t.sol`

Run examples:
```bash
forge build
forge test
ETH_RPC_URL=<rpc> forge test --match-path test/fork/YLiquidWstETHAaveAdapter.t.sol -vv
ETH_RPC_URL=<rpc> forge test --match-path test/fork/YLiquidSUSDeAdapter.t.sol -vv
ETH_RPC_URL=<rpc> forge test --match-path test/fork/AaveGenericReceiverWstETH.t.sol -vv
```

## Foundry/Env Notes
- `foundry.toml` uses `evm_version = "shanghai"`.
- Deploy script: `script/DeployYLiquid.s.sol`
  - network input still comes from `--rpc-url` and `--private-key` at runtime.
  - market/rate/adapter parameters are set directly in script constants.

## Working Rule
- If requirements are ambiguous, ask for target behavior and request relevant reference code/contracts before implementing.
