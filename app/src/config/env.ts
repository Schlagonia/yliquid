import { isAddress, type Address } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEFAULT_LIDO_WITHDRAWAL_QUEUE = "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1";
const DEFAULT_YEARN_APR_ORACLE = "0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92";

const toAddress = (value: string | undefined): Address | undefined => {
  if (!value) return undefined;
  if (value.toLowerCase() === ZERO_ADDRESS) return undefined;
  if (!isAddress(value)) return undefined;
  return value;
};

const toChainId = (value: string | undefined): number => {
  const chainId = Number(value ?? "1");
  if (!Number.isInteger(chainId) || chainId <= 0) return 1;
  return chainId;
};

export const env = {
  chainId: toChainId(import.meta.env.VITE_CHAIN_ID),
  rpcUrlMainnet: import.meta.env.VITE_RPC_URL_MAINNET || "https://ethereum-rpc.publicnode.com",
  contracts: {
    yearnVault: toAddress(import.meta.env.VITE_YEARN_VAULT),
    yearnAprOracle:
      toAddress(import.meta.env.VITE_YEARN_APR_ORACLE) ??
      toAddress(DEFAULT_YEARN_APR_ORACLE),
    yLiquidMarket: toAddress(import.meta.env.VITE_YLIQUID_MARKET),
    positionNft: toAddress(import.meta.env.VITE_YLIQUID_POSITION_NFT),
    wstEthAdapter: toAddress(import.meta.env.VITE_YLIQUID_WSTETH_ADAPTER),
    aaveReceiver: toAddress(import.meta.env.VITE_AAVE_GENERIC_RECEIVER),
    aavePool: toAddress(import.meta.env.VITE_AAVE_POOL),
    aaveDataProvider: toAddress(import.meta.env.VITE_AAVE_DATA_PROVIDER),
    lidoWithdrawalQueue:
      toAddress(import.meta.env.VITE_LIDO_WITHDRAWAL_QUEUE) ??
      toAddress(DEFAULT_LIDO_WITHDRAWAL_QUEUE),
  },
  tokens: {
    weth: toAddress(import.meta.env.VITE_WETH),
    wstEth: toAddress(import.meta.env.VITE_WSTETH),
    aWstEth: toAddress(import.meta.env.VITE_AWSTETH),
  },
};
