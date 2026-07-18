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
#   ./recover.sh --handle '+1...' --include-iphone-backup --json
#   ./recover.sh --handle '+1...' --include-iphone-backup /path/to/backup --json
#   ./recover.sh --all-handles --since 24h --json
#   ./recover.sh --handles-file handles.txt --since 7d --json
#   ./recover.sh --handles-file handles.txt --dry-run
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

# The work dir holds a full chat.db snapshot and recovered plaintext. Default to
# owner-only perms for everything we create (dirs 0700, files 0600) so nothing
# private lands in a world-readable location (#112 / F-M1).
umask 077

# Removes the auto-created private work dir on exit. A user-supplied --work is
# never touched — it's theirs to keep.
imu_cleanup_workdir() {
  if [[ "${WORK_AUTOCREATED:-0}" == "1" && -n "${WORK:-}" && -d "${WORK:-}" ]]; then
    rm -rf "$WORK"
  fi
  return 0
}

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
HANDLES_FILE=""
ALL_HANDLES=0
ROWID=""
WORK=""            # empty => create a private per-run dir under $TMPDIR
WORK_AUTOCREATED=0
LIVE="$HOME/Library/Messages"
JSON_MODE=0
SINCE="24h"
DRY_RUN=0
INCLUDE_IPHONE_BACKUP=0
IPHONE_BACKUP_PATH=""
IPHONE_BACKUP_CONFIG="$HOME/.config/imessage-unsent/iphone-backup-paths.txt"
FAILURE_CATEGORY=""

usage() {
  sed -n '2,30p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handle) HANDLE="$2"; shift 2 ;;
    --handles-file) HANDLES_FILE="$2"; shift 2 ;;
    --all-handles) ALL_HANDLES=1; shift ;;
    --rowid)  ROWID="$2";  shift 2 ;;
    --work)   WORK="$2";   shift 2 ;;
    --json)   JSON_MODE=1; shift ;;
    --since)  SINCE="$2";  shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --include-iphone-backup)
      INCLUDE_IPHONE_BACKUP=1
      if [[ $# -gt 1 && "${2:-}" != --* ]]; then
        IPHONE_BACKUP_PATH="$2"
        shift 2
      else
        shift
      fi
      ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

MODE_COUNT=0
[[ -n "$HANDLE" ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ -n "$HANDLES_FILE" ]] && MODE_COUNT=$((MODE_COUNT + 1))
[[ "$ALL_HANDLES" == "1" ]] && MODE_COUNT=$((MODE_COUNT + 1))
BATCH_MODE=0
if [[ -n "$HANDLES_FILE" || "$ALL_HANDLES" == "1" ]]; then
  BATCH_MODE=1
fi

if [[ "$MODE_COUNT" -ne 1 ]]; then
  echo "ERROR: choose exactly one of --handle, --handles-file, or --all-handles" >&2
  usage 1
fi

if [[ "$BATCH_MODE" == "0" && "$DRY_RUN" == "1" ]]; then
  echo "ERROR: --dry-run is only supported with --handles-file or --all-handles" >&2
  exit 1
fi

if [[ "$BATCH_MODE" == "0" && -n "$ROWID" && ! "$ROWID" =~ ^[0-9]+$ ]]; then
  echo "ERROR: --rowid must be numeric" >&2
  exit 1
fi

if [[ "$BATCH_MODE" == "1" && -n "$ROWID" ]]; then
  echo "ERROR: --rowid is only supported with --handle" >&2
  exit 1
fi

if [[ "$BATCH_MODE" == "1" && "$INCLUDE_IPHONE_BACKUP" == "1" ]]; then
  echo "ERROR: --include-iphone-backup is only supported with --handle" >&2
  exit 1
fi

if [[ -n "$HANDLES_FILE" && ! -f "$HANDLES_FILE" ]]; then
  echo "ERROR: --handles-file does not exist: $HANDLES_FILE" >&2
  exit 1
fi

if [[ "$BATCH_MODE" == "1" ]]; then
  imu_since_cutoff_ns "$SINCE" >/dev/null || exit 1
fi

if [[ "$DRY_RUN" == "1" ]]; then
  if [[ "$JSON_MODE" == "1" ]]; then
    python3 - "$ALL_HANDLES" "$HANDLES_FILE" "$SINCE" <<'PY'
import json
import sys

all_handles = sys.argv[1] == "1"
handles_file = sys.argv[2]
since = sys.argv[3]
if all_handles:
    payload = [{"handle": None, "dry_run": True, "scan": "all-handles", "since": since, "candidates": []}]
else:
    handles = [
        line.strip()
        for line in open(handles_file)
        if line.strip() and not line.lstrip().startswith("#")
    ]
    payload = [{"handle": handle, "dry_run": True, "since": since, "candidates": []} for handle in handles]
print(json.dumps(payload, ensure_ascii=False))
PY
  elif [[ "$ALL_HANDLES" == "1" ]]; then
    printf '[dry-run] would scan all handles in %s since %s\n' "$LIVE" "$SINCE"
  else
    printf '[dry-run] would scan handles from %s since %s\n' "$HANDLES_FILE" "$SINCE"
    awk 'NF && $1 !~ /^#/ {print "  " $0}' "$HANDLES_FILE"
  fi
  exit 0
fi

# When the user didn't pass --work, create an unpredictable private dir under
# $TMPDIR (per-user + 0700 on macOS; mktemp forces 0700 even under /tmp) and
# remove it on exit. A user-supplied --work is hardened to 0700 but never
# auto-deleted — it's theirs to keep (#112 / F-M1).
if [[ -z "$WORK" ]]; then
  WORK="$(mktemp -d "${TMPDIR:-/tmp}/imessage-recovery.XXXXXX")" || {
    echo "error: could not create a private work directory" >&2
    exit 1
  }
  WORK_AUTOCREATED=1
  trap 'imu_cleanup_workdir' EXIT
else
  mkdir -p "$WORK"
  chmod 700 "$WORK" 2>/dev/null || true
fi
LOG="$WORK/report.txt"
SNAP="$WORK/chat.db"
MSI="$WORK/msi.bin"
AB="$WORK/ab.bin"
MSI_XML="$WORK/msi.xml"
WAL_JSON="$WORK/wal-candidates.json"
IPHONE_BACKUP_JSON="$WORK/iphone-backup.json"
: > "$LOG"
printf '{"enabled":false,"hit":false,"reason":"not requested"}\n' > "$IPHONE_BACKUP_JSON"

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
    --wal-json "$WAL_JSON" \
    --iphone-json "$IPHONE_BACKUP_JSON" \
    --failure-category "${FAILURE_CATEGORY:-}"
}

batch_first_wal_result() {
  local wal_json="${1:?usage: batch_first_wal_result <wal_json>}"
  python3 "$LIB_DIR/recovery_selection.py" --wal-json "$wal_json" --format tsv
}

batch_state_recent() {
  local state_file="${1:?usage: batch_state_recent <state_file> <handle> <date_edited> <now>}"
  local handle="${2:?usage: batch_state_recent <state_file> <handle> <date_edited> <now>}"
  local date_edited="${3:?usage: batch_state_recent <state_file> <handle> <date_edited> <now>}"
  local now="${4:?usage: batch_state_recent <state_file> <handle> <date_edited> <now>}"

  [[ -f "$state_file" ]] || return 1
  awk -F '\t' -v h="$handle" -v edited="$date_edited" -v now="$now" '
    $1 == h && $2 == edited && now - $3 < 60 { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$state_file"
}

batch_append_record() {
  local path="${1:?usage: batch_append_record <path> <fields...>}"
  shift
  local first=1
  local field
  for field in "$@"; do
    if [[ "$first" == "1" ]]; then
      first=0
    else
      printf '\t' >> "$path"
    fi
    printf '%s' "$field" >> "$path"
  done
  printf '\n' >> "$path"
}

run_batch_mode() {
  local since_ns handles_path results_path state_path now
  local handle candidate_lines latest_edited
  local row_handle rowid guid sent_at edited_at date_edited
  local wal_offset wal_length text_b64 wal_json_path

  since_ns=$(imu_since_cutoff_ns "$SINCE") || exit 1
  handles_path="$WORK/batch-handles.txt"
  results_path="$WORK/batch-results.tsv"
  state_path="$WORK/batch-state.tsv"
  : > "$handles_path"
  : > "$results_path"

  if [[ "$ALL_HANDLES" == "1" ]]; then
    imu_candidate_handles "$SNAP" "$since_ns" > "$handles_path"
  else
    awk 'NF && $1 !~ /^#/ {print $0}' "$HANDLES_FILE" > "$handles_path"
  fi

  if [[ ! -s "$handles_path" ]]; then
    log "[batch] No handles to scan in the selected window."
    if [[ "$JSON_MODE" == "1" ]]; then
      printf '[]\n'
    fi
    return 0
  fi

  log "[batch] Scanning handles from one snapshot..."
  now=$(date +%s)
  while IFS= read -r handle; do
    [[ -n "$handle" ]] || continue
    candidate_lines=$(imu_batch_candidates_for_handle "$SNAP" "$since_ns" "$handle")

    if [[ -z "$candidate_lines" ]]; then
      log "  $handle: no retracted inbound messages in window"
      batch_append_record "$results_path" "$handle" "" "" "" "" "" "" "" "" "0" ""
      continue
    fi

    latest_edited=$(printf '%s\n' "$candidate_lines" | awk -F '\t' 'NR == 1 { print $6 }')
    if batch_state_recent "$state_path" "$handle" "$latest_edited" "$now"; then
      log "  $handle: skipped (rate-limited)"
      batch_append_record "$results_path" "$handle" "" "" "" "" "" "" "" "" "1" "rate_limited"
      continue
    fi

    while IFS=$'\t' read -r row_handle rowid guid sent_at edited_at date_edited; do
      [[ -n "$rowid" ]] || continue
      wal_offset=""
      wal_length=""
      text_b64=""
      if [[ -s "$WORK/chat.db-wal" ]]; then
        wal_json_path="$WORK/wal-$rowid.json"
        imu_extract_from_wal_json "$WORK/chat.db-wal" "$guid" > "$wal_json_path"
        IFS=$'\t' read -r wal_offset wal_length text_b64 <<< "$(batch_first_wal_result "$wal_json_path")"
      fi
      batch_append_record \
        "$results_path" \
        "$row_handle" "$rowid" "$guid" "$sent_at" "$edited_at" "$date_edited" \
        "$wal_offset" "$wal_length" "$text_b64" "0" ""
      if [[ -n "$text_b64" ]]; then
        log "  $row_handle: ROWID $rowid recovered via WAL"
      else
        log "  $row_handle: ROWID $rowid no WAL text recovered"
      fi
    done <<< "$candidate_lines"

    printf '%s\t%s\t%s\n' "$handle" "$latest_edited" "$now" >> "$state_path"
  done < "$handles_path"

  if [[ "$JSON_MODE" == "1" ]]; then
    python3 "$LIB_DIR/batch_report.py" "$results_path"
  else
    log "[batch] Results written to $results_path"
  fi
}

RAN_AT=$(imu_iso_utc)

hr
log "imessage-unsent recovery — $(date)"
if [[ "$BATCH_MODE" == "1" ]]; then
  if [[ "$ALL_HANDLES" == "1" ]]; then
    log "mode:      all-handles batch"
  else
    log "mode:      handles-file batch ($HANDLES_FILE)"
  fi
  log "since:     $SINCE"
else
  log "handle:    $HANDLE"
fi
log "live dir:  $LIVE"
log "work dir:  $WORK"
hr

# ─── Step 0 ─── Freeze state ───────────────────────────────────────────────
if [[ -f "$SNAP" ]]; then
  log "[0] Using existing chat.db snapshot in work dir..."
  for f in chat.db chat.db-wal chat.db-shm; do
    if [[ -f "$WORK/$f" ]]; then
      log "  found $f  ($(imu_stat_size "$WORK/$f") bytes, mtime $(imu_stat_mtime "$WORK/$f"))"
    else
      log "  WARN: $WORK/$f not present"
    fi
  done
else
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
fi
if [[ ! -f "$SNAP" ]]; then
  log "  ABORT: $SNAP missing — does the terminal have Full Disk Access?"
  exit 1
fi
hr

if [[ "$BATCH_MODE" == "1" ]]; then
  run_batch_mode
  exit $?
fi

# ─── Step 1 ─── Locate chat by handle (NOT display_name; that's NULL for 1:1) ─
log "[1] Resolving handle '$HANDLE' → handle.ROWID..."
HANDLE_ROWID=$(imu_handle_rowid "$SNAP" "$HANDLE")
if [[ -z "$HANDLE_ROWID" ]]; then
  log "  No handle row for '$HANDLE' — try the alternate format (E.164 vs raw, email vs phone)."
  log "  Hint: sqlite3 -readonly $SNAP \"SELECT DISTINCT id FROM handle WHERE id LIKE '%${HANDLE: -4}%';\""
  FAILURE_CATEGORY="unknown_handle"
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
  FAILURE_CATEGORY="unknown_handle"
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
  FAILURE_CATEGORY="not_in_local_wal"
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
IFS='|' read -r SENT_AT EDITED_AT SENT_NS EDITED_NS <<<"$(sqlite3 -readonly -separator '|' "$SNAP" "
  SELECT datetime(date/1000000000 + 978307200, 'unixepoch', 'localtime'),
         datetime(date_edited/1000000000 + 978307200, 'unixepoch', 'localtime'),
         date,
         date_edited
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
    log "  No pre-retract text found in live chat.db-wal."
    printf "No pre-retract text found in live chat.db-wal.\n" > "$WORK/wal-hits.txt"
    FAILURE_CATEGORY="wal_checkpointed"
  else
    while IFS=$'\t' read -r off len text; do
      text_repr=$(python3 -c 'import sys; print(repr(sys.argv[1]))' "$text")
      line="WAL_OFFSET $off  LEN $len  TEXT: $text_repr"
      log "  $line"
      printf "%s\n" "$line" >> "$WORK/wal-hits.txt"
    done <<< "$WAL_RESULTS"
  fi

  # Also scan the rolling WAL history buffer (#67). The daemon snapshots
  # chat.db-wal on every change, so older WAL frames that SQLite has since
  # checkpointed away may still survive in `wal-history/`. This is the
  # difference-maker for long messages where the live WAL has already been
  # rewritten by the time the recovery runs.
  WAL_HISTORY_DIR="$WORK/wal-history"
  if [[ -d "$WAL_HISTORY_DIR" ]]; then
    hist_count=0
    while IFS= read -r -d '' HIST; do
      [[ -f "$HIST" ]] || continue
      hist_count=$((hist_count + 1))
      HIST_RESULTS=$(imu_extract_from_wal "$HIST" "$GUID" 2>/dev/null || true)
      if [[ -n "$HIST_RESULTS" ]]; then
        while IFS=$'\t' read -r off len text; do
          text_repr=$(python3 -c 'import sys; print(repr(sys.argv[1]))' "$text")
          line="WAL_HISTORY $(basename "$HIST")  OFFSET $off  LEN $len  TEXT: $text_repr"
          log "  $line"
          printf "%s\n" "$line" >> "$WORK/wal-hits.txt"
        done <<< "$HIST_RESULTS"
      fi
    done < <(find "$WAL_HISTORY_DIR" -maxdepth 1 -name '*.db-wal' -print0 2>/dev/null)
    log "  wal-history scan: $hist_count snapshot(s)"

    # Merge candidates from every source into wal-candidates.json so the
    # downstream JSON-report builder sees them all.
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
    python3 "$lib_dir/wal_merge_candidates.py" \
      --guid "$GUID" \
      --live "$WAL" \
      --history-dir "$WAL_HISTORY_DIR" \
      > "$WAL_JSON"
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

# ─── Step 6 ─── iPhone backup vector ──────────────────────────────────────
log "[6] iPhone backup vector..."
if [[ "$INCLUDE_IPHONE_BACKUP" == "1" ]]; then
  IPHONE_ARGS=(
    --handle "$HANDLE"
    --guid "$GUID"
    --sent-ns "$SENT_NS"
    --edited-ns "$EDITED_NS"
    --home "$HOME"
    --config "$IPHONE_BACKUP_CONFIG"
  )
  if [[ -n "$IPHONE_BACKUP_PATH" ]]; then
    IPHONE_ARGS+=(--path "$IPHONE_BACKUP_PATH")
  fi

  if python3 "$LIB_DIR/iphone_backup.py" "${IPHONE_ARGS[@]}" > "$IPHONE_BACKUP_JSON" 2>>"$LOG"; then
    python3 - "$IPHONE_BACKUP_JSON" <<'PY' | sed 's/^/  /' | tee -a "$LOG" >&2
import json
import sys

payload = json.load(open(sys.argv[1]))
if payload.get("hit"):
    backup = payload.get("backup") or {}
    print(f"iPhone backup hit: {payload.get('length')} bytes from {backup.get('root')}")
else:
    print(f"iPhone backup miss: {payload.get('reason')}")
PY
  else
    log "  iPhone backup vector failed; see report.txt for details."
    printf '{"enabled":true,"hit":false,"reason":"iphone backup helper failed"}\n' > "$IPHONE_BACKUP_JSON"
  fi
else
  log "  not requested; pass --include-iphone-backup [path] to enable."
fi
hr

# ─── Step 7 ─── Other vectors (informational) ─────────────────────────────
log "[7] Other recovery vectors to consider manually:"
log "  - Time Machine snapshots of chat.db (tmutil listbackups, then mount)"
log "  - APFS local snapshots (tmutil listlocalsnapshots /)"
log "  - iMazing / iExplorer / 3uTools backups (paths vary)"
hr

log "[done] Report: $LOG"
log "Artifacts:"
ls -la "$WORK" | sed 's/^/  /' | tee -a "$LOG" >&2
if [[ "$WORK_AUTOCREATED" == "1" ]]; then
  log "Note: this private work dir is removed on exit. Pass --work DIR to keep artifacts."
fi

if [[ "$JSON_MODE" == "1" ]]; then
  json_report
fi
