#!/usr/bin/env bash
# PREMIA — make the app build and run on a real Android phone.
# Run from ~/github/premia-app:   bash premia-device.sh
#
# Fixes three bugs that would have failed the first passkey tap on device:
#   1. no webAuthnClient -> mera fell back to navigator.credentials (web only)
#   2. PRF salts were 16 bytes -> mera throws INPUT_INVALID (needs exactly 32)
#   3. getPasskeyPrfOutput took { rp: { id } } -> the option is { rpId }
# and adds what React Native needs: react-native-passkey, a CSPRNG polyfill
# for Hermes, the Android package id, and EAS build profiles.
set -euo pipefail
[ -f App.tsx ] && [ -f package.json ] || { echo "run this from ~/github/premia-app"; exit 1; }

RP_ID="premia-swap.vercel.app"
PKG="xyz.premia.app"

echo "==> native deps"
npx expo install expo-crypto expo-dev-client
npm install --save-exact react-native-passkey@3.6.1

mkdir -p lib

cat > lib/mera.ts <<'PREMIA_EOF'
/**
 * Passkey accounts via mera.
 *
 * One passkey ceremony yields 32 PRF bytes. Those bytes seed an ordinary
 * secp256k1 key -- no smart account, no bundler, no custody backend. The
 * account is a normal EOA that viem can drive, and it reconstructs on any
 * device that can reach the same passkey.
 *
 * Namespaces (the "one passkey, many keys" idea): the same passkey mints
 * unrelated keys under different PRF salts. Wallet and Perpl API credential
 * are separate keys from one credential, and neither is ever stored.
 */
import {
  createPasskeyWithPrfOutput,
  getPasskeyPrfOutput,
  createSecp256k1SigningSession,
  createEd25519SigningSession,
  getEvmAddress,
} from "@category-labs/mera";
import { toViemAccount } from "@category-labs/mera/viem";
import {
  createWalletClient,
  http,
  sha256,
  stringToBytes,
  type LocalAccount,
} from "viem";
import { monad } from "./chain";
import { webAuthnClient } from "./webauthn";

/** The host the passkeys belong to. It serves /.well-known/assetlinks.json. */
export const RP_ID = process.env.EXPO_PUBLIC_RP_ID ?? "premia-swap.vercel.app";
const RP_NAME = "PREMIA";

/**
 * mera requires PRF salts of exactly 32 bytes. Hashing a readable label keeps
 * each namespace legible in code and exactly 32 bytes on the wire.
 */
const salt = (label: string): Uint8Array => sha256(stringToBytes(label), "bytes");

/** Distinct salts => unrelated keys from the same passkey. */
export const SALT = {
  wallet: salt("premia/wallet/v1"),
  perplApiKey: salt("premia/perpl-api-key/v1"),
  makerState: salt("premia/maker-state/v1"),
} as const;

export type Session = {
  address: `0x${string}`;
  account: LocalAccount;
  credentialId: string;
};

/** First run: create the passkey and the wallet key in one ceremony. */
export async function signUp(label: string): Promise<Session> {
  const created = await createPasskeyWithPrfOutput({
    rp: { id: RP_ID, name: RP_NAME },
    user: { name: label, displayName: label },
    prfSalt: SALT.wallet,
    webAuthnClient,
  });
  return sessionFromPrf(created.prfOutput, created.credentialId);
}

/** Returning user, any device. Nothing is read from storage. */
export async function signIn(): Promise<Session> {
  const got = await getPasskeyPrfOutput({
    rpId: RP_ID,
    prfSalt: SALT.wallet,
    webAuthnClient,
  });
  return sessionFromPrf(got.prfOutput, got.credentialId);
}

function sessionFromPrf(prfOutput: Uint8Array, credentialId: string): Session {
  const session = createSecp256k1SigningSession({ privateKey: prfOutput });
  const account = toViemAccount(session);
  return {
    address: getEvmAddress(session.publicKey) as `0x${string}`,
    account,
    credentialId,
  };
}

export function walletClient(account: LocalAccount) {
  return createWalletClient({ account, chain: monad, transport: http() });
}

/**
 * Perpl authenticates programmatic clients with an Ed25519 key. Deriving it
 * from the passkey under its own salt means the trading credential is
 * regenerable on any device and stored nowhere. Pass the wallet's
 * credentialId to pin the same passkey the wallet came from.
 */
export async function derivePerplApiKey(credentialId?: string) {
  const got = await getPasskeyPrfOutput({
    rpId: RP_ID,
    prfSalt: SALT.perplApiKey,
    webAuthnClient,
    ...(credentialId ? { credential: { credentialId } } : {}),
  });
  return createEd25519SigningSession({ privateKey: got.prfOutput });
}
PREMIA_EOF

cat > lib/webauthn.ts <<'PREMIA_EOF'
/**
 * Web: leave the client undefined so mera uses navigator.credentials.
 * iOS and Android resolve webauthn.native.ts instead (Metro platform suffix).
 */
import type { WebAuthnClient } from "@category-labs/mera";

export const webAuthnClient: WebAuthnClient | undefined = undefined;
PREMIA_EOF

cat > lib/webauthn.native.ts <<'PREMIA_EOF'
/**
 * iOS and Android: run the WebAuthn ceremonies through react-native-passkey
 * (Credential Manager on Android, AuthenticationServices on iOS).
 */
export { reactNativeWebAuthnClient as webAuthnClient } from "@category-labs/mera/react-native-webauthn-client";
PREMIA_EOF

cat > lib/polyfills.ts <<'PREMIA_EOF'
/**
 * Hermes ships no CSPRNG, and mera needs crypto.getRandomValues for WebAuthn
 * challenges and user handles. Must load before anything imports mera.
 */
import { getRandomValues } from "expo-crypto";

if (typeof globalThis.crypto?.getRandomValues !== "function") {
  Object.defineProperty(globalThis, "crypto", {
    configurable: true,
    value: { ...globalThis.crypto, getRandomValues },
  });
}
PREMIA_EOF

cat > index.ts <<'PREMIA_EOF'
import "./lib/polyfills"; // first: mera needs crypto.getRandomValues at import time
import { registerRootComponent } from "expo";
import App from "./App";

registerRootComponent(App);
PREMIA_EOF

echo "==> app.json: package id + associated domain"
RP_ID="$RP_ID" PKG="$PKG" node -e '
const fs = require("fs");
const pj = JSON.parse(fs.readFileSync("package.json", "utf8"));
pj.main = "index.ts";
fs.writeFileSync("package.json", JSON.stringify(pj, null, 2) + "\n");

const j = JSON.parse(fs.readFileSync("app.json", "utf8"));
const e = j.expo;
e.name = "PREMIA";
e.slug = e.slug || "premia-app";
e.android = { ...(e.android || {}), package: process.env.PKG };
e.ios = { ...(e.ios || {}), bundleIdentifier: process.env.PKG,
          associatedDomains: [`webcredentials:${process.env.RP_ID}`] };
fs.writeFileSync("app.json", JSON.stringify(j, null, 2) + "\n");
console.log("   android.package =", e.android.package);
'

cat > eas.json <<PREMIA_EOF
{
  "cli": { "version": ">= 16.0.0", "appVersionSource": "remote" },
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal",
      "android": { "buildType": "apk" },
      "env": { "EXPO_PUBLIC_RP_ID": "$RP_ID" }
    },
    "preview": {
      "distribution": "internal",
      "android": { "buildType": "apk" },
      "env": { "EXPO_PUBLIC_RP_ID": "$RP_ID" }
    }
  }
}
PREMIA_EOF

echo "EXPO_PUBLIC_RP_ID=$RP_ID" > .env

echo "==> typecheck"
npx tsc --noEmit && echo "   ok" || echo "   typecheck reported errors above -- paste them to Claude"

echo ""
echo "Done. RP ID = $RP_ID, package = $PKG"
echo "Next: npm i -g eas-cli && eas login && eas init"
