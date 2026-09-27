import { useEffect, useState } from "react";
import { View, Text, Pressable, ScrollView, ActivityIndicator } from "react-native";
import { signUp, signIn, type Session } from "./lib/mera";
import { loadSeries, mid, impliedApr, type Series } from "./lib/premia";
import { loadContext, type MarketCtx } from "./lib/perpl";

export default function App() {
  const [session, setSession] = useState<Session | null>(null);
  const [series, setSeries] = useState<Series[]>([]);
  const [ctx, setCtx] = useState<Record<number, MarketCtx>>({});
  const [mids, setMids] = useState<Record<number, bigint | null>>({});
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // The curve loads without a session. Nobody should have to sign in to see
  // a price.
  useEffect(() => {
    (async () => {
      // Two independent sources. Perpl's API has no CORS headers, so it
      // fails on web and works on device -- that must not blank the curve,
      // which comes from the chain.
      try {
        const s = await loadSeries();
        setSeries(s);
        const m: Record<number, bigint | null> = {};
        for (const x of s) m[x.id] = await mid(x.id);
        setMids(m);
      } catch (e: any) { setErr("chain: " + String(e?.message ?? e)); }
      try {
        setCtx(await loadContext());
      } catch { /* index prices unavailable; APR stays hidden */ }
    })();
  }, []);

  async function auth(fn: () => Promise<Session>) {
    setBusy(true); setErr(null);
    try { setSession(await fn()); }
    catch (e: any) {
      // The common failure is a passkey created without PRF support.
      const c = e?.cause;
      const detail = c ? ` | cause: ${c.error ?? c.code ?? c.name ?? ""} ${c.message ?? String(c)}` : "";
      console.log("[premia] auth error", e?.code, e?.message, JSON.stringify(c ?? null));
      setErr(`${e?.code ?? "ERR"}: ${e?.message ?? e}${detail}`);
    } finally { setBusy(false); }
  }

  return (
    <ScrollView style={{ flex: 1, backgroundColor: "#0b0b0d" }}
                contentContainerStyle={{ padding: 20, paddingTop: 64 }}>
      <Text style={{ color: "#fff", fontSize: 30, fontWeight: "700" }}>PREMIA</Text>
      <Text style={{ color: "#8a8a93", marginTop: 6, fontSize: 15 }}>
        Lock your funding bill in dollars.
      </Text>

      <View style={{ marginTop: 28 }}>
        <Text style={{ color: "#6f6f78", fontSize: 12, letterSpacing: 1 }}>
          THE FUNDING CURVE
        </Text>
        {series.length === 0 && !err && (
          <ActivityIndicator style={{ marginTop: 20 }} color="#888" />
        )}
        {series.map((s) => {
          const k = mids[s.id];
          const px = ctx[s.marketId]?.indexPrice ?? 0;
          const apr = k == null ? null : impliedApr(k, s.marketId, px);
          return (
            <View key={s.id} style={{
              marginTop: 14, padding: 16, borderRadius: 14,
              backgroundColor: "#141418", borderWidth: 1, borderColor: "#22222a",
            }}>
              <View style={{ flexDirection: "row", justifyContent: "space-between" }}>
                <Text style={{ color: "#fff", fontSize: 17, fontWeight: "600" }}>
                  {s.symbol} · {s.intervals || 33} intervals
                </Text>
                <Text style={{ color: apr == null ? "#6f6f78" : "#5ad19a", fontSize: 17 }}>
                  {apr == null ? "no quotes" : `${apr.toFixed(2)}%`}
                </Text>
              </View>
              <Text style={{ color: "#6f6f78", marginTop: 6, fontSize: 13 }}>
                {k == null ? "be the first to quote" :
                  `${Number(k) / 1e6} AUSD per lot per interval`}
              </Text>
              <Text style={{ color: "#4a4a52", marginTop: 4, fontSize: 12 }}>
                {s.settled ? `settled at ${s.netPerLot}` :
                  `closes at block ${s.endBlock}`}
              </Text>
            </View>
          );
        })}
      </View>

      <View style={{ marginTop: 34 }}>
        {session ? (
          <Text style={{ color: "#8a8a93", fontSize: 13 }}>
            {session.address}
          </Text>
        ) : (
          <>
            <Pressable onPress={() => auth(signIn)} disabled={busy}
              style={{ padding: 16, borderRadius: 12, backgroundColor: "#fff" }}>
              <Text style={{ textAlign: "center", fontWeight: "600" }}>
                {busy ? "..." : "Continue with passkey"}
              </Text>
            </Pressable>
            <Pressable onPress={() => auth(() => signUp("premia"))} disabled={busy}
              style={{ padding: 16, marginTop: 10 }}>
              <Text style={{ textAlign: "center", color: "#8a8a93" }}>
                Create an account
              </Text>
            </Pressable>
          </>
        )}
        {err && (
          <Text style={{ color: "#e06c6c", marginTop: 14, fontSize: 13 }}>{err}</Text>
        )}
      </View>
    </ScrollView>
  );
}
