import { useEffect, useMemo, useState } from "react";
import { erc20Abi, formatUnits, zeroAddress, type Address } from "viem";
import {
  useAccount,
  usePublicClient,
  useReadContract,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";

import { protocolConfig } from "../../config/contracts";
import { erc4626Abi } from "../../lib/abi/erc4626Abi";
import { yearnAprOracleAbi } from "../../lib/abi/yearnAprOracleAbi";
import { yLiquidMarketAbi } from "../../lib/abi/yLiquidMarketAbi";
import { yLiquidRateModelAbi } from "../../lib/abi/yLiquidRateModelAbi";
import { formatAmount, parseAmountInput, shortAddress } from "../../lib/format";

const WAD = 10n ** 18n;
const BPS_TO_WAD = 10n ** 14n;
const SECONDS_PER_DAY = 24n * 60n * 60n;
const SECONDS_PER_YEAR = 365n * SECONDS_PER_DAY;
const HISTORY_WINDOW_SECONDS = 7n * SECONDS_PER_DAY;

type VaultStrategyParamsTuple = readonly [bigint, bigint, bigint, bigint];

const formatAprPercent = (aprWad: bigint | undefined): string => {
  if (aprWad === undefined) return "N/A";

  const sign = aprWad < 0n ? "-" : "";
  const normalized = aprWad < 0n ? -aprWad : aprWad;
  const hundredthsPercent = (normalized * 10_000n) / WAD;
  const whole = hundredthsPercent / 100n;
  const fraction = (hundredthsPercent % 100n).toString().padStart(2, "0");
  return `${sign}${whole.toString()}.${fraction}%`;
};

const toInputValue = (value: bigint, decimals: number): string => {
  const raw = formatUnits(value, decimals);
  if (!raw.includes(".")) return raw;
  return raw.replace(/\.?0+$/, "");
};

export const DepositorPanel = () => {
  const vaultAddress = protocolConfig.contracts.yearnVault;
  const safeVault = vaultAddress ?? zeroAddress;
  const yearnAprOracleAddress = protocolConfig.contracts.yearnAprOracle;
  const safeYearnAprOracle = yearnAprOracleAddress ?? zeroAddress;
  const marketAddress = protocolConfig.contracts.yLiquidMarket;
  const safeMarket = marketAddress ?? zeroAddress;

  const { address, isConnected } = useAccount();
  const publicClient = usePublicClient();
  const walletAddress = address ?? zeroAddress;

  const [depositInput, setDepositInput] = useState("");
  const [withdrawInput, setWithdrawInput] = useState("");
  const [txHash, setTxHash] = useState<`0x${string}` | undefined>();
  const [lastAction, setLastAction] = useState("");
  const [historicalAprWad, setHistoricalAprWad] = useState<bigint | undefined>();
  const [historicalAprLoading, setHistoricalAprLoading] = useState(false);
  const [historicalAprHint, setHistoricalAprHint] = useState("");

  const { writeContractAsync, isPending: writePending } = useWriteContract();
  const { isLoading: txConfirming } = useWaitForTransactionReceipt({ hash: txHash });

  const { data: assetData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "asset",
    query: { enabled: Boolean(vaultAddress) },
  });

  const assetAddress = (assetData as Address | undefined) ?? protocolConfig.tokens.weth;
  const safeAsset = assetAddress ?? zeroAddress;

  const { data: assetSymbolData } = useReadContract({
    address: safeAsset,
    abi: erc20Abi,
    functionName: "symbol",
    query: { enabled: Boolean(assetAddress) },
  });

  const { data: assetDecimalsData } = useReadContract({
    address: safeAsset,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(assetAddress) },
  });

  const decimals = Number(assetDecimalsData ?? 18);
  const symbol = (assetSymbolData as string | undefined) ?? "ASSET";

  const { data: shareBalanceData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(vaultAddress && isConnected) },
  });

  const shareBalance = (shareBalanceData as bigint | undefined) ?? 0n;

  const { data: holdingsAssetsData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "convertToAssets",
    args: [shareBalance],
    query: { enabled: Boolean(vaultAddress && isConnected) },
  });

  const { data: maxWithdrawData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "maxWithdraw",
    args: [walletAddress],
    query: { enabled: Boolean(vaultAddress && isConnected) },
  });

  const { data: defaultStrategyData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "default_queue",
    args: [0n],
    query: { enabled: Boolean(vaultAddress) },
  });

  const defaultStrategy = defaultStrategyData as Address | undefined;
  const safeDefaultStrategy = defaultStrategy ?? zeroAddress;

  const { data: strategyAprData } = useReadContract({
    address: safeYearnAprOracle,
    abi: yearnAprOracleAbi,
    functionName: "getStrategyApr",
    args: [safeVault, 0n],
    query: { enabled: Boolean(yearnAprOracleAddress && vaultAddress) },
  });

  const { data: vaultStrategyParamsData } = useReadContract({
    address: safeVault,
    abi: erc4626Abi,
    functionName: "strategies",
    args: [safeDefaultStrategy],
    query: { enabled: Boolean(vaultAddress && defaultStrategy) },
  });

  const { data: totalPrincipalActiveData } = useReadContract({
    address: safeMarket,
    abi: yLiquidMarketAbi,
    functionName: "totalPrincipalActive",
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

  const { data: allowanceData } = useReadContract({
    address: safeAsset,
    abi: erc20Abi,
    functionName: "allowance",
    args: [walletAddress, safeVault],
    query: { enabled: Boolean(assetAddress && vaultAddress && isConnected) },
  });

  const { data: walletAssetBalanceData } = useReadContract({
    address: safeAsset,
    abi: erc20Abi,
    functionName: "balanceOf",
    args: [walletAddress],
    query: { enabled: Boolean(assetAddress && isConnected) },
  });

  const holdingsAssets = (holdingsAssetsData as bigint | undefined) ?? 0n;
  const maxWithdraw = (maxWithdrawData as bigint | undefined) ?? 0n;
  const allowance = (allowanceData as bigint | undefined) ?? 0n;
  const walletAssetBalance = (walletAssetBalanceData as bigint | undefined) ?? 0n;
  const baseStrategyAprWad = strategyAprData as bigint | undefined;
  const totalPrincipalActive = (totalPrincipalActiveData as bigint | undefined) ?? 0n;
  const liquidStrategyAllocation =
    ((vaultStrategyParamsData as VaultStrategyParamsTuple | undefined)?.[2]) ?? 0n;
  const baseRateBps = baseRateBpsData as bigint | undefined;
  const baseRateAprWad =
    baseRateBps === undefined ? undefined : baseRateBps * BPS_TO_WAD;

  const estimatedAprWad = baseStrategyAprWad;

  const estimatedAprLabel = formatAprPercent(estimatedAprWad);
  const baseAprLabel = formatAprPercent(baseStrategyAprWad);
  const baseRateAprLabel = formatAprPercent(baseRateAprWad);
  const historicalAprLabel = historicalAprLoading
    ? "Loading..."
    : formatAprPercent(historicalAprWad);

  const depositAmount = useMemo(
    () => parseAmountInput(depositInput, decimals),
    [depositInput, decimals],
  );
  const withdrawAmount = useMemo(
    () => parseAmountInput(withdrawInput, decimals),
    [withdrawInput, decimals],
  );

  const needsApproval = depositAmount > 0n && allowance < depositAmount;
  const hasConfig = Boolean(vaultAddress && assetAddress);
  const busy = writePending || txConfirming;

  useEffect(() => {
    let cancelled = false;

    const loadHistoricalApr = async () => {
      if (!publicClient || !vaultAddress) {
        setHistoricalAprWad(undefined);
        setHistoricalAprHint("");
        setHistoricalAprLoading(false);
        return;
      }

      setHistoricalAprLoading(true);
      setHistoricalAprHint("");

      try {
        const latestBlockNumber = await publicClient.getBlockNumber();
        const latestBlock = await publicClient.getBlock({
          blockNumber: latestBlockNumber,
        });

        if (latestBlock.timestamp <= HISTORY_WINDOW_SECONDS) {
          if (!cancelled) {
            setHistoricalAprWad(undefined);
            setHistoricalAprHint("N/A: vault has less than 7 days of chain history.");
          }
          return;
        }

        const targetTimestamp = latestBlock.timestamp - HISTORY_WINDOW_SECONDS;

        let low = 0n;
        let high = latestBlockNumber;
        let targetBlockNumber = 0n;

        while (low <= high) {
          const middle = (low + high) / 2n;
          const middleBlock = await publicClient.getBlock({
            blockNumber: middle,
          });

          if (middleBlock.timestamp <= targetTimestamp) {
            targetBlockNumber = middle;
            low = middle + 1n;
            continue;
          }

          if (middle === 0n) break;
          high = middle - 1n;
        }

        const codeAtTargetBlock = await publicClient.getCode({
          address: vaultAddress,
          blockNumber: targetBlockNumber,
        });
        if (!codeAtTargetBlock || codeAtTargetBlock === "0x") {
          if (!cancelled) {
            setHistoricalAprWad(undefined);
            setHistoricalAprHint("N/A: vault has not been live for 7 days yet.");
          }
          return;
        }

        const [currentPpsData, historicalPpsData] = await Promise.all([
          publicClient.readContract({
            address: vaultAddress,
            abi: erc4626Abi,
            functionName: "pricePerShare",
          }),
          publicClient.readContract({
            address: vaultAddress,
            abi: erc4626Abi,
            functionName: "pricePerShare",
            blockNumber: targetBlockNumber,
          }),
        ]);

        const currentPps = currentPpsData as bigint;
        const historicalPps = historicalPpsData as bigint;
        if (historicalPps === 0n) {
          if (!cancelled) {
            setHistoricalAprWad(undefined);
            setHistoricalAprHint("N/A: vault has not been live for 7 days yet.");
          }
          return;
        }

        const periodReturnWad = ((currentPps - historicalPps) * WAD) / historicalPps;
        const annualizedAprWad =
          (periodReturnWad * SECONDS_PER_YEAR) / HISTORY_WINDOW_SECONDS;

        if (!cancelled) {
          setHistoricalAprWad(annualizedAprWad);
          setHistoricalAprHint("");
        }
      } catch {
        if (!cancelled) {
          setHistoricalAprWad(undefined);
          setHistoricalAprHint("N/A: unable to read 7D PPS history from RPC.");
        }
      } finally {
        if (!cancelled) {
          setHistoricalAprLoading(false);
        }
      }
    };

    void loadHistoricalApr();

    return () => {
      cancelled = true;
    };
  }, [publicClient, vaultAddress]);

  const handleApprove = async () => {
    if (!hasConfig || depositAmount === 0n || !assetAddress || !vaultAddress) return;

    const hash = await writeContractAsync({
      address: assetAddress,
      abi: erc20Abi,
      functionName: "approve",
      args: [vaultAddress, depositAmount],
    });

    setLastAction(`Approve ${symbol}`);
    setTxHash(hash);
  };

  const handleDeposit = async () => {
    if (!hasConfig || !isConnected || !address || depositAmount === 0n || !vaultAddress) return;

    const hash = await writeContractAsync({
      address: vaultAddress,
      abi: erc4626Abi,
      functionName: "deposit",
      args: [depositAmount, address],
    });

    setLastAction(`Deposit ${symbol}`);
    setTxHash(hash);
  };

  const handleWithdraw = async () => {
    if (!hasConfig || !isConnected || !address || withdrawAmount === 0n || !vaultAddress) return;

    const hash = await writeContractAsync({
      address: vaultAddress,
      abi: erc4626Abi,
      functionName: "withdraw",
      args: [withdrawAmount, address, address],
    });

    setLastAction(`Withdraw ${symbol}`);
    setTxHash(hash);
  };

  const handleMaxDeposit = () => {
    setDepositInput(toInputValue(walletAssetBalance, decimals));
  };

  const handleMaxWithdraw = () => {
    setWithdrawInput(toInputValue(maxWithdraw, decimals));
  };

  if (!vaultAddress) {
    return (
      <section className="panel panel-warning">
        <h2>Vault Deposits</h2>
        <p>Set <code>VITE_YEARN_VAULT</code> in <code>app/.env</code> to enable this flow.</p>
      </section>
    );
  }

  return (
    <section className="panel">
      <header className="section-head">
        <h2>Vault Deposits</h2>
        <p>
          Put idle assets to work to supply liquidity for non-atomic unwinding of positions. Earn
          a min rate plus a premium when loopers need to quickly unwind illiquid positions. NOTE:
          deposits may become illiquid when utilization is high
        </p>
      </header>

      <div className="metric-grid">
        <article className="metric-card">
          <span className="metric-label">Connected Wallet</span>
          <strong>{shortAddress(address)}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Total Vault Value</span>
          <strong>
            {formatAmount(holdingsAssets, decimals, 6)} {symbol}
          </strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Available to Withdraw</span>
          <strong>
            {formatAmount(maxWithdraw, decimals, 6)} {symbol}
          </strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">Estimated APR</span>
          <strong>{estimatedAprLabel}</strong>
        </article>
        <article className="metric-card">
          <span className="metric-label">7D Historical APR</span>
          <strong>{historicalAprLabel}</strong>
        </article>
      </div>

      {estimatedAprWad !== undefined ? (
        <p className="hint">
          Estimated APR is weighted by capital: base strategy APR ({baseAprLabel}) on liquid
          allocation ({formatAmount(liquidStrategyAllocation, decimals, 4)} {symbol}) and yLiquid
          base rate APR ({baseRateAprLabel}) on active principal (
          {formatAmount(totalPrincipalActive, decimals, 4)} {symbol}).
        </p>
      ) : (
        <p className="hint">
          Estimated APR requires APR oracle, market rate model, and strategy allocation data.
        </p>
      )}
      {historicalAprHint && <p className="hint">{historicalAprHint}</p>}

      <div className="action-grid">
        <article className="action-card">
          <h3>Add Funds</h3>
          <label>
            Amount ({symbol})
            <input
              value={depositInput}
              onChange={(event) => setDepositInput(event.target.value)}
              placeholder="0.0"
              inputMode="decimal"
            />
          </label>
          <p className="hint">
            Spending approval: {formatAmount(allowance, decimals, 6)} {symbol}
          </p>
          <p className="hint">
            Wallet balance:{" "}
            <button
              type="button"
              className="hint-action"
              onClick={handleMaxDeposit}
              disabled={walletAssetBalance === 0n}
            >
              {formatAmount(walletAssetBalance, decimals, 6)} {symbol} (Max)
            </button>
          </p>
          {needsApproval ? (
            <button
              type="button"
              className="button button-accent"
              disabled={!isConnected || busy || depositAmount === 0n}
              onClick={handleApprove}
            >
              {busy ? "Processing..." : `Approve ${symbol}`}
            </button>
          ) : (
            <button
              type="button"
              className="button button-accent"
              disabled={!isConnected || busy || depositAmount === 0n}
              onClick={handleDeposit}
            >
              {busy ? "Processing..." : `Deposit ${symbol}`}
            </button>
          )}
        </article>

        <article className="action-card">
          <h3>Withdraw Funds</h3>
          <label>
            Amount ({symbol})
            <input
              value={withdrawInput}
              onChange={(event) => setWithdrawInput(event.target.value)}
              placeholder="0.0"
              inputMode="decimal"
            />
          </label>
          <p className="hint">
            Vault shares:{" "}
            <button
              type="button"
              className="hint-action"
              onClick={handleMaxWithdraw}
              disabled={maxWithdraw === 0n}
            >
              {formatAmount(shareBalance, decimals, 6)} (Use Max Withdraw)
            </button>
          </p>
          <button
            type="button"
            className="button"
            disabled={!isConnected || busy || withdrawAmount === 0n}
            onClick={handleWithdraw}
          >
            {busy ? "Processing..." : `Withdraw ${symbol}`}
          </button>
        </article>
      </div>

      {txHash && (
        <p className="tx-hint">
          {lastAction}: <code>{txHash}</code>
        </p>
      )}
    </section>
  );
};
