import { getAddress, isAddress, type Address, type Hex } from "viem";

const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";
const DEFAULT_LIDO_WITHDRAWAL_QUEUE = "0x889edC2eDab5f40e902b864aD4d7AdE8E412F9B1";
const DEFAULT_ETHERFI_WITHDRAW_REQUEST_NFT = "0x7d5706f6ef3F89B3951E23e557CDFBC3239D4E2c";
const DEFAULT_YEARN_APR_ORACLE = "0x1981AD9F44F2EA9aDd2dC4AD7D075c102C70aF92";
const DEFAULT_MORPHO_WSTETH_WETH_MARKET_ID =
  "0xb8fc70e82bc5bb53e773626fcc6a23f7eefa036918d7ef216ecfb1950a94a85e";
const DEFAULT_MORPHO_WEETH_WETH_MARKET_ID =
  "0x37e7484d642d90f14451f1910ba4b7b8e4c3ccdd0ec28f8b2bdb35479e472ba7";

const toAddress = (value: string | undefined): Address | undefined => {
  if (!value) return undefined;
  const normalized = value.trim();
  if (normalized.toLowerCase() === ZERO_ADDRESS) return undefined;
  if (!isAddress(normalized, { strict: false })) return undefined;
  return getAddress(normalized);
};

const toChainId = (value: string | undefined): number => {
  const chainId = Number(value ?? "1");
  if (!Number.isInteger(chainId) || chainId <= 0) return 1;
  return chainId;
};

const toBytes32 = (value: string | undefined): Hex | undefined => {
  if (!value) return undefined;
  if (!/^0x[0-9a-fA-F]{64}$/.test(value)) return undefined;
  return value as Hex;
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
    weEthAdapter: toAddress(import.meta.env.VITE_YLIQUID_WEETH_ADAPTER),
    aaveReceiver: toAddress(import.meta.env.VITE_AAVE_GENERIC_RECEIVER),
    morphoReceiver: toAddress(import.meta.env.VITE_MORPHO_GENERIC_RECEIVER),
    aavePool: toAddress(import.meta.env.VITE_AAVE_POOL),
    aaveDataProvider: toAddress(import.meta.env.VITE_AAVE_DATA_PROVIDER),
    morpho: toAddress(import.meta.env.VITE_MORPHO),
    morphoWstEthMarketId:
      toBytes32(import.meta.env.VITE_MORPHO_WSTETH_MARKET_ID) ??
      toBytes32(DEFAULT_MORPHO_WSTETH_WETH_MARKET_ID),
    morphoWeEthMarketId:
      toBytes32(import.meta.env.VITE_MORPHO_WEETH_MARKET_ID) ??
      toBytes32(import.meta.env.VITE_MORPHO_MARKET_ID) ??
      toBytes32(DEFAULT_MORPHO_WEETH_WETH_MARKET_ID),
    lidoWithdrawalQueue:
      toAddress(import.meta.env.VITE_LIDO_WITHDRAWAL_QUEUE) ??
      toAddress(DEFAULT_LIDO_WITHDRAWAL_QUEUE),
    etherFiWithdrawRequestNft:
      toAddress(import.meta.env.VITE_ETHERFI_WITHDRAW_REQUEST_NFT) ??
      toAddress(DEFAULT_ETHERFI_WITHDRAW_REQUEST_NFT),
  },
  tokens: {
    weth: toAddress(import.meta.env.VITE_WETH),
    wstEth: toAddress(import.meta.env.VITE_WSTETH),
    weEth: toAddress(import.meta.env.VITE_WEETH),
    aWstEth: toAddress(import.meta.env.VITE_AWSTETH),
  },
};
