import { createPublicClient, http, parseAbi, type LocalAccount } from "viem";
import { monad, PREMIA_SWAP, AUSD, MARKETS } from "./chain";
import { walletClient } from "./mera";

export const publicClient = createPublicClient({ chain: monad, transport: http() });

export const swapAbi = parseAbi([
  "function seriesCount() view returns (uint256)",
  "function getSeries(uint256) view returns ((uint16 marketId,uint64 startBlock,uint64 endBlock,int128 minK,uint64 tickStep,uint128 capPerLot,uint128 unitScale,bool settled,int128 netPerLot,uint32 intervals))",
  "function priceOf(uint256,uint8) view returns (int128)",
  "function bestTick(uint256,uint8) view returns (bool,uint8)",
  "function depthAt(uint256,uint8,uint8) view returns (uint128)",
  "function bitmap(uint256,uint8) view returns (uint256)",
  "function quoteClaim(uint256,address) view returns (uint256)",
  "function fillsOf(uint256,address) view returns ((uint128 lots,int128 k,uint8 side)[])",
  "function postQuote(uint256,uint8,uint8,uint128)",
  "function cancelQuote(uint256,uint8,uint8,uint256)",
  "function take(uint256,uint8,uint128,uint8)",
  "function settle(uint256)",
  "function claim(uint256)",
]);

export const erc20Abi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);

export const PAY_FIXED = 0;      // pays K, receives realised funding
export const RECEIVE_FIXED = 1;

export type Series = {
  id: number;
  marketId: number;
  symbol: string;
  startBlock: bigint;
  endBlock: bigint;
  minK: bigint;
  tickStep: bigint;
  capPerLot: bigint;
  unitScale: bigint;
  settled: boolean;
  netPerLot: bigint;
  intervals: number;
};

export async function loadSeries(): Promise<Series[]> {
  const n = await publicClient.readContract({
    address: PREMIA_SWAP, abi: swapAbi, functionName: "seriesCount",
  });
  const out: Series[] = [];
  for (let i = 0; i < Number(n); i++) {
    const s = await publicClient.readContract({
      address: PREMIA_SWAP, abi: swapAbi, functionName: "getSeries", args: [BigInt(i)],
    });
    const meta = MARKETS[s.marketId as keyof typeof MARKETS];
    out.push({
      id: i,
      marketId: s.marketId,
      symbol: meta?.symbol ?? `#${s.marketId}`,
      startBlock: s.startBlock, endBlock: s.endBlock,
      minK: s.minK, tickStep: s.tickStep,
      capPerLot: s.capPerLot, unitScale: s.unitScale,
      settled: s.settled, netPerLot: s.netPerLot, intervals: s.intervals,
    });
  }
  return out;
}

/** Mid price of a series, in AUSD wei per lot per funding interval. */
export async function mid(seriesId: number): Promise<bigint | null> {
  const [[hasBid, bidTick], [hasAsk, askTick]] = await Promise.all([
    publicClient.readContract({ address: PREMIA_SWAP, abi: swapAbi,
      functionName: "bestTick", args: [BigInt(seriesId), PAY_FIXED] }),
    publicClient.readContract({ address: PREMIA_SWAP, abi: swapAbi,
      functionName: "bestTick", args: [BigInt(seriesId), RECEIVE_FIXED] }),
  ]);
  if (!hasBid && !hasAsk) return null;
  const px = async (t: number) => publicClient.readContract({
    address: PREMIA_SWAP, abi: swapAbi, functionName: "priceOf",
    args: [BigInt(seriesId), t],
  });
  if (hasBid && hasAsk) return (await px(bidTick) + await px(askTick)) / 2n;
  return hasBid ? await px(bidTick) : await px(askTick);
}

/**
 * Annualised funding implied by a fixed rate.
 * k is AUSD wei per lot per interval; a lot is `lotInCoin` of the underlying,
 * so notional = lotInCoin * indexPrice.
 */
export function impliedApr(k: bigint, marketId: number, indexPriceUsd: number): number {
  const meta = MARKETS[marketId as keyof typeof MARKETS];
  if (!meta || indexPriceUsd <= 0) return 0;
  const perIntervalUsd = Number(k) / 1e6;
  const notionalUsd = meta.lotInCoin * indexPriceUsd;
  const intervalsPerYear = (365 * 24 * 3600) / 2580;
  return (perIntervalUsd / notionalUsd) * intervalsPerYear * 100;
}

export async function ensureAllowance(account: LocalAccount, needed: bigint) {
  const current = await publicClient.readContract({
    address: AUSD, abi: erc20Abi, functionName: "allowance",
    args: [account.address, PREMIA_SWAP],
  });
  if (current >= needed) return null;
  const wc = walletClient(account);
  return wc.writeContract({
    address: AUSD, abi: erc20Abi, functionName: "approve",
    args: [PREMIA_SWAP, 2n ** 96n],
  });
}

export async function postQuote(
  account: LocalAccount, seriesId: number, side: number, tick: number, lots: bigint,
  capPerLot: bigint, unitScale: bigint,
) {
  await ensureAllowance(account, capPerLot * lots * unitScale);
  return walletClient(account).writeContract({
    address: PREMIA_SWAP, abi: swapAbi, functionName: "postQuote",
    args: [BigInt(seriesId), side, tick, lots],
  });
}

export async function take(
  account: LocalAccount, seriesId: number, side: number, lots: bigint, limitTick: number,
  capPerLot: bigint, unitScale: bigint,
) {
  await ensureAllowance(account, capPerLot * lots * unitScale);
  return walletClient(account).writeContract({
    address: PREMIA_SWAP, abi: swapAbi, functionName: "take",
    args: [BigInt(seriesId), side, lots, limitTick],
  });
}
