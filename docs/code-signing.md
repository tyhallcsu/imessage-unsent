# Code-signing and notarization

This document explains how to sign and notarize the `imu-watcher` daemon and the `IMUMenuBar.app` GUI for a release. The signing pipeline is implemented by [`scripts/sign-release.sh`](../scripts/sign-release.sh) and called automatically from [`scripts/build-release.sh`](../scripts/build-release.sh) and the [`Release` workflow](../.github/workflows/release.yml).

## Status of this scaffold

| Capability | State |
|---|---|
| Hardened Runtime + entitlements file in repo | ✅ ([`gui/entitlements.plist`](../gui/entitlements.plist)) |
| `scripts/sign-release.sh` — codesign + notarytool + stapler | ✅ |
| Workflow wiring (`release.yml` reads secrets, runs sign step) | ✅ |
| **Apple Developer ID cert provisioned and stored as secret** | ❌ — operator action below |
| **Apple ID + App-Specific Password for notarytool** | ❌ — operator action below |

Until the two operator actions are completed, every release run logs `Skipping codesign + notarize: missing env vars (...)` and ships unsigned artifacts. The unsigned path is intentionally supported so forks and dry-run builds work without Apple credentials.

## What gets signed

| Artifact | Codesign? | Notarize? | Staple? | Why |
|---|---|---|---|---|
| `IMUMenuBar.app` | yes | yes | yes | App bundles can be stapled; Gatekeeper checks the staple offline |
| `imu-watcher` (daemon binary) | yes | no | no | `xcrun stapler` only works on `.app` / `.dmg` / `.pkg`; CLI Mach-O binaries take only the codesign + Hardened Runtime |

Both are signed with `--options=runtime` (Hardened Runtime). The GUI is signed with the project entitlements file; the daemon is signed with the cert's default entitlements (no extra entitlements file).

## Sandbox status (intentionally NOT enabled)

[`gui/entitlements.plist`](../gui/entitlements.plist) does **not** set `com.apple.security.app-sandbox=true`. The reason is documented in that file's comment header: the GUI reads recovery archives from arbitrary paths (`RecoveryDetailLoader`) and uses Contacts via `CNContactStore`, both of which would need extra plumbing to work under the sandbox. Hardened Runtime alone is sufficient for notarization; the sandbox is a separate hardening step that should land as its own PR after the file-access and Contacts patterns have been adapted.

## Operator setup — one-time

### 1. Provision a Developer ID Application certificate

```bash
# In Keychain Access (or via Xcode → Preferences → Accounts → Manage Certificates)
# create a "Developer ID Application: <Your Name> (TEAMID)" cert.
# Then export the cert + private key as a single .p12:
#
#   Keychain Access → My Certificates → right-click your Developer ID
#   → Export → file format: Personal Information Exchange (.p12)
#   → set a strong export password (you'll need this for the secret below).
```

Convert the `.p12` to base64 for storing as a GitHub Actions secret:

```bash
base64 -i developer-id.p12 | pbcopy
```

### 2. Provision an App-Specific Password for notarytool

`notarytool` cannot use your normal Apple ID password. Generate an App-Specific Password at <https://account.apple.com/account/manage> → Sign-In and Security → App-Specific Passwords. Label it `imu-notarize` so you remember what it's for.

### 3. Set GitHub Actions secrets

In `Settings → Secrets and variables → Actions → New repository secret`:

| Secret name | Value | Required for |
|---|---|---|
| `APPLE_DEVELOPER_ID_CERT_BASE64` | base64 contents of the `.p12` (step 1) | signing |
| `APPLE_DEVELOPER_ID_CERT_PASSWORD` | the `.p12` export password (step 1) | signing |
| `APPLE_DEVELOPER_ID_NAME` | the cert's full common name, e.g. `Developer ID Application: Acme LLC (1A2B3C4D5E)` | signing |
| `APPLE_TEAM_ID` | your 10-character Developer Team ID, e.g. `1A2B3C4D5E` | signing + notarytool |
| `APPLE_NOTARIZE_USER` | the Apple ID email that owns the App-Specific Password (step 2) | notarization |
| `APPLE_NOTARIZE_PASSWORD` | the App-Specific Password itself (step 2) | notarization |

`scripts/sign-release.sh` only signs if the four signing secrets are all set; it only notarizes if the two notarization secrets are *also* set. The release pipeline degrades gracefully:

- 0/6 secrets set → unsigned artifacts (today's default)
- 4/6 (signing only) → signed artifacts, no notarization (Gatekeeper still warns on first launch)
- 6/6 → signed + notarized + stapled (no Gatekeeper warning)

### 4. Cut a test release

```bash
git tag v0.4.0-rc1
git push origin v0.4.0-rc1
```

Watch the Actions tab for the `Release` run. Look for one of these in the build step output:

- `==> Skipping codesign + notarize: missing env vars (...)` — secrets not all set yet.
- `==> Sign + notarize complete.` — full path succeeded.

When notarization succeeds, the workflow logs `xcrun stapler staple` output and the final `spctl --assess --type execute` is `accepted`.

## Local signing (advanced)

You can run `scripts/sign-release.sh` locally for testing without GitHub Actions, if you have the cert in your default keychain (no need to base64 it):

```bash
make release VERSION=v0.4.0-test
# build-release.sh calls sign-release.sh, which falls through to the
# "skipping" path because APPLE_DEVELOPER_ID_CERT_BASE64 isn't set.
```

To run signing locally, set all four `APPLE_DEVELOPER_ID_*` env vars in your shell. The base64 export is the same as for CI; the script doesn't care whether the keychain it provisions is on a Mac runner or your laptop.

## Verifying a signed build

After running `make release VERSION=v0.4.0` with secrets set, verify the artifacts:

```bash
# Daemon
codesign --verify --deep --strict --verbose=2 dist/imu-watcher-v0.4.0-arm64.tar.gz
# (Or extract first; codesign needs the binary, not the tarball.)

# GUI
unzip -q dist/IMUMenuBar-v0.4.0.zip
codesign --verify --deep --strict --verbose=2 IMUMenuBar.app
spctl --assess --type execute --verbose=2 IMUMenuBar.app
# Expected: "IMUMenuBar.app: accepted source=Notarized Developer ID"
```

If `spctl` reports `source=Developer ID` (without `Notarized`), the cert is right but notarization didn't run or didn't staple — check the Actions log for the `Submitting GUI to notarytool` step.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `errSecInternalComponent` during `codesign` | Keychain unlock failed. Check `APPLE_DEVELOPER_ID_CERT_PASSWORD` matches the export password from step 1. |
| `The specified item could not be found in the keychain.` | `APPLE_DEVELOPER_ID_NAME` doesn't match the cert's common name. Check exact spelling, including the trailing `(TEAMID)`. |
| `Authentication failed` from `notarytool` | App-Specific Password expired or revoked, or `APPLE_NOTARIZE_USER` is wrong. Regenerate per step 2. |
| `Invalid` from notarytool with no further detail | Run `xcrun notarytool log <submission-id>` against your developer account to see the detailed reasons. Most common: the binary wasn't built with `--options=runtime` (this script always sets it). |
| `xcrun stapler staple` fails with "could not validate" | Notarization succeeded but the ticket isn't yet visible to Apple's CDN. Re-running the stapler usually fixes it; in CI we accept the warning rather than fail the run. |

## Related issues

- [#19](https://github.com/tyhallcsu/imessage-unsent/issues/19) — release CI workflow (unsigned path), shipped in PR #51
- [#20](https://github.com/tyhallcsu/imessage-unsent/issues/20) — this issue
- Future: dedicated PR to enable App Sandbox once the file-access and Contacts patterns are adapted.
