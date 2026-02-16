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
    id: "wsteth-aave-unwind",
    label: "wstETH -> WETH (Aave Receiver)",
    adapter: env.contracts.wstEthAdapter,
    receiver: env.contracts.aaveReceiver,
  },
];

export const requiredAddresses = [
  ["Yearn Vault", protocolConfig.contracts.yearnVault],
  ["yLiquid Market", protocolConfig.contracts.yLiquidMarket],
  ["Position NFT", protocolConfig.contracts.positionNft],
  ["wstETH Adapter", protocolConfig.contracts.wstEthAdapter],
  ["Aave Receiver", protocolConfig.contracts.aaveReceiver],
  ["Aave Pool", protocolConfig.contracts.aavePool],
  ["Lido Withdrawal Queue", protocolConfig.contracts.lidoWithdrawalQueue],
  ["wstETH", protocolConfig.tokens.wstEth],
] as const;
