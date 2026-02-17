import { erc20Abi, zeroAddress, type Address } from "viem";
import { useReadContract } from "wagmi";

import { protocolConfig } from "../../config/contracts";
import { yLiquidAdapterAbi } from "../../lib/abi/yLiquidAdapterAbi";
import { etherFiWithdrawRequestNftAbi } from "../../lib/abi/etherFiWithdrawRequestNftAbi";
import { lidoWithdrawalQueueAbi } from "../../lib/abi/lidoWithdrawalQueueAbi";
import { yLiquidMarketAbi } from "../../lib/abi/yLiquidMarketAbi";
import { yLiquidPositionNftAbi } from "../../lib/abi/yLiquidPositionNftAbi";
import { formatAmount, formatTimestamp, shortAddress } from "../../lib/format";
import type { AdapterPositionView, MarketPositionTuple } from "../../types/protocol";

type TrackedPositionCardProps = {
  tokenId: number;
  marketAddress: Address;
  adapterAddress?: Address;
  positionNftAddress: Address | undefined;
  lidoQueueAddress: Address | undefined;
  etherFiWithdrawRequestNftAddress: Address | undefined;
  walletAddress: Address | undefined;
  settlingTokenId: number | null;
  onSettle: (tokenId: number) => Promise<void>;
};

const marketStateLabel = (state: number): string => {
  switch (state) {
    case 1:
      return "Active";
    case 2:
      return "Ready";
    case 3:
      return "Closed";
    case 4:
      return "Defaulted";
    default:
      return `State ${state}`;
  }
};

const adapterStatusLabel = (status: number): string => {
  switch (status) {
    case 1:
      return "Open";
    case 2:
      return "Closed";
    default:
      return `Status ${status}`;
  }
};

export const TrackedPositionCard = ({
  tokenId,
  marketAddress,
  adapterAddress,
  positionNftAddress,
  lidoQueueAddress,
  etherFiWithdrawRequestNftAddress,
  walletAddress,
  settlingTokenId,
  onSettle,
}: TrackedPositionCardProps) => {
  const safeNft = positionNftAddress ?? zeroAddress;
  const explorerBaseUrl =
    protocolConfig.chainId === 11155111
      ? "https://sepolia.etherscan.io"
      : "https://etherscan.io";

  const { data: marketPositionData } = useReadContract({
    address: marketAddress,
    abi: yLiquidMarketAbi,
    functionName: "positions",
    args: [BigInt(tokenId)],
  });

  const { data: quoteDebtData } = useReadContract({
    address: marketAddress,
    abi: yLiquidMarketAbi,
    functionName: "quoteDebt",
    args: [BigInt(tokenId)],
  });

  const { data: nftOwnerData } = useReadContract({
    address: safeNft,
    abi: yLiquidPositionNftAbi,
    functionName: "ownerOf",
    args: [BigInt(tokenId)],
    query: { enabled: Boolean(positionNftAddress) },
  });

  const marketPosition = marketPositionData as MarketPositionTuple | undefined;
  const resolvedAdapterAddress = (marketPosition?.[1] as Address | undefined) ?? adapterAddress;
  const safeAdapter = resolvedAdapterAddress ?? zeroAddress;

  const { data: adapterViewData } = useReadContract({
    address: safeAdapter,
    abi: yLiquidAdapterAbi,
    functionName: "positionView",
    args: [BigInt(tokenId)],
    query: { enabled: Boolean(resolvedAdapterAddress) },
  });

  const adapterView = adapterViewData as AdapterPositionView | undefined;
  const requestId = adapterView?.referenceId ?? 0n;
  const safeLoanAsset = adapterView?.loanAsset ?? zeroAddress;
  const safeCollateralAsset = adapterView?.collateralAsset ?? zeroAddress;
  const safeQueue = lidoQueueAddress ?? zeroAddress;
  const safeEtherFiWithdrawRequestNft = etherFiWithdrawRequestNftAddress ?? zeroAddress;
  const isWstEthCollateral = Boolean(
    protocolConfig.tokens.wstEth &&
      adapterView?.collateralAsset &&
      adapterView.collateralAsset.toLowerCase() === protocolConfig.tokens.wstEth.toLowerCase(),
  );
  const isWeEthCollateral = Boolean(
    protocolConfig.tokens.weEth &&
      adapterView?.collateralAsset &&
      adapterView.collateralAsset.toLowerCase() === protocolConfig.tokens.weEth.toLowerCase(),
  );

  const { data: loanSymbolData } = useReadContract({
    address: safeLoanAsset,
    abi: erc20Abi,
    functionName: "symbol",
    query: { enabled: Boolean(adapterView?.loanAsset) },
  });

  const { data: loanDecimalsData } = useReadContract({
    address: safeLoanAsset,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(adapterView?.loanAsset) },
  });

  const { data: collateralSymbolData } = useReadContract({
    address: safeCollateralAsset,
    abi: erc20Abi,
    functionName: "symbol",
    query: { enabled: Boolean(adapterView?.collateralAsset) },
  });

  const { data: collateralDecimalsData } = useReadContract({
    address: safeCollateralAsset,
    abi: erc20Abi,
    functionName: "decimals",
    query: { enabled: Boolean(adapterView?.collateralAsset) },
  });

  const { data: queueStatusesData } = useReadContract({
    address: safeQueue,
    abi: lidoWithdrawalQueueAbi,
    functionName: "getWithdrawalStatus",
    args: [[requestId]],
    query: {
      enabled: Boolean(isWstEthCollateral && lidoQueueAddress && requestId > 0n),
    },
  });

  const { data: etherFiIsFinalizedData } = useReadContract({
    address: safeEtherFiWithdrawRequestNft,
    abi: etherFiWithdrawRequestNftAbi,
    functionName: "isFinalized",
    args: [requestId],
    query: {
      enabled: Boolean(
        isWeEthCollateral && etherFiWithdrawRequestNftAddress && requestId > 0n,
      ),
    },
  });

  const debt = (quoteDebtData as bigint | undefined) ?? 0n;
  const owner = (nftOwnerData as Address | undefined) ?? adapterView?.owner;
  const loanSymbol = (loanSymbolData as string | undefined) ?? "Loan";
  const collateralSymbol = (collateralSymbolData as string | undefined) ?? "Collateral";
  const loanDecimals = Number(loanDecimalsData ?? 18);
  const collateralDecimals = Number(collateralDecimalsData ?? 18);

  const queueStatuses = queueStatusesData as
    | {
        amountOfStETH: bigint;
        amountOfShares: bigint;
        owner: Address;
        timestamp: bigint;
        isFinalized: boolean;
        isClaimed: boolean;
      }[]
    | undefined;
  const queueStatus = queueStatuses?.[0];

  const queueIsFinalized = queueStatus?.isFinalized;
  const queueIsClaimed = queueStatus?.isClaimed;
  const queueReady =
    queueIsFinalized === undefined ? undefined : queueIsFinalized && !queueIsClaimed;
  const etherFiIsFinalized = etherFiIsFinalizedData as boolean | undefined;
  const etherFiReady =
    requestId === 0n ? undefined : etherFiIsFinalized === undefined ? undefined : etherFiIsFinalized;
  const queueStatusLabel = isWstEthCollateral
    ? requestId === 0n
      ? "-"
      : queueReady
        ? "Claimable"
        : queueIsClaimed
          ? "Claimed"
          : queueIsFinalized === false
            ? "Pending Finalization"
            : "Unknown"
    : isWeEthCollateral
      ? requestId === 0n
        ? "-"
        : etherFiIsFinalized === undefined
          ? "Checking On-Chain"
          : etherFiIsFinalized
            ? "Claimable"
            : "Pending Finalization"
      : "-";

  const marketState = Number(marketPosition?.[6] ?? 0n);
  const adapterStatus = Number(adapterView?.status ?? 0n);
  const unlockTime = adapterView?.expectedUnlockTime ?? marketPosition?.[5] ?? 0n;

  const isOpen = marketState === 1 && adapterStatus === 1;
  const blockedByQueue =
    (isWstEthCollateral && queueReady === false) ||
    (isWeEthCollateral && requestId > 0n && etherFiReady !== true);

  const canSettle = Boolean(
    owner &&
      walletAddress &&
      owner.toLowerCase() === walletAddress.toLowerCase() &&
      isOpen &&
      !blockedByQueue,
  );
  const ownerHref = owner ? `${explorerBaseUrl}/address/${owner}` : undefined;
  const proxyHref = adapterView?.proxy
    ? `${explorerBaseUrl}/address/${adapterView.proxy}`
    : undefined;

  return (
    <article className="position-card">
      <header>
        <h4>Position #{tokenId}</h4>
        <span>
          {marketStateLabel(marketState)} / {adapterStatusLabel(adapterStatus)}
        </span>
      </header>

      <dl>
        <div>
          <dt>Owner</dt>
          <dd>
            {ownerHref ? (
              <a className="address-link" href={ownerHref} target="_blank" rel="noreferrer">
                {shortAddress(owner)}
              </a>
            ) : (
              shortAddress(owner)
            )}
          </dd>
        </div>
        <div>
          <dt>Proxy</dt>
          <dd>
            {proxyHref ? (
              <a className="address-link" href={proxyHref} target="_blank" rel="noreferrer">
                {shortAddress(adapterView?.proxy)}
              </a>
            ) : (
              shortAddress(adapterView?.proxy)
            )}
          </dd>
        </div>
        <div>
          <dt>Principal</dt>
          <dd>{formatAmount(adapterView?.principal, loanDecimals, 6)} {loanSymbol}</dd>
        </div>
        <div>
          <dt>Collateral</dt>
          <dd>{formatAmount(adapterView?.collateralAmount, collateralDecimals, 6)} {collateralSymbol}</dd>
        </div>
        <div>
          <dt>Debt Quote</dt>
          <dd>{formatAmount(debt, loanDecimals, 6)} {loanSymbol}</dd>
        </div>
        <div>
          <dt>Exected Finalization</dt>
          <dd>{formatTimestamp(unlockTime)}</dd>
        </div>
        <div>
          <dt>
            {isWstEthCollateral
              ? "Lido Request ID"
              : isWeEthCollateral
                ? "EtherFi Request ID"
                : "Request ID"}
          </dt>
          <dd>{adapterView?.referenceId?.toString() ?? "-"}</dd>
        </div>
        <div>
          <dt>
            {isWstEthCollateral
              ? "Lido Queue Status"
              : isWeEthCollateral
                ? "EtherFi Queue Status"
                : "Withdrawal Status"}
          </dt>
          <dd>{queueStatusLabel}</dd>
        </div>
        {isWstEthCollateral && (
          <div>
            <dt>Queue Timestamp</dt>
            <dd>{formatTimestamp(queueStatus?.timestamp)}</dd>
          </div>
        )}
      </dl>

      <button
        type="button"
        className="button"
        disabled={!canSettle || settlingTokenId === tokenId}
        onClick={() => onSettle(tokenId)}
      >
        {settlingTokenId === tokenId ? "Settling..." : "Settle and Claim"}
      </button>
      {isWstEthCollateral && requestId > 0n && queueReady === false && (
        <p className="warning-text">Lido request is still waiting for finalization.</p>
      )}
      {isWeEthCollateral && requestId > 0n && etherFiReady !== true && (
        <p className="warning-text">
          {etherFiReady === undefined
            ? "EtherFi request status is still loading."
            : "EtherFi request is still waiting for finalization."}
        </p>
      )}
    </article>
  );
};
