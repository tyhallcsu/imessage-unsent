#!/usr/bin/env bash
# Report what the signing pipeline needs and what is currently configured.
#
# Safe to run any time — read-only, no secrets printed, exit 0 regardless.
# Exists because `docs/code-signing.md` describes a target state and there was
# no way to ask "where am I now?" without cutting a release and reading the log.

set -uo pipefail

ok() { printf '  \033[32m✓\033[0m %s\n' "$1"; }
no() { printf '  \033[31m✗\033[0m %s\n' "$1"; }
info() { printf '  \033[2m·\033[0m %s\n' "$1"; }

echo
echo "Signing status"
echo "=============="
echo

echo "Apple credentials (required for Developer ID signing + notarization)"
missing=0
for var in APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD \
           APPLE_DEVELOPER_ID_NAME APPLE_TEAM_ID \
           APPLE_NOTARIZE_USER APPLE_NOTARIZE_PASSWORD; do
  # Presence only — never the value.
  if [[ -n "${!var:-}" ]]; then ok "$var is set"; else no "$var is not set"; missing=$((missing + 1)); fi
done
echo

echo "Signing identities in the login keychain"
devid="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Developer ID Application' || true)"
appledev="$(security find-identity -v -p codesigning 2>/dev/null | grep -c 'Apple Development' || true)"
devid="${devid:-0}"; appledev="${appledev:-0}"
if [[ "$devid" -gt 0 ]]; then
  ok "Developer ID Application certificate present ($devid)"
else
  no "no Developer ID Application certificate"
  info "requires a PAID Apple Developer Program membership — a free Apple ID cannot issue one"
fi
if [[ "$appledev" -gt 0 ]]; then
  ok "Apple Development certificate present ($appledev)"
  info "a free Apple ID can create these in Xcode; they cannot notarize or be"
  info "distributed, but they DO give a stable code identity that TCC can bind to"
else
  info "no Apple Development certificate (free Apple IDs can create one in Xcode)"
fi
echo

echo "Tooling"
command -v codesign >/dev/null && ok "codesign" || no "codesign"
if xcrun --find notarytool >/dev/null 2>&1; then ok "notarytool"; else no "notarytool (needs full Xcode)"; fi
command -v stapler >/dev/null 2>&1 || xcrun --find stapler >/dev/null 2>&1 \
  && ok "stapler" || no "stapler"
echo

echo "Currently installed build"
APP="$HOME/Applications/iMessage Unsent.app"
[[ -d "$APP" ]] || APP="/Applications/iMessage Unsent.app"
if [[ -d "$APP" ]]; then
  sig="$(codesign -dvv "$APP" 2>&1 | grep -E '^Signature=' | cut -d= -f2)"
  auth="$(codesign -dvv "$APP" 2>&1 | grep -m1 '^Authority=' | cut -d= -f2-)"
  case "$sig" in
    adhoc)
      no "app is ad-hoc signed"
      info "TCC cannot bind a durable grant to an ad-hoc identity — this is why"
      info "Contacts cannot be granted (see issue #179)"
      ;;
    "") no "app is unsigned" ;;
    *)  ok "app signature: $sig${auth:+ (${auth})}" ;;
  esac
else
  info "no installed app found"
fi
echo

if [[ "$missing" -gt 0 ]]; then
  echo "Result: releases will ship UNSIGNED (${missing}/6 credentials missing)."
  echo "        This is a supported path — see docs/code-signing.md."
else
  echo "Result: credentials complete; releases will be signed and notarized."
fi
echo
