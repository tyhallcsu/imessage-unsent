#!/usr/bin/env bats

# Issue #185 — the entitlements plist must be parseable by the thing that
# actually parses it.
#
# `gui/entitlements.plist` shipped for months containing `--options=runtime`
# inside its leading XML comment. A double hyphen is illegal inside an XML
# comment (XML 1.0 §2.5), so the file was not well-formed and every
# `codesign --entitlements` against it died with:
#
#     Failed to parse entitlements: AMFIUnserializeXML: syntax error near line 9
#
# Nothing caught it because `plutil -lint` says OK — it tolerates the malformed
# comment — and because no release had ever been signed. `scripts/sign-release.sh`
# passes this file for both the app and the daemon, so the first real Developer ID
# signing would have failed mid-release.
#
# So this asserts against the real parser rather than a lenient stand-in: it runs
# an actual ad-hoc `codesign --entitlements`, which needs no certificate but goes
# through AMFI exactly as a Developer ID signing would.

load helpers

setup() {
  ENTITLEMENTS="$BATS_TEST_DIRNAME/../../gui/entitlements.plist"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "entitlements: file exists where the signing scripts expect it" {
  [ -f "$ENTITLEMENTS" ]
}

@test "entitlements: is well-formed XML" {
  # The check plutil does not do. Catches the double-hyphen-in-comment class
  # directly, with a readable error, before the codesign test below.
  run xmllint --noout "$ENTITLEMENTS"
  [ "$status" -eq 0 ]
}

@test "entitlements: is a valid property list" {
  run plutil -lint "$ENTITLEMENTS"
  [ "$status" -eq 0 ]
}

@test "entitlements: codesign accepts it (AMFI parses it)" {
  # The regression test proper. Ad-hoc signing (`-s -`) requires no identity but
  # exercises the same entitlements parser as a real signing run, so this fails
  # for exactly the reason a release would have.
  cp /bin/echo "$TMP/victim"
  run codesign --force -s - --entitlements "$ENTITLEMENTS" "$TMP/victim"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Failed to parse entitlements"* ]]
  [[ "$output" != *"AMFIUnserializeXML"* ]]
}

@test "entitlements: comment body carries no double hyphen" {
  # Belt and braces, and the one that names the actual rule for whoever edits
  # the rationale next — the codesign test above tells them something broke, this
  # one tells them what. The delimiters `<!--` and `-->` contain a double hyphen
  # by construction, so strip those before looking.
  run bash -c "sed -e 's/<!--//g' -e 's/-->//g' '$ENTITLEMENTS' | grep -n -- '--'"
  [ "$status" -ne 0 ]
}

@test "entitlements: every tracked plist is well-formed" {
  # #185 was in one file, but nothing was checking any of them. Info.plist and
  # the LaunchAgent plist reach launchd and the bundle loader by the same route.
  cd "$BATS_TEST_DIRNAME/../.."
  local bad=0
  while IFS= read -r plist; do
    if ! xmllint --noout "$plist" 2>/dev/null; then
      echo "malformed: $plist"
      bad=1
    fi
  done < <(git ls-files '*.plist')
  [ "$bad" -eq 0 ]
}
