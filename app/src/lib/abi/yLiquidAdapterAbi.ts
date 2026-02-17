export const yLiquidAdapterAbi = [
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
] as const;
