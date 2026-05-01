#!/usr/bin/env bats

load helpers

@test "recover.sh --help exits 0" {
  run "$REPO_DIR/scripts/recover.sh" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "recover.sh without --handle exits 1" {
  run "$REPO_DIR/scripts/recover.sh"

  [ "$status" -eq 1 ]
  [[ "$output" == *"ERROR: --handle is required"* ]]
}
