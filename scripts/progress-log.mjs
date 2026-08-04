#!/usr/bin/env node
// Update the live completion-loop progress dashboard state (idempotent, additive).
//
//   node scripts/progress-log.mjs [--root <dir>] [--reseed] \
//        [--merge '<json>'] [--event '<kind>:<message>'] \
//        [--pct <0-100>] [--status '<text>'] [--next '<text>'] [--milestone '<id>:<status>']
//
// Behaviour:
//   - Seeds artifacts/progress/progress.json from progress.seed.json on first run.
//   - --reseed ignores an existing (possibly corrupt) progress.json and restarts from
//     the seed; without it, a corrupt progress.json fails loudly with guidance.
//   - Deep-merges --merge into the state (objects merge; arrays/scalars REPLACE).
//   - --pct / --status / --next are shorthands for common single-field updates.
//   - --milestone <id>:<status> updates one milestone in place by id (array-aware,
//     which a deep-merge cannot do); appends a stub milestone if the id is new.
//   - Stamps meta.generatedAt (ISO) and writes atomically (temp file + rename).
//   - Serializes the read-modify-write with a no-stale-break .progress.lock mutex, so two
//     concurrent runs on the same dir queue then FAIL LOUD rather than silently drop an
//     update. No auto-unlock; a crashed writer's lock is cleared human-only (see withLock).
//   - Appends {ts,kind,msg} to events.jsonl when --event is given (the kind is taken
//     from the text before the first ':' only when it is a known kind).
//
// event kinds (drive the viewer's colour chips):
//   info | test | build | security | commit | push | pr | merge | deploy |
//   debate | milestone | blocker | decision | handoff
// Unknown kinds still render (neutral chip) — the set above is just the styled one.
import { readFile, writeFile, appendFile, rename, open, unlink } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, resolve } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name) => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : null; };

function resolveRoot() {
  const explicit = opt('--root');
  if (explicit) return resolve(explicit);
  const sibling = join(__dirname, '..', 'artifacts', 'progress');
  if (existsSync(sibling)) return sibling;
  return resolve(process.cwd(), 'artifacts', 'progress');
}
const DIR = resolveRoot();
const STATE = join(DIR, 'progress.json');
const SEED = join(DIR, 'progress.seed.json');
const EVENTS = join(DIR, 'events.jsonl');

const KNOWN_KINDS = new Set(['info', 'test', 'build', 'security', 'commit', 'push', 'pr',
  'merge', 'deploy', 'debate', 'milestone', 'blocker', 'decision', 'handoff']);

const isObj = (v) => v && typeof v === 'object' && !Array.isArray(v);
function deepMerge(base, patch) {
  if (!isObj(base) || !isObj(patch)) return patch;
  const out = { ...base };
  for (const [k, v] of Object.entries(patch)) out[k] = isObj(v) && isObj(out[k]) ? deepMerge(out[k], v) : v;
  return out;
}

// Clean exit that still runs `finally` blocks (unlike process.exit), so a held lock is
// always released. Thrown inside withLock → the finally unlinks, then main().catch exits.
class ExitError extends Error { constructor(code) { super(`exit ${code}`); this.code = code; } }

// Single-writer mutex over the progress.json read-modify-write, so two concurrent
// progress-log runs against the same artifacts/progress/ can't silently drop an update
// (last-writer-wins). Pure O_EXCL create with NO automatic stale-break — a race-free one
// is impossible with zero deps, and stealing a lock risks deleting a live writer's file.
// On contention: wait ≤8s, then FAIL LOUD (never a silent lost update). A crashed writer
// leaves the lock; the error names it + the holder pid. Recovery is HUMAN-ONLY: confirm
// that pid is not running, then delete the file. Scope: a local worktree filesystem
// (not a network/distributed FS, where neither O_EXCL nor the pid is a reliable token).
const LOCK = join(DIR, '.progress.lock');
async function withLock(fn) {
  const deadline = Date.now() + 8000;
  let fh;
  for (;;) {
    try { fh = await open(LOCK, 'wx'); break; } // atomic exclusive create — the only acquire path
    catch (e) {
      if (e.code !== 'EEXIST') throw e;
      if (Date.now() > deadline) {
        let by = ''; try { by = (await readFile(LOCK, 'utf8')).trim(); } catch { /* empty or just released */ }
        console.error(`progress-log: lock held (${LOCK}${by ? `, ${by}` : ''}) — another writer is active, or`
          + ' a prior one crashed. If that pid is not running, delete the file and retry.');
        throw new ExitError(1); // NOT holding the lock here → do not unlink
      }
      await new Promise((r) => setTimeout(r, 25 + Math.floor(Math.random() * 50)));
    }
  }
  // We are the sole holder (no steal path exists), so the finally only ever removes our own lock.
  try {
    await fh.write(`pid ${process.pid} @ ${new Date().toISOString()}`);
    await fh.close();
    return await fn();
  } finally {
    await unlink(LOCK).catch(() => {});
  }
}

async function main() {
  if (!existsSync(DIR)) { console.error(`progress-log: root not found: ${DIR}`); process.exit(1); }

  // Parse + validate every input BEFORE taking the lock (pure, no file I/O) so an input
  // error exits without ever touching the lock.
  const reseed = argv.includes('--reseed');
  const mergeStr = opt('--merge');
  let patch = null;
  if (mergeStr) {
    try { patch = JSON.parse(mergeStr); }
    catch (e) { console.error('progress-log: --merge is not valid JSON:', e.message); process.exit(2); }
  }
  const pctStr = opt('--pct');
  let pct = null;
  if (pctStr != null) {
    pct = Math.max(0, Math.min(100, Number(pctStr)));
    if (Number.isNaN(pct)) { console.error('progress-log: --pct must be a number'); process.exit(2); }
  }
  const status = opt('--status');
  const next = opt('--next');
  const milestoneStr = opt('--milestone');
  let mId = null, mSt = null;
  if (milestoneStr != null) {
    const idx = milestoneStr.indexOf(':');
    if (idx < 0) { console.error('progress-log: --milestone must be "<id>:<status>"'); process.exit(2); }
    mId = milestoneStr.slice(0, idx).trim();
    mSt = milestoneStr.slice(idx + 1).trim();
  }

  // Locked read-modify-write: read state → apply → atomic temp+rename, as one unit.
  await withLock(async () => {
    // --reseed ignores an existing (possibly corrupt) progress.json and restarts from the seed.
    let state = {};
    const readFrom = (!reseed && existsSync(STATE)) ? STATE : (existsSync(SEED) ? SEED : null);
    if (readFrom) {
      try { state = JSON.parse(await readFile(readFrom, 'utf8')); }
      catch (e) {
        console.error(`progress-log: ${readFrom} is not valid JSON — ${e.message}`);
        if (readFrom === STATE) console.error('progress-log: fix it, or re-run with --reseed to restart from the seed.');
        throw new ExitError(1);
      }
    }
    if (patch) state = deepMerge(state, patch);
    if (pct != null) state.overall = { ...(state.overall || {}), completionPct: pct };
    if (status != null) state.meta = { ...(state.meta || {}), status };
    if (next != null) state.next = next;
    if (mId != null) {
      state.milestones = Array.isArray(state.milestones) ? state.milestones : [];
      const m = state.milestones.find((x) => x && x.id === mId);
      if (m) m.status = mSt;
      else state.milestones.push({ id: mId, title: mId, status: mSt });
    }
    state.meta = state.meta || {};
    state.meta.generatedAt = new Date().toISOString();
    // Atomic write: temp file + rename, so a polling viewer never reads a truncated file.
    const tmp = STATE + '.' + process.pid + '.tmp';
    await writeFile(tmp, JSON.stringify(state, null, 2) + '\n');
    await rename(tmp, STATE);
  });

  // events.jsonl is an INDEPENDENT append-only audit log (O_APPEND, atomic per short line),
  // deliberately OUTSIDE the lock: state + event are a snapshot + audit log, not an atomic pair.
  const eventStr = opt('--event');
  if (eventStr) {
    // Treat the part before the first ':' as the kind ONLY when it is a known kind —
    // otherwise a colon in the message (e.g. a URL) would be misread as the kind.
    let kind = 'info', msg = eventStr.trim();
    const idx = eventStr.indexOf(':');
    if (idx > -1) {
      const cand = eventStr.slice(0, idx).trim().toLowerCase();
      if (KNOWN_KINDS.has(cand)) { kind = cand; msg = eventStr.slice(idx + 1).trim(); }
    }
    await appendFile(EVENTS, JSON.stringify({ ts: new Date().toISOString(), kind, msg }) + '\n');
  }
  console.log('[progress] state updated' + (eventStr ? ' + event logged' : '') + ` (${STATE})`);
}
main().catch((e) => { if (e instanceof ExitError) process.exit(e.code); console.error(e); process.exit(1); });
