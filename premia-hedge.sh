#!/usr/bin/env bash
# PREMIA: one-tap hedge from the passkey wallet.
# Run from ~/github/premia-app:   bash premia-hedge.sh
# Fast Refresh picks it up, no rebuild needed.
set -euo pipefail
[ -f App.tsx ] && [ -f lib/premia.ts ] || { echo "run this from ~/github/premia-app"; exit 1; }
python3 - <<'PY'
import sys
edits = {
 "lib/premia.ts": [(
"""  const wc = walletClient(account);
  return wc.writeContract({
    address: AUSD, abi: erc20Abi, functionName: "approve",
    args: [PREMIA_SWAP, 2n ** 96n],
  });""",
"""  const wc = walletClient(account);
  const hash = await wc.writeContract({
    address: AUSD, abi: erc20Abi, functionName: "approve",
    args: [PREMIA_SWAP, 2n ** 96n],
  });
  // The trade that follows is gas-estimated against chain state, so the
  // allowance has to be mined first or the estimate reverts.
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;""")],
 "App.tsx": [
("""import { loadSeries, mid, impliedApr, type Series } from "./lib/premia";""",
"""import { loadSeries, mid, impliedApr, take, publicClient, PAY_FIXED, type Series } from "./lib/premia";"""),
("""  const [busy, setBusy] = useState(false);""",
"""  const [busy, setBusy] = useState(false);
  const [hedged, setHedged] = useState<string | null>(null);

  /**
   * One tap: pay fixed on 1 lot of the newest series still open for trading.
   * Signed by the passkey-derived key in memory, so no second prompt.
   */
  async function hedge() {
    if (!session) return;
    setBusy(true); setErr(null); setHedged(null);
    try {
      const head = await publicClient.getBlockNumber();
      const all = await loadSeries();
      setSeries(all);
      const s = [...all].reverse().find((x) => !x.settled && head < x.startBlock);
      if (!s) throw new Error("no series open for trading");
      // limit tick 90 = K of at most minK + 90*tickStep; refuses a worse price
      const hash = await take(session.account, s.id, PAY_FIXED, 1n, 90, s.capPerLot, s.unitScale);
      console.log("[premia] hedge tx", hash);
      await publicClient.waitForTransactionReceipt({ hash });
      setHedged(`Hedged 1 lot of ${s.symbol} (series ${s.id})\\n${hash}`);
    } catch (e: any) {
      const msg = String(e?.shortMessage ?? e?.message ?? e);
      console.log("[premia] hedge error", msg);
      setErr(msg);
    } finally { setBusy(false); }
  }"""),
("""          <Text style={{ color: "#8a8a93", fontSize: 13 }}>
            {session.address}
          </Text>""",
"""          <View>
            <Text style={{ color: "#8a8a93", fontSize: 13 }}>
              {session.address}
            </Text>
            <Pressable onPress={hedge} disabled={busy}
              style={{ padding: 16, marginTop: 16, borderRadius: 12, backgroundColor: "#fff" }}>
              <Text style={{ textAlign: "center", fontWeight: "600" }}>
                {busy ? "..." : "Lock my ZEC funding · 1 lot"}
              </Text>
            </Pressable>
            {hedged && (
              <Text selectable style={{ color: "#7bd88f", marginTop: 12, fontSize: 12 }}>{hedged}</Text>
            )}
          </View>"""),
 ]}
new = {}
for path, pairs in edits.items():
    s = open(path).read()
    for old, rep in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f"ABORT, nothing written: {path} anchor matched {n} times:\n{old[:80]}")
        s = s.replace(old, rep)
    new[path] = s
for path, s in new.items():
    open(path, "w").write(s)
    print("patched", path)
PY
npx tsc --noEmit && echo "typecheck ok" || echo "typecheck errors above, paste them to Claude"
