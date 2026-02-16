import { useAccount, useConnect, useDisconnect } from "wagmi";

import { shortAddress } from "../lib/format";

export const WalletBadge = () => {
  const { address, isConnected } = useAccount();
  const { connect, connectors, isPending: connectPending } = useConnect();
  const { disconnect } = useDisconnect();

  if (!isConnected) {
    const connector = connectors[0];

    return (
      <button
        type="button"
        className="button button-accent"
        disabled={!connector || connectPending}
        onClick={() => connector && connect({ connector })}
      >
        {connectPending ? "Connecting..." : "Connect Wallet"}
      </button>
    );
  }

  return (
    <div className="wallet-pill">
      <span>{shortAddress(address)}</span>
      <button type="button" className="button button-ghost" onClick={() => disconnect()}>
        Disconnect
      </button>
    </div>
  );
};
