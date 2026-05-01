#!/usr/bin/env bats

@test "recover.sh help exits successfully" {
  run ./scripts/recover.sh --help
  [ "$status" -eq 0 ]
}

@test "recover.sh requires handle" {
  run ./scripts/recover.sh --no-snapshot --work "$BATS_TEST_TMPDIR"
  [ "$status" -eq 1 ]
}
