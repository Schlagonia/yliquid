import { zeroAddress, type Address } from "viem";
import { useReadContract } from "wagmi";

import { protocolConfig } from "../../config/contracts";
import { yLiquidAdapterUiAbi } from "../../lib/abi/yLiquidAdapterUiAbi";
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
  walletAddress: Address | undefined;
  settlingTokenId: number | null;
  onSettle: (tokenId: number) => Promise<void>;
};

const marketStateLabel = (state: number): string => {
  switch (state) {
    case 1:
      return "Active";
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
  const resolvedAdapterAddress = (marketPosition?.[2] as Address | undefined) ?? adapterAddress;
  const safeAdapter = resolvedAdapterAddress ?? zeroAddress;

  const { data: adapterViewData } = useReadContract({
    address: safeAdapter,
    abi: yLiquidAdapterUiAbi,
    functionName: "positionView",
    args: [BigInt(tokenId)],
    query: { enabled: Boolean(resolvedAdapterAddress) },
  });

  const adapterView = adapterViewData as AdapterPositionView | undefined;
  const requestId = adapterView?.referenceId ?? 0n;
  const safeQueue = lidoQueueAddress ?? zeroAddress;

  const { data: queueStatusesData } = useReadContract({
    address: safeQueue,
    abi: lidoWithdrawalQueueAbi,
    functionName: "getWithdrawalStatus",
    args: [[requestId]],
    query: {
      enabled: Boolean(lidoQueueAddress && requestId > 0n),
    },
  });

  const debt = (quoteDebtData as bigint | undefined) ?? 0n;
  const owner = (nftOwnerData as Address | undefined) ?? adapterView?.owner;

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
  const queueStatusLabel =
    requestId === 0n
      ? "-"
      : queueReady
        ? "Claimable"
        : queueIsClaimed
          ? "Claimed"
          : queueIsFinalized === false
            ? "Pending Finalization"
            : "Unknown";

  const marketState = Number(marketPosition?.[7] ?? 0n);
  const adapterStatus = Number(adapterView?.status ?? 0n);
  const unlockTime = adapterView?.expectedUnlockTime ?? marketPosition?.[6] ?? 0n;

  const isOpen = marketState === 1 && adapterStatus === 1;

  const canSettle = Boolean(
    owner &&
      walletAddress &&
      owner.toLowerCase() === walletAddress.toLowerCase() &&
      isOpen &&
      queueReady !== false,
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
          <dd>{formatAmount(adapterView?.principal, 18, 6)} WETH</dd>
        </div>
        <div>
          <dt>Collateral</dt>
          <dd>{formatAmount(adapterView?.collateralAmount, 18, 6)} wstETH</dd>
        </div>
        <div>
          <dt>Debt Quote</dt>
          <dd>{formatAmount(debt, 18, 6)} WETH</dd>
        </div>
        <div>
          <dt>Ready After</dt>
          <dd>{formatTimestamp(unlockTime)}</dd>
        </div>
        <div>
          <dt>Lido Request ID</dt>
          <dd>{adapterView?.referenceId?.toString() ?? "-"}</dd>
        </div>
        <div>
          <dt>Lido Queue Status</dt>
          <dd>{queueStatusLabel}</dd>
        </div>
        <div>
          <dt>Queue Timestamp</dt>
          <dd>{formatTimestamp(queueStatus?.timestamp)}</dd>
        </div>
      </dl>

      <button
        type="button"
        className="button"
        disabled={!canSettle || settlingTokenId === tokenId}
        onClick={() => onSettle(tokenId)}
      >
        {settlingTokenId === tokenId ? "Settling..." : "Settle and Claim"}
      </button>
      {requestId > 0n && queueReady === false && (
        <p className="warning-text">Lido request is still waiting for finalization.</p>
      )}
    </article>
  );
};
