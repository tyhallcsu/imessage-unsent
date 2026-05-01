#!/usr/bin/env bats

load helpers

@test "recover.sh --json recovers the fixture text end to end" {
  run "$REPO_DIR/tests/fixtures/check-fixture.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *"fixture-recovery-json-ok"* ]]
}
