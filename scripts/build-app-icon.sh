#!/usr/bin/env bash
# Generate the macOS AppIcon.icns for the IMUMenuBar .app bundle from the
# committed source PNG at assets/MacOS_AppIcon_iMessage_Unsent.png.
#
# Output:
#   gui/.build/icon/AppIcon.iconset/   (10 sized PNGs, intermediate)
#   gui/.build/icon/AppIcon.icns       (final, copied into IMUMenuBar.app/Contents/Resources)
#
# The output dir lives under gui/.build/ so it is automatically gitignored
# (.build/ is already in .gitignore) and re-runnable from a clean checkout.
#
# Usage:
#   bash scripts/build-app-icon.sh                  # default paths
#   bash scripts/build-app-icon.sh <source.png>     # override source
#   bash scripts/build-app-icon.sh <source.png> <out-dir>
#
# Consumers:
#   - scripts/build-release.sh  (release artifact)
#   - script/build_and_run.sh   (local-dev `make gui-run`)
#   - make icon                 (manual regen)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SOURCE_PNG="${1:-$ROOT_DIR/assets/MacOS_AppIcon_iMessage_Unsent.png}"
OUT_DIR="${2:-$ROOT_DIR/gui/.build/icon}"
ICONSET_DIR="$OUT_DIR/AppIcon.iconset"
ICNS_OUT="$OUT_DIR/AppIcon.icns"

log() { printf '==> %s\n' "$*"; }

if [[ ! -f "$SOURCE_PNG" ]]; then
  echo "::error::source PNG not found: $SOURCE_PNG" >&2
  echo "Place the icon at assets/MacOS_AppIcon_iMessage_Unsent.png or pass a path as \$1." >&2
  exit 1
fi

for cmd in sips iconutil; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "::error::required tool not found: $cmd (macOS-native; this script must run on macOS)" >&2
    exit 1
  fi
done

log "Source: $SOURCE_PNG"
log "Output: $ICNS_OUT"

# Clean and recreate so a stale partial run cannot poison the output.
rm -rf "$ICONSET_DIR" "$ICNS_OUT"
mkdir -p "$ICONSET_DIR"

# Standard macOS .iconset sizes. iconutil REQUIRES exactly these names.
# (See `man iconutil` and Apple TN2326.)
sizes=(
  "16:icon_16x16.png"
  "32:icon_16x16@2x.png"
  "32:icon_32x32.png"
  "64:icon_32x32@2x.png"
  "128:icon_128x128.png"
  "256:icon_128x128@2x.png"
  "256:icon_256x256.png"
  "512:icon_256x256@2x.png"
  "512:icon_512x512.png"
  "1024:icon_512x512@2x.png"
)

log "Generating ${#sizes[@]} sized PNGs into $ICONSET_DIR/"
for entry in "${sizes[@]}"; do
  px="${entry%%:*}"
  name="${entry##*:}"
  /usr/bin/sips -s format png -z "$px" "$px" "$SOURCE_PNG" \
    --out "$ICONSET_DIR/$name" >/dev/null
done

log "Compiling .icns via iconutil"
/usr/bin/iconutil -c icns "$ICONSET_DIR" -o "$ICNS_OUT"

if [[ ! -f "$ICNS_OUT" ]]; then
  echo "::error::iconutil did not produce $ICNS_OUT" >&2
  exit 1
fi

log "OK: $(ls -lh "$ICNS_OUT" | awk '{print $5, $9}')"
