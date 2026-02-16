import { formatUnits, parseUnits, type Address } from "viem";

export const shortAddress = (value: Address | undefined): string => {
  if (!value) return "Not set";
  return `${value.slice(0, 6)}...${value.slice(-4)}`;
};

export const formatAmount = (
  value: bigint | undefined,
  decimals = 18,
  fractionDigits = 4,
): string => {
  if (value === undefined) return "-";
  const raw = formatUnits(value, decimals);
  const [whole, fraction = ""] = raw.split(".");
  if (!fraction.length || fractionDigits === 0) return whole;
  return `${whole}.${fraction.slice(0, fractionDigits)}`;
};

export const parseAmountInput = (value: string, decimals: number): bigint => {
  const normalized = value.trim();
  if (!normalized) return 0n;

  try {
    return parseUnits(normalized, decimals);
  } catch {
    return 0n;
  }
};

export const formatTimestamp = (unixSeconds: bigint | number | undefined): string => {
  if (unixSeconds === undefined) return "-";
  const sec = typeof unixSeconds === "bigint" ? Number(unixSeconds) : unixSeconds;
  if (!Number.isFinite(sec) || sec <= 0) return "-";
  return new Date(sec * 1000).toLocaleString();
};
