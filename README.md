# yLiquid

yLiquid is a non-atomic leverage bridge built on top of Yearn V3 vault mechanics.
LP funds are deployed via Yearn-facing flows. Borrowers use whitelisted adapter paths, then repay with interest before release.

## Current Status
- Active project context and constraints live in `AGENTS.md`.
- Core contracts are under `src/`.
- Unit and fork tests are under `test/`.
- Deployment script is `script/DeployYLiquid.s.sol`.

Recent refactors already applied:
- Removed legacy wrapper/limit modules:
  - `src/YLiquidLPWrapper.sol`
  - `src/YLiquidDepositLimitModule.sol`
- Removed type/UI split artifacts:
  - `src/YLiquidTypes.sol`
  - `src/interfaces/IYLiquidAdapterUI.sol`
- `IYLiquidAdapter` is now the single adapter execution + view interface.
- Standard adapter events are simplified (`PositionOpened` / `PositionClosed`).
- `PositionView` now excludes settlement-specific fields.
- Added `src/adapters/WeETHUnwindAdapter.sol`.
- Added `src/receivers/MorphoGenericReceiver.sol`.

## Contract Layout
- `src/YLiquidMarket.sol`: core lifecycle, pricing, solvency checks, governance controls.
  - Includes Yearn V3 debt-manager style strategy rebalancing via `update_debt` (`idle -> market -> idle`).
- `src/YLiquidRateModel.sol`: base + risk premium + overdue rate model with governance setters.
- `src/YLiquidPositionNFT.sol`: ERC721 position ownership.
- `src/adapters/SUSDeAdapter.sol`: sUSDe cooldown adapter.
- `src/adapters/WstETHUnwindAdapter.sol`: wstETH unwind adapter.
- `src/adapters/WeETHUnwindAdapter.sol`: weETH unwind adapter (Ether.fi withdraw queue path).
- `src/receivers/AaveGenericReceiver.sol`: stateless generic Aave callback receiver for owner-backed positions.
- `src/receivers/MorphoGenericReceiver.sol`: stateless generic Morpho callback receiver for owner-backed positions.
- `src/interfaces/IYLiquidAdapter.sol`: shared adapter execution + UI schema (`execute*`, `positionView`, `PositionOpened`, `PositionClosed`).
- `src/interfaces/*`: lean protocol interfaces.

## Design Docs
- `AGENTS.md`: current scope, architecture, and hard constraints.
- `docs/reference-map.md`: upstream pattern mapping.
- `docs/mainnet-addresses.example.md`: deployment config checklist.

## Development

Build:

```bash
forge build
```

Test:

```bash
forge test
```

Targeted unit test:

```bash
forge test --match-path test/MorphoGenericReceiver.t.sol
```

Mainnet fork tests:

```bash
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/YLiquidWstETHAaveAdapter.t.sol -vv
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/YLiquidSUSDeAdapter.t.sol -vv
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/AaveGenericReceiverWstETH.t.sol -vv
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/YLiquidWeETHMorphoReceiver.t.sol -vv
```

## Deployment
Edit `script/DeployYLiquid.s.sol` config constants first (factory/existing vault, addresses, rates, adapter toggles).

Current script supports market + optional:
- `SUSDeAdapter`
- `WstETHUnwindAdapter`
- `AaveGenericReceiver`
- `WeETHUnwindAdapter`
- `MorphoGenericReceiver`

Current default constants in the script:
- `SUSDE_ADDRESS = address(0)` (disabled by default).
- `WSTETH_ADDRESS`, `AAVE_POOL`, `WEETH_ADDRESS`, and `MORPHO` are non-zero (enabled by default).
- `IDLE_STRATEGY` is non-zero.

Then deploy:

```bash
forge script script/DeployYLiquid.s.sol:DeployYLiquid \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Notes
This repo is in active build phase.
