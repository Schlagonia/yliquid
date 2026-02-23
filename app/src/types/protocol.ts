import type { Address, Hex } from "viem";

export type OptionalAddress = Address | undefined;
export type OptionalHex = Hex | undefined;

export type LeverageVenue = "aave" | "morpho";

export type ContractsConfig = {
  yearnVault: OptionalAddress;
  yearnAprOracle: OptionalAddress;
  yLiquidMarket: OptionalAddress;
  positionNft: OptionalAddress;
  wstEthAdapter: OptionalAddress;
  weEthAdapter: OptionalAddress;
  aaveReceiver: OptionalAddress;
  morphoReceiver: OptionalAddress;
  aavePool: OptionalAddress;
  aaveDataProvider: OptionalAddress;
  morpho: OptionalAddress;
  morphoWstEthMarketId: OptionalHex;
  morphoWeEthMarketId: OptionalHex;
  lidoWithdrawalQueue: OptionalAddress;
  etherFiWithdrawRequestNft: OptionalAddress;
};

export type TokensConfig = {
  weth: OptionalAddress;
  wstEth: OptionalAddress;
  weEth: OptionalAddress;
  aWstEth: OptionalAddress;
};

export type AdapterOption = {
  id: string;
  label: string;
  venue: LeverageVenue;
  adapter: OptionalAddress;
  receiver: OptionalAddress;
  collateralAsset: OptionalAddress;
  collateralSymbol: string;
  morphoMarketId?: OptionalHex;
};

export type AdapterPositionView = {
  owner: Address;
  proxy: Address;
  loanAsset: Address;
  collateralAsset: Address;
  principal: bigint;
  collateralAmount: bigint;
  expectedUnlockTime: bigint;
  referenceId: bigint;
  status: bigint;
};

export type MarketPositionTuple = readonly [Address, Address, bigint, bigint, bigint, bigint, bigint];

export type MorphoMarketParams = {
  loanToken: Address;
  collateralToken: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
};

export type MorphoPosition = {
  supplyShares: bigint;
  borrowShares: bigint;
  collateral: bigint;
};

export type MorphoMarket = {
  totalSupplyAssets: bigint;
  totalSupplyShares: bigint;
  totalBorrowAssets: bigint;
  totalBorrowShares: bigint;
  lastUpdate: bigint;
  fee: bigint;
};
