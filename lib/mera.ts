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
