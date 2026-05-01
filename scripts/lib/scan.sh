#!/usr/bin/env bash
# scripts/lib/scan.sh — Vector 1: handle → chat → retracted-message candidate.
# Part of the modular library refactor — see issue #2.

[[ -n "${IMU_LIB_SCAN:-}" ]] && return
IMU_LIB_SCAN=1

set -uo pipefail

if [[ -z "${IMU_LIB_COMMON:-}" ]]; then
  # shellcheck source=common.sh
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
fi

imu_handle_rowid() {
  local snap_db="${1:?usage: imu_handle_rowid <snap_db> <handle>}"
  local handle="${2:?usage: imu_handle_rowid <snap_db> <handle>}"
  local safe_handle
  safe_handle=$(imu_sql_escape "$handle")
  sqlite3 -readonly "$snap_db" "SELECT ROWID FROM handle WHERE id = '$safe_handle' LIMIT 1;"
}

imu_chat_rowid() {
  local snap_db="${1:?usage: imu_chat_rowid <snap_db> <handle> <handle_rowid>}"
  local handle="${2:?usage: imu_chat_rowid <snap_db> <handle> <handle_rowid>}"
  local handle_rowid="${3:?usage: imu_chat_rowid <snap_db> <handle> <handle_rowid>}"
  local safe_handle chat_rowid
  safe_handle=$(imu_sql_escape "$handle")

  chat_rowid=$(sqlite3 -readonly "$snap_db" "
    SELECT c.ROWID
    FROM chat c
    JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
    WHERE chj.handle_id = $handle_rowid
      AND c.chat_identifier = '$safe_handle'
    ORDER BY c.ROWID LIMIT 1;
  ")

  if [[ -z "$chat_rowid" ]]; then
    chat_rowid=$(sqlite3 -readonly "$snap_db" "
      SELECT c.ROWID
      FROM chat c
      JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
      WHERE chj.handle_id = $handle_rowid
      ORDER BY c.ROWID DESC LIMIT 1;
    ")
  fi

  printf "%s\n" "$chat_rowid"
}

imu_candidate_table() {
  local snap_db="${1:?usage: imu_candidate_table <snap_db> <chat_rowid>}"
  local chat_rowid="${2:?usage: imu_candidate_table <snap_db> <chat_rowid>}"
  sqlite3 -readonly "$snap_db" <<SQL
.headers on
.mode tabs
SELECT m.ROWID, m.guid,
       datetime(m.date/1000000000 + 978307200, 'unixepoch', 'localtime')        AS sent_at,
       datetime(m.date_edited/1000000000 + 978307200, 'unixepoch', 'localtime') AS edited_at,
       m.is_from_me, m.is_empty,
       length(m.attributedBody)       AS ab_len,
       length(m.message_summary_info) AS msi_len
FROM message m
JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
WHERE cmj.chat_id = $chat_rowid
  AND m.is_from_me = 0
  AND m.date_edited != 0
  AND m.is_empty = 1
ORDER BY m.date DESC LIMIT 10;
SQL
}

# imu_find_candidate <snap_db> <handle>
#
# Resolves <handle> (E.164 phone or Apple ID email) to the most recent inbound
# retracted message in the corresponding chat. Returns one line: <ROWID>|<GUID>.
# Empty stdout = no candidate found.
#
# Predicate (verified on macOS Sequoia / Darwin 24.x):
#   m.is_from_me = 0
#   AND m.date_edited != 0     -- NOT date_retracted (unused on Darwin 24)
#   AND m.is_empty   = 1
#
imu_find_candidate() {
  local snap_db="${1:?usage: imu_find_candidate <snap_db> <handle>}"
  local handle="${2:?usage: imu_find_candidate <snap_db> <handle>}"
  local rowid="${3:-}"
  local handle_rowid chat_rowid

  if [[ -n "$rowid" ]]; then
    sqlite3 -readonly -separator '|' "$snap_db" "
      SELECT ROWID, guid
      FROM message
      WHERE ROWID = $rowid
      LIMIT 1;
    "
    return
  fi

  handle_rowid=$(imu_handle_rowid "$snap_db" "$handle")
  [[ -n "$handle_rowid" ]] || return 0

  chat_rowid=$(imu_chat_rowid "$snap_db" "$handle" "$handle_rowid")
  [[ -n "$chat_rowid" ]] || return 0

  sqlite3 -readonly -separator '|' "$snap_db" "
    SELECT m.ROWID, m.guid
    FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id = $chat_rowid
      AND m.is_from_me = 0
      AND m.date_edited != 0
      AND m.is_empty = 1
    ORDER BY m.date DESC LIMIT 1;
  "
}
