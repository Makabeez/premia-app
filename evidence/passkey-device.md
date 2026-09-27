# Passkey wallet on a real device (28 Sept 2026)

- Device: Samsung Galaxy S25 Ultra, Google Password Manager as passkey provider
- Build: EAS development build, package `xyz.premia.app`
- Relying party: `premia-swap.vercel.app` (Digital Asset Links: `handle_all_urls` + `get_login_creds`)

| step | result |
|------|--------|
| Create account (passkey + PRF, salt `sha256("premia/wallet/v1")`) | `0xD410065655dd3107e164e486AD80A8A138D34Dc5` |
| Uninstall app, reinstall, sign in with the same passkey | same address |

Nothing is stored on the device: the secp256k1 key is re-derived from the passkey's PRF output
on every sign-in. Uninstalling wipes all app storage, so a matching address after reinstall
can only come from the passkey.

Lesson: Android rejected passkey creation with `RP ID cannot be validated` until
`delegate_permission/common.handle_all_urls` was added next to `get_login_creds`,
as Google's FIDO2 docs require.
