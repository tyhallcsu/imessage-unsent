#!/usr/bin/env bash
# imessage-unsent / recover.sh
#
# Forensic recovery of a fully retracted ("unsent") iMessage on macOS.
# Operates read-only against a snapshot of ~/Library/Messages/chat.db family.
# All vectors run independently; safe to rerun.
#
# Usage:
#   ./recover.sh --handle '+1XXXXXXXXXX'
#   ./recover.sh --handle 'someone@icloud.com'
#   ./recover.sh --handle '+1...' --rowid 123
#   ./recover.sh --handle '+1...' --work /custom/dir
#   ./recover.sh --handle '+1...' --work /archive --no-snapshot --json
#
# Prerequisites:
#   - Full Disk Access granted to your terminal
#   - sqlite3, plutil, python3
#   - optional: pip3 install --user typedstream
#   - optional: cargo install imessage-exporter

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=lib/snapshot.sh
source "$LIB_DIR/snapshot.sh"
# shellcheck source=lib/scan.sh
source "$LIB_DIR/scan.sh"
# shellcheck source=lib/wal.sh
source "$LIB_DIR/wal.sh"

HANDLE=""
ROWID=""
WORK="/tmp/imessage-recovery"
LIVE="${IMU_LIVE_DIR:-$HOME/Library/Messages}"
JSON_MODE=0
DO_SNAPSHOT=1

usage() {
  sed -n '2,28p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handle) HANDLE="${2:-}"; shift 2 ;;
    --rowid) ROWID="${2:-}"; shift 2 ;;
    --work) WORK="${2:-}"; shift 2 ;;
    --live) LIVE="${2:-}"; shift 2 ;;
    --json) JSON_MODE=1; shift ;;
    --no-snapshot) DO_SNAPSHOT=0; shift ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$HANDLE" ]]; then
  echo "ERROR: --handle is required (phone number in E.164 format or Apple ID email)" >&2
  usage 1
fi

if [[ -n "$ROWID" && ! "$ROWID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --rowid must be numeric" >&2
  exit 1
fi

mkdir -p "$WORK"
LOG="$WORK/report.txt"
SNAP="$WORK/chat.db"
MSI="$WORK/msi.bin"
AB="$WORK/ab.bin"
MSI_XML="$WORK/msi.xml"
WAL_JSON="$WORK/wal-candidates.json"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
hr() { log "================================================================"; }

json_report() {
  python3 "$LIB_DIR/json_report.py" \
    --ran-at "$RAN_AT" \
    --handle "$HANDLE" \
    --chat-rowid "${CHAT_ROWID:-}" \
    --rowid "${ROWID:-}" \
    --guid "${GUID:-}" \
    --sent-at "${SENT_AT:-}" \
    --edited-at "${EDITED_AT:-}" \
    --msi "$MSI" \
    --ab "$AB" \
    --wal-json "$WAL_JSON"
}

RAN_AT=$(imu_iso_utc)

hr
log "imessage-unsent recovery - $(date)"
log "handle:    $HANDLE"
log "live dir:  $LIVE"
log "work dir:  $WORK"
hr

if [[ "$DO_SNAPSHOT" == "1" ]]; then
  log "[0] Quitting Messages.app and snapshotting chat.db family..."
  if imu_snapshot "$WORK" "$LIVE" 1; then
    for f in chat.db chat.db-wal chat.db-shm; do
      if [[ -f "$WORK/$f" ]]; then
        log "  copied $f  ($(imu_stat_size "$WORK/$f") bytes, mtime $(imu_stat_mtime "$WORK/$f"))"
      else
        log "  WARN: $WORK/$f not present"
      fi
    done
  else
    log "  ABORT: $SNAP missing - does the terminal have Full Disk Access?"
    exit 1
  fi
else
  log "[0] Using existing snapshot in work dir (--no-snapshot)."
  if [[ ! -f "$SNAP" ]]; then
    log "  ABORT: $SNAP missing."
    exit 1
  fi
fi
hr

log "[1] Resolving handle '$HANDLE' -> handle.ROWID..."
HANDLE_ROWID=$(imu_handle_rowid "$SNAP" "$HANDLE" || true)
if [[ -z "$HANDLE_ROWID" ]]; then
  log "  No handle row for '$HANDLE' - try E.164 vs raw, email vs phone."
  log "  Hint: sqlite3 -readonly $SNAP \"SELECT DISTINCT id FROM handle WHERE id LIKE '%${HANDLE: -4}%';\""
  if [[ "$JSON_MODE" == "1" ]]; then
    : > "$WAL_JSON"
    json_report
  fi
  exit 1
fi
log "  -> handle.ROWID = $HANDLE_ROWID"

log "[1b] Locating 1:1 chat for that handle..."
CHAT_ROWID=$(imu_chat_rowid "$SNAP" "$HANDLE" "$HANDLE_ROWID")
log "  -> chat.ROWID = ${CHAT_ROWID:-(none)}"
if [[ -z "$CHAT_ROWID" ]]; then
  log "  ABORT: no chat found for handle $HANDLE"
  if [[ "$JSON_MODE" == "1" ]]; then
    : > "$WAL_JSON"
    json_report
  fi
  exit 1
fi

log "[1c] Searching for inbound retracted messages (date_edited != 0 AND is_empty = 1)..."
imu_candidate_table "$SNAP" "$CHAT_ROWID" | tee "$WORK/candidates.tsv" | sed 's/^/    /' | tee -a "$LOG" >&2

if [[ -z "$ROWID" ]]; then
  CANDIDATE=$(imu_find_candidate "$SNAP" "$HANDLE" "" || true)
else
  CANDIDATE=$(imu_find_candidate "$SNAP" "$HANDLE" "$ROWID" || true)
fi

if [[ -n "$CANDIDATE" ]]; then
  IFS='|' read -r ROWID GUID CHAT_ROWID HANDLE_ROWID <<<"$CANDIDATE"
fi

log "  -> top candidate ROWID: ${ROWID:-(none)}"
if [[ -z "$ROWID" || -z "${GUID:-}" ]]; then
  log "  No unsent inbound message found in chat $CHAT_ROWID."
  if [[ "$JSON_MODE" == "1" ]]; then
    : > "$WAL_JSON"
    json_report
  fi
  exit 0
fi

log "  -> candidate GUID: $GUID"
IFS='|' read -r SENT_AT EDITED_AT <<<"$(sqlite3 -readonly -separator '|' "$SNAP" "
  SELECT datetime(date/1000000000 + 978307200, 'unixepoch', 'localtime'),
         datetime(date_edited/1000000000 + 978307200, 'unixepoch', 'localtime')
  FROM message WHERE ROWID=$ROWID;
")"
hr

log "[2] Extracting BLOBs for ROWID $ROWID..."
rm -f "$MSI" "$AB" "$MSI_XML"
SAFE_MSI=$(imu_sql_escape "$MSI")
SAFE_AB=$(imu_sql_escape "$AB")
sqlite3 -readonly "$SNAP" "SELECT writefile('$SAFE_MSI', message_summary_info) FROM message WHERE ROWID=$ROWID;" >/dev/null
sqlite3 -readonly "$SNAP" "SELECT writefile('$SAFE_AB', attributedBody) FROM message WHERE ROWID=$ROWID;" >/dev/null

if [[ -s "$MSI" ]]; then
  log "  msi.bin: $(imu_stat_size "$MSI") bytes"
  if command -v plutil >/dev/null && plutil -convert xml1 -o "$MSI_XML" "$MSI" 2>>"$LOG"; then
    log "  msi.xml written"
  fi
  if command -v plutil >/dev/null; then
    log "  --- plutil -p msi.bin ---"
    plutil -p "$MSI" 2>/dev/null | head -60 | sed 's/^/    /' | tee -a "$LOG" >&2 || true
    log "  -------------------------"
  fi
  log "  Note: For fully unsent messages this plist contains metadata only."
else
  log "  msi.bin: empty"
fi

if [[ -s "$AB" ]]; then
  log "  ab.bin:  $(imu_stat_size "$AB") bytes"
else
  log "  ab.bin:  empty (Apple wipes attributedBody on full retraction)"
fi
hr

log "[3] Attempting typedstream decode of attributedBody (and ec blobs in msi)..."
if python3 -c 'import typedstream' 2>/dev/null; then
  python3 "$SCRIPT_DIR/decode.py" "$AB" "$MSI" 2>&1 | sed 's/^/    /' | tee -a "$LOG" >&2 || true
else
  log "  python 'typedstream' not installed; install with: pip3 install --user typedstream"
fi
hr

log "[4] Searching chat.db-wal for pre-retract page images..."
WAL="$WORK/chat.db-wal"
if [[ ! -s "$WAL" ]]; then
  log "  WAL file empty or missing; skipping."
  printf '[]\n' > "$WAL_JSON"
else
  log "  WAL size: $(imu_stat_size "$WAL") bytes"
  PGSIZE=$(sqlite3 -readonly "$SNAP" "PRAGMA page_size;")
  WAL_SIZE=$(imu_stat_size "$WAL")
  log "  page_size = $PGSIZE  approx_frames = $(( (WAL_SIZE - 32) / (24 + PGSIZE) ))"
  HITS=$(grep -aob "$GUID" "$WAL" | cut -d: -f1 || true)
  log "  GUID occurrences in WAL: $(printf '%s\n' "$HITS" | sed '/^$/d' | wc -l | tr -d ' ')"
  imu_extract_from_wal_json "$WAL" "$GUID" > "$WAL_JSON"
  python3 - "$WAL_JSON" <<'PY' 2>&1 | sed 's/^/    /' | tee -a "$LOG" >&2
import json
import sys

items = json.load(open(sys.argv[1], encoding="utf-8"))
if not items:
    print("No pre-retract text found following any GUID occurrence.")
else:
    for item in items:
        print(f"WAL_OFFSET {item['offset']}  LEN {item['length']}  TEXT: {item['text']!r}")
PY
fi
hr

log "[5] imessage-exporter cross-check..."
EXP="$WORK/export"
rm -rf "$EXP"
if command -v imessage-exporter >/dev/null; then
  if ! imessage-exporter -f txt -o "$EXP" -p "$SNAP" -c full 2>>"$LOG"; then
    log "  exporter exited non-zero (often harmless if attachments dir is missing)"
  fi
  if [[ -d "$EXP" ]]; then
    : > "$WORK/exporter-hits.txt"
    grep -RIn -B1 -A4 "$GUID" "$EXP" >> "$WORK/exporter-hits.txt" 2>/dev/null || true
    grep -RIn -i 'unsent\|retract' "$EXP" 2>/dev/null | head -30 >> "$WORK/exporter-hits.txt" || true
    log "  exporter-hits.txt: $(wc -l < "$WORK/exporter-hits.txt" | tr -d ' ') lines"
  fi
else
  log "  imessage-exporter not installed; skip (optional)"
  log "    install: cargo install imessage-exporter"
fi
hr

log "[6] Other recovery vectors to consider manually:"
log "  - Time Machine snapshots of chat.db"
log "  - APFS local snapshots"
log "  - iPhone backups in ~/Library/Application Support/MobileSync/Backup/"
log "  - iMazing / iExplorer / 3uTools backups"
hr

log "[done] Report: $LOG"
log "Artifacts:"
ls -la "$WORK" | sed 's/^/  /' | tee -a "$LOG" >&2

if [[ "$JSON_MODE" == "1" ]]; then
  json_report
fi
