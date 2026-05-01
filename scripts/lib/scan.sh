#!/usr/bin/env bash
# SQLite scan helpers for locating retracted iMessages.

set -uo pipefail

[[ -n "${IMU_LIB_SCAN:-}" ]] && return
IMU_LIB_SCAN=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

imu_handle_rowid() {
  local snap_db=$1
  local handle=$2
  local safe_handle
  safe_handle=$(imu_sql_escape "$handle")
  sqlite3 -readonly "$snap_db" "SELECT ROWID FROM handle WHERE id = '$safe_handle' LIMIT 1;"
}

imu_chat_rowid() {
  local snap_db=$1
  local handle=$2
  local handle_rowid=$3
  local safe_handle
  safe_handle=$(imu_sql_escape "$handle")

  local chat_rowid
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

  printf "%s" "$chat_rowid"
}

imu_candidate_table() {
  local snap_db=$1
  local chat_rowid=$2

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

imu_find_candidate() {
  local snap_db=$1
  local handle=$2
  local forced_rowid=${3:-}

  local handle_rowid
  handle_rowid=$(imu_handle_rowid "$snap_db" "$handle")
  [[ -n "$handle_rowid" ]] || return 1

  local chat_rowid
  chat_rowid=$(imu_chat_rowid "$snap_db" "$handle" "$handle_rowid")
  [[ -n "$chat_rowid" ]] || return 1

  local rowid=$forced_rowid
  if [[ -z "$rowid" ]]; then
    rowid=$(sqlite3 -readonly "$snap_db" "
      SELECT m.ROWID FROM message m
      JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
      WHERE cmj.chat_id = $chat_rowid
        AND m.is_from_me = 0
        AND m.date_edited != 0
        AND m.is_empty = 1
      ORDER BY m.date DESC LIMIT 1;
    ")
  fi
  [[ -n "$rowid" ]] || return 2

  local guid
  guid=$(sqlite3 -readonly "$snap_db" "SELECT guid FROM message WHERE ROWID=$rowid;")
  [[ -n "$guid" ]] || return 2

  printf "%s|%s|%s|%s\n" "$rowid" "$guid" "$chat_rowid" "$handle_rowid"
}
