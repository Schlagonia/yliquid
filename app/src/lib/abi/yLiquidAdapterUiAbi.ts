export const yLiquidAdapterUiAbi = [
  {
    type: "function",
    name: "positionView",
    stateMutability: "view",
    inputs: [{ name: "tokenId", type: "uint256" }],
    outputs: [
      {
        name: "",
        type: "tuple",
        components: [
          { name: "owner", type: "address" },
          { name: "proxy", type: "address" },
          { name: "loanAsset", type: "address" },
          { name: "collateralAsset", type: "address" },
          { name: "principal", type: "uint256" },
          { name: "collateralAmount", type: "uint256" },
          { name: "expectedUnlockTime", type: "uint64" },
          { name: "referenceId", type: "uint256" },
          { name: "status", type: "uint8" },
        ],
      },
    ],
  },
  {
    type: "event",
    name: "PositionOpened",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "receiver", type: "address", indexed: true },
      { name: "asset", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
      { name: "collateralAsset", type: "address", indexed: false },
      { name: "collateralAmount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
  {
    type: "event",
    name: "PositionClosed",
    inputs: [
      { name: "tokenId", type: "uint256", indexed: true },
      { name: "owner", type: "address", indexed: true },
      { name: "receiver", type: "address", indexed: true },
      { name: "asset", type: "address", indexed: false },
      { name: "amount", type: "uint256", indexed: false },
      { name: "collateralAsset", type: "address", indexed: false },
      { name: "collateralAmount", type: "uint256", indexed: false },
    ],
    anonymous: false,
  },
] as const;
