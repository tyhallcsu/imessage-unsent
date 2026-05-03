#!/usr/bin/env bats

# Tests for scripts/rc_smoke.sh.
#
# These cover:
#   - argument validation (rejects junk version strings; the default version
#     passes the same regex build-release.sh uses)
#   - artifact-inspection helpers (sha256 sidecar match, tarball/zip content
#     presence) using fake fixtures so the test stays under a second
#
# We deliberately do NOT invoke the full smoke flow here — that would mean
# running both `swift test` suites + `swift build -c release` x2 and pulling
# Gatekeeper-relevant signing logic. CI runs the full chain via Makefile
# targets that already have their own jobs; the bats job needs to stay fast.

load helpers

# rc_smoke.sh is source-able: invoking with `BASH_SOURCE != $0` skips the
# main flow, leaving only the helpers defined in the current shell.
RC_SMOKE_SCRIPT="$REPO_DIR/scripts/rc_smoke.sh"

setup() {
  # Each test gets its own subshell-style env; sourcing inside `run` is awkward
  # because `run` itself spawns a subshell. Instead, each test sources the
  # script in its own bash -c invocation and runs the relevant helper.
  :
}

# --- arg validation ---------------------------------------------------------

@test "rc_smoke.sh rejects a non-semver version" {
  run bash "$RC_SMOKE_SCRIPT" "0.4.0"
  [ "$status" -eq 2 ]
  [[ "$output" == *"version must look like"* ]]
}

@test "rc_smoke.sh rejects junk like 'rc1'" {
  run bash "$RC_SMOKE_SCRIPT" "rc1"
  [ "$status" -eq 2 ]
  [[ "$output" == *"version must look like"* ]]
}

@test "rc_smoke.sh accepts the default v0.0.0-smoke version (validation only)" {
  # Source the script and call rc_validate_version with no arg — it should
  # accept the default sentinel.
  run bash -c "
    set -e
    source '$RC_SMOKE_SCRIPT'
    rc_validate_version v0.0.0-smoke && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

@test "rc_smoke.sh accepts a real RC version (validation only)" {
  run bash -c "
    set -e
    source '$RC_SMOKE_SCRIPT'
    rc_validate_version v0.4.0-rc1 && echo OK
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK"* ]]
}

# --- rc_verify_sha256 -------------------------------------------------------

@test "rc_verify_sha256 returns 0 for a matching sidecar" {
  local artifact="$BATS_TEST_TMPDIR/payload.bin"
  printf 'hello world' > "$artifact"
  ( cd "$BATS_TEST_TMPDIR" && shasum -a 256 "payload.bin" > "payload.bin.sha256" )

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_sha256 '$BATS_TEST_TMPDIR/payload.bin.sha256'
  "
  [ "$status" -eq 0 ]
}

@test "rc_verify_sha256 returns nonzero for a corrupted artifact" {
  local artifact="$BATS_TEST_TMPDIR/payload.bin"
  printf 'hello world' > "$artifact"
  ( cd "$BATS_TEST_TMPDIR" && shasum -a 256 "payload.bin" > "payload.bin.sha256" )
  printf 'tampered' > "$artifact"

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_sha256 '$BATS_TEST_TMPDIR/payload.bin.sha256'
  "
  [ "$status" -ne 0 ]
}

@test "rc_verify_sha256 returns nonzero for a missing sidecar" {
  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_sha256 '$BATS_TEST_TMPDIR/does-not-exist.sha256'
  "
  [ "$status" -ne 0 ]
}

# --- rc_verify_tarball_contents --------------------------------------------

@test "rc_verify_tarball_contents passes when every required entry is present" {
  local stage="$BATS_TEST_TMPDIR/stage/imu-watcher-v0.0.0-smoke"
  mkdir -p "$stage/scripts/lib"
  : > "$stage/imu-watcher"
  : > "$stage/scripts/recover.sh"
  : > "$stage/scripts/lib/.keep"
  : > "$stage/com.imu.watcher.plist"
  : > "$stage/install.sh"
  local tarball="$BATS_TEST_TMPDIR/imu-watcher-v0.0.0-smoke-x86_64.tar.gz"
  ( cd "$BATS_TEST_TMPDIR/stage" && tar -czf "$tarball" "imu-watcher-v0.0.0-smoke" )

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_tarball_contents '$tarball' \
      'imu-watcher' 'scripts/recover.sh' 'scripts/lib' 'com.imu.watcher.plist' 'install.sh'
  "
  [ "$status" -eq 0 ]
}

@test "rc_verify_tarball_contents fails clearly when an entry is missing" {
  local stage="$BATS_TEST_TMPDIR/stage/imu-watcher-v0.0.0-smoke"
  mkdir -p "$stage/scripts"
  : > "$stage/imu-watcher"
  # Intentionally omit recover.sh so the check must flag it.
  local tarball="$BATS_TEST_TMPDIR/imu-watcher-v0.0.0-smoke-x86_64.tar.gz"
  ( cd "$BATS_TEST_TMPDIR/stage" && tar -czf "$tarball" "imu-watcher-v0.0.0-smoke" )

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_tarball_contents '$tarball' 'imu-watcher' 'scripts/recover.sh'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"scripts/recover.sh"* ]]
}

@test "rc_verify_tarball_contents fails when the tarball does not exist" {
  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_tarball_contents '$BATS_TEST_TMPDIR/missing.tar.gz' 'imu-watcher'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"missing tarball"* ]]
}

# --- rc_verify_zip_contents -------------------------------------------------

@test "rc_verify_zip_contents passes when expected app entries are present" {
  local stage="$BATS_TEST_TMPDIR/zip-stage"
  mkdir -p "$stage/IMUMenuBar.app/Contents/MacOS"
  : > "$stage/IMUMenuBar.app/Contents/MacOS/IMUMenuBar"
  : > "$stage/IMUMenuBar.app/Contents/Info.plist"
  local zipfile="$BATS_TEST_TMPDIR/IMUMenuBar-v0.0.0-smoke.zip"
  ( cd "$stage" && /usr/bin/zip -qry "$zipfile" "IMUMenuBar.app" )

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_zip_contents '$zipfile' \
      'IMUMenuBar.app/Contents/MacOS/IMUMenuBar' 'IMUMenuBar.app/Contents/Info.plist'
  "
  [ "$status" -eq 0 ]
}

@test "rc_verify_zip_contents fails when the binary is missing from the .app" {
  local stage="$BATS_TEST_TMPDIR/zip-stage"
  mkdir -p "$stage/IMUMenuBar.app/Contents/MacOS"
  # Intentionally omit the binary
  : > "$stage/IMUMenuBar.app/Contents/Info.plist"
  local zipfile="$BATS_TEST_TMPDIR/IMUMenuBar-v0.0.0-smoke.zip"
  ( cd "$stage" && /usr/bin/zip -qry "$zipfile" "IMUMenuBar.app" )

  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_verify_zip_contents '$zipfile' 'IMUMenuBar.app/Contents/MacOS/IMUMenuBar'
  "
  [ "$status" -ne 0 ]
  [[ "$output" == *"IMUMenuBar.app/Contents/MacOS/IMUMenuBar"* ]]
}

# --- step recording ---------------------------------------------------------

@test "rc_step records a PASS for a successful command and exits 0" {
  run bash -c "
    set +e
    source '$RC_SMOKE_SCRIPT'
    rc_step 'hello' true
    echo NAMES=\${RC_STEP_NAMES[*]}
    echo STATUSES=\${RC_STEP_STATUSES[*]}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"NAMES=hello"* ]]
  [[ "$output" == *"STATUSES=PASS"* ]]
}

@test "rc_step records a FAIL for a failing command without aborting under set -e" {
  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_step 'always-fails' false || true
    rc_step 'follow-up' true
    echo STATUSES=\${RC_STEP_STATUSES[*]}
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"STATUSES=FAIL PASS"* ]]
}

@test "rc_print_summary lists every recorded step" {
  run bash -c "
    source '$RC_SMOKE_SCRIPT'
    rc_record PASS 'first' ''
    rc_record FAIL 'second' 'exit 7'
    rc_record SKIP 'third' 'reason'
    rc_print_summary
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"[PASS] first"* ]]
  [[ "$output" == *"[FAIL] second — exit 7"* ]]
  [[ "$output" == *"[SKIP] third — reason"* ]]
  [[ "$output" == *"RC SMOKE FAILED"* ]]
}
