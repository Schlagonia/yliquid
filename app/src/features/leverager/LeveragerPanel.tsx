import { useEffect, useMemo, useState } from "react";
import {
  decodeEventLog,
  encodeAbiParameters,
  erc20Abi,
  formatUnits,
  getAddress,
  isAddress,
  parseAbiItem,
  zeroAddress,
  type Address,
  type Hex,
} from "viem";
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";

import { adapterOptions, protocolConfig } from "../../config/contracts";
import {
  aaveAddressesProviderAbi,
  aavePoolAbi,
  aaveProtocolDataProviderAbi,
} from "../../lib/abi/aaveAbi";
import { morphoAbi } from "../../lib/abi/morphoAbi";
import { yLiquidMarketAbi } from "../../lib/abi/yLiquidMarketAbi";
import { yLiquidPositionNftAbi } from "../../lib/abi/yLiquidPositionNftAbi";
import { yLiquidRateModelAbi } from "../../lib/abi/yLiquidRateModelAbi";
import { formatAmount, parseAmountInput, shortAddress } from "../../lib/format";
import { TrackedPositionCard } from "./TrackedPositionCard";
import type { MorphoMarket, MorphoMarketParams, MorphoPosition } from "../../types/protocol";

const STORAGE_KEY = "yliquid_tracked_token_ids";
const COLLATERAL_USAGE_BPS = 9_990n; // 99.9%
const BPS = 10_000n;
const LOG_SCAN_INITIAL_CHUNK = 250_000n;
const LOG_SCAN_MIN_CHUNK = 2_000n;
const MORPHO_VIRTUAL_SHARES = 1_000_000n;
const MORPHO_VIRTUAL_ASSETS = 1n;
const MORPHO_AUTH_TX_LABEL_ENABLE = "Authorize Morpho Receiver Authorization";
const MORPHO_AUTH_TX_LABEL_DISABLE = "Unset Morpho Receiver Authorization";
const POSITION_TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
);

const MORPHO_MARKET_PARAMS_COMPONENTS = [
  { name: "loanToken", type: "address" },
  { name: "collateralToken", type: "address" },
  { name: "oracle", type: "address" },
  { name: "irm", type: "address" },
  { name: "lltv", type: "uint256" },
] as const;

type ReserveTokensTuple = readonly [Address, Address, Address];

type BpsValue = bigint | number | undefined | null;

const normalizeBps = (value: BpsValue): bigint | undefined => {
  if (typeof value === "bigint") return value;
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return BigInt(Math.trunc(value));
  }
  return undefined;
};

const formatBpsAsPercent = (bps: BpsValue): string => {
  const normalized = normalizeBps(bps);
  if (normalized === undefined) return "N/A";
  const whole = normalized / 100n;
  const fraction = (normalized % 100n).toString().padStart(2, "0");
  return `${whole.toString()}.${fraction}% APR`;
};

const parseMarketIdInput = (value: string): Hex | undefined => {
  const normalized = value.trim();
  if (!/^0x[0-9a-fA-F]{64}$/.test(normalized)) return undefined;
  return normalized as Hex;
};

const toRecord = (value: unknown): Record<string, unknown> | undefined => {
  if (value && typeof value === "object") return value as Record<string, unknown>;
  return undefined;
};

const toBigInt = (value: unknown): bigint | undefined => {
  if (typeof value === "bigint") return value;
  return undefined;
};

const toAddressValue = (value: unknown): Address | undefined => {
  if (typeof value !== "string") return undefined;
  if (!isAddress(value, { strict: false })) return undefined;
  return value as Address;
};

const normalizeMorphoMarketParams = (value: unknown): MorphoMarketParams | undefined => {
  const tuple = Array.isArray(value) ? value : undefined;
  const record = toRecord(value);

  const loanToken = toAddressValue(record?.loanToken ?? tuple?.[0]);
  const collateralToken = toAddressValue(record?.collateralToken ?? tuple?.[1]);
  const oracle = toAddressValue(record?.oracle ?? tuple?.[2]);
  const irm = toAddressValue(record?.irm ?? tuple?.[3]);
  const lltv = toBigInt(record?.lltv ?? tuple?.[4]);

  if (!loanToken || !collateralToken || !oracle || !irm || lltv === undefined) return undefined;

  return {
    loanToken,
    collateralToken,
    oracle,
    irm,
    lltv,
  };
};

const normalizeMorphoPosition = (value: unknown): MorphoPosition | undefined => {
  const tuple = Array.isArray(value) ? value : undefined;
  const record = toRecord(value);

  const supplyShares = toBigInt(record?.supplyShares ?? tuple?.[0]);
  const borrowShares = toBigInt(record?.borrowShares ?? tuple?.[1]);
  const collateral = toBigInt(record?.collateral ?? tuple?.[2]);

  if (supplyShares === undefined || borrowShares === undefined || collateral === undefined) {
    return undefined;
  }

  return {
    supplyShares,
    borrowShares,
    collateral,
  };
};

const normalizeMorphoMarket = (value: unknown): MorphoMarket | undefined => {
  const tuple = Array.isArray(value) ? value : undefined;
  const record = toRecord(value);

  const totalSupplyAssets = toBigInt(record?.totalSupplyAssets ?? tuple?.[0]);
  const totalSupplyShares = toBigInt(record?.totalSupplyShares ?? tuple?.[1]);
  const totalBorrowAssets = toBigInt(record?.totalBorrowAssets ?? tuple?.[2]);
  const totalBorrowShares = toBigInt(record?.totalBorrowShares ?? tuple?.[3]);
  const lastUpdate = toBigInt(record?.lastUpdate ?? tuple?.[4]);
  const fee = toBigInt(record?.fee ?? tuple?.[5]);

  if (
    totalSupplyAssets === undefined ||
    totalSupplyShares === undefined ||
    totalBorrowAssets === undefined ||
    totalBorrowShares === undefined ||
    lastUpdate === undefined ||
    fee === undefined
  ) {
    return undefined;
  }

  return {
    totalSupplyAssets,
    totalSupplyShares,
    totalBorrowAssets,
    totalBorrowShares,
    lastUpdate,
    fee,
  };
};

const divUp = (numerator: bigint, denominator: bigint): bigint => {
  if (numerator === 0n) return 0n;
  return ((numerator - 1n) / denominator) + 1n;
};

const morphoBorrowSharesToAssetsUp = (
  shares: bigint,
  totalBorrowAssets: bigint,
  totalBorrowShares: bigint,
): bigint => {
  const adjustedAssets = totalBorrowAssets + MORPHO_VIRTUAL_ASSETS;
  const adjustedShares = totalBorrowShares + MORPHO_VIRTUAL_SHARES;
  return divUp(shares * adjustedAssets, adjustedShares);
};

export const LeveragerPanel = () => {
  const marketAddress = protocolConfig.contracts.yLiquidMarket;
  const safeMarket = marketAddress ?? zeroAddress;

  const aavePoolAddress = protocolConfig.contracts.aavePool;
  const morphoAddress = protocolConfig.contracts.morpho;

  const safeWeth = protocolConfig.tokens.weth ?? zeroAddress;

  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const walletAddress = address ?? zeroAddress;

  const [selectedAdapterId, setSelectedAdapterId] = useState(adapterOptions[0]?.id ?? "");
  const selectedAdapter =
    adapterOptions.find((adapter) => adapter.id === selectedAdapterId) ?? adapterOptions[0];
  const selectedAdapterAddress = selectedAdapter?.adapter;
  const safeSelectedAdapter = selectedAdapterAddress ?? zeroAddress;

  const isAaveRoute = selectedAdapter?.venue === "aave";
  const isMorphoRoute = selectedAdapter?.venue === "morpho";
  const defaultMorphoMarketId = selectedAdapter?.morphoMarketId;

  const [principalInput, setPrincipalInput] = useState("");
  const [collateralInput, setCollateralInput] = useState("");
  const [receiverInput, setReceiverInput] = useState<string>(selectedAdapter?.receiver ?? "");
  const [aTokenInput, setATokenInput] = useState<string>(protocolConfig.tokens.aWstEth ?? "");
  const [morphoMarketIdInput, setMorphoMarketIdInput] = useState<string>(
    defaultMorphoMarketId ?? "",
  );
  const [hasAutoBuiltInputs, setHasAutoBuiltInputs] = useState(false);

  const [tokenIdInput, setTokenIdInput] = useState("");
  const [trackedTokenIds, setTrackedTokenIds] = useState<number[]>([]);
  const [walletOpenTokenIds, setWalletOpenTokenIds] = useState<number[]>([]);
  const [isLoadingWalletPositions, setIsLoadingWalletPositions] = useState(false);
  const [walletPositionsError, setWalletPositionsError] = useState("");

  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const [txLabel, setTxLabel] = useState("");
  const [settlingTokenId, setSettlingTokenId] = useState<number | null>(null);
  const [errorText, setErrorText] = useState("");
  const [morphoAuthorizationOverride, setMorphoAuthorizationOverride] = useState<boolean | undefined>(
    undefined,
  );

  const { writeContractAsync, isPending: writePending } = useWriteContract();
  const {
    data: receipt,
    isLoading: txConfirming,
    isSuccess: txConfirmed,
  } = useWaitForTransactionReceipt({ hash: txHash });

  const normalizedReceiverInput = receiverInput.trim();
  const receiverAddress = isAddress(normalizedReceiverInput, { strict: false })
    ? (getAddress(normalizedReceiverInput) as Address)
    : undefined;
  const safeReceiver = receiverAddress ?? zeroAddress;

  const resolvedMorphoMarketId = parseMarketIdInput(morphoMarketIdInput);

  const { data: availableLiquidityData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "availableLiquidity",
    query: { enabled: Boolean(marketAddress) },
  });

  const { data: positionNftData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "POSITION_NFT",
    query: { enabled: Boolean(marketAddress) },
  });

  const { data: rateModelData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "rateModel",
    query: { enabled: Boolean(marketAddress) },
  });

  const rateModelAddress = rateModelData as Address | undefined;
  const safeRateModel = rateModelAddress ?? zeroAddress;

  const { data: baseRateBpsData } = useReadContract({
    address: safeRateModel,
    abi: yLiquidRateModelAbi,
    functionName: "baseRateBps",
    query: { enabled: Boolean(rateModelAddress) },
  });

  const { data: adapterRiskPremiumBpsData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "adapterRiskPremiumBps",
    args: [safeSelectedAdapter],
    query: { enabled: Boolean(marketAddress && selectedAdapterAddress) },
  });

  const { data: wethDecimalsData } = useReadContract({
    address: safeWeth,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(protocolConfig.tokens.weth) },
  });

  const selectedCollateralAsset = selectedAdapter?.collateralAsset;
  const safeSelectedCollateralAsset = selectedCollateralAsset ?? zeroAddress;

  // Aave route reads.
  const safeAavePool = aavePoolAddress ?? zeroAddress;
  const { data: aaveAddressesProviderData } = useReadContract({
    address: safeAavePool,
    abi: aavePoolAbi,
    functionName: "ADDRESSES_PROVIDER",
    query: { enabled: Boolean(isAaveRoute && aavePoolAddress) },
  });

  const aaveAddressesProvider = aaveAddressesProviderData as Address | undefined;
  const safeAaveAddressesProvider = aaveAddressesProvider ?? zeroAddress;

  const { data: aaveDataProviderFromPoolData } = useReadContract({
    address: safeAaveAddressesProvider,
    abi: aaveAddressesProviderAbi,
    functionName: "getPoolDataProvider",
    query: {
      enabled: Boolean(
        isAaveRoute && aaveAddressesProvider && !protocolConfig.contracts.aaveDataProvider,
      ),
    },
  });

  const resolvedAaveDataProvider =
    protocolConfig.contracts.aaveDataProvider ?? (aaveDataProviderFromPoolData as Address | undefined);
  const safeAaveDataProvider = resolvedAaveDataProvider ?? zeroAddress;

  const { data: collateralReserveTokensData } = useReadContract({
    address: safeAaveDataProvider,
    abi: aaveProtocolDataProviderAbi,
    functionName: "getReserveTokensAddresses",
    args: [safeSelectedCollateralAsset],
    query: {
      enabled: Boolean(isAaveRoute && resolvedAaveDataProvider && selectedCollateralAsset),
    },
  });

  const { data: wethReserveTokensData } = useReadContract({
    address: safeAaveDataProvider,
    abi: aaveProtocolDataProviderAbi,
    functionName: "getReserveTokensAddresses",
    args: [safeWeth],
    query: {
      enabled: Boolean(isAaveRoute && resolvedAaveDataProvider && protocolConfig.tokens.weth),
    },
  });

  const collateralReserveTokens = collateralReserveTokensData as ReserveTokensTuple | undefined;
  const wethReserveTokens = wethReserveTokensData as ReserveTokensTuple | undefined;

  const resolvedAaveCollateralAToken = isAaveRoute
    ? (selectedCollateralAsset &&
      protocolConfig.tokens.wstEth &&
      selectedCollateralAsset.toLowerCase() === protocolConfig.tokens.wstEth.toLowerCase()
        ? (protocolConfig.tokens.aWstEth ?? collateralReserveTokens?.[0])
        : collateralReserveTokens?.[0])
    : undefined;

  const resolvedVariableDebtWeth = wethReserveTokens?.[2];

  const safeAaveCollateralAToken = resolvedAaveCollateralAToken ?? zeroAddress;
  const safeVariableDebtWeth = resolvedVariableDebtWeth ?? zeroAddress;

  const { data: aaveCollateralBalanceData } = useReadContract({
    address: safeAaveCollateralAToken,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(isConnected && isAaveRoute && resolvedAaveCollateralAToken) },
  });

  const { data: wethDebtBalanceData } = useReadContract({
    address: safeVariableDebtWeth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(isConnected && isAaveRoute && resolvedVariableDebtWeth) },
  });

  const { data: aaveCollateralDecimalsData } = useReadContract({
    address: safeAaveCollateralAToken,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(isAaveRoute && resolvedAaveCollateralAToken) },
  });

  const { data: aaveCollateralAllowanceData } = useReadContract({
    address: safeAaveCollateralAToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: [walletAddress, safeReceiver],
    query: {
      enabled: Boolean(
        isConnected && isAaveRoute && resolvedAaveCollateralAToken && receiverAddress,
      ),
    },
  });

  // Morpho route reads.
  const safeMorpho = morphoAddress ?? zeroAddress;
  const { data: morphoMarketParamsData } = useReadContract({
    address: safeMorpho,
    abi: morphoAbi,
    functionName: "idToMarketParams",
    args: resolvedMorphoMarketId ? [resolvedMorphoMarketId] : undefined,
    query: {
      enabled: Boolean(isMorphoRoute && morphoAddress && resolvedMorphoMarketId),
    },
  });

  const { data: morphoPositionData } = useReadContract({
    address: safeMorpho,
    abi: morphoAbi,
    functionName: "position",
    args:
      resolvedMorphoMarketId && isConnected
        ? [resolvedMorphoMarketId, walletAddress]
        : undefined,
    query: {
      enabled: Boolean(isMorphoRoute && morphoAddress && resolvedMorphoMarketId && isConnected),
    },
  });

  const { data: morphoMarketData } = useReadContract({
    address: safeMorpho,
    abi: morphoAbi,
    functionName: "market",
    args: resolvedMorphoMarketId ? [resolvedMorphoMarketId] : undefined,
    query: {
      enabled: Boolean(isMorphoRoute && morphoAddress && resolvedMorphoMarketId),
    },
  });

  const { data: morphoAuthorizationData, refetch: refetchMorphoAuthorization } = useReadContract({
    address: safeMorpho,
    abi: morphoAbi,
    functionName: "isAuthorized",
    args: receiverAddress ? [walletAddress, receiverAddress] : undefined,
    query: {
      enabled: Boolean(isMorphoRoute && morphoAddress && isConnected && receiverAddress),
      refetchInterval: 8_000,
    },
  });

  const { data: morphoCollateralDecimalsData } = useReadContract({
    address: safeSelectedCollateralAsset,
    abi: erc20Abi,
    functionName: "decimals",
    query: {
      enabled: Boolean(isMorphoRoute && selectedCollateralAsset),
    },
  });

  const availableLiquidity = (availableLiquidityData as bigint | undefined) ?? 0n;
  const positionNftAddress =
    protocolConfig.contracts.positionNft ?? (positionNftData as Address | undefined);
  const safePositionNft = positionNftAddress ?? zeroAddress;

  const { data: openPositionCountData } = useReadContract({
    address: safePositionNft,
    abi: yLiquidPositionNftAbi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: {
      enabled: Boolean(isConnected && positionNftAddress),
    },
  });

  const aaveCollateralBalance = (aaveCollateralBalanceData as bigint | undefined) ?? 0n;
  const wethDebtBalance = (wethDebtBalanceData as bigint | undefined) ?? 0n;
  const aaveCollateralAllowance = (aaveCollateralAllowanceData as bigint | undefined) ?? 0n;
  const morphoMarketParams = normalizeMorphoMarketParams(morphoMarketParamsData);
  const morphoPosition = normalizeMorphoPosition(morphoPositionData);
  const morphoMarket = normalizeMorphoMarket(morphoMarketData);
  const morphoCollateralBalance = morphoPosition?.collateral ?? 0n;
  const morphoBorrowAssets =
    morphoMarket && morphoPosition
      ? morphoBorrowSharesToAssetsUp(
          morphoPosition.borrowShares,
          morphoMarket.totalBorrowAssets,
          morphoMarket.totalBorrowShares,
        )
      : 0n;
  const morphoAuthorizationOnchain = Boolean(morphoAuthorizationData ?? false);
  const morphoAuthorized = morphoAuthorizationOverride ?? morphoAuthorizationOnchain;

  const openPositionCount = Number(openPositionCountData ?? 0n);
  const baseRateBps = normalizeBps(baseRateBpsData as BpsValue);
  const adapterRiskPremiumBps = normalizeBps(adapterRiskPremiumBpsData as BpsValue);
  const currentBorrowRateBps =
    baseRateBps === undefined ? undefined : baseRateBps + (adapterRiskPremiumBps ?? 0n);
  const currentBorrowRateLabel = formatBpsAsPercent(currentBorrowRateBps);
  const baseRateLabel = formatBpsAsPercent(baseRateBps);
  const routeRiskPremiumLabel = formatBpsAsPercent(adapterRiskPremiumBps ?? 0n);

  const wethDecimals = Number(wethDecimalsData ?? 18);
  const collateralDecimals = isAaveRoute
    ? Number(aaveCollateralDecimalsData ?? 18)
    : Number(morphoCollateralDecimalsData ?? 18);

  const suggestedCollateralAmount = isAaveRoute
    ? (aaveCollateralBalance * COLLATERAL_USAGE_BPS) / BPS
    : (morphoCollateralBalance * COLLATERAL_USAGE_BPS) / BPS;

  const suggestedPrincipalAmount = isAaveRoute
    ? (wethDebtBalance > availableLiquidity ? availableLiquidity : wethDebtBalance)
    : morphoBorrowAssets > availableLiquidity
      ? availableLiquidity
      : morphoBorrowAssets;

  const principalAmount = useMemo(
    () => parseAmountInput(principalInput, wethDecimals),
    [principalInput, wethDecimals],
  );
  const collateralAmount = useMemo(
    () => parseAmountInput(collateralInput, collateralDecimals),
    [collateralInput, collateralDecimals],
  );

  const needsCollateralApproval =
    isAaveRoute && collateralAmount > 0n && aaveCollateralAllowance < collateralAmount;
  const needsMorphoAuthorization =
    isMorphoRoute && isConnected && Boolean(receiverAddress) && !morphoAuthorized;

  const noLiquidity = availableLiquidity === 0n;
  const willCapPrincipal =
    principalAmount > 0n && availableLiquidity > 0n && principalAmount > availableLiquidity;
  const effectivePrincipalAmount = willCapPrincipal ? availableLiquidity : principalAmount;

  const busy = writePending || txConfirming;
  const morphoAuthorizationBusy =
    busy && (txLabel === MORPHO_AUTH_TX_LABEL_ENABLE || txLabel === MORPHO_AUTH_TX_LABEL_DISABLE);
  const walletTokenIdSet = useMemo(() => new Set(walletOpenTokenIds), [walletOpenTokenIds]);
  const manualOnlyTrackedTokenIds = useMemo(
    () => trackedTokenIds.filter((tokenId) => !walletTokenIdSet.has(tokenId)),
    [trackedTokenIds, walletTokenIdSet],
  );

  const morphoLoanMatches =
    !morphoMarketParams ||
    !protocolConfig.tokens.weth ||
    morphoMarketParams.loanToken.toLowerCase() === protocolConfig.tokens.weth.toLowerCase();
  const morphoCollateralMatches =
    !morphoMarketParams ||
    !selectedCollateralAsset ||
    morphoMarketParams.collateralToken.toLowerCase() === selectedCollateralAsset.toLowerCase();

  useEffect(() => {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return;

    try {
      const parsed = JSON.parse(raw) as number[];
      if (Array.isArray(parsed)) {
        setTrackedTokenIds(parsed.filter((value) => Number.isInteger(value) && value > 0));
      }
    } catch {
      setTrackedTokenIds([]);
    }
  }, []);

  useEffect(() => {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(trackedTokenIds));
  }, [trackedTokenIds]);

  useEffect(() => {
    setReceiverInput(selectedAdapter?.receiver ?? "");
  }, [selectedAdapter?.receiver]);

  useEffect(() => {
    if (!isMorphoRoute) return;
    setMorphoMarketIdInput(defaultMorphoMarketId ?? "");
  }, [isMorphoRoute, defaultMorphoMarketId]);

  useEffect(() => {
    if (!isAaveRoute) return;
    if (resolvedAaveCollateralAToken) {
      setATokenInput(resolvedAaveCollateralAToken);
    }
  }, [selectedAdapterId, isAaveRoute, resolvedAaveCollateralAToken]);

  useEffect(() => {
    if (!isMorphoRoute) return;
    if (!morphoMarketIdInput && defaultMorphoMarketId) {
      setMorphoMarketIdInput(defaultMorphoMarketId);
    }
  }, [isMorphoRoute, morphoMarketIdInput, defaultMorphoMarketId]);

  useEffect(() => {
    let cancelled = false;

    const discoverWalletPositionIds = async () => {
      if (!publicClient || !isConnected || !address || !positionNftAddress) {
        setWalletOpenTokenIds([]);
        setWalletPositionsError("");
        setIsLoadingWalletPositions(false);
        return;
      }

      if (openPositionCount === 0) {
        setWalletOpenTokenIds([]);
        setWalletPositionsError("");
        setIsLoadingWalletPositions(false);
        return;
      }

      setIsLoadingWalletPositions(true);
      setWalletPositionsError("");

      try {
        const latestBlock = await publicClient.getBlockNumber();
        const expectedCount = Math.max(0, openPositionCount);

        let chunkSize = LOG_SCAN_INITIAL_CHUNK;
        let toBlock = latestBlock;

        const checkedTokenIds = new Set<bigint>();
        const discoveredOwnedTokenIds = new Set<bigint>();

        while (discoveredOwnedTokenIds.size < expectedCount) {
          const fromBlock =
            toBlock >= chunkSize - 1n ? toBlock - chunkSize + 1n : 0n;

          let receivedLogs:
            | {
                args: {
                  tokenId?: bigint;
                };
              }[]
            | undefined;

          try {
            receivedLogs = await publicClient.getLogs({
              address: positionNftAddress,
              event: POSITION_TRANSFER_EVENT,
              args: { to: address },
              fromBlock,
              toBlock,
            });
          } catch {
            if (chunkSize > LOG_SCAN_MIN_CHUNK) {
              chunkSize /= 2n;
              continue;
            }

            throw new Error("rpc_log_scan_failed");
          }

          const newlySeenTokenIds: bigint[] = [];

          for (const log of receivedLogs) {
            const tokenId = log.args.tokenId;
            if (typeof tokenId !== "bigint" || checkedTokenIds.has(tokenId)) continue;
            checkedTokenIds.add(tokenId);
            newlySeenTokenIds.push(tokenId);
          }

          if (newlySeenTokenIds.length > 0) {
            const ownerReads = await Promise.all(
              newlySeenTokenIds.map(async (tokenId) => {
                try {
                  const owner = (await publicClient.readContract({
                    address: positionNftAddress,
                    abi: yLiquidPositionNftAbi,
                    functionName: "ownerOf",
                    args: [tokenId],
                  })) as Address;

                  return { tokenId, owner };
                } catch {
                  return undefined;
                }
              }),
            );

            for (const result of ownerReads) {
              if (!result) continue;
              if (result.owner.toLowerCase() !== address.toLowerCase()) continue;
              discoveredOwnedTokenIds.add(result.tokenId);
            }
          }

          if (fromBlock === 0n) {
            break;
          }

          toBlock = fromBlock - 1n;
        }

        const discoveredTokenIds = Array.from(discoveredOwnedTokenIds)
          .map((tokenId) => Number(tokenId))
          .filter((tokenId) => Number.isInteger(tokenId) && tokenId > 0)
          .sort((left, right) => right - left);

        if (!cancelled) {
          setWalletOpenTokenIds(discoveredTokenIds);
          if (discoveredTokenIds.length < openPositionCount) {
            setWalletPositionsError(
              `Found ${discoveredTokenIds.length}/${openPositionCount} position IDs. Your RPC may be limiting historical log queries.`,
            );
          }
        }
      } catch {
        if (!cancelled) {
          setWalletOpenTokenIds([]);
          setWalletPositionsError(
            "Could not load position IDs from logs. Try another RPC endpoint.",
          );
        }
      } finally {
        if (!cancelled) {
          setIsLoadingWalletPositions(false);
        }
      }
    };

    void discoverWalletPositionIds();

    return () => {
      cancelled = true;
    };
  }, [publicClient, isConnected, address, positionNftAddress, openPositionCount]);

  useEffect(() => {
    if (txConfirmed) {
      setSettlingTokenId(null);
      if (txLabel === MORPHO_AUTH_TX_LABEL_ENABLE || txLabel === MORPHO_AUTH_TX_LABEL_DISABLE) {
        void refetchMorphoAuthorization();
        setMorphoAuthorizationOverride(undefined);
      }
    }
  }, [txConfirmed, txLabel, refetchMorphoAuthorization]);

  useEffect(() => {
    if (!isMorphoRoute) {
      setMorphoAuthorizationOverride(undefined);
      return;
    }

    setMorphoAuthorizationOverride(undefined);
  }, [isMorphoRoute, receiverAddress, address]);

  useEffect(() => {
    if (!receipt || txLabel !== "Open Position") return;

    for (const log of receipt.logs) {
      if (!marketAddress || log.address.toLowerCase() !== marketAddress.toLowerCase()) continue;

      try {
        const decoded = decodeEventLog({
          abi: yLiquidMarketAbi,
          data: log.data,
          topics: log.topics,
          strict: true,
        });
        if (decoded.eventName !== "PositionOpened") continue;

        const openedTokenId = Number(decoded.args.tokenId);
        if (!Number.isInteger(openedTokenId) || openedTokenId <= 0) continue;
        setTrackedTokenIds((prev) =>
          prev.includes(openedTokenId) ? prev : [openedTokenId, ...prev],
        );
      } catch {
        continue;
      }
    }
  }, [receipt, txLabel, marketAddress]);

  useEffect(() => {
    if (hasAutoBuiltInputs) return;
    if (principalInput || collateralInput) return;
    if (suggestedPrincipalAmount === 0n && suggestedCollateralAmount === 0n) return;

    if (suggestedPrincipalAmount > 0n) {
      setPrincipalInput(formatUnits(suggestedPrincipalAmount, wethDecimals));
    }
    if (suggestedCollateralAmount > 0n) {
      setCollateralInput(formatUnits(suggestedCollateralAmount, collateralDecimals));
    }
    if (isAaveRoute && resolvedAaveCollateralAToken) {
      setATokenInput(resolvedAaveCollateralAToken);
    }
    if (isMorphoRoute && defaultMorphoMarketId) {
      setMorphoMarketIdInput(defaultMorphoMarketId);
    }
    setHasAutoBuiltInputs(true);
  }, [
    hasAutoBuiltInputs,
    principalInput,
    collateralInput,
    suggestedPrincipalAmount,
    suggestedCollateralAmount,
    wethDecimals,
    collateralDecimals,
    isAaveRoute,
    resolvedAaveCollateralAToken,
    isMorphoRoute,
    defaultMorphoMarketId,
  ]);

  const addTrackedToken = () => {
    const parsed = Number(tokenIdInput);
    if (!Number.isInteger(parsed) || parsed <= 0) return;

    setTrackedTokenIds((prev) => (prev.includes(parsed) ? prev : [parsed, ...prev]));
    setTokenIdInput("");
  };

  const removeTrackedToken = (tokenId: number) => {
    setTrackedTokenIds((prev) => prev.filter((value) => value !== tokenId));
  };

  const buildInputsFromRoute = () => {
    setErrorText("");

    if (suggestedPrincipalAmount > 0n) {
      setPrincipalInput(formatUnits(suggestedPrincipalAmount, wethDecimals));
    }
    if (suggestedCollateralAmount > 0n) {
      setCollateralInput(formatUnits(suggestedCollateralAmount, collateralDecimals));
    }
    if (isAaveRoute && resolvedAaveCollateralAToken) {
      setATokenInput(resolvedAaveCollateralAToken);
    }
    if (isMorphoRoute && defaultMorphoMarketId) {
      setMorphoMarketIdInput(defaultMorphoMarketId);
    }
    setHasAutoBuiltInputs(true);
  };

  const handleApproveCollateral = async () => {
    setErrorText("");

    if (!isAaveRoute) return;

    if (!isConnected || !resolvedAaveCollateralAToken || !receiverAddress || collateralAmount === 0n) {
      setErrorText("Enter a valid receiver, collateral aToken, and collateral amount.");
      return;
    }

    try {
      const hash = await writeContractAsync({
        address: resolvedAaveCollateralAToken,
        abi: erc20Abi,
        functionName: "approve",
        args: [receiverAddress, collateralAmount],
      });
      setTxLabel("Approve Aave Collateral");
      setTxHash(hash);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Approval failed.";
      setErrorText(message.split("\n")[0]);
    }
  };

  const handleToggleMorphoAuthorization = async () => {
    setErrorText("");

    if (!isMorphoRoute) return;
    if (!isConnected || !morphoAddress || !receiverAddress) {
      setErrorText("Enter a valid Morpho receiver address first.");
      return;
    }

    const nextAuthorizationState = !morphoAuthorized;
    const nextTxLabel = nextAuthorizationState
      ? MORPHO_AUTH_TX_LABEL_ENABLE
      : MORPHO_AUTH_TX_LABEL_DISABLE;

    try {
      const hash = await writeContractAsync({
        address: morphoAddress,
        abi: morphoAbi,
        functionName: "setAuthorization",
        args: [receiverAddress, nextAuthorizationState],
      });
      setTxLabel(nextTxLabel);
      setTxHash(hash);
      setMorphoAuthorizationOverride(nextAuthorizationState);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Authorization update failed.";
      if (message.toLowerCase().includes("already set")) {
        setMorphoAuthorizationOverride(nextAuthorizationState);
        void refetchMorphoAuthorization();
        return;
      }
      setErrorText(message.split("\n")[0]);
    }
  };

  const handleOpenPosition = async () => {
    setErrorText("");

    if (!isConnected || !address || !marketAddress || !selectedAdapter?.adapter) return;
    if (principalAmount === 0n || collateralAmount === 0n) {
      setErrorText("Principal and collateral must both be greater than zero.");
      return;
    }
    if (!receiverAddress) {
      setErrorText("Receiver contract address is invalid.");
      return;
    }
    if (!selectedCollateralAsset) {
      setErrorText("Route collateral asset is not configured.");
      return;
    }

    if (needsCollateralApproval) {
      setErrorText("Approve Aave collateral to the receiver before opening.");
      return;
    }

    if (needsMorphoAuthorization) {
      setErrorText("Authorize the Morpho receiver before opening.");
      return;
    }

    if (noLiquidity) {
      setErrorText("Market liquidity is currently zero.");
      return;
    }

    const principalForOpen =
      principalAmount > availableLiquidity ? availableLiquidity : principalAmount;
    if (principalForOpen === 0n) {
      setErrorText("Principal becomes zero after liquidity cap.");
      return;
    }

    let callbackData: Hex = "0x";

    if (isAaveRoute) {
      if (!isAddress(aTokenInput)) {
        setErrorText("Aave collateral token address is invalid.");
        return;
      }

      callbackData = encodeAbiParameters(
        [
          { name: "collateralAsset", type: "address" },
          { name: "collateralAToken", type: "address" },
          { name: "collateralAmount", type: "uint256" },
        ],
        [selectedCollateralAsset, aTokenInput as Address, collateralAmount],
      );
    } else if (isMorphoRoute) {
      if (!resolvedMorphoMarketId) {
        setErrorText("Morpho market ID must be a valid bytes32 value.");
        return;
      }
      if (!morphoMarketParams) {
        setErrorText("Could not load Morpho market params for the configured market ID.");
        return;
      }
      if (!morphoLoanMatches) {
        setErrorText("Morpho market loan token does not match WETH.");
        return;
      }
      if (!morphoCollateralMatches) {
        setErrorText("Morpho market collateral token does not match this route.");
        return;
      }

      callbackData = encodeAbiParameters(
        [
          {
            name: "marketParams",
            type: "tuple",
            components: MORPHO_MARKET_PARAMS_COMPONENTS,
          },
          { name: "collateralAmount", type: "uint256" },
        ],
        [
          {
            loanToken: morphoMarketParams.loanToken,
            collateralToken: morphoMarketParams.collateralToken,
            oracle: morphoMarketParams.oracle,
            irm: morphoMarketParams.irm,
            lltv: morphoMarketParams.lltv,
          },
          collateralAmount,
        ],
      );
    }

    try {
      const hash = await writeContractAsync({
        address: marketAddress,
        abi: yLiquidMarketAbi,
        functionName: "openPosition",
        args: [
          principalForOpen,
          selectedAdapter.adapter,
          receiverAddress,
          collateralAmount,
          callbackData,
        ],
      });

      setTxLabel("Open Position");
      setTxHash(hash);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Transaction failed.";
      setErrorText(message.split("\n")[0]);
    }
  };

  const handleSettle = async (tokenId: number) => {
    setErrorText("");

    if (!marketAddress) return;

    try {
      setSettlingTokenId(tokenId);
      const hash = await writeContractAsync({
        address: marketAddress,
        abi: yLiquidMarketAbi,
        functionName: "settleAndRepay",
        args: [BigInt(tokenId), zeroAddress, "0x"],
      });

      setTxLabel(`Settle Position #${tokenId}`);
      setTxHash(hash);
    } catch (error) {
      setSettlingTokenId(null);
      const message = error instanceof Error ? error.message : "Settle failed.";
      setErrorText(message.split("\n")[0]);
    }
  };

  if (!selectedAdapter || !marketAddress || !selectedAdapter.adapter || !selectedAdapter.receiver || !selectedAdapter.collateralAsset) {
    return (
      <section className="panel panel-warning">
        <h2>Leverage Unwind</h2>
        <p>
          Set route contracts in <code>app/.env</code>: <code>VITE_YLIQUID_MARKET</code>,
          <code> VITE_YLIQUID_WSTETH_ADAPTER</code>, <code>VITE_YLIQUID_WEETH_ADAPTER</code>,
          <code> VITE_AAVE_GENERIC_RECEIVER</code>, and <code>VITE_MORPHO_GENERIC_RECEIVER</code>.
        </p>
      </section>
    );
  }

  if (isAaveRoute && !aavePoolAddress) {
    return (
      <section className="panel panel-warning">
        <h2>Leverage Unwind</h2>
        <p>
          Set <code>VITE_AAVE_POOL</code> in <code>app/.env</code> to enable the Aave unwind route.
        </p>
      </section>
    );
  }

  if (isMorphoRoute && !morphoAddress) {
    return (
      <section className="panel panel-warning">
        <h2>Leverage Unwind</h2>
        <p>
          Set <code>VITE_MORPHO</code> in <code>app/.env</code> to enable the Morpho unwind route.
        </p>
      </section>
    );
  }

  return (
    <section className="panel">
      <header className="section-head">
        <h2>Leverage Unwind</h2>
        <p>
          Pick a route, verify prerequisites, then run <code>openPosition</code>.
        </p>
      </header>

      <div className="metric-grid">
        <article className="metric-card">
          <span className="metric-label">Open Positions</span>
          <strong>{openPositionCount}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Available Market Liquidity</span>
          <strong>{formatAmount(availableLiquidity, 18, 6)} WETH</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Current Borrow Rate</span>
          <strong>{currentBorrowRateLabel}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Principal Used (Capped)</span>
          <strong>{formatAmount(effectivePrincipalAmount, wethDecimals, 6)} WETH</strong>
        </article>

        {isAaveRoute && (
          <>
            <article className="metric-card">
              <span className="metric-label">Your Aave Collateral (aToken)</span>
              <strong>{formatAmount(aaveCollateralBalance, collateralDecimals, 6)}</strong>
            </article>
            <article className="metric-card">
              <span className="metric-label">Your Aave WETH Debt</span>
              <strong>{formatAmount(wethDebtBalance, wethDecimals, 6)} WETH</strong>
            </article>
          </>
        )}

        {isMorphoRoute && (
          <>
            <article className="metric-card">
              <span className="metric-label">Your Morpho Collateral</span>
              <strong>
                {formatAmount(morphoCollateralBalance, collateralDecimals, 6)} {selectedAdapter.collateralSymbol}
              </strong>
            </article>
            <article className="metric-card">
              <span className="metric-label">Your Morpho Borrowed (Est.)</span>
              <strong>{formatAmount(morphoBorrowAssets, wethDecimals, 6)} WETH</strong>
            </article>
          </>
        )}

        <article className="metric-card">
          <span className="metric-label">Suggested Collateral (99.9%)</span>
          <strong>
            {formatAmount(suggestedCollateralAmount, collateralDecimals, 6)} {selectedAdapter.collateralSymbol}
          </strong>
        </article>
      </div>

      {isConnected && openPositionCount > 0 && (
        <p className="warning-text">
          This wallet has {openPositionCount} open position{openPositionCount > 1 ? "s" : ""}.
        </p>
      )}
      {isConnected && openPositionCount === 0 && (
        <p className="hint">No open yLiquid positions found for this wallet.</p>
      )}
      {isConnected && openPositionCount > 0 && isLoadingWalletPositions && (
        <p className="hint">Loading position IDs...</p>
      )}
      {isConnected && openPositionCount > 0 && walletPositionsError && (
        <p className="warning-text">{walletPositionsError}</p>
      )}

      {isConnected && walletOpenTokenIds.length > 0 && (
        <article className="action-card">
          <h3>Your Open Positions</h3>
          <p className="hint">These positions are currently owned by your connected wallet.</p>
          <div className="positions-grid">
            {walletOpenTokenIds.map((tokenId) => (
              <TrackedPositionCard
                key={`wallet-open-${tokenId}`}
                tokenId={tokenId}
                marketAddress={marketAddress}
                positionNftAddress={positionNftAddress}
                lidoQueueAddress={protocolConfig.contracts.lidoWithdrawalQueue}
                etherFiWithdrawRequestNftAddress={protocolConfig.contracts.etherFiWithdrawRequestNft}
                walletAddress={address}
                settlingTokenId={settlingTokenId}
                onSettle={handleSettle}
              />
            ))}
          </div>
        </article>
      )}

      <article className="action-card">
        <h3>Open New Unwind</h3>

        <p className="hint">
          Route: <strong>{selectedAdapter.label}</strong> | Receiver: <strong>{shortAddress(selectedAdapter.receiver)}</strong>
        </p>
        <p className="hint">
          Borrow APR for this route: <strong>{currentBorrowRateLabel}</strong> (base{" "}
          {baseRateLabel} + route premium {routeRiskPremiumLabel})
        </p>
        <p className="hint">Note: this unwind transaction may leave small dust balances behind.</p>

        <div className="form-grid">
          <label>
            Unwind Route
            <select
              value={selectedAdapterId}
              onChange={(event) => setSelectedAdapterId(event.target.value)}
            >
              {adapterOptions.map((adapter) => (
                <option key={adapter.id} value={adapter.id}>
                  {adapter.label}
                </option>
              ))}
            </select>
          </label>

          <label>
            Debt to Repay (WETH)
            <input
              value={principalInput}
              onChange={(event) => setPrincipalInput(event.target.value)}
              placeholder="0.0"
              inputMode="decimal"
            />
          </label>

          <label>
            Collateral to Lock ({selectedAdapter.collateralSymbol})
            <input
              value={collateralInput}
              onChange={(event) => setCollateralInput(event.target.value)}
              placeholder="0.0"
              inputMode="decimal"
            />
          </label>

          <label>
            Receiver Contract
            <input
              value={receiverInput}
              onChange={(event) => setReceiverInput(event.target.value)}
              placeholder="0x..."
            />
          </label>

          {isAaveRoute && (
            <label>
              Aave Collateral Token (aToken)
              <input
                value={aTokenInput}
                onChange={(event) => setATokenInput(event.target.value)}
                placeholder="0x..."
              />
            </label>
          )}

          {isMorphoRoute && (
            <label>
              Morpho Market ID (bytes32)
              <input
                value={morphoMarketIdInput}
                onChange={(event) => setMorphoMarketIdInput(event.target.value)}
                placeholder="0x..."
              />
            </label>
          )}
        </div>

        <div className="button-row">
          <button
            type="button"
            className="button"
            disabled={busy || !isConnected}
            onClick={buildInputsFromRoute}
          >
            {isAaveRoute ? "Prefill From Aave" : "Prefill From Morpho"}
          </button>

          {isAaveRoute && (
            <button
              type="button"
              className="button"
              disabled={!isConnected || busy || !needsCollateralApproval}
              onClick={handleApproveCollateral}
            >
              {busy && txLabel === "Approve Aave Collateral" ? "Approving..." : "Approve Collateral"}
            </button>
          )}

          {isMorphoRoute && (
            <button
              type="button"
              className="button"
              disabled={!isConnected || busy || !receiverAddress}
              onClick={handleToggleMorphoAuthorization}
            >
              {morphoAuthorizationBusy
                ? "Updating Authorization..."
                : morphoAuthorized
                  ? "Unset Authorization"
                  : "Authorize Receiver"}
            </button>
          )}

          <button
            type="button"
            className="button button-accent"
            disabled={
              !isConnected ||
              busy ||
              principalAmount === 0n ||
              collateralAmount === 0n ||
              noLiquidity ||
              !receiverAddress ||
              (isAaveRoute && needsCollateralApproval) ||
              (isMorphoRoute && !morphoAuthorized) ||
              (isMorphoRoute && !resolvedMorphoMarketId)
            }
            onClick={handleOpenPosition}
          >
            {busy && txLabel === "Open Position" ? "Opening..." : "Open Unwind Position"}
          </button>
        </div>

        {isAaveRoute && (
          <>
            <p className="hint">
              Receiver allowance: {formatAmount(aaveCollateralAllowance, collateralDecimals, 6)} /{" "}
              {formatAmount(collateralAmount, collateralDecimals, 6)} aToken
            </p>

            {needsCollateralApproval && (
              <p className="warning-text">
                Approval needed: the Aave receiver cannot pull your collateral aToken yet.
              </p>
            )}

            {!!resolvedAaveCollateralAToken &&
              isAddress(aTokenInput) &&
              aTokenInput.toLowerCase() !== resolvedAaveCollateralAToken.toLowerCase() && (
                <p className="warning-text">
                  Custom aToken differs from Aave data provider output.
                </p>
              )}
          </>
        )}

        {isMorphoRoute && (
          <>
            <p className="hint">
              Morpho receiver authorization: <strong>{morphoAuthorized ? "Authorized" : "Missing"}</strong>
            </p>
            {resolvedMorphoMarketId === undefined && (
              <p className="warning-text">Morpho market ID must be a valid bytes32 value.</p>
            )}
            {!morphoLoanMatches && (
              <p className="warning-text">Selected market loan token is not WETH.</p>
            )}
            {!morphoCollateralMatches && (
              <p className="warning-text">
                Selected market collateral token does not match {selectedAdapter.collateralSymbol}.
              </p>
            )}
            {needsMorphoAuthorization && (
              <p className="warning-text">
                Authorization needed: Morpho receiver uses auths, not ERC20 allowances.
              </p>
            )}
          </>
        )}

        {willCapPrincipal && (
          <p className="warning-text">
            Entered debt is above available liquidity. We will cap principal automatically.
          </p>
        )}
        {noLiquidity && (
          <p className="warning-text">
            Market liquidity is zero, so opening is temporarily blocked.
          </p>
        )}
      </article>

      <article className="action-card">
        <h3>Track Specific Position IDs</h3>
        <div className="inline-row">
          <input
            value={tokenIdInput}
            onChange={(event) => setTokenIdInput(event.target.value)}
            placeholder="Token ID"
            inputMode="numeric"
          />
          <button type="button" className="button" onClick={addTrackedToken}>
            Track
          </button>
        </div>

        {manualOnlyTrackedTokenIds.length === 0 ? (
          trackedTokenIds.length === 0 ? (
            <p className="hint">No manual position IDs tracked yet.</p>
          ) : (
            <p className="hint">All tracked IDs already appear in your open positions list.</p>
          )
        ) : (
          <div className="positions-grid">
            {manualOnlyTrackedTokenIds.map((tokenId) => (
              <div key={tokenId}>
                <TrackedPositionCard
                  tokenId={tokenId}
                  marketAddress={marketAddress}
                  positionNftAddress={positionNftAddress}
                  lidoQueueAddress={protocolConfig.contracts.lidoWithdrawalQueue}
                  etherFiWithdrawRequestNftAddress={protocolConfig.contracts.etherFiWithdrawRequestNft}
                  walletAddress={address}
                  settlingTokenId={settlingTokenId}
                  onSettle={handleSettle}
                />
                <button
                  type="button"
                  className="button button-link"
                  onClick={() => removeTrackedToken(tokenId)}
                >
                  Remove ID #{tokenId}
                </button>
              </div>
            ))}
          </div>
        )}
      </article>

      {txHash && (
        <p className="tx-hint">
          {txLabel}: <code>{txHash}</code>
        </p>
      )}

      {errorText && <p className="error-text">{errorText}</p>}
    </section>
  );
};
