import { useMemo, useState } from "react";
import type { Address } from "viem";

import { WalletBadge } from "./components/WalletBadge";
import { protocolConfig, requiredAddresses } from "./config/contracts";
import { DepositorPanel } from "./features/depositor/DepositorPanel";
import { LeveragerPanel } from "./features/leverager/LeveragerPanel";
import { shortAddress } from "./lib/format";

type Lane = "depositor" | "leverager";
type ExplorerAddress = {
  label: string;
  address: Address;
};

const laneLabels: Record<Lane, string> = {
  depositor: "Deposit & Withdraw",
  leverager: "Unwind Leverage",
};

const App = () => {
  const [lane, setLane] = useState<Lane>("depositor");
  const explorerBaseUrl =
    protocolConfig.chainId === 11155111
      ? "https://sepolia.etherscan.io"
      : "https://etherscan.io";

  const missingAddresses = useMemo(
    () => requiredAddresses.filter(([, value]) => !value),
    [],
  );
  const explorerAddresses = useMemo(
    (): ExplorerAddress[] => {
      const rawEntries: [string, Address | undefined][] = [
        ["yLiquid Market", protocolConfig.contracts.yLiquidMarket],
        ["Position NFT", protocolConfig.contracts.positionNft],
        ["wstETH Unwind Adapter", protocolConfig.contracts.wstEthAdapter],
        ["Aave Generic Receiver", protocolConfig.contracts.aaveReceiver],
      ];

      return rawEntries.flatMap(([label, address]) =>
        address ? [{ label, address }] : [],
      );
    },
    [],
  );

  return (
    <div className="app">
      <div className="backdrop" aria-hidden="true" />

      <header className="topbar">
        <div className="topbar-main">
          <p className="eyebrow">yLiquid</p>
          <div className="title-row">
            <svg
              className="water-glyph"
              viewBox="0 0 96 48"
              fill="none"
              xmlns="http://www.w3.org/2000/svg"
              aria-hidden="true"
            >
              <path
                d="M4 14C12 8 20 8 28 14C36 20 44 20 52 14C60 8 68 8 76 14C84 20 90 20 92 18"
                stroke="currentColor"
                strokeWidth="6"
                strokeLinecap="round"
              />
              <path
                d="M4 30C12 24 20 24 28 30C36 36 44 36 52 30C60 24 68 24 76 30C84 36 90 36 92 34"
                stroke="currentColor"
                strokeWidth="6"
                strokeLinecap="round"
                opacity="0.66"
              />
            </svg>
            <h1>yLiquid Control Panel</h1>
          </div>
          <p className="subtitle">
            Connect wallet, manage vault funds, and unwind leveraged loops in one place.
          </p>
        </div>
        <div className="topbar-actions">
          <a
            className="button button-ghost external-link"
            href="https://github.com/Schlagonia/yliquid"
            target="_blank"
            rel="noreferrer"
          >
            GitHub
          </a>
          <WalletBadge />
        </div>
      </header>

      {missingAddresses.length > 0 && (
        <section className="panel panel-warning">
          <h2>Setup Checklist</h2>
          <p>Add these to <code>app/.env</code> before you start sending transactions:</p>
          <ul className="checklist">
            {missingAddresses.map(([label]) => (
              <li key={label}>{label}</li>
            ))}
          </ul>
        </section>
      )}

      <nav className="lane-nav" aria-label="Primary flows">
        {(Object.keys(laneLabels) as Lane[]).map((item) => (
          <button
            key={item}
            type="button"
            className={`lane-tab ${lane === item ? "is-active" : ""}`}
            onClick={() => setLane(item)}
          >
            {laneLabels[item]}
          </button>
        ))}
      </nav>

      <main>{lane === "depositor" ? <DepositorPanel /> : <LeveragerPanel />}</main>

      <section className="panel">
        <header className="section-head">
          <h2>Protocol Contracts</h2>
          <p>Direct links to yLiquid contracts on Etherscan.</p>
        </header>
        {explorerAddresses.length === 0 ? (
          <p className="hint">No protocol contract addresses configured yet.</p>
        ) : (
          <div className="contracts-grid">
            {explorerAddresses.map(({ label, address }) => (
              <a
                key={label}
                className="contract-link"
                href={`${explorerBaseUrl}/address/${address}`}
                target="_blank"
                rel="noreferrer"
              >
                <span>{label}</span>
                <code>{shortAddress(address)}</code>
              </a>
            ))}
          </div>
        )}
      </section>
    </div>
  );
};

export default App;
