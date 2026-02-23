# yLiquid App (Initial Setup)

Lightweight dApp scaffold for two user lanes:
- Depositors: deposit/withdraw ERC4626 Yearn vault shares.
- Leveragers: open and settle yLiquid unwind positions:
  - Aave borrower unwind (`wstETH -> WETH` via `AaveGenericReceiver`)
  - Aave borrower unwind (`weETH -> WETH` via `AaveGenericReceiver`)
  - Morpho borrower unwind (`wstETH -> WETH` via `MorphoGenericReceiver`)
  - Morpho borrower unwind (`weETH -> WETH` via `MorphoGenericReceiver`)

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
- `VITE_YLIQUID_WEETH_ADAPTER`
- `VITE_AAVE_GENERIC_RECEIVER`
- `VITE_MORPHO_GENERIC_RECEIVER`
- `VITE_AAVE_POOL`
- `VITE_MORPHO`
- `VITE_MORPHO_WSTETH_MARKET_ID`
- `VITE_MORPHO_WEETH_MARKET_ID`

Optional:
- `VITE_AWSTETH` (auto-resolved from Aave data provider if unset)
- `VITE_AAVE_DATA_PROVIDER` (auto-resolved from pool address provider if unset)
- `VITE_LIDO_WITHDRAWAL_QUEUE` (defaults to mainnet queue)
- `VITE_ETHERFI_WITHDRAW_REQUEST_NFT` (defaults to mainnet request NFT)
- `VITE_WEETH` (defaults to none; set for Morpho weETH route)
- `VITE_MORPHO_MARKET_ID` (legacy fallback for weETH market id)

## Notes

- Route-aware callback encoding:
  - Aave route encodes `AaveGenericReceiver.OpenCallbackData`.
  - Morpho route encodes `MorphoGenericReceiver.OpenCallbackData` with selected market params.
- Aave flow enforces `Approve aToken -> Open Position`.
- Morpho flow enforces `setAuthorization(receiver, true) -> Open Position` (auths, not allowances).
- Principal is capped to current `market.availableLiquidity`.
- Tracked positions read Lido queue status for wstETH requests and EtherFi request status for weETH before enabling settlement.
