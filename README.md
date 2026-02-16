# yLiquid

yLiquid is a non-atomic leverage bridge built on top of Yearn V3 vault mechanics.
LP funds are deployed via Yearn-facing flows. Borrowers use whitelisted adapter paths, then repay with interest before release.

## Current Status
- Active project context and constraints captured in `AGENTS.md`.
- Core contracts implemented under `src/`.
- Unit and fork tests implemented under `test/`.
- Deployment script implemented in `script/DeployYLiquid.s.sol`.

## Contract Layout
- `src/YLiquidMarket.sol`: core lifecycle, pricing, solvency checks, governance controls.
  - Includes Yearn V3 debt-manager style strategy rebalancing via `update_debt` (`idle -> market -> idle`).
- `src/YLiquidLPWrapper.sol`: cooldown-gated LP wrapper around ERC4626 vault flow using timestamp locks.
- `src/YLiquidDepositLimitModule.sol`: wrapper-only Yearn deposit limit module.
- `src/YLiquidRateModel.sol`: base + risk premium + overdue rate model.
- `src/YLiquidPositionNFT.sol`: ERC721 position ownership.
- `src/adapters/SUSDeAdapter.sol`: sUSDe cooldown adapter.
- `src/adapters/WstETHUnwindAdapter.sol`: wstETH unwind adapter.
- `src/receivers/AaveGenericReceiver.sol`: stateless generic Aave callback receiver for owner-backed positions.
- `src/interfaces/IYLiquidAdapterUI.sol`: shared adapter UI schema (`positionView`, `StandardizedPositionOpened`, `StandardizedPositionClosed`).
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

Mainnet fork tests (wstETH and sUSDe flows):

```bash
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/YLiquidWstETHAaveAdapter.t.sol -vv
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/YLiquidSUSDeAdapter.t.sol -vv
ETH_RPC_URL=<your_rpc_url> forge test --match-path test/fork/AaveGenericReceiverWstETH.t.sol -vv
```

## Deployment
Edit `script/DeployYLiquid.s.sol` config constants first (factory/existing vault, addresses, rates, adapter toggles).

Then deploy:

```bash
forge script script/DeployYLiquid.s.sol:DeployYLiquid \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

## Notes
This repo is in active build phase.
