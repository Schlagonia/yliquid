import { useEffect, useMemo, useState } from "react";
import {
  decodeEventLog,
  encodeAbiParameters,
  erc20Abi,
  formatUnits,
  isAddress,
  parseAbiItem,
  zeroAddress,
  type Address,
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
import { yLiquidMarketAbi } from "../../lib/abi/yLiquidMarketAbi";
import { yLiquidPositionNftAbi } from "../../lib/abi/yLiquidPositionNftAbi";
import { formatAmount, parseAmountInput, shortAddress } from "../../lib/format";
import { TrackedPositionCard } from "./TrackedPositionCard";

const STORAGE_KEY = "yliquid_tracked_token_ids";
const COLLATERAL_USAGE_BPS = 9_900n; // 99%
const BPS = 10_000n;
const LOG_SCAN_INITIAL_CHUNK = 250_000n;
const LOG_SCAN_MIN_CHUNK = 2_000n;
const POSITION_TRANSFER_EVENT = parseAbiItem(
  "event Transfer(address indexed from, address indexed to, uint256 indexed tokenId)",
);

type ReserveTokensTuple = readonly [Address, Address, Address];

export const LeveragerPanel = () => {
  const marketAddress = protocolConfig.contracts.yLiquidMarket;
  const safeMarket = marketAddress ?? zeroAddress;

  const aavePoolAddress = protocolConfig.contracts.aavePool;
  const safeAavePool = aavePoolAddress ?? zeroAddress;

  const safeWeth = protocolConfig.tokens.weth ?? zeroAddress;
  const safeWstEth = protocolConfig.tokens.wstEth ?? zeroAddress;

  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const walletAddress = address ?? zeroAddress;

  const [selectedAdapterId, setSelectedAdapterId] = useState(adapterOptions[0]?.id ?? "");
  const selectedAdapter =
    adapterOptions.find((adapter) => adapter.id === selectedAdapterId) ?? adapterOptions[0];

  const [principalInput, setPrincipalInput] = useState("");
  const [collateralInput, setCollateralInput] = useState("");
  const [receiverInput, setReceiverInput] = useState<string>(selectedAdapter?.receiver ?? "");
  const [aTokenInput, setATokenInput] = useState<string>(protocolConfig.tokens.aWstEth ?? "");
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

  const { writeContractAsync, isPending: writePending } = useWriteContract();
  const {
    data: receipt,
    isLoading: txConfirming,
    isSuccess: txConfirmed,
  } = useWaitForTransactionReceipt({ hash: txHash });

  const { data: availableLiquidityData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "availableLiquidity",
    query: { enabled: Boolean(marketAddress) },
  });

  const { data: positionNftData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "positionNFT",
    query: { enabled: Boolean(marketAddress) },
  });

  const { data: wethDecimalsData } = useReadContract({
    address: safeWeth,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(protocolConfig.tokens.weth) },
  });

  const { data: aaveAddressesProviderData } = useReadContract({
    address: safeAavePool,
    abi: aavePoolAbi,
    functionName: "ADDRESSES_PROVIDER",
    query: { enabled: Boolean(aavePoolAddress) },
  });

  const aaveAddressesProvider = aaveAddressesProviderData as Address | undefined;
  const safeAaveAddressesProvider = aaveAddressesProvider ?? zeroAddress;

  const { data: aaveDataProviderFromPoolData } = useReadContract({
    address: safeAaveAddressesProvider,
    abi: aaveAddressesProviderAbi,
    functionName: "getPoolDataProvider",
    query: {
      enabled: Boolean(
        aaveAddressesProvider && !protocolConfig.contracts.aaveDataProvider,
      ),
    },
  });

  const resolvedAaveDataProvider =
    protocolConfig.contracts.aaveDataProvider ?? (aaveDataProviderFromPoolData as Address | undefined);
  const safeAaveDataProvider = resolvedAaveDataProvider ?? zeroAddress;

  const { data: wstEthReserveTokensData } = useReadContract({
    address: safeAaveDataProvider,
    abi: aaveProtocolDataProviderAbi,
    functionName: "getReserveTokensAddresses",
    args: [safeWstEth],
    query: {
      enabled: Boolean(resolvedAaveDataProvider && protocolConfig.tokens.wstEth),
    },
  });

  const { data: wethReserveTokensData } = useReadContract({
    address: safeAaveDataProvider,
    abi: aaveProtocolDataProviderAbi,
    functionName: "getReserveTokensAddresses",
    args: [safeWeth],
    query: {
      enabled: Boolean(resolvedAaveDataProvider && protocolConfig.tokens.weth),
    },
  });

  const wstEthReserveTokens = wstEthReserveTokensData as ReserveTokensTuple | undefined;
  const wethReserveTokens = wethReserveTokensData as ReserveTokensTuple | undefined;

  const resolvedAWstEth = protocolConfig.tokens.aWstEth ?? wstEthReserveTokens?.[0];
  const resolvedVariableDebtWeth = wethReserveTokens?.[2];

  const safeAWstEth = resolvedAWstEth ?? zeroAddress;
  const safeVariableDebtWeth = resolvedVariableDebtWeth ?? zeroAddress;

  const receiverAddress = isAddress(receiverInput)
    ? (receiverInput as Address)
    : undefined;
  const safeReceiver = receiverAddress ?? zeroAddress;

  const { data: aWstEthBalanceData } = useReadContract({
    address: safeAWstEth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(isConnected && resolvedAWstEth) },
  });

  const { data: wethDebtBalanceData } = useReadContract({
    address: safeVariableDebtWeth,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(isConnected && resolvedVariableDebtWeth) },
  });

  const { data: collateralDecimalsData } = useReadContract({
    address: safeAWstEth,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(resolvedAWstEth) },
  });

  const { data: collateralAllowanceData } = useReadContract({
    address: safeAWstEth,
    abi: erc20Abi,
    functionName: "allowance",
    args: [walletAddress, safeReceiver],
    query: {
      enabled: Boolean(isConnected && resolvedAWstEth && receiverAddress),
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

  const aWstEthBalance = (aWstEthBalanceData as bigint | undefined) ?? 0n;
  const wethDebtBalance = (wethDebtBalanceData as bigint | undefined) ?? 0n;
  const collateralAllowance = (collateralAllowanceData as bigint | undefined) ?? 0n;
  const openPositionCount = Number(openPositionCountData ?? 0n);

  const wethDecimals = Number(wethDecimalsData ?? 18);
  const collateralDecimals = Number(collateralDecimalsData ?? 18);

  const suggestedCollateralAmount = (aWstEthBalance * COLLATERAL_USAGE_BPS) / BPS;
  const suggestedPrincipalAmount =
    wethDebtBalance > availableLiquidity ? availableLiquidity : wethDebtBalance;

  const principalAmount = useMemo(
    () => parseAmountInput(principalInput, wethDecimals),
    [principalInput, wethDecimals],
  );
  const collateralAmount = useMemo(
    () => parseAmountInput(collateralInput, collateralDecimals),
    [collateralInput, collateralDecimals],
  );

  const needsCollateralApproval =
    collateralAmount > 0n && collateralAllowance < collateralAmount;
  const noLiquidity = availableLiquidity === 0n;
  const willCapPrincipal =
    principalAmount > 0n && availableLiquidity > 0n && principalAmount > availableLiquidity;
  const effectivePrincipalAmount = willCapPrincipal ? availableLiquidity : principalAmount;

  const busy = writePending || txConfirming;
  const walletTokenIdSet = useMemo(() => new Set(walletOpenTokenIds), [walletOpenTokenIds]);
  const manualOnlyTrackedTokenIds = useMemo(
    () => trackedTokenIds.filter((tokenId) => !walletTokenIdSet.has(tokenId)),
    [trackedTokenIds, walletTokenIdSet],
  );

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
    if (!aTokenInput && resolvedAWstEth) {
      setATokenInput(resolvedAWstEth);
    }
  }, [aTokenInput, resolvedAWstEth]);

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
                  from?: Address;
                  to?: Address;
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
          } catch (error) {
            if (chunkSize > LOG_SCAN_MIN_CHUNK) {
              chunkSize /= 2n;
              continue;
            }

            throw error;
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
      } catch (error) {
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
    }
  }, [txConfirmed]);

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

    setPrincipalInput(formatUnits(suggestedPrincipalAmount, wethDecimals));
    setCollateralInput(formatUnits(suggestedCollateralAmount, collateralDecimals));
    if (resolvedAWstEth) {
      setATokenInput(resolvedAWstEth);
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
    resolvedAWstEth,
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

  const buildInputsFromAave = () => {
    setErrorText("");
    setPrincipalInput(formatUnits(suggestedPrincipalAmount, wethDecimals));
    setCollateralInput(formatUnits(suggestedCollateralAmount, collateralDecimals));
    if (resolvedAWstEth) {
      setATokenInput(resolvedAWstEth);
    }
    setHasAutoBuiltInputs(true);
  };

  const handleApproveCollateral = async () => {
    setErrorText("");

    if (!isConnected || !resolvedAWstEth || !receiverAddress || collateralAmount === 0n) {
      setErrorText("Enter a valid receiver, aWstETH token, and collateral amount.");
      return;
    }

    try {
      const hash = await writeContractAsync({
        address: resolvedAWstEth,
        abi: erc20Abi,
        functionName: "approve",
        args: [receiverAddress, collateralAmount],
      });
      setTxLabel("Approve aWstETH");
      setTxHash(hash);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Approval failed.";
      setErrorText(message.split("\n")[0]);
    }
  };

  const handleOpenPosition = async () => {
    setErrorText("");

    if (!isConnected || !address || !marketAddress || !selectedAdapter?.adapter) return;
    if (!protocolConfig.tokens.wstEth || principalAmount === 0n || collateralAmount === 0n) return;
    if (!receiverAddress) {
      setErrorText("Receiver contract address is invalid.");
      return;
    }

    if (needsCollateralApproval) {
      setErrorText("Approve aWstETH for the receiver before opening.");
      return;
    }

    if (noLiquidity) {
      setErrorText("Market liquidity is currently zero.");
      return;
    }

    if (!isAddress(aTokenInput)) {
      setErrorText("Aave collateral token address is invalid.");
      return;
    }

    const principalForOpen =
      principalAmount > availableLiquidity ? availableLiquidity : principalAmount;
    if (principalForOpen === 0n) {
      setErrorText("Principal becomes zero after liquidity cap.");
      return;
    }

    const callbackData = encodeAbiParameters(
      [
        { name: "collateralAsset", type: "address" },
        { name: "collateralAToken", type: "address" },
        { name: "collateralAmount", type: "uint256" },
      ],
      [protocolConfig.tokens.wstEth, aTokenInput as Address, collateralAmount],
    );

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

  if (!marketAddress || !selectedAdapter?.adapter || !aavePoolAddress) {
    return (
      <section className="panel panel-warning">
        <h2>Leverage Unwind</h2>
        <p>
          Set <code>VITE_YLIQUID_MARKET</code>, <code>VITE_YLIQUID_WSTETH_ADAPTER</code>,
          and <code>VITE_AAVE_POOL</code> in <code>app/.env</code> to enable this flow.
        </p>
      </section>
    );
  }

  return (
    <section className="panel">
      <header className="section-head">
        <h2>Leverage Unwind</h2>
        <p>
          We read your Aave loop, prefill unwind values, then run
          <code> approve -&gt; openPosition</code>.
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
          <span className="metric-label">Your aWstETH Balance</span>
          <strong>{formatAmount(aWstEthBalance, collateralDecimals, 6)}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Your Aave WETH Debt</span>
          <strong>{formatAmount(wethDebtBalance, wethDecimals, 6)} WETH</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Suggested Collateral (99%)</span>
          <strong>{formatAmount(suggestedCollateralAmount, collateralDecimals, 6)}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Principal Used (Capped)</span>
          <strong>{formatAmount(effectivePrincipalAmount, wethDecimals, 6)} WETH</strong>
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
            Collateral to Lock (aWstETH)
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

          <label>
            Aave Collateral Token (aToken)
            <input
              value={aTokenInput}
              onChange={(event) => setATokenInput(event.target.value)}
              placeholder="0x..."
            />
          </label>
        </div>

        <div className="button-row">
          <button
            type="button"
            className="button"
            disabled={busy || !isConnected}
            onClick={buildInputsFromAave}
          >
            Prefill From Aave
          </button>

          <button
            type="button"
            className="button"
            disabled={!isConnected || busy || !needsCollateralApproval}
            onClick={handleApproveCollateral}
          >
            {busy && txLabel === "Approve aWstETH" ? "Approving..." : "Approve aWstETH"}
          </button>

          <button
            type="button"
            className="button button-accent"
            disabled={
              !isConnected ||
              busy ||
              principalAmount === 0n ||
              collateralAmount === 0n ||
              needsCollateralApproval ||
              noLiquidity
            }
            onClick={handleOpenPosition}
          >
            {busy && txLabel === "Open Position" ? "Opening..." : "Open Unwind Position"}
          </button>
        </div>

        <p className="hint">
          Receiver allowance: {formatAmount(collateralAllowance, collateralDecimals, 6)} / {formatAmount(collateralAmount, collateralDecimals, 6)} aWstETH
        </p>

        {needsCollateralApproval && (
          <p className="warning-text">
            Approval needed: receiver cannot pull the selected collateral amount yet.
          </p>
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

        {!!resolvedAWstEth && isAddress(aTokenInput) && aTokenInput.toLowerCase() !== resolvedAWstEth.toLowerCase() && (
          <p className="warning-text">
            Custom aToken differs from Aave data provider output.
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
