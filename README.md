<p align="center">
  <img src="docs/banner.svg" alt="PREMIA: lock your funding bill in dollars" width="100%">
</p>

<p align="center"><b>The PREMIA mobile app: one passkey, one tap, a perp on Perpl with its funding locked.</b><br>
No seed phrase. No smart account. No backend holding keys.</p>

<p align="center">
  <a href="https://premia-swap.vercel.app"><img src="https://img.shields.io/badge/Live-premia--swap.vercel.app-7c5cff?style=for-the-badge" alt="Live"></a>
  <a href="https://github.com/Makabeez/premia"><img src="https://img.shields.io/badge/Contracts-Makabeez%2Fpremia-2ea44f?style=for-the-badge" alt="Contracts"></a>
  <img src="https://img.shields.io/badge/Tested%20on-Galaxy%20S25%20Ultra-b79cff?style=for-the-badge" alt="Device">
  <img src="https://img.shields.io/badge/License-MIT-lightgrey?style=for-the-badge" alt="MIT">
</p>
<p align="center">
  <img src="https://img.shields.io/badge/Expo-SDK%2057-000020?style=flat-square" alt="Expo">
  <img src="https://img.shields.io/badge/mera-0.2.0-8a8a93?style=flat-square" alt="mera">
  <img src="https://img.shields.io/badge/react--native--passkey-3.6.1-8a8a93?style=flat-square" alt="passkey">
  <img src="https://img.shields.io/badge/viem-2-8a8a93?style=flat-square" alt="viem">
  <img src="https://img.shields.io/badge/Monad-mainnet-5b3fd6?style=flat-square" alt="Monad">
</p>

> Companion to [Makabeez/premia](https://github.com/Makabeez/premia) (contracts, backtest, evidence).
> Built for **Metropolis** (Monad).

## What one tap does

**"Lock my ZEC funding · 1 lot"** sends four transactions, all signed silently by the key the
passkey unlocked, with no second prompt:

1. `AUSD.approve(Perpl)`: first use only
2. `Perpl.createAccount(11 AUSD)`: first use only
3. `Perpl.execOrder(OpenLong 0.01 ZEC, 2x, immediate-or-cancel)`: **the exposure**
4. `PremiaSwap.take(series, PayFixed, 1 lot)`: **the hedge**; the long's funding is now −K

1 PREMIA lot is exactly 0.01 ZEC = 100 Perpl lot units, so the hedge ratio is 1:1 by construction.
Perpl is a fully on-chain order book, so the perp order is an ordinary contract call from the
same wallet: no API key, no off-chain signature.

**Done on mainnet on 29 Sept 2026**: 4 txs in 4 consecutive blocks. See
[`premia/evidence/one-tap-hedge.md`](https://github.com/Makabeez/premia/blob/main/evidence/one-tap-hedge.md).

## One passkey, many keys

```
passkey (Google Password Manager, synced)
   │  WebAuthn PRF, user-verified
   ├── salt sha256("premia/wallet/v1")        ──▶ secp256k1 ─▶ EOA 0xD410…4Dc5   (trades, signs)
   ├── salt sha256("premia/perpl-api-key/v1") ──▶ Ed25519   ─▶ Perpl API identity (derived, not yet used)
   └── salt sha256("premia/maker-state/v1")   ──▶ reserved for maker state
```

The wallet key is **re-derived on every sign-in and never stored**. Proof: create the account,
uninstall the app (wiping all its storage), reinstall, sign in: same address.
[`evidence/passkey-device.md`](evidence/passkey-device.md).

## Architecture

```
 App.tsx ── one-tap hedge, claim, funding curve
   ├─ lib/mera.ts        passkey ─PRF─▶ keys (salts above), viem LocalAccount
   ├─ lib/webauthn*.ts   RN client on device (react-native-passkey), browser client on web
   ├─ lib/polyfills.ts   crypto.getRandomValues for Hermes (expo-crypto)
   ├─ lib/perplTrade.ts  Perpl: createAccount + execOrder (ABI from PerplFoundation/dex-sdk)
   ├─ lib/premia.ts      PremiaSwap: series, book, take, claim
   └─ lib/chain.ts       Monad 143, contract addresses, market lot sizes
```

## Run it

Passkeys with PRF need a real device and a development build (not Expo Go).

```bash
npm install
npm i -g eas-cli && eas login && eas init
eas build --profile development --platform android   # installs via link/QR on the phone
npx expo start --dev-client --tunnel                  # tunnel: WSL/NAT-safe
```

The relying-party domain (`EXPO_PUBLIC_RP_ID`, default `premia-swap.vercel.app`) must serve
`/.well-known/assetlinks.json` with your signing certificate's SHA-256 and **both** relations:

```json
"relation": ["delegate_permission/common.handle_all_urls",
             "delegate_permission/common.get_login_creds"]
```

With only `get_login_creds`, as the mera React Native guide shows, Android rejects passkey
creation with `RP ID cannot be validated`. That cost us an hour; Google's FIDO2 docs require both.

## Honest limits

- Android only has been tested; the iOS associated domain is configured, not verified.
- The perp and the hedge are separate transactions; if the second fails, the perp stays open.
- The perp leg is wired for ZEC; other markets need their lot mapping.
- The Perpl API key namespace is derived but not yet used by any screen.

## License

MIT
