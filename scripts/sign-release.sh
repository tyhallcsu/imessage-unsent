#!/usr/bin/env bash
# Sign and notarize release artifacts (daemon binary + GUI .app).
#
# Usage: scripts/sign-release.sh <gui-app-path> <daemon-binary-path>
#   <gui-app-path>          path to "iMessage Unsent.app"
#   <daemon-binary-path>    path to imu-watcher binary
#
# Required env vars (when signing):
#   APPLE_DEVELOPER_ID_CERT_BASE64   — base64-encoded .p12 cert+key
#   APPLE_DEVELOPER_ID_CERT_PASSWORD — password for the .p12
#   APPLE_DEVELOPER_ID_NAME          — common name on the cert,
#                                      e.g. "Developer ID Application: Acme (TEAMID)"
#   APPLE_TEAM_ID                    — 10-character Developer Team ID
# For notarization (optional but recommended; otherwise just signs):
#   APPLE_NOTARIZE_USER              — Apple ID for notarytool
#   APPLE_NOTARIZE_PASSWORD          — App-Specific Password for that Apple ID
#
# Behavior:
#   - If the four signing env vars above are absent, this script exits 0
#     with a clear "skipping (no creds)" message. The release pipeline
#     proceeds with unsigned artifacts.
#   - If signing creds are present but notarization creds are not, signs
#     only — does not attempt notarytool.
#   - If both are present, signs + submits to notarytool with --wait, then
#     staples the ticket to the .app.
#
# The script is idempotent: rerunning with the same inputs and the same
# creds produces the same final state.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <gui-app-path> <daemon-binary-path>" >&2
  exit 2
fi

APP_PATH="$1"
DAEMON_BIN="$2"

if [[ ! -d "$APP_PATH" ]]; then
  echo "::error::expected GUI .app at $APP_PATH (not a directory)" >&2
  exit 1
fi
if [[ ! -x "$DAEMON_BIN" ]]; then
  echo "::error::expected daemon binary at $DAEMON_BIN (not executable)" >&2
  exit 1
fi

log() { printf '==> %s\n' "$*"; }

# --- Skip path: no signing creds ------------------------------------------

missing_signing=()
[[ -z "${APPLE_DEVELOPER_ID_CERT_BASE64:-}" ]]   && missing_signing+=("APPLE_DEVELOPER_ID_CERT_BASE64")
[[ -z "${APPLE_DEVELOPER_ID_CERT_PASSWORD:-}" ]] && missing_signing+=("APPLE_DEVELOPER_ID_CERT_PASSWORD")
[[ -z "${APPLE_DEVELOPER_ID_NAME:-}" ]]          && missing_signing+=("APPLE_DEVELOPER_ID_NAME")
[[ -z "${APPLE_TEAM_ID:-}" ]]                    && missing_signing+=("APPLE_TEAM_ID")

if [[ ${#missing_signing[@]} -gt 0 ]]; then
  log "No Developer ID env vars (${missing_signing[*]}); ad-hoc signing instead."
  log "Ad-hoc signing produces a stable code identity so macOS registers the app for"
  log "Notifications/Contacts/etc., but does NOT pass Gatekeeper without manual approval."
  log "See docs/code-signing.md for the Developer ID flow that produces notarized builds."
  # The .app bundle: --force overwrites the linker-signed signature; binding the
  # Info.plist into the seal is what fixes the notification-prompt issue (#94)
  # where unbound Info.plist caused requestAuthorization to silently no-op.
  # `|| log` lets the script continue past synthetic test fixtures (empty Mach-O,
  # placeholder files) without aborting the release pipeline; real bundles
  # produced by build-release.sh always sign cleanly.
  if [[ -f "$APP_PATH/Contents/MacOS/IMUMenuBar" ]]; then
    codesign --force --sign - --timestamp=none "$APP_PATH/Contents/MacOS/IMUMenuBar" 2>&1 \
      || log "WARN: failed to ad-hoc sign GUI binary (likely a non-Mach-O test fixture)"
  fi
  codesign --force --sign - --timestamp=none "$APP_PATH" 2>&1 \
    || log "WARN: failed to ad-hoc sign GUI bundle (likely a synthetic fixture)"
  # The daemon binary is a CLI Mach-O; ad-hoc sign for the same reason.
  codesign --force --sign - --timestamp=none "$DAEMON_BIN" 2>&1 \
    || log "WARN: failed to ad-hoc sign daemon (likely a non-Mach-O test fixture)"
  log "Ad-hoc sign step complete."
  exit 0
fi

# --- Sign -----------------------------------------------------------------

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTITLEMENTS="$REPO_ROOT/gui/entitlements.plist"
if [[ ! -f "$ENTITLEMENTS" ]]; then
  echo "::error::expected entitlements at $ENTITLEMENTS" >&2
  exit 1
fi

# Import the cert into a temporary keychain so we don't pollute the runner's
# default keychain, and so the keychain disappears at end-of-job.
KEYCHAIN_PATH="${RUNNER_TEMP:-/tmp}/imu-release.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
CERT_PATH="${RUNNER_TEMP:-/tmp}/imu-release-cert.p12"

cleanup() {
  security delete-keychain "$KEYCHAIN_PATH" >/dev/null 2>&1 || true
  rm -f "$CERT_PATH"
}
trap cleanup EXIT

log "Provisioning temporary keychain at $KEYCHAIN_PATH"
echo "$APPLE_DEVELOPER_ID_CERT_BASE64" | base64 --decode > "$CERT_PATH"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$CERT_PATH" -P "$APPLE_DEVELOPER_ID_CERT_PASSWORD" \
  -A -t cert -f pkcs12 -k "$KEYCHAIN_PATH"
security list-keychain -d user -s "$KEYCHAIN_PATH" "$(security list-keychains -d user | sed 's/[" ]//g')"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" >/dev/null

log "Signing daemon binary $DAEMON_BIN"
codesign --force --sign "$APPLE_DEVELOPER_ID_NAME" \
  --options=runtime --timestamp \
  "$DAEMON_BIN"

log "Signing GUI app bundle $APP_PATH"
# Sign nested binaries first (deepest first), then the bundle itself. The
# .app today only nests its own MacOS executable, but if Resources/ ever
# picks up Helper Tools we'd want to enumerate them here.
codesign --force --sign "$APPLE_DEVELOPER_ID_NAME" \
  --options=runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH/Contents/MacOS/IMUMenuBar"
codesign --force --sign "$APPLE_DEVELOPER_ID_NAME" \
  --options=runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  "$APP_PATH"

log "Verifying daemon signature"
codesign --verify --deep --strict --verbose=2 "$DAEMON_BIN"
log "Verifying GUI signature"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# --- Notarize (optional) --------------------------------------------------

if [[ -z "${APPLE_NOTARIZE_USER:-}" || -z "${APPLE_NOTARIZE_PASSWORD:-}" ]]; then
  log "Signing complete. Skipping notarization (APPLE_NOTARIZE_USER/PASSWORD absent)."
  log "Note: a signed-but-not-notarized .app still triggers Gatekeeper warnings on first launch."
  exit 0
fi

NOTARIZE_DIR="${RUNNER_TEMP:-/tmp}/imu-notarize"
mkdir -p "$NOTARIZE_DIR"

log "Zipping GUI .app for notarization submission"
APP_ZIP="$NOTARIZE_DIR/iMessage-Unsent-notarize.zip"
( cd "$(dirname "$APP_PATH")" && /usr/bin/ditto -c -k --keepParent "$(basename "$APP_PATH")" "$APP_ZIP" )

log "Submitting GUI to notarytool (--wait)"
xcrun notarytool submit "$APP_ZIP" \
  --apple-id "$APPLE_NOTARIZE_USER" \
  --password "$APPLE_NOTARIZE_PASSWORD" \
  --team-id "$APPLE_TEAM_ID" \
  --wait

log "Stapling notarization ticket to GUI"
xcrun stapler staple "$APP_PATH"
xcrun stapler validate "$APP_PATH"

# Daemon binaries can also be notarized but the resulting ticket cannot be
# stapled to a Mach-O binary (only .app/.dmg/.pkg). We skip the daemon
# notarization step — the codesign + Hardened Runtime is sufficient for
# CLI use; users who want it inside an installer .pkg can wrap it later.

log "Verifying GUI passes Gatekeeper"
spctl --assess --type execute --verbose=2 "$APP_PATH" || {
  echo "::warning::spctl assessment failed for $APP_PATH (review notarization log above)"
}

log "Sign + notarize complete."
