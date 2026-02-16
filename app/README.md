# yLiquid App (Initial Setup)

Lightweight dApp scaffold for two user lanes:
- Depositors: deposit/withdraw ERC4626 Yearn vault shares.
- Leveragers: open and settle yLiquid unwind positions (wstETH -> WETH via Aave receiver).

## Start

```bash
cd app
cp .env.example .env
npm install
npm run dev
```

## Required .env values

Set deployed addresses before writing transactions:
- `VITE_YEARN_VAULT`
- `VITE_YLIQUID_MARKET`
- `VITE_YLIQUID_POSITION_NFT`
- `VITE_YLIQUID_WSTETH_ADAPTER`
- `VITE_AAVE_GENERIC_RECEIVER`
- `VITE_AAVE_POOL`

Optional:
- `VITE_AWSTETH` (auto-resolved from Aave data provider if unset)
- `VITE_AAVE_DATA_PROVIDER` (auto-resolved from pool address provider if unset)
- `VITE_LIDO_WITHDRAWAL_QUEUE` (defaults to mainnet queue)

## Notes

- Current leverager flow is wired for the `WstETHUnwindAdapter` + `AaveGenericReceiver` callback shape.
- Leverager flow enforces `Approve aWstETH -> Open Position` and auto-builds collateral as 99% of wallet aWstETH.
- Principal is capped to current `market.availableLiquidity`.
- Tracked positions read Lido queue status on-chain and show when request is claimable.
- Adapter selection is structured to extend to additional adapters later.
