/**
 * Web: leave the client undefined so mera uses navigator.credentials.
 * iOS and Android resolve webauthn.native.ts instead (Metro platform suffix).
 */
import type { WebAuthnClient } from "@category-labs/mera";

export const webAuthnClient: WebAuthnClient | undefined = undefined;
