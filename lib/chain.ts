import { defineChain } from "viem";

export const monad = defineChain({
  id: 143,
  name: "Monad",
  nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
  blockExplorers: { default: { name: "Monadscan", url: "https://monadscan.com" } },
});

export const PREMIA_SWAP = "0x4695e7747555857929CA99FC86A9F44cef832749" as const;
export const PERPL       = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F" as const;
export const AUSD        = "0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a" as const;

export const AUSD_DECIMALS = 6;
export const FUNDING_INTERVAL_BLOCKS = 8571n;
export const FUNDING_INTERVAL_SECONDS = 2580;

/// Launch markets, chosen on measured funding level and forecastability.
/// See BENCHMARKS.md -- SOL is excluded deliberately.
export const MARKETS = {
  50: { symbol: "ZEC",  lotInCoin: 0.01,  unitScale: 1n },
  40: { symbol: "HYPE", lotInCoin: 0.001, unitScale: 1n },
  10: { symbol: "MON",  lotInCoin: 1,     unitScale: 1n },
} as const;
