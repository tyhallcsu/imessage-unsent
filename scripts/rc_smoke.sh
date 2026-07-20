#!/usr/bin/env bash
#
# rc_smoke.sh — local "release-candidate smoke" workflow.
#
# Proves that someone (Tyler, a contributor, or CI) can build, package, and
# diagnose imessage-unsent end-to-end without poking shared system state.
#
# What it runs:
#   1. shellcheck  (Makefile target — covers all shell sources)
#   2. swift test --package-path daemon
#   3. swift test --package-path gui
#   4. scripts/build-release.sh "$VERSION" "$OUTPUT_DIR"
#   5. scripts/release-notes.sh "$VERSION" > "$OUTPUT_DIR/RELEASE_NOTES.md"
#   6. scripts/app_doctor.sh
#   7. Artifact integrity:
#        - daemon tarball exists, sha256 file matches, contents include
#          imu-watcher / scripts/recover.sh / scripts/lib / com.imu.watcher.plist
#          / install.sh
#        - GUI zip exists, sha256 file matches, contents include
#          iMessage Unsent.app/Contents/MacOS/IMUMenuBar / Info.plist
#   8. Confirms scripts/uninstall-daemon.sh is present and executable so users
#      have an exit ramp (does not run it).
#
# Usage:
#   bash scripts/rc_smoke.sh [VERSION] [OUTPUT_DIR]
#   VERSION=v0.4.0-rc1 bash scripts/rc_smoke.sh
#
#   VERSION       defaults to v0.0.0-smoke (a sentinel that won't collide with
#                 a real release tag — and will fail any "is this a real tag"
#                 check).
#   OUTPUT_DIR    defaults to $(mktemp -d -t imu-rc-smoke.XXXXXX). When the
#                 default is used, it's wiped on success so the normal `dist/`
#                 stays untouched. Pass an explicit dir to keep artifacts.
#
# Environment overrides:
#   IMU_RC_SKIP_SWIFT=1     skip the two `swift test` runs (useful when CI has
#                           already proven them, or when iterating on the
#                           script itself).
#   IMU_RC_SKIP_SHELLCHECK=1 skip `make shellcheck`.
#   IMU_RC_KEEP_DIST=1      keep $OUTPUT_DIR even when the default temp dir
#                           was used. Implies success-path retention.
#
# What it deliberately does NOT do:
#   - install the LaunchAgent
#   - request Full Disk Access
#   - touch ~/Library/Messages
#   - require Apple Developer ID secrets (build-release.sh skips signing
#     gracefully when secrets are absent — that's the point of unsigned RCs)
#   - require a real unsent iMessage event
#   - publish a GitHub release or push a tag
#
# Exit codes:
#   0  every step passed
#   1  one or more steps failed (summary table prints regardless)
#   2  bad arguments

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers (kept top-level so they're source-able from bats tests).
# ---------------------------------------------------------------------------

DEFAULT_VERSION="v0.0.0-smoke"
SEMVER_RE='^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$'

# Required entries inside the daemon tarball, validated by `tar -tzf`.
DAEMON_REQUIRED_ENTRIES=(
  "imu-watcher"
  "scripts/recover.sh"
  "scripts/lib"
  "com.imu.watcher.plist"
  "install.sh"
)

# Required entries inside the GUI .app zip, validated by `unzip -Z1`.
# Note: bundle is "iMessage Unsent.app" (with space) — Apple convention.
# AppIcon.icns is load-bearing: Finder/Dock branding AND the About window
# read it from Contents/Resources (#137). If it leaves the package, this
# gate must fail.
GUI_REQUIRED_ENTRIES=(
  "iMessage Unsent.app/Contents/MacOS/IMUMenuBar"
  "iMessage Unsent.app/Contents/Info.plist"
  "iMessage Unsent.app/Contents/Resources/AppIcon.icns"
)

# Validates a version string against the same regex build-release.sh uses.
# Returns 0 / 1 — does not exit, so callers can decide.
rc_validate_version() {
  local version="${1:?usage: rc_validate_version <version>}"
  [[ "$version" =~ $SEMVER_RE ]]
}

# Verify a sha256 sidecar file matches its target. Argument is the path to
# the .sha256 file; the artifact is its dirname + the first whitespace-
# delimited word of the file contents.
rc_verify_sha256() {
  local sha_file="${1:?usage: rc_verify_sha256 <sha-file>}"
  if [[ ! -f "$sha_file" ]]; then
    return 1
  fi
  local dir
  dir="$(cd "$(dirname "$sha_file")" && pwd)"
  ( cd "$dir" && shasum -a 256 -c "$(basename "$sha_file")" ) >/dev/null
}

# Confirm every entry in the named array appears as a substring of `tar -tzf`
# output. Returns 0 / 1 — emits the missing entry on stderr.
# Usage: rc_verify_tarball_contents <tarball> <entry> [<entry> ...]
rc_verify_tarball_contents() {
  local tarball="${1:?usage: rc_verify_tarball_contents <tarball> <entry...>}"
  shift
  if [[ ! -f "$tarball" ]]; then
    printf 'rc_verify_tarball_contents: missing tarball %s\n' "$tarball" >&2
    return 1
  fi
  local listing
  listing="$(tar -tzf "$tarball")"
  local entry
  for entry in "$@"; do
    if ! grep -qF "$entry" <<<"$listing"; then
      printf 'rc_verify_tarball_contents: %s does not contain entry: %s\n' "$tarball" "$entry" >&2
      return 1
    fi
  done
}

# Same shape, but for zip files.
# Usage: rc_verify_zip_contents <zip> <entry> [<entry> ...]
rc_verify_zip_contents() {
  local zipfile="${1:?usage: rc_verify_zip_contents <zip> <entry...>}"
  shift
  if [[ ! -f "$zipfile" ]]; then
    printf 'rc_verify_zip_contents: missing zip %s\n' "$zipfile" >&2
    return 1
  fi
  local listing
  listing="$(unzip -Z1 "$zipfile")"
  local entry
  for entry in "$@"; do
    if ! grep -qF "$entry" <<<"$listing"; then
      printf 'rc_verify_zip_contents: %s does not contain entry: %s\n' "$zipfile" "$entry" >&2
      return 1
    fi
  done
}

# ---------------------------------------------------------------------------
# Step recording — accumulates results so the summary table is comprehensive
# even when an early step fails.
# ---------------------------------------------------------------------------

# Two parallel arrays so we don't depend on bash 4 associative arrays. macOS
# ships /bin/bash 3.2 by default and CI's macos-latest can hit it via env.
RC_STEP_NAMES=()
RC_STEP_STATUSES=()
RC_STEP_NOTES=()

rc_record() {
  local status="${1:?status}" name="${2:?name}" note="${3:-}"
  RC_STEP_STATUSES+=("$status")
  RC_STEP_NAMES+=("$name")
  RC_STEP_NOTES+=("$note")
}

rc_step() {
  local name="${1:?name}"
  shift
  printf '\n==> %s\n' "$name"
  if "$@"; then
    rc_record PASS "$name" ""
    return 0
  else
    local rc=$?
    rc_record FAIL "$name" "exit $rc"
    return "$rc"
  fi
}

rc_print_summary() {
  printf '\n==================== RC SMOKE SUMMARY ====================\n'
  local i
  local fails=0
  for i in "${!RC_STEP_NAMES[@]}"; do
    local status="${RC_STEP_STATUSES[$i]}"
    local name="${RC_STEP_NAMES[$i]}"
    local note="${RC_STEP_NOTES[$i]}"
    if [[ "$status" == "FAIL" ]]; then
      fails=$((fails + 1))
    fi
    if [[ -n "$note" ]]; then
      printf '[%s] %s — %s\n' "$status" "$name" "$note"
    else
      printf '[%s] %s\n' "$status" "$name"
    fi
  done
  printf '%s\n' "----------------------------------------------------------"
  if [[ "$fails" -eq 0 ]]; then
    printf 'RC SMOKE PASSED (%d steps)\n' "${#RC_STEP_NAMES[@]}"
  else
    printf 'RC SMOKE FAILED — %d failing step(s)\n' "$fails"
  fi
}

# ---------------------------------------------------------------------------
# Main flow.
# ---------------------------------------------------------------------------

rc_main() {
  local version="${1:-${VERSION:-$DEFAULT_VERSION}}"
  local output_dir="${2:-${OUTPUT_DIR:-}}"
  local using_temp_dist=0
  local repo_dir
  repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

  if ! rc_validate_version "$version"; then
    printf 'error: version must look like vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-prerelease, got: %s\n' "$version" >&2
    return 2
  fi

  if [[ -z "$output_dir" ]]; then
    output_dir="$(mktemp -d -t imu-rc-smoke.XXXXXX)"
    using_temp_dist=1
  fi
  mkdir -p "$output_dir"
  output_dir="$(cd "$output_dir" && pwd)"

  printf 'imessage-unsent RC smoke — %s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  printf 'Version:    %s\n' "$version"
  printf 'OutputDir:  %s%s\n' "$output_dir" "$([[ "$using_temp_dist" == "1" ]] && echo " (temp)" || echo "")"
  printf 'Repo:       %s\n' "$repo_dir"
  printf '\n'

  local arch
  arch="$(uname -m)"
  local daemon_tarball="$output_dir/imu-watcher-${version}-${arch}.tar.gz"
  local gui_zip="$output_dir/iMessage-Unsent-${version}.zip"
  local notes_md="$output_dir/RELEASE_NOTES.md"

  # --- 1. shellcheck -------------------------------------------------------
  if [[ "${IMU_RC_SKIP_SHELLCHECK:-0}" == "1" ]]; then
    rc_record SKIP "shellcheck" "IMU_RC_SKIP_SHELLCHECK=1"
  else
    rc_step "shellcheck" \
      bash -c "cd '$repo_dir' && make shellcheck" || true
  fi

  # --- 2. swift test --package-path daemon ---------------------------------
  if [[ "${IMU_RC_SKIP_SWIFT:-0}" == "1" ]]; then
    rc_record SKIP "swift test (daemon)" "IMU_RC_SKIP_SWIFT=1"
  else
    rc_step "swift test (daemon)" \
      swift test --package-path "$repo_dir/daemon" || true
  fi

  # --- 3. swift test --package-path gui ------------------------------------
  if [[ "${IMU_RC_SKIP_SWIFT:-0}" == "1" ]]; then
    rc_record SKIP "swift test (gui)" "IMU_RC_SKIP_SWIFT=1"
  else
    rc_step "swift test (gui)" \
      swift test --package-path "$repo_dir/gui" || true
  fi

  # --- 4. build-release.sh -------------------------------------------------
  rc_step "build-release.sh ($version)" \
    bash "$repo_dir/scripts/build-release.sh" "$version" "$output_dir" || true

  # --- 5. release-notes.sh -------------------------------------------------
  rc_step "release-notes.sh ($version)" \
    bash -c "bash '$repo_dir/scripts/release-notes.sh' '$version' > '$notes_md'" || true

  # --- 6. app_doctor.sh ----------------------------------------------------
  # Stream output so the user can see what their install looks like.
  rc_step "app_doctor.sh" \
    bash "$repo_dir/scripts/app_doctor.sh" || true

  # --- 7. Artifact integrity ----------------------------------------------
  rc_step "daemon tarball exists" \
    test -f "$daemon_tarball" || true
  rc_step "daemon tarball sha256 matches" \
    rc_verify_sha256 "${daemon_tarball}.sha256" || true
  rc_step "daemon tarball contents" \
    rc_verify_tarball_contents "$daemon_tarball" "${DAEMON_REQUIRED_ENTRIES[@]}" || true
  rc_step "gui zip exists" \
    test -f "$gui_zip" || true
  rc_step "gui zip sha256 matches" \
    rc_verify_sha256 "${gui_zip}.sha256" || true
  rc_step "gui zip contents" \
    rc_verify_zip_contents "$gui_zip" "${GUI_REQUIRED_ENTRIES[@]}" || true
  rc_step "release notes generated" \
    test -s "$notes_md" || true

  # --- 8. Uninstall path is present (sanity, not executed) -----------------
  rc_step "uninstall-daemon.sh present + executable" \
    bash -c "test -x '$repo_dir/scripts/uninstall-daemon.sh'" || true

  rc_print_summary

  local fails=0
  local s
  for s in "${RC_STEP_STATUSES[@]}"; do
    [[ "$s" == "FAIL" ]] && fails=$((fails + 1))
  done

  if [[ "$using_temp_dist" == "1" && "${IMU_RC_KEEP_DIST:-0}" != "1" && "$fails" -eq 0 ]]; then
    printf '\nCleaning temp output dir: %s\n' "$output_dir"
    rm -rf "$output_dir"
  else
    printf '\nArtifacts kept under: %s\n' "$output_dir"
  fi

  if [[ "$fails" -gt 0 ]]; then
    return 1
  fi
}

# Only invoke main when executed directly, not when sourced (so bats can call
# the helpers in isolation).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rc_main "$@"
fi
