#!/usr/bin/env bash
# Sign the locally-installed app + daemon with a code-signing identity you already
# have — typically an "Apple Development" certificate, which a FREE Apple ID can
# create in Xcode.
#
# This is NOT a substitute for Developer ID:
#   - it cannot be notarized (notarization needs a paid membership)
#   - other people's Macs will still warn on first launch
#   - it is not for distribution; the released artifacts stay unsigned
#
# What it DOES buy, and the reason this script exists: a stable code identity.
# TCC cannot bind a durable grant to an ad-hoc signature, which is why Contacts
# access is impossible on the shipped build (#179). A real certificate — even a
# free Apple Development one — gives TCC something to bind to, so the Contacts
# prompt can appear and the grant can stick.
#
# Usage:
#   scripts/sign-local.sh                 # lists identities and exits
#   scripts/sign-local.sh "Apple Development: you@example.com (TEAMID)"

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Applications/iMessage Unsent.app"
[[ -d "$APP" ]] || APP="/Applications/iMessage Unsent.app"
DAEMON="$HOME/Library/Application Support/imessage-unsent/bin/imu-watcher"
ENTITLEMENTS="$REPO_DIR/gui/entitlements.plist"

if [[ $# -lt 1 ]]; then
  echo "Available code-signing identities:"
  echo
  security find-identity -v -p codesigning | sed 's/^/  /'
  echo
  echo "Re-run with the identity in quotes, e.g.:"
  echo "  scripts/sign-local.sh \"Apple Development: you@example.com (TEAMID)\""
  echo
  echo "Prefer an 'Apple Development' identity. 'Apple Configurator' and"
  echo "'Apple Distribution' certificates are for other purposes."
  exit 0
fi

IDENTITY="$1"

if ! security find-identity -v -p codesigning | grep -qF "$IDENTITY"; then
  echo "error: identity not found in the login keychain: $IDENTITY" >&2
  echo "run without arguments to list what is available" >&2
  exit 1
fi

[[ -d "$APP" ]] || { echo "error: app not found; install it first" >&2; exit 1; }
[[ -f "$DAEMON" ]] || { echo "error: daemon not installed; run make daemon-install" >&2; exit 1; }

echo "==> signing app:    $APP"
codesign --force --deep --options=runtime \
  --entitlements "$ENTITLEMENTS" \
  --sign "$IDENTITY" "$APP"

echo "==> signing daemon: $DAEMON"
codesign --force --options=runtime --sign "$IDENTITY" "$DAEMON"

echo
echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
codesign --verify --strict --verbose=2 "$DAEMON" 2>&1 | sed 's/^/  /'
echo
codesign -dvv "$APP" 2>&1 | grep -E '^(Signature|Authority|TeamIdentifier)=' | sed 's/^/  /'

cat <<'NOTE'

Both binaries now have a stable identity. Two consequences:

  1. Contacts can now be granted. Open the app's Settings and click
     "Enable Contacts" — the macOS prompt should appear this time.

  2. Full Disk Access MAY need re-granting. Changing the signature changes the
     daemon's code identity, which can invalidate the grant — though measured on
     an adhoc-to-Apple-Development re-sign it survived. Check before touching it:

       launchctl kickstart -k gui/$(id -u)/com.imu.watcher
       printf '{"op":"status"}\n' | nc -U "$HOME/Library/Application Support/imessage-unsent/daemon.sock"

     If chat_db_readable is true you are done. If it is false, re-grant:
       System Settings → Privacy & Security → Full Disk Access
       toggle imu-watcher off, then on, then kickstart again

Re-running make daemon-install or reinstalling the app REPLACES these binaries
with unsigned ones, so re-run this script after any upgrade.
NOTE
