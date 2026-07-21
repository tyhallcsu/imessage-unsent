#!/usr/bin/env bats

# Tests for the release tooling under scripts/.
#
# These exercise the fast paths (arg validation, release-notes generation
# against the live repo). The actual swift build pipeline is covered by the
# release.yml workflow itself — duplicating it in bats would add 30-60s per
# run for no extra signal.

load helpers

@test "build-release.sh requires a version argument" {
  run bash "$REPO_DIR/scripts/build-release.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "build-release.sh rejects a non-semver version" {
  run bash "$REPO_DIR/scripts/build-release.sh" "0.4.0"
  [ "$status" -eq 1 ]
  [[ "$output" == *"version must look like"* ]]
}

@test "build-release.sh accepts a stable semver version (validation only)" {
  run bash -c "
    set -e
    cd '$REPO_DIR'
    # Stop right after validation by overriding swift to fail fast — we only
    # want to confirm the version regex passed.
    PATH='$BATS_TEST_TMPDIR/fake-bin:$PATH' \
      bash scripts/build-release.sh v0.4.0 '$BATS_TEST_TMPDIR/dist' 2>&1 | head -5 || true
  "
  # The header log line is emitted before any swift call, so seeing it
  # proves arg validation passed without needing to actually run swift.
  [[ "$output" == *"Building daemon"* ]] || [[ "$output" == *"swift"* ]] || [[ "$output" == *"==>"* ]]
}

@test "build-release.sh accepts a pre-release version" {
  run bash -c "
    set +e
    bash '$REPO_DIR/scripts/build-release.sh' v0.4.0-rc1 '$BATS_TEST_TMPDIR/dist' 2>&1 | head -3
  "
  # Validation must pass; later steps may fail in this minimal env, that's fine.
  [[ "$output" != *"version must look like"* ]]
}

@test "release-notes.sh requires a version argument" {
  run bash "$REPO_DIR/scripts/release-notes.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "release-notes.sh produces a markdown header for the requested tag" {
  run bash "$REPO_DIR/scripts/release-notes.sh" v9.9.9
  [ "$status" -eq 0 ]
  [[ "$output" == "# v9.9.9"* ]]
}

@test "release-notes.sh emits an Artifacts section naming the real artifacts" {
  run bash "$REPO_DIR/scripts/release-notes.sh" v9.9.9
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Artifacts"* ]]
  [[ "$output" == *"imu-watcher-VERSION-"* ]]
  # Must match the GUI zip name build-release.sh actually produces (#115 / F-M7).
  [[ "$output" == *"iMessage-Unsent-VERSION.zip"* ]]
  [[ "$output" != *"IMUMenuBar-VERSION.zip"* ]]
}

@test "release-notes artifact names match build-release.sh GUI_ZIP_NAME" {
  # Guard against future drift: the zip name in the notes must equal the prefix
  # build-release.sh derives, so they can never silently diverge again.
  local gui_prefix
  gui_prefix="$(grep -oE 'GUI_ZIP_NAME="[^"]*"' "$REPO_DIR/scripts/build-release.sh" | head -1)"
  [[ "$gui_prefix" == *'iMessage-Unsent-${VERSION}.zip'* ]]
  run bash "$REPO_DIR/scripts/release-notes.sh" v9.9.9
  [[ "$output" == *"iMessage-Unsent-VERSION.zip"* ]]
}

@test "release-notes.sh categorizes a feat commit under Highlights" {
  # Build a tiny throwaway repo with two commits: one feat, one fix.
  local repo="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo seed > a; git add a; git commit -q -m "feat: ship first thing"
    echo more > b; git add b; git commit -q -m "fix: stop the leak"
    echo even-more > c; git add c; git commit -q -m "docs: add release notes"
    echo other > d; git add d; git commit -q -m "perf: make the leak faster"
  )

  run bash -c "cd '$repo' && bash '$REPO_DIR/scripts/release-notes.sh' v0.1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"## Highlights"* ]]
  [[ "$output" == *"ship first thing"* ]]
  [[ "$output" == *"## Fixes"* ]]
  [[ "$output" == *"stop the leak"* ]]
  [[ "$output" == *"## Documentation"* ]]
  [[ "$output" == *"## Other"* ]]
  [[ "$output" == *"perf: make the leak faster"* ]]
}

@test "release-notes.sh excludes merge commits" {
  local repo="$BATS_TEST_TMPDIR/repo-merge"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo seed > a; git add a; git commit -q -m "feat: initial"
    git checkout -q -b side
    echo s > s; git add s; git commit -q -m "fix: side fix"
    git checkout -q -
    git merge -q --no-ff side -m "Merge pull request #1 from side" >/dev/null
  )

  run bash -c "cd '$repo' && bash '$REPO_DIR/scripts/release-notes.sh' v0.1.0"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Merge pull request"* ]]
  [[ "$output" == *"side fix"* ]]
}

@test "release-notes.sh handles a repo with no previous tag (first release)" {
  local repo="$BATS_TEST_TMPDIR/repo-first"
  mkdir -p "$repo"
  ( cd "$repo"
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test"
    echo seed > a; git add a; git commit -q -m "feat: initial release"
  )

  run bash -c "cd '$repo' && bash '$REPO_DIR/scripts/release-notes.sh' v0.1.0"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All commits (first release)"* ]]
  [[ "$output" == *"initial release"* ]]
}

@test "sign-release.sh requires both arguments" {
  run bash "$REPO_DIR/scripts/sign-release.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]

  run bash "$REPO_DIR/scripts/sign-release.sh" "$BATS_TEST_TMPDIR/some.app"
  [ "$status" -eq 2 ]
}

@test "sign-release.sh rejects missing GUI .app path" {
  local app="$BATS_TEST_TMPDIR/Missing.app"
  local daemon="$BATS_TEST_TMPDIR/imu-watcher"
  : > "$daemon"; chmod +x "$daemon"
  run bash "$REPO_DIR/scripts/sign-release.sh" "$app" "$daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected GUI .app at"* ]]
}

@test "sign-release.sh rejects non-executable daemon path" {
  local app="$BATS_TEST_TMPDIR/IMUMenuBar.app"; mkdir -p "$app"
  local daemon="$BATS_TEST_TMPDIR/imu-watcher"; : > "$daemon"  # not chmod +x
  run bash "$REPO_DIR/scripts/sign-release.sh" "$app" "$daemon"
  [ "$status" -eq 1 ]
  [[ "$output" == *"expected daemon binary at"* ]]
}

@test "sign-release.sh ad-hoc signs with clear log when no signing creds present" {
  local app="$BATS_TEST_TMPDIR/IMUMenuBar.app"; mkdir -p "$app/Contents/MacOS"
  local daemon="$BATS_TEST_TMPDIR/imu-watcher"; : > "$daemon"; chmod +x "$daemon"

  run bash -c "
    unset APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD APPLE_DEVELOPER_ID_NAME APPLE_TEAM_ID APPLE_NOTARIZE_USER APPLE_NOTARIZE_PASSWORD
    bash '$REPO_DIR/scripts/sign-release.sh' '$app' '$daemon'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"ad-hoc signing instead"* ]]
  [[ "$output" == *"APPLE_DEVELOPER_ID_CERT_BASE64"* ]]
  [[ "$output" == *"docs/code-signing.md"* ]]
}

@test "sign-release.sh names every missing signing var when partially configured" {
  local app="$BATS_TEST_TMPDIR/IMUMenuBar.app"; mkdir -p "$app/Contents/MacOS"
  local daemon="$BATS_TEST_TMPDIR/imu-watcher"; : > "$daemon"; chmod +x "$daemon"

  run bash -c "
    unset APPLE_DEVELOPER_ID_CERT_BASE64 APPLE_DEVELOPER_ID_CERT_PASSWORD APPLE_DEVELOPER_ID_NAME APPLE_TEAM_ID
    export APPLE_DEVELOPER_ID_NAME='Developer ID Application: Test (TEST123456)'
    bash '$REPO_DIR/scripts/sign-release.sh' '$app' '$daemon'
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"APPLE_DEVELOPER_ID_CERT_BASE64"* ]]
  [[ "$output" == *"APPLE_DEVELOPER_ID_CERT_PASSWORD"* ]]
  [[ "$output" == *"APPLE_TEAM_ID"* ]]
}

# --- standalone tarball install (#151 / R-1) --------------------------------

@test "install-daemon.sh installs the shipped tarball layout without swift build" {
  # Simulate the extracted release tarball: prebuilt binary + plist template
  # + scripts/ sitting NEXT TO the script (shipped as install.sh). The old
  # installer resolved everything repo-relative and hard-failed here.
  local stage="$BATS_TEST_TMPDIR/tarball"
  mkdir -p "$stage/scripts"
  printf '#!/bin/sh\nexit 0\n' > "$stage/imu-watcher"
  chmod +x "$stage/imu-watcher"
  cp "$REPO_DIR/daemon/com.imu.watcher.plist" "$stage/com.imu.watcher.plist"
  cp "$REPO_DIR/scripts/recover.sh" "$stage/scripts/recover.sh"
  cp -R "$REPO_DIR/scripts/lib" "$stage/scripts/lib"
  cp "$REPO_DIR/scripts/install-daemon.sh" "$stage/install.sh"
  chmod +x "$stage/install.sh"

  # swift must NOT be invoked in this layout; launchctl is stubbed out.
  local stub_bin="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$stub_bin"
  printf '#!/bin/sh\necho "swift must not run in tarball layout" >&2\nexit 97\n' > "$stub_bin/swift"
  printf '#!/bin/sh\nexit 0\n' > "$stub_bin/launchctl"
  chmod +x "$stub_bin/swift" "$stub_bin/launchctl"

  local fake_home="$BATS_TEST_TMPDIR/home"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" PATH="$stub_bin:$PATH" bash "$stage/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" != *"swift must not run"* ]]

  [ -x "$fake_home/Library/Application Support/imessage-unsent/bin/imu-watcher" ]
  [ -f "$fake_home/Library/Application Support/imessage-unsent/scripts/recover.sh" ]
  [ -f "$fake_home/Library/LaunchAgents/com.imu.watcher.plist" ]
  grep -q "$fake_home/Library/Application Support/imessage-unsent/bin/imu-watcher" \
    "$fake_home/Library/LaunchAgents/com.imu.watcher.plist"
}

@test "install-daemon.sh repo layout still routes through swift build" {
  # Guard the OTHER branch: from a checkout (no sibling prebuilt binary),
  # the installer must attempt the source build. The stub swift fails fast,
  # which is exactly the assertion — reaching swift proves branch selection.
  local stub_bin="$BATS_TEST_TMPDIR/stub-bin2"
  mkdir -p "$stub_bin"
  printf '#!/bin/sh\necho "swift invoked"; exit 96\n' > "$stub_bin/swift"
  chmod +x "$stub_bin/swift"

  local fake_home="$BATS_TEST_TMPDIR/home2"
  mkdir -p "$fake_home"

  run env HOME="$fake_home" PATH="$stub_bin:$PATH" bash "$REPO_DIR/scripts/install-daemon.sh"
  [ "$status" -eq 96 ]
  [[ "$output" == *"swift invoked"* ]]
}
