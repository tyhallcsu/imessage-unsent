#!/usr/bin/env bash
# imessage-unsent / recover.sh
#
# Forensic recovery of a fully retracted ("unsent") iMessage on macOS.
# Operates read-only against a snapshot of ~/Library/Messages/chat.db family.
# All vectors run independently; safe to rerun.
#
# Usage:
#   ./recover.sh --handle '+1XXXXXXXXXX'        # phone number (E.164)
#   ./recover.sh --handle 'someone@icloud.com'  # Apple ID email
#   ./recover.sh --handle '+1...' --rowid 123   # skip auto-detect; force ROWID
#   ./recover.sh --handle '+1...' --work /custom/dir
#   ./recover.sh --handle '+1...' --json       # emit machine-readable JSON on stdout
#
# Prerequisites:
#   - Full Disk Access granted to your terminal (System Settings → Privacy & Security → Full Disk Access)
#   - sqlite3 (macOS built-in or `brew install sqlite`)
#   - plutil (macOS built-in)
#   - python3 (macOS built-in)
#   - optional: pip3 install --user typedstream
#   - optional: cargo install imessage-exporter
#
# IMPORTANT (macOS Sequoia / Darwin 24.x):
#   Apple records unsends in `date_edited != 0 AND is_empty = 1`.
#   The dedicated `date_retracted` column is unused on this build.
#   This script reflects that reality.

set -uo pipefail   # NOT -e: each vector runs independently and may fail without aborting

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
# shellcheck source=lib/decode.sh
source "$LIB_DIR/decode.sh"

# ─── arg parsing ───────────────────────────────────────────────────────────
HANDLE=""
ROWID=""
WORK="/tmp/imessage-recovery"
LIVE="$HOME/Library/Messages"
JSON_MODE=0

usage() {
  sed -n '2,30p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handle) HANDLE="$2"; shift 2 ;;
    --rowid)  ROWID="$2";  shift 2 ;;
    --work)   WORK="$2";   shift 2 ;;
    --json)   JSON_MODE=1; shift ;;
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
hr()  { log "================================================================"; }

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
log "imessage-unsent recovery — $(date)"
log "handle:    $HANDLE"
log "live dir:  $LIVE"
log "work dir:  $WORK"
hr

# ─── Step 0 ─── Freeze state ───────────────────────────────────────────────
log "[0] Quitting Messages.app and snapshotting chat.db family..."
if imu_snapshot "$WORK" "$LIVE" >/dev/null; then
  for f in chat.db chat.db-wal chat.db-shm; do
    if [[ -f "$WORK/$f" ]]; then
      log "  copied $f  ($(imu_stat_size "$WORK/$f") bytes, mtime $(imu_stat_mtime "$WORK/$f"))"
    else
      log "  WARN: $LIVE/$f not present"
    fi
  done
else
  for f in chat.db chat.db-wal chat.db-shm; do
    if [[ -f "$WORK/$f" ]]; then
      log "  copied $f  ($(imu_stat_size "$WORK/$f") bytes, mtime $(imu_stat_mtime "$WORK/$f"))"
    else
      log "  WARN: $LIVE/$f not present"
    fi
  done
fi
if [[ ! -f "$SNAP" ]]; then
  log "  ABORT: $SNAP missing — does the terminal have Full Disk Access?"
  exit 1
fi
hr

# ─── Step 1 ─── Locate chat by handle (NOT display_name; that's NULL for 1:1) ─
log "[1] Resolving handle '$HANDLE' → handle.ROWID..."
HANDLE_ROWID=$(imu_handle_rowid "$SNAP" "$HANDLE")
if [[ -z "$HANDLE_ROWID" ]]; then
  log "  No handle row for '$HANDLE' — try the alternate format (E.164 vs raw, email vs phone)."
  log "  Hint: sqlite3 -readonly $SNAP \"SELECT DISTINCT id FROM handle WHERE id LIKE '%${HANDLE: -4}%';\""
  if [[ "$JSON_MODE" == "1" ]]; then
    printf '[]\n' > "$WAL_JSON"
    json_report
  fi
  exit 1
fi
log "  -> handle.ROWID = $HANDLE_ROWID"

log "[1b] Locating 1:1 chat for that handle..."
CHAT_ROWID=$(imu_chat_rowid "$SNAP" "$HANDLE" "$HANDLE_ROWID")
if [[ -z "$CHAT_ROWID" ]]; then
  log "  No 1:1 chat found; falling back to most-recently-active chat with this handle."
fi
log "  -> chat.ROWID = ${CHAT_ROWID:-(none)}"

if [[ -z "$CHAT_ROWID" ]]; then
  log "  ABORT: no chat found for handle $HANDLE"
  if [[ "$JSON_MODE" == "1" ]]; then
    printf '[]\n' > "$WAL_JSON"
    json_report
  fi
  exit 1
fi

# ─── Step 1c ─── Find unsent candidate(s) ──────────────────────────────────
# CRITICAL: on macOS 24.6 (Sequoia) Apple records unsends in
# `date_edited != 0 AND is_empty = 1`. The `date_retracted` column is unused
# on this build despite being in the schema.
log "[1c] Searching for inbound retracted messages (date_edited != 0 AND is_empty = 1)..."
imu_candidate_table "$SNAP" "$CHAT_ROWID" | tee "$WORK/candidates.tsv" | sed 's/^/    /' | tee -a "$LOG" >&2

if [[ -z "$ROWID" ]]; then
  CANDIDATE=$(imu_find_candidate "$SNAP" "$HANDLE")
else
  CANDIDATE=$(imu_find_candidate "$SNAP" "$HANDLE" "$ROWID")
fi

if [[ -n "$CANDIDATE" ]]; then
  IFS='|' read -r ROWID GUID <<<"$CANDIDATE"
fi
log "  -> top candidate ROWID: ${ROWID:-(none)}"

if [[ -z "$ROWID" ]]; then
  log "  No unsent inbound message found in chat $CHAT_ROWID."
  log "  If you're sure one exists, check edited messages too:"
  log "    sqlite3 -readonly $SNAP \"SELECT ROWID, date_edited, is_empty FROM message WHERE handle_id=$HANDLE_ROWID AND date_edited!=0 ORDER BY date DESC LIMIT 10;\""
  if [[ "$JSON_MODE" == "1" ]]; then
    printf '[]\n' > "$WAL_JSON"
    json_report
  fi
  exit 0
fi

if [[ -z "${GUID:-}" ]]; then
  GUID=$(sqlite3 -readonly "$SNAP" "SELECT guid FROM message WHERE ROWID=$ROWID;")
fi
log "  -> candidate GUID: $GUID"
IFS='|' read -r SENT_AT EDITED_AT <<<"$(sqlite3 -readonly -separator '|' "$SNAP" "
  SELECT datetime(date/1000000000 + 978307200, 'unixepoch', 'localtime'),
         datetime(date_edited/1000000000 + 978307200, 'unixepoch', 'localtime')
  FROM message WHERE ROWID=$ROWID;
")"
hr

# ─── Step 2 ─── Dump message_summary_info + attributedBody BLOBs ──────────
log "[2] Extracting BLOBs for ROWID $ROWID..."
rm -f "$MSI" "$AB" "$MSI_XML"
SAFE_MSI=$(imu_sql_escape "$MSI")
SAFE_AB=$(imu_sql_escape "$AB")
sqlite3 -readonly "$SNAP" "SELECT writefile('$SAFE_MSI', message_summary_info) FROM message WHERE ROWID=$ROWID;" >/dev/null
sqlite3 -readonly "$SNAP" "SELECT writefile('$SAFE_AB',  attributedBody)        FROM message WHERE ROWID=$ROWID;" >/dev/null

if [[ -s "$MSI" ]]; then
  log "  msi.bin: $(imu_stat_size "$MSI") bytes"
  plutil -convert xml1 -o "$MSI_XML" "$MSI" 2>>"$LOG" \
    && log "  msi.xml written"
  log "  --- plutil -p msi.bin ---"
  plutil -p "$MSI" 2>/dev/null | head -60 | sed 's/^/    /' | tee -a "$LOG" >&2
  log "  -------------------------"
  log "  Note: For *fully unsent* messages this plist contains metadata only:"
  log "    rp = retracted parts, otr.0.le = original char length, ust = user-sent text marker."
  log "    The original text is NOT preserved here."
else
  log "  msi.bin: empty"
fi
if [[ -s "$AB" ]]; then
  log "  ab.bin:  $(imu_stat_size "$AB") bytes"
else
  log "  ab.bin:  empty (Apple wipes attributedBody on full retraction)"
fi
hr

# ─── Step 3 ─── Optional typedstream decode ───────────────────────────────
log "[3] Attempting typedstream decode of attributedBody (and ec blobs in msi)..."
if python3 -c 'import typedstream' 2>/dev/null; then
  imu_decode_blobs "$AB" "$MSI" "$SCRIPT_DIR/decode.py" 2>&1 | sed 's/^/    /' | tee -a "$LOG" >&2
else
  log "  python 'typedstream' not installed; install with: pip3 install --user typedstream"
fi
hr

# ─── Step 4 ─── chat.db-wal byte forensics (the vector that usually wins) ─
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

  # Search WAL for the GUID; it appears in the messages page record near the original text.
  log "  searching for GUID byte string..."
  HITS=$(grep -aob "$GUID" "$WAL" | cut -d: -f1)
  log "  GUID occurrences in WAL: $(printf '%s\n' "$HITS" | wc -l | tr -d ' ')"

  WAL_RESULTS=$(imu_extract_from_wal "$WAL" "$GUID")
  imu_extract_from_wal_json "$WAL" "$GUID" > "$WAL_JSON"
  : > "$WORK/wal-hits.txt"
  if [[ -z "$WAL_RESULTS" ]]; then
    log "  No pre-retract text found following any GUID occurrence."
    printf "No pre-retract text found following any GUID occurrence.\n" > "$WORK/wal-hits.txt"
  else
    while IFS=$'\t' read -r off len text; do
      text_repr=$(python3 -c 'import sys; print(repr(sys.argv[1]))' "$text")
      line="WAL_OFFSET $off  LEN $len  TEXT: $text_repr"
      log "  $line"
      printf "%s\n" "$line" >> "$WORK/wal-hits.txt"
    done <<< "$WAL_RESULTS"
  fi
fi
hr

# ─── Step 5 ─── Cross-check with imessage-exporter (ReagentX) ─────────────
log "[5] imessage-exporter cross-check..."
EXP="$WORK/export"
rm -rf "$EXP"
if command -v imessage-exporter >/dev/null; then
  if ! imessage-exporter -f txt -o "$EXP" -p "$SNAP" -c full >/dev/null 2>>"$LOG"; then
    log "  exporter exited non-zero (often harmless if attachments dir is missing)"
  fi
  if [[ -d "$EXP" ]]; then
    : > "$WORK/exporter-hits.txt"
    grep -RIn -B1 -A4 "$GUID"  "$EXP" >> "$WORK/exporter-hits.txt" 2>/dev/null || true
    grep -RIn -i 'unsent\|retract' "$EXP" 2>/dev/null | head -30 >> "$WORK/exporter-hits.txt" || true
    log "  exporter-hits.txt: $(wc -l <"$WORK/exporter-hits.txt" | tr -d ' ') lines"
  fi
else
  log "  imessage-exporter not installed; skip (optional)"
  log "    install: cargo install imessage-exporter"
fi
hr

# ─── Step 6 ─── Other vectors (informational) ─────────────────────────────
log "[6] Other recovery vectors to consider manually:"
log "  - Time Machine snapshots of chat.db (tmutil listbackups, then mount)"
log "  - APFS local snapshots (tmutil listlocalsnapshots /)"
log "  - iPhone backups in ~/Library/Application Support/MobileSync/Backup/"
log "  - iMazing / iExplorer / 3uTools backups (paths vary)"
hr

log "[done] Report: $LOG"
log "Artifacts:"
ls -la "$WORK" | sed 's/^/  /' | tee -a "$LOG" >&2

if [[ "$JSON_MODE" == "1" ]]; then
  json_report
fi
