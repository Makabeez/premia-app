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
