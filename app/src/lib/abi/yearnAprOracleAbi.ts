export const yearnAprOracleAbi = [
  {
    type: "function",
    name: "getStrategyApr",
    stateMutability: "view",
    inputs: [
      { name: "strategy", type: "address" },
      { name: "debtChange", type: "int256" },
    ],
    outputs: [{ name: "apr", type: "uint256" }],
  },
] as const;
