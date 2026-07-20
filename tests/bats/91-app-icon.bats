#!/usr/bin/env bats

# Branding-integrity gates (#137).
#
# The About window and Finder/Dock both render the icon generated from the
# committed source PNG. These tests fail if:
#   - the source asset disappears or loses its alpha channel (an opaque RGB
#     PNG ships as a black square in Finder — see README "App icon"),
#   - scripts/build-app-icon.sh stops producing a valid AppIcon.icns,
#   - the rc-smoke packaging gate stops requiring AppIcon.icns inside the
#     released .app zip.
#
# sips/iconutil are macOS-native; the bats CI job runs on macos-latest.

load helpers

SOURCE_PNG="$REPO_DIR/assets/MacOS_AppIcon_iMessage_Unsent.png"
RC_SMOKE_SCRIPT="$REPO_DIR/scripts/rc_smoke.sh"

@test "icon source PNG exists and keeps its alpha channel" {
  [ -f "$SOURCE_PNG" ]
  run /usr/bin/sips -g hasAlpha "$SOURCE_PNG"
  [ "$status" -eq 0 ]
  [[ "$output" == *"hasAlpha: yes"* ]]
}

@test "build-app-icon.sh produces AppIcon.icns with all 10 iconset sizes" {
  local out_dir="$BATS_TEST_TMPDIR/icon-out"
  run bash "$REPO_DIR/scripts/build-app-icon.sh" "$SOURCE_PNG" "$out_dir"
  [ "$status" -eq 0 ]
  [ -f "$out_dir/AppIcon.icns" ]
  [ -s "$out_dir/AppIcon.icns" ]
  local count
  count="$(find "$out_dir/AppIcon.iconset" -name 'icon_*.png' | wc -l | tr -d ' ')"
  [ "$count" -eq 10 ]
}

@test "build-app-icon.sh fails clearly when the source PNG is missing" {
  run bash "$REPO_DIR/scripts/build-app-icon.sh" "$BATS_TEST_TMPDIR/nope.png" "$BATS_TEST_TMPDIR/out"
  [ "$status" -ne 0 ]
  [[ "$output" == *"source PNG not found"* ]]
}

@test "rc-smoke packaging gate requires AppIcon.icns inside the released .app" {
  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    for entry in \"\${GUI_REQUIRED_ENTRIES[@]}\"; do
      printf '%s\n' \"\$entry\"
    done
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"iMessage Unsent.app/Contents/Resources/AppIcon.icns"* ]]
}
