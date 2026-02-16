import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { type ReactNode } from "react";
import { WagmiProvider, createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { mainnet, sepolia } from "wagmi/chains";

import { protocolConfig } from "../config/contracts";

const supportedChains = [mainnet, sepolia] as const;

export const activeChain =
  supportedChains.find((chain) => chain.id === protocolConfig.chainId) ?? mainnet;

const wagmiConfig = createConfig({
  chains: supportedChains,
  connectors: [injected()],
  transports: {
    [mainnet.id]: http(protocolConfig.rpcUrlMainnet),
    [sepolia.id]: http(),
  },
});

const queryClient = new QueryClient();

type Web3ProviderProps = {
  children: ReactNode;
};

export const Web3Provider = ({ children }: Web3ProviderProps) => {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>
    </WagmiProvider>
  );
};
