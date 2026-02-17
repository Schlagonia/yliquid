import { env } from "./env";
import type { AdapterOption } from "../types/protocol";

export const protocolConfig = {
  chainId: env.chainId,
  rpcUrlMainnet: env.rpcUrlMainnet,
  contracts: env.contracts,
  tokens: env.tokens,
};

export const adapterOptions: AdapterOption[] = [
  {
    id: "aave-wsteth",
    label: "Aave Position -> wstETH Unwind",
    venue: "aave",
    adapter: env.contracts.wstEthAdapter,
    receiver: env.contracts.aaveReceiver,
    collateralAsset: env.tokens.wstEth,
    collateralSymbol: "wstETH",
  },
  {
    id: "aave-weeth",
    label: "Aave Position -> weETH Unwind",
    venue: "aave",
    adapter: env.contracts.weEthAdapter,
    receiver: env.contracts.aaveReceiver,
    collateralAsset: env.tokens.weEth,
    collateralSymbol: "weETH",
  },
  {
    id: "morpho-wsteth",
    label: "Morpho Position -> wstETH Unwind",
    venue: "morpho",
    adapter: env.contracts.wstEthAdapter,
    receiver: env.contracts.morphoReceiver,
    collateralAsset: env.tokens.wstEth,
    collateralSymbol: "wstETH",
    morphoMarketId: env.contracts.morphoWstEthMarketId,
  },
  {
    id: "morpho-weeth",
    label: "Morpho Position -> weETH Unwind",
    venue: "morpho",
    adapter: env.contracts.weEthAdapter,
    receiver: env.contracts.morphoReceiver,
    collateralAsset: env.tokens.weEth,
    collateralSymbol: "weETH",
    morphoMarketId: env.contracts.morphoWeEthMarketId,
  },
];

export const requiredAddresses = [
  ["Yearn Vault", protocolConfig.contracts.yearnVault],
  ["yLiquid Market", protocolConfig.contracts.yLiquidMarket],
  ["Position NFT", protocolConfig.contracts.positionNft],
  ["wstETH Adapter", protocolConfig.contracts.wstEthAdapter],
  ["weETH Adapter", protocolConfig.contracts.weEthAdapter],
  ["Aave Receiver", protocolConfig.contracts.aaveReceiver],
  ["Morpho Receiver", protocolConfig.contracts.morphoReceiver],
  ["Aave Pool", protocolConfig.contracts.aavePool],
  ["Morpho", protocolConfig.contracts.morpho],
  ["Lido Withdrawal Queue", protocolConfig.contracts.lidoWithdrawalQueue],
  ["EtherFi Withdraw Request NFT", protocolConfig.contracts.etherFiWithdrawRequestNft],
  ["wstETH", protocolConfig.tokens.wstEth],
  ["weETH", protocolConfig.tokens.weEth],
] as const;
