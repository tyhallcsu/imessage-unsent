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

# ─── arg parsing ───────────────────────────────────────────────────────────
HANDLE=""
ROWID=""
WORK="/tmp/imessage-recovery"
LIVE="$HOME/Library/Messages"

usage() {
  sed -n '2,30p' "$0"
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --handle) HANDLE="$2"; shift 2 ;;
    --rowid)  ROWID="$2";  shift 2 ;;
    --work)   WORK="$2";   shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "unknown arg: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$HANDLE" ]]; then
  echo "ERROR: --handle is required (phone number in E.164 format or Apple ID email)" >&2
  usage 1
fi

mkdir -p "$WORK"
LOG="$WORK/report.txt"
SNAP="$WORK/chat.db"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG" >&2; }
hr()  { log "================================================================"; }

hr
log "imessage-unsent recovery — $(date)"
log "handle:    $HANDLE"
log "live dir:  $LIVE"
log "work dir:  $WORK"
hr

# ─── Step 0 ─── Freeze state ───────────────────────────────────────────────
log "[0] Quitting Messages.app and snapshotting chat.db family..."
osascript -e 'quit app "Messages"' 2>/dev/null || true
sleep 2
for f in chat.db chat.db-wal chat.db-shm; do
  if [[ -f "$LIVE/$f" ]]; then
    cp "$LIVE/$f" "$WORK/$f"
    log "  copied $f  ($(stat -f '%z' "$WORK/$f") bytes, mtime $(stat -f '%Sm' "$WORK/$f"))"
  else
    log "  WARN: $LIVE/$f not present"
  fi
done
if [[ ! -f "$SNAP" ]]; then
  log "  ABORT: $SNAP missing — does the terminal have Full Disk Access?"
  exit 1
fi
hr

# ─── Step 1 ─── Locate chat by handle (NOT display_name; that's NULL for 1:1) ─
log "[1] Resolving handle '$HANDLE' → handle.ROWID..."
HANDLE_ROWID=$(sqlite3 -readonly "$SNAP" \
  "SELECT ROWID FROM handle WHERE id = '${HANDLE//\'/\'\'}' LIMIT 1;")
if [[ -z "$HANDLE_ROWID" ]]; then
  log "  No handle row for '$HANDLE' — try the alternate format (E.164 vs raw, email vs phone)."
  log "  Hint: sqlite3 -readonly $SNAP \"SELECT DISTINCT id FROM handle WHERE id LIKE '%${HANDLE: -4}%';\""
  exit 1
fi
log "  -> handle.ROWID = $HANDLE_ROWID"

log "[1b] Locating 1:1 chat for that handle..."
CHAT_ROWID=$(sqlite3 -readonly "$SNAP" "
  SELECT c.ROWID
  FROM chat c
  JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
  WHERE chj.handle_id = $HANDLE_ROWID
    AND c.chat_identifier = '${HANDLE//\'/\'\'}'
  ORDER BY c.ROWID LIMIT 1;
")
if [[ -z "$CHAT_ROWID" ]]; then
  log "  No 1:1 chat found; falling back to most-recently-active chat with this handle."
  CHAT_ROWID=$(sqlite3 -readonly "$SNAP" "
    SELECT c.ROWID
    FROM chat c
    JOIN chat_handle_join chj ON chj.chat_id = c.ROWID
    WHERE chj.handle_id = $HANDLE_ROWID
    ORDER BY c.ROWID DESC LIMIT 1;
  ")
fi
log "  -> chat.ROWID = ${CHAT_ROWID:-(none)}"

if [[ -z "$CHAT_ROWID" ]]; then
  log "  ABORT: no chat found for handle $HANDLE"
  exit 1
fi

# ─── Step 1c ─── Find unsent candidate(s) ──────────────────────────────────
# CRITICAL: on macOS 24.6 (Sequoia) Apple records unsends in
# `date_edited != 0 AND is_empty = 1`. The `date_retracted` column is unused
# on this build despite being in the schema.
log "[1c] Searching for inbound retracted messages (date_edited != 0 AND is_empty = 1)..."
sqlite3 -readonly "$SNAP" <<SQL | tee "$WORK/candidates.tsv" | sed 's/^/    /' | tee -a "$LOG"
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
WHERE cmj.chat_id = $CHAT_ROWID
  AND m.is_from_me = 0
  AND m.date_edited != 0
  AND m.is_empty = 1
ORDER BY m.date DESC LIMIT 10;
SQL

if [[ -z "$ROWID" ]]; then
  ROWID=$(sqlite3 -readonly "$SNAP" "
    SELECT m.ROWID FROM message m
    JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
    WHERE cmj.chat_id = $CHAT_ROWID
      AND m.is_from_me = 0
      AND m.date_edited != 0
      AND m.is_empty = 1
    ORDER BY m.date DESC LIMIT 1;
  ")
fi
log "  -> top candidate ROWID: ${ROWID:-(none)}"

if [[ -z "$ROWID" ]]; then
  log "  No unsent inbound message found in chat $CHAT_ROWID."
  log "  If you're sure one exists, check edited messages too:"
  log "    sqlite3 -readonly $SNAP \"SELECT ROWID, date_edited, is_empty FROM message WHERE handle_id=$HANDLE_ROWID AND date_edited!=0 ORDER BY date DESC LIMIT 10;\""
  exit 0
fi

GUID=$(sqlite3 -readonly "$SNAP" "SELECT guid FROM message WHERE ROWID=$ROWID;")
log "  -> candidate GUID: $GUID"
hr

# ─── Step 2 ─── Dump message_summary_info + attributedBody BLOBs ──────────
log "[2] Extracting BLOBs for ROWID $ROWID..."
rm -f "$WORK/msi.bin" "$WORK/ab.bin" "$WORK/msi.xml"
sqlite3 -readonly "$SNAP" "SELECT writefile('$WORK/msi.bin', message_summary_info) FROM message WHERE ROWID=$ROWID;" >/dev/null
sqlite3 -readonly "$SNAP" "SELECT writefile('$WORK/ab.bin',  attributedBody)        FROM message WHERE ROWID=$ROWID;" >/dev/null

if [[ -s "$WORK/msi.bin" ]]; then
  log "  msi.bin: $(stat -f '%z' "$WORK/msi.bin") bytes"
  plutil -convert xml1 -o "$WORK/msi.xml" "$WORK/msi.bin" 2>>"$LOG" \
    && log "  msi.xml written"
  log "  --- plutil -p msi.bin ---"
  plutil -p "$WORK/msi.bin" 2>/dev/null | head -60 | sed 's/^/    /' | tee -a "$LOG"
  log "  -------------------------"
  log "  Note: For *fully unsent* messages this plist contains metadata only:"
  log "    rp = retracted parts, otr.0.le = original char length, ust = user-sent text marker."
  log "    The original text is NOT preserved here."
else
  log "  msi.bin: empty"
fi
if [[ -s "$WORK/ab.bin" ]]; then
  log "  ab.bin:  $(stat -f '%z' "$WORK/ab.bin") bytes"
else
  log "  ab.bin:  empty (Apple wipes attributedBody on full retraction)"
fi
hr

# ─── Step 3 ─── Optional typedstream decode ───────────────────────────────
log "[3] Attempting typedstream decode of attributedBody (and ec blobs in msi)..."
DECODE="$(dirname "$0")/decode.py"
if [[ ! -f "$DECODE" ]]; then
  log "  decode.py not found alongside recover.sh — skipping"
elif python3 -c 'import typedstream' 2>/dev/null; then
  python3 "$DECODE" "$WORK/ab.bin" "$WORK/msi.bin" 2>&1 | sed 's/^/    /' | tee -a "$LOG"
else
  log "  python 'typedstream' not installed; install with: pip3 install --user typedstream"
fi
hr

# ─── Step 4 ─── chat.db-wal byte forensics (the vector that usually wins) ─
log "[4] Searching chat.db-wal for pre-retract page images..."
WAL="$WORK/chat.db-wal"
if [[ ! -s "$WAL" ]]; then
  log "  WAL file empty or missing; skipping."
else
  log "  WAL size: $(stat -f '%z' "$WAL") bytes"
  PGSIZE=$(sqlite3 -readonly "$SNAP" "PRAGMA page_size;")
  log "  page_size = $PGSIZE  approx_frames = $(( ($(stat -f '%z' "$WAL") - 32) / (24 + PGSIZE) ))"

  # Search WAL for the GUID; it appears in the messages page record near the original text.
  log "  searching for GUID byte string..."
  HITS=$(grep -aob "$GUID" "$WAL" | cut -d: -f1)
  log "  GUID occurrences in WAL: $(printf '%s\n' "$HITS" | wc -l | tr -d ' ')"

  python3 - "$WAL" "$GUID" "$WORK/wal-hits.txt" <<'PY' 2>&1 | sed 's/^/    /' | tee -a "$LOG"
import sys
wal_path, guid, out_path = sys.argv[1], sys.argv[2].encode(), sys.argv[3]
with open(wal_path, 'rb') as f:
    data = f.read()
hits, start = [], 0
while True:
    i = data.find(guid, start)
    if i < 0: break
    hits.append(i); start = i + 1

# The serialized message row stores: ... <guid TEXT 36 bytes> <text TEXT N bytes>
# followed by the typedstream marker b'\x04\x0bstreamtyped'.
# So bytes immediately after each GUID hit are candidate text.
seen = set()
results = []
for off in hits:
    after = data[off+36:off+36+512]
    end = after.find(b'\x04\x0bstreamtyped')
    if end <= 0:
        continue
    candidate = after[:end]
    # Skip leading control bytes (length prefixes)
    while candidate and candidate[0] < 0x20 and candidate[0] not in (0x09, 0x0a, 0x0d):
        candidate = candidate[1:]
    if not candidate:
        continue
    try:
        text = candidate.decode('utf-8')
    except UnicodeDecodeError:
        continue
    if not any(c.isprintable() for c in text):
        continue
    key = text[:120]
    if key in seen:
        continue
    seen.add(key)
    results.append((off, text))

with open(out_path, 'w') as out:
    if not results:
        msg = "No pre-retract text found following any GUID occurrence."
        print(msg); out.write(msg + "\n")
    else:
        for off, text in results:
            line = f"WAL_OFFSET {off}  LEN {len(text)}  TEXT: {text!r}"
            print(line); out.write(line + "\n")
PY
fi
hr

# ─── Step 5 ─── Cross-check with imessage-exporter (ReagentX) ─────────────
log "[5] imessage-exporter cross-check..."
EXP="$WORK/export"
rm -rf "$EXP"
if command -v imessage-exporter >/dev/null; then
  if ! imessage-exporter -f txt -o "$EXP" -p "$SNAP" -c full 2>>"$LOG"; then
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
ls -la "$WORK" | sed 's/^/  /' | tee -a "$LOG"
