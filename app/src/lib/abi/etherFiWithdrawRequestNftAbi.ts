export const etherFiWithdrawRequestNftAbi = [
  {
    type: "function",
    name: "isFinalized",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    type: "function",
    name: "getClaimableAmount",
    stateMutability: "view",
    inputs: [{ name: "requestId", type: "uint256" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
