#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
EXECUTABLE_NAME="IMUMenuBar"
APP_DISPLAY_NAME="iMessage Unsent"
BUNDLE_ID="com.imessage-unsent.app"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/gui"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
VERSION_SOURCE="$ROOT_DIR/daemon/Sources/IMUCore/Version.swift"

pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true

swift build --package-path "$PACKAGE_DIR"
BUILD_BINARY="$(swift build --package-path "$PACKAGE_DIR" --show-bin-path)/$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_CONTENTS/Resources"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$PACKAGE_DIR/Info.plist" "$INFO_PLIST"

APP_VERSION="${IMU_APP_VERSION:-$(awk -F '\"' '/^public let imuDaemonVersion = / { print $2; exit }' "$VERSION_SOURCE")}"
if [[ -n "$APP_VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $APP_VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $APP_VERSION" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$INFO_PLIST"
fi

# Stage AppIcon.icns so the dev-built .app shows the real icon in Finder/Dock.
bash "$ROOT_DIR/scripts/build-app-icon.sh"
cp "$ROOT_DIR/gui/.build/icon/AppIcon.icns" "$APP_CONTENTS/Resources/AppIcon.icns"

# Ad-hoc codesign so the bundle has a stable code identity bound to its
# Info.plist. Without this, macOS treats each rebuild as a new app and will
# not register the bundle for Notifications / Contacts / etc., which makes
# requestAuthorization silently no-op. The signature is ad-hoc (no Developer
# ID) so Gatekeeper still warns on first launch — clear with `xattr -dr
# com.apple.quarantine "$APP_BUNDLE"` if needed.
codesign --force --sign - --timestamp=none "$APP_BINARY"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$EXECUTABLE_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
