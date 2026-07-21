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

# Prefer the requested tag as the range end so re-generating notes for an OLD
# tag reports that tag's history — not whatever is currently checked out
# (#115 / F-M9). Fall back to HEAD for a local preview run before the tag
# exists (the documented use of this script).
if git rev-parse -q --verify "refs/tags/${VERSION}^{commit}" >/dev/null 2>&1; then
  end_ref="$VERSION"
else
  end_ref="HEAD"
fi

if [[ -n "$prev_tag" ]]; then
  range="${prev_tag}..${end_ref}"
  range_label="Changes since ${prev_tag}"
else
  range="$end_ref"
  range_label="All commits (first release)"
fi

# Pull commits in the range, dropping noise. Stash to a temp file so we can
# iterate the same list multiple times without re-running git log, AND so the
# script stays portable to bash 3.2 (no `mapfile`, which is bash 4+ — macOS
# ships /bin/bash 3.2 and CI's macos-latest can hit it via `env bash`).
COMMITS_FILE="$(mktemp -t imu-release-notes-commits.XXXXXX)"
trap 'rm -f "$COMMITS_FILE"' EXIT

git log --no-merges --pretty='%s|%h' "$range" 2>/dev/null \
  | grep -Ev '^(chore|merge|Merge pull request)' \
  > "$COMMITS_FILE" || true

filter_section() {
  local prefix="$1"
  local commit subject sha display
  while IFS= read -r commit; do
    case "$commit" in
      "${prefix}:"*|"${prefix}("*)
        subject="${commit%|*}"
        sha="${commit##*|}"
        # Strip the leading `<prefix>: ` (or `<prefix>(<scope>): `) from display
        display="${subject#"${prefix}"}"
        display="${display#:}"
        display="${display#(*)}"
        display="${display#:}"
        display="${display# }"
        printf -- '- %s (%s)\n' "$display" "$sha"
        ;;
    esac
  done < "$COMMITS_FILE"
}

filter_other() {
  local commit subject sha
  while IFS= read -r commit; do
    case "$commit" in
      feat:*|feat\(*|fix:*|fix\(*|docs:*|docs\(*) ;;
      *)
        subject="${commit%|*}"
        sha="${commit##*|}"
        printf -- '- %s (%s)\n' "$subject" "$sha"
        ;;
    esac
  done < "$COMMITS_FILE"
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

- `imu-watcher-VERSION-<arch>.tar.gz` — daemon binary + recovery scripts + LaunchAgent template
- `iMessage-Unsent-VERSION.zip` — menu bar app bundle
- Each artifact has a sibling `.sha256` file with the SHA-256 checksum.

> [!NOTE]
> Signing is credential-driven (see docs/code-signing.md): verify with `codesign --verify --deep --strict` on the extracted app. Unsigned or ad-hoc builds trip Gatekeeper on first launch — clear with `xattr -d com.apple.quarantine <path>`.
TAIL
