#!/usr/bin/env bash
# PREMIA for the Agora bounty: AUSD balance card, Perpl top-up on an emptied
# account, hedge limit = live best quote. Run from ~/github/premia-app.
set -euo pipefail
[ -f App.tsx ] && [ -f lib/perplTrade.ts ] || { echo "run this from ~/github/premia-app"; exit 1; }
cat > lib/perplTrade.ts <<'PREMIA_EOF'
/**
 * Perpl perp leg: open the perp this swap hedges, from the passkey wallet.
 *
 * Perpl is a fully on-chain order book, so there is no API key and no
 * off-chain signature: an order is a plain `execOrder` call to the Exchange
 * contract, signed by the same passkey-derived EOA that trades on PREMIA.
 * ABI and field scaling follow PerplFoundation/dex-sdk (abi/dex/Exchange.json,
 * types/request.rs).
 */
import { parseAbi, type LocalAccount, type PublicClient, type WalletClient } from "viem";

export const PERPL_EXCHANGE = "0x34B6552d57a35a1D042CcAe1951BD1C370112a6F" as const;

export const perplAbi = parseAbi([
  "function createAccount(uint256 amountCNS) returns (uint256 accountId)",
  "function depositCollateral(uint256 amountCNS)",
  "function getMinAccountOpenCNS() view returns (uint256)",
  "function execOrder((uint256 orderDescId,uint256 perpId,uint8 orderType,uint256 orderId,uint256 pricePNS,uint256 lotLNS,uint256 expiryBlock,bool postOnly,bool fillOrKill,bool immediateOrCancel,uint256 maxMatches,uint256 leverageHdths,uint256 lastExecutionBlock,uint256 amountCNS,uint256 maxNegPnlCollatBPS) orderDesc) returns ((uint256 perpId,uint256 orderId) signature)",
  "function getAccountByAddr(address accountAddress) view returns ((uint256 accountId,uint256 balanceCNS,uint256 lockedBalanceCNS,uint8 frozen,address accountAddr,(uint256 bank1,uint256 bank2,uint256 bank3,uint256 bank4) positions) accountInfo)",
  "function getPositionV2(uint256 perpId,uint256 accountId) view returns ((uint256 accountId,uint256 nextNodeId,uint256 prevNodeId,uint8 positionType,uint256 depositCNS,uint256 pricePNS,uint256 lotLNS,uint256 entryBlock,int256 pnlCNS,int256 deltaPnlCNS,int256 premiumPnlCNS,uint256 priceResiduePNSQ16) positionInfo,uint256 markPricePNS,bool markPriceValid)",
  "function getPerpetualInfoV2(uint256 perpId) view returns ((string name,string symbol,uint256 priceDecimals,uint256 lotDecimals,bytes32 linkFeedId,uint256 priceTolPer100K,uint256 marginTol,uint256 marginTolDecimals,uint256 refPriceMaxAgeSec,uint256 positionBalanceCNS,uint256 insuranceBalanceCNS,uint256 markPNS,uint256 markTimestamp,uint256 lastPNS,uint256 lastTimestamp,uint256 oraclePNS,uint256 oracleTimestampSec,uint256 longOpenInterestLNS,uint256 shortOpenInterestLNS,uint256 fundingStartBlock,int16 fundingRatePct100k,uint256 absFundingClampPctPer100K,uint8 status,uint256 basePricePNS,uint256 maxBidPriceONS,uint256 minBidPriceONS,uint256 maxAskPriceONS,uint256 minAskPriceONS,uint256 numOrders,bool ignOracle,uint256 fundingSumScalingExp) perpetualInfo)",
]);

const erc20 = parseAbi([
  "function allowance(address,address) view returns (uint256)",
  "function approve(address,uint256) returns (bool)",
]);

export const OPEN_LONG = 0;
export const OPEN_SHORT = 1;

/** Perpl account id for this wallet, or null if it has never deposited. */
export async function perplAccountId(pc: PublicClient, addr: `0x${string}`): Promise<bigint | null> {
  try {
    const a = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "getAccountByAddr", args: [addr] });
    return a.accountId > 0n ? a.accountId : null;
  } catch {
    return null; // the exchange reverts for unknown addresses
  }
}

async function send(pc: PublicClient, wc: WalletClient, account: LocalAccount, req: any) {
  const hash = await wc.writeContract({ ...req, account, chain: wc.chain });
  const r = await pc.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`reverted: ${hash}`);
  return hash;
}

/**
 * Open (or add to) a perp position with an immediate-or-cancel order that
 * crosses the book up to `slippageBps` past the best price. Creates the
 * Perpl account on first use with `depositCNS` of collateral.
 */
export async function openPerp(opts: {
  pc: PublicClient; wc: WalletClient; account: LocalAccount; collateral: `0x${string}`;
  perpId: number; long: boolean; lotLNS: bigint; leverage: number;
  depositCNS: bigint; slippageBps?: number;
}) {
  const { pc, wc, account, collateral, perpId, long, lotLNS, leverage, depositCNS } = opts;
  const slip = BigInt(opts.slippageBps ?? 50);
  const hashes: string[] = [];

  let accountId = await perplAccountId(pc, account.address);
  if (accountId !== null) {
    // Existing account: top it up to depositCNS of free collateral if a
    // previous close-and-withdraw emptied it.
    const a = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "getAccountByAddr", args: [account.address] });
    const free = a.balanceCNS - a.lockedBalanceCNS;
    if (free < depositCNS) {
      const need = depositCNS - free;
      const allowance = await pc.readContract({ address: collateral, abi: erc20,
        functionName: "allowance", args: [account.address, PERPL_EXCHANGE] });
      if (allowance < need) {
        hashes.push(await send(pc, wc, account, { address: collateral, abi: erc20,
          functionName: "approve", args: [PERPL_EXCHANGE, need] }));
      }
      hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
        functionName: "depositCollateral", args: [need] }));
    }
  }
  if (accountId === null) {
    const allowance = await pc.readContract({ address: collateral, abi: erc20,
      functionName: "allowance", args: [account.address, PERPL_EXCHANGE] });
    if (allowance < depositCNS) {
      hashes.push(await send(pc, wc, account, { address: collateral, abi: erc20,
        functionName: "approve", args: [PERPL_EXCHANGE, depositCNS] }));
    }
    hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "createAccount", args: [depositCNS] }));
    accountId = await perplAccountId(pc, account.address);
    if (accountId === null) throw new Error("Perpl account was not created");
  }

  const info = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getPerpetualInfoV2", args: [BigInt(perpId)] });
  // ONS = PNS - basePricePNS; best ask for a buy, best bid for a sell.
  const best = (long ? info.minAskPriceONS : info.maxBidPriceONS) + info.basePricePNS;
  if (best === 0n) throw new Error("empty book");
  const limit = long ? best * (10_000n + slip) / 10_000n : best * (10_000n - slip) / 10_000n;

  hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "execOrder", args: [{
      orderDescId: BigInt(Date.now() % 1_000_000_000),
      perpId: BigInt(perpId),
      orderType: long ? OPEN_LONG : OPEN_SHORT,
      orderId: 0n,
      pricePNS: limit,
      lotLNS,
      expiryBlock: 0n,
      postOnly: false,
      fillOrKill: false,
      immediateOrCancel: true,
      maxMatches: 100n,
      leverageHdths: BigInt(Math.round(leverage * 100)),
      lastExecutionBlock: 0n,
      amountCNS: 0n,
      maxNegPnlCollatBPS: 1000n,
    }] }));

  const pos = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getPositionV2", args: [BigInt(perpId), accountId] });
  return { accountId, hashes, position: pos[0], markPNS: pos[1], limitPNS: limit };
}

const perplExitAbi = parseAbi([
  "function withdrawCollateral(uint256 amountCNS)",
]);

export const CLOSE_LONG = 2;
export const CLOSE_SHORT = 3;

/**
 * Close the whole position on `perpId` with an immediate-or-cancel reduce-only
 * order, then withdraw the account's free collateral back to the wallet.
 * Withdrawals need a wallet signature on the Exchange (never an API key),
 * which is exactly what the passkey-derived EOA is.
 */
export async function closePerpAndWithdraw(opts: {
  pc: PublicClient; wc: WalletClient; account: LocalAccount; perpId: number; slippageBps?: number;
}) {
  const { pc, wc, account, perpId } = opts;
  const slip = BigInt(opts.slippageBps ?? 50);
  const hashes: string[] = [];
  const accountId = await perplAccountId(pc, account.address);
  if (accountId === null) throw new Error("no Perpl account for this wallet");

  const [pos] = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getPositionV2", args: [BigInt(perpId), accountId] });
  if (pos.lotLNS > 0n) {
    const info = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "getPerpetualInfoV2", args: [BigInt(perpId)] });
    // positionType 0 = long, 1 = short (contract enum). Closing a long sells into the bid.
    const isLong = pos.positionType === 0;
    const best = (isLong ? info.maxBidPriceONS : info.minAskPriceONS) + info.basePricePNS;
    if (best === 0n) throw new Error("empty book");
    const limit = isLong ? best * (10_000n - slip) / 10_000n : best * (10_000n + slip) / 10_000n;
    hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplAbi,
      functionName: "execOrder", args: [{
        orderDescId: BigInt(Date.now() % 1_000_000_000) + 1n,
        perpId: BigInt(perpId),
        orderType: isLong ? CLOSE_LONG : CLOSE_SHORT,
        orderId: 0n, pricePNS: limit, lotLNS: pos.lotLNS, expiryBlock: 0n,
        postOnly: false, fillOrKill: false, immediateOrCancel: true, maxMatches: 100n,
        leverageHdths: 100n, lastExecutionBlock: 0n, amountCNS: 0n, maxNegPnlCollatBPS: 1000n,
      }] }));
  }

  const acct = await pc.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
    functionName: "getAccountByAddr", args: [account.address] });
  const free = acct.balanceCNS - acct.lockedBalanceCNS;
  if (free > 0n) {
    hashes.push(await send(pc, wc, account, { address: PERPL_EXCHANGE, abi: perplExitAbi,
      functionName: "withdrawCollateral", args: [free] }));
  }
  return { hashes, withdrawnCNS: free, closedLotLNS: pos.lotLNS };
}
PREMIA_EOF
python3 - <<'PREMIA_PY'
import sys
p = "App.tsx"; s = open(p).read()
if "refreshBalances" in s:
    print("balance card already present, skipping"); sys.exit(0)
edits = [
("""import { openPerp, closePerpAndWithdraw } from "./lib/perplTrade";""",
"""import { openPerp, closePerpAndWithdraw, perplAbi, perplAccountId, PERPL_EXCHANGE } from "./lib/perplTrade";"""),
("""import { swapAbi } from "./lib/premia";""",
"""import { swapAbi, erc20Abi } from "./lib/premia";"""),
("""  const [running, setRunning] = useState<string | null>(null);""",
"""  const [running, setRunning] = useState<string | null>(null);

  // What the wallet holds: AUSD in the wallet, AUSD in its Perpl account, the open ZEC perp.
  const [bal, setBal] = useState<{ wallet: bigint; perpl: bigint | null; lot: bigint; entry: bigint } | null>(null);
  async function refreshBalances(addr: `0x${string}`) {
    try {
      const wallet = await publicClient.readContract({ address: AUSD, abi: erc20Abi,
        functionName: "balanceOf", args: [addr] });
      let perpl: bigint | null = null, lot = 0n, entry = 0n;
      const id = await perplAccountId(publicClient as any, addr);
      if (id !== null) {
        const a = await publicClient.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
          functionName: "getAccountByAddr", args: [addr] });
        perpl = a.balanceCNS;
        const [pos] = await publicClient.readContract({ address: PERPL_EXCHANGE, abi: perplAbi,
          functionName: "getPositionV2", args: [50n, id] });
        lot = pos.lotLNS; entry = pos.pricePNS;
      }
      setBal({ wallet, perpl, lot, entry });
    } catch (e: any) { console.log("[premia] balance error", e?.shortMessage ?? e?.message); }
  }
  // Refresh on sign-in and after every action (each one ends by setting `hedged`).
  useEffect(() => { if (session) refreshBalances(session.account.address); }, [session, hedged]);"""),
("""            <Text style={{ color: "#8a8a93", fontSize: 13 }}>
              {session.address}
            </Text>""",
"""            <View style={{ padding: 18, borderRadius: 14, backgroundColor: "#15131f", borderWidth: 1, borderColor: "#2a2440" }}>
              <Text style={{ color: "#6f6f78", fontSize: 12, letterSpacing: 1 }}>AUSD BALANCE</Text>
              <Text style={{ color: "#fff", fontSize: 34, fontWeight: "700", marginTop: 4 }}>
                {bal ? (Number(bal.wallet) / 1e6).toFixed(2) : "..."} <Text style={{ fontSize: 18, color: "#b79cff" }}>AUSD</Text>
              </Text>
              <Text style={{ color: "#8a8a93", fontSize: 13, marginTop: 8 }}>
                {bal && bal.perpl !== null ? `In Perpl account: ${(Number(bal.perpl) / 1e6).toFixed(2)} AUSD` : "No Perpl account yet"}
              </Text>
              <Text style={{ color: "#8a8a93", fontSize: 13, marginTop: 2 }}>
                {bal && bal.lot > 0n ? `Open: long ${Number(bal.lot) / 1e4} ZEC @ ${(Number(bal.entry) / 100).toFixed(2)}` : "No open perp"}
              </Text>
            </View>
            <Text selectable style={{ color: "#8a8a93", fontSize: 12, marginTop: 12 }}>
              {session.address}
            </Text>"""),
]
for old, new in edits:
    n = s.count(old)
    if n != 1:
        sys.exit(f"ABORT, nothing written: App.tsx anchor matched {n} times:\n{old[:90]}")
    s = s.replace(old, new)
open(p, "w").write(s); print("patched App.tsx: AUSD balance card")
PREMIA_PY
python3 - <<'PREMIA_PY'
import sys
p = "App.tsx"; s = open(p).read()
if "bestAsk" in s:
    print("live price limit already present, skipping"); sys.exit(0)
old = """      //    limit tick 90 = K of at most minK + 90*tickStep; refuses a worse price
      const hash = await take(session.account, s.id, PAY_FIXED, 1n, 90, s.capPerLot, s.unitScale);"""
new = """      //    Limit = the best receive-fixed quote right now, so the order never fills
      //    at a worse price than the one on screen.
      const [hasAsk, bestAsk] = await publicClient.readContract({ address: PREMIA_SWAP, abi: swapAbi,
        functionName: "bestTick", args: [BigInt(s.id), 1] });
      if (!hasAsk) throw new Error(`no quotes to lock against on series ${s.id}`);
      const hash = await take(session.account, s.id, PAY_FIXED, 1n, bestAsk, s.capPerLot, s.unitScale);"""
n = s.count(old)
if n != 1:
    sys.exit(f"ABORT, nothing written: hedge anchor matched {n} times")
open(p, "w").write(s.replace(old, new)); print("patched App.tsx: live price limit")
PREMIA_PY
npx tsc --noEmit && echo "typecheck ok" || { echo "typecheck errors above: paste them to Claude, nothing committed"; exit 1; }
mkdir -p scripts/patches && cp "$0" scripts/patches/premia-agora.sh 2>/dev/null || true
git add -A && git commit -m "AUSD balance card, Perpl top-up for emptied accounts, hedge limit from live best quote" && git push
echo "Done."
