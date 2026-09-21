/**
 * Perpl public market data. No auth, no key.
 * Used for index prices (to annualise a fixed rate) and realised funding
 * (to show what the float leg has actually done).
 */
const API = "https://app.perpl.xyz/api";

export type MarketCtx = {
  id: number; symbol: string;
  priceDecimals: number; sizeDecimals: number; scalingExp: number;
  indexPrice: number; fundingRateMicros: number;
};

export async function loadContext(): Promise<Record<number, MarketCtx>> {
  const r = await fetch(`${API}/v1/pub/context`);
  const d = await r.json();
  const out: Record<number, MarketCtx> = {};
  for (const m of d.markets) {
    const cfg = m.config ?? {};
    out[m.id] = {
      id: m.id,
      symbol: m.symbol ?? m.name,
      priceDecimals: cfg.price_decimals ?? 2,
      sizeDecimals: cfg.size_decimals ?? 4,
      scalingExp: cfg.funding_sum_scaling_exp ?? 0,
      indexPrice: (m.funding?.idx ?? m.state?.idx ?? 0) / 10 ** (cfg.price_decimals ?? 2),
      fundingRateMicros: m.funding?.rate ?? 0,
    };
  }
  return out;
}

/** Realised funding per lot over a window, straight from the accumulator. */
export async function realisedFunding(marketId: number, fromMs: number, toMs: number) {
  const r = await fetch(`${API}/v1/market-data/${marketId}/funding/${fromMs}-${toMs}`);
  const d = await r.json();
  const ev: any[] = d.d ?? [];
  if (ev.length < 2) return { deltaWeiPerLot: 0, intervals: 0, events: ev };
  return {
    deltaWeiPerLot: ev[ev.length - 1].sum - ev[0].sum,
    intervals: ev.length - 1,
    events: ev,
  };
}

/** Trailing EMA of per-interval payments — the naive fair-value baseline. */
export function emaFairValue(events: any[], n = 72): number {
  if (!events.length) return 0;
  const k = 2 / (n + 1);
  let e = events[0].ppl;
  for (const x of events.slice(1)) e = x.ppl * k + e * (1 - k);
  return e;
}
