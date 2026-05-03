#!/usr/bin/env bash
# Build release artifacts for the daemon (imu-watcher) and GUI (IMUMenuBar.app).
#
# Usage: scripts/build-release.sh <version> [output-dir]
#   <version>     e.g. v0.4.0 or v0.4.0-rc1 (the leading "v" is required)
#   [output-dir]  defaults to ./dist
#
# Produces, under <output-dir>/:
#   imu-watcher-<version>-<arch>.tar.gz   + .sha256
#     ├── imu-watcher                     (release-mode daemon binary)
#     ├── scripts/                        (recover.sh + lib/)
#     ├── com.imu.watcher.plist           (LaunchAgent template)
#     ├── install.sh                      (a thin wrapper around scripts/install-daemon.sh)
#     ├── LICENSE
#     └── README.md
#   IMUMenuBar-<version>.zip               + .sha256
#     └── IMUMenuBar.app/                 (release-mode menu bar app bundle)
#
# Code-signing and notarization are NOT performed by this script — that lives
# in scripts/sign-release.sh (issue #20). Artifacts produced here are
# always unsigned; the release workflow surfaces this in the release body.
#
# This script is platform-neutral about the build steps but only runs on
# macOS (it produces a .app bundle).

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version> [output-dir]" >&2
  exit 2
fi

VERSION="$1"
OUTPUT_DIR="${2:-dist}"

if [[ ! "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]]; then
  echo "::error::version must look like vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-prerelease, got: $VERSION" >&2
  exit 1
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "::error::release builds must run on macOS (Darwin), got: $(uname -s)" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCH="$(uname -m)"
DAEMON_TARBALL_NAME="imu-watcher-${VERSION}-${ARCH}.tar.gz"
GUI_ZIP_NAME="IMUMenuBar-${VERSION}.zip"
STAGE_DIR="$(mktemp -d -t imu-release.XXXXXX)"
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR_ABS="$(cd "$OUTPUT_DIR" && pwd)"

log() { printf '==> %s\n' "$*"; }

# --- Daemon ----------------------------------------------------------------

log "Building daemon (swift build -c release)"
swift build --package-path "$ROOT_DIR/daemon" -c release

DAEMON_BIN_DIR="$(swift build --package-path "$ROOT_DIR/daemon" -c release --show-bin-path)"
DAEMON_BIN="$DAEMON_BIN_DIR/imu-watcher"
if [[ ! -x "$DAEMON_BIN" ]]; then
  echo "::error::expected daemon binary at $DAEMON_BIN" >&2
  exit 1
fi

DAEMON_STAGE="$STAGE_DIR/imu-watcher-${VERSION}"
mkdir -p "$DAEMON_STAGE/scripts"
install -m 0755 "$DAEMON_BIN" "$DAEMON_STAGE/imu-watcher"
cp -R "$ROOT_DIR/scripts/recover.sh" "$DAEMON_STAGE/scripts/recover.sh"
cp -R "$ROOT_DIR/scripts/lib" "$DAEMON_STAGE/scripts/lib"
cp -R "$ROOT_DIR/scripts/decode.py" "$DAEMON_STAGE/scripts/decode.py"
# Strip Python build artifacts that get picked up incidentally.
find "$DAEMON_STAGE/scripts" -name __pycache__ -type d -prune -exec rm -rf {} +
find "$DAEMON_STAGE/scripts" -name '*.pyc' -delete
cp "$ROOT_DIR/daemon/com.imu.watcher.plist" "$DAEMON_STAGE/com.imu.watcher.plist"
cp "$ROOT_DIR/scripts/install-daemon.sh" "$DAEMON_STAGE/install.sh"
chmod 0755 "$DAEMON_STAGE/install.sh"
[[ -f "$ROOT_DIR/LICENSE" ]] && cp "$ROOT_DIR/LICENSE" "$DAEMON_STAGE/LICENSE"
[[ -f "$ROOT_DIR/README.md" ]] && cp "$ROOT_DIR/README.md" "$DAEMON_STAGE/README.md"

log "Packaging daemon -> $DAEMON_TARBALL_NAME"
tar -C "$STAGE_DIR" -czf "$OUTPUT_DIR_ABS/$DAEMON_TARBALL_NAME" "imu-watcher-${VERSION}"
( cd "$OUTPUT_DIR_ABS" && shasum -a 256 "$DAEMON_TARBALL_NAME" > "${DAEMON_TARBALL_NAME}.sha256" )

# --- GUI .app bundle -------------------------------------------------------

log "Building GUI menu bar app (swift build -c release)"
swift build --package-path "$ROOT_DIR/gui" -c release
GUI_BIN_DIR="$(swift build --package-path "$ROOT_DIR/gui" -c release --show-bin-path)"
GUI_BIN="$GUI_BIN_DIR/IMUMenuBar"
if [[ ! -x "$GUI_BIN" ]]; then
  echo "::error::expected gui binary at $GUI_BIN" >&2
  exit 1
fi

APP_STAGE="$STAGE_DIR/IMUMenuBar.app"
APP_CONTENTS="$APP_STAGE/Contents"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources"
install -m 0755 "$GUI_BIN" "$APP_CONTENTS/MacOS/IMUMenuBar"
cp "$ROOT_DIR/gui/Info.plist" "$APP_CONTENTS/Info.plist"
# Add the version into the Info.plist so the GUI reports it (CFBundleShortVersionString).
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION#v}" "$APP_CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}" "$APP_CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string ${VERSION#v}" "$APP_CONTENTS/Info.plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION#v}" "$APP_CONTENTS/Info.plist"

log "Packaging GUI -> $GUI_ZIP_NAME"
( cd "$STAGE_DIR" && /usr/bin/zip -qry "$OUTPUT_DIR_ABS/$GUI_ZIP_NAME" "IMUMenuBar.app" )
( cd "$OUTPUT_DIR_ABS" && shasum -a 256 "$GUI_ZIP_NAME" > "${GUI_ZIP_NAME}.sha256" )

# --- Summary ---------------------------------------------------------------

log "Done. Artifacts in $OUTPUT_DIR_ABS:"
( cd "$OUTPUT_DIR_ABS" && ls -lh "$DAEMON_TARBALL_NAME" "${DAEMON_TARBALL_NAME}.sha256" "$GUI_ZIP_NAME" "${GUI_ZIP_NAME}.sha256" )
log "Note: artifacts are UNSIGNED. Wire scripts/sign-release.sh (issue #20) once Developer ID secrets are provisioned."
