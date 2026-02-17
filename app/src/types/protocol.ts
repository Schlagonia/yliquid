import type { Address } from "viem";

export type OptionalAddress = Address | undefined;

export type ContractsConfig = {
  yearnVault: OptionalAddress;
  yearnAprOracle: OptionalAddress;
  yLiquidMarket: OptionalAddress;
  positionNft: OptionalAddress;
  wstEthAdapter: OptionalAddress;
  aaveReceiver: OptionalAddress;
  aavePool: OptionalAddress;
  aaveDataProvider: OptionalAddress;
  lidoWithdrawalQueue: OptionalAddress;
};

export type TokensConfig = {
  weth: OptionalAddress;
  wstEth: OptionalAddress;
  aWstEth: OptionalAddress;
};

export type AdapterOption = {
  id: string;
  label: string;
  adapter: OptionalAddress;
  receiver: OptionalAddress;
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

export type MarketPositionTuple = readonly [Address, Address, Address, bigint, bigint, bigint, bigint, bigint];
