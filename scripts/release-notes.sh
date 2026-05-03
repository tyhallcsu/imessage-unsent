#!/usr/bin/env bash
# Generate Markdown release notes from conventional commits since the previous
# tag (or since the repo's first commit if this is the first tag).
#
# Usage: scripts/release-notes.sh <version>
#   <version>  e.g. v0.4.0 (used to derive the "since previous tag" range)
#
# Output: Markdown to stdout. Sections:
#   ## Highlights  (feat: commits)
#   ## Fixes       (fix: commits)
#   ## Documentation (docs: commits)
#   ## Other       (everything else not in the noise list below)
#
# Commits matching chore: / refs: / merge: / Merge pull request are filtered out.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "usage: $0 <version>" >&2
  exit 2
fi

VERSION="$1"

# Find the previous tag, if any. `git describe` may not see the current tag if
# we're invoked before it's pushed, so fall back to looking for any tag
# strictly older than VERSION.
prev_tag="$(git describe --tags --abbrev=0 "${VERSION}^" 2>/dev/null || true)"
if [[ -z "$prev_tag" ]]; then
  prev_tag="$(git tag --list --sort=-v:refname \
    | awk -v v="$VERSION" '$0 != v { print; exit }')"
fi

if [[ -n "$prev_tag" ]]; then
  range="${prev_tag}..HEAD"
  range_label="Changes since ${prev_tag}"
else
  range="HEAD"
  range_label="All commits (first release)"
fi

# Pull commits in the range, dropping noise.
mapfile -t commits < <(
  git log --no-merges --pretty='%s|%h' "$range" \
    | grep -Ev '^(chore|merge|Merge pull request)' || true
)

filter_section() {
  local prefix="$1"
  local commit
  for commit in "${commits[@]}"; do
    case "$commit" in
      "${prefix}:"*|"${prefix}("*)
        local subject="${commit%|*}"
        local sha="${commit##*|}"
        # Strip the leading `<prefix>: ` (or `<prefix>(<scope>): `) from display
        local display="${subject#"${prefix}"}"
        display="${display#:}"
        display="${display#(*)}"
        display="${display#:}"
        display="${display# }"
        printf -- '- %s (%s)\n' "$display" "$sha"
        ;;
    esac
  done
}

filter_other() {
  local commit
  for commit in "${commits[@]}"; do
    case "$commit" in
      feat:*|feat\(*|fix:*|fix\(*|docs:*|docs\(*) ;;
      *)
        local subject="${commit%|*}"
        local sha="${commit##*|}"
        printf -- '- %s (%s)\n' "$subject" "$sha"
        ;;
    esac
  done
}

print_section() {
  local title="$1"
  local body="$2"
  if [[ -n "$body" ]]; then
    printf '\n## %s\n\n%s\n' "$title" "$body"
  fi
}

printf '# %s\n\n%s\n' "$VERSION" "$range_label"

highlights="$(filter_section feat || true)"
fixes="$(filter_section fix || true)"
docs="$(filter_section docs || true)"
other="$(filter_other || true)"

print_section "Highlights" "$highlights"
print_section "Fixes" "$fixes"
print_section "Documentation" "$docs"
print_section "Other" "$other"

cat <<'TAIL'

## Artifacts

- `imu-watcher-VERSION-<arch>.tar.gz` — daemon binary + recovery scripts + LaunchAgent template (UNSIGNED)
- `IMUMenuBar-VERSION.zip` — menu bar app bundle (UNSIGNED)
- Each artifact has a sibling `.sha256` file with the SHA-256 checksum.

> [!NOTE]
> Artifacts are unsigned. macOS Gatekeeper will warn on first launch. Use `xattr -d com.apple.quarantine <path>` to clear the warning, or wait for a signed/notarized build (tracked in issues #19 and #20).
TAIL
