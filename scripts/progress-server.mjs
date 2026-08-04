#!/usr/bin/env node
// Zero-dependency static server for the live completion-loop progress dashboard.
// Serves artifacts/progress/ (index.html + progress.json + events.jsonl + seed)
// with no-store caching so the auto-refreshing viewer always sees the latest state.
//
//   node scripts/progress-server.mjs [--port 8765] [--root <dir>] [--host 127.0.0.1] [--strict]
//
// Design goals (see references/dashboard-spec.md):
//   - Dependency-light: only node:http / node:fs / node:path. No framework.
//   - Port-safe: prefer --port (default 8765); if taken, auto-advance to the next
//     free port unless --strict is set. The caller/skill is responsible for
//     deciding whether an already-listening server is its own stale instance
//     (see .server.json) before killing anything.
//   - Loopback-only by default: never binds a public interface unless --host says so.
//   - Self-identifying: writes .server.json {pid,port,url,root,startedAt} into the
//     served root so a later run can recognise this project's own server.
//
// The durable record is docs/PROGRESS.md + the committed handoff tracker; this
// only renders the live view.
import http from 'node:http';
import { readFile, stat, writeFile, realpath } from 'node:fs/promises';
import { existsSync, realpathSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join, normalize, resolve, sep } from 'node:path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
const opt = (name, def = null) => { const i = argv.indexOf(name); return i > -1 ? argv[i + 1] : def; };
const has = (name) => argv.includes(name);

// ── Resolve the served root ──────────────────────────────────────────────────
// Priority: explicit --root, then <script>/../artifacts/progress (the "copied into
// a repo's scripts/" case), then <cwd>/artifacts/progress (running standalone).
function resolveRoot() {
  const explicit = opt('--root');
  if (explicit) return resolve(explicit);
  const sibling = join(__dirname, '..', 'artifacts', 'progress');
  if (existsSync(sibling)) return sibling;
  return resolve(process.cwd(), 'artifacts', 'progress');
}
const ROOT = resolveRoot();

const PREFERRED = Number(opt('--port', 8765)) || 8765;
const HOST = opt('--host', '127.0.0.1');
const STRICT = has('--strict');
const MAX_TRIES = 24; // scan PREFERRED..PREFERRED+23 before giving up

if (!existsSync(ROOT)) {
  console.error(`[progress] served root does not exist: ${ROOT}`);
  console.error(`[progress] pass --root <dir> or run 'init' first to create artifacts/progress/.`);
  process.exit(1);
}
// realpath the root once so the request handler can enforce true (symlink-aware)
// containment, not just a lexical prefix check.
const REAL_ROOT = realpathSync(ROOT);
if (HOST !== '127.0.0.1' && HOST !== 'localhost') {
  console.error(`[progress] WARNING: binding ${HOST} exposes the dashboard beyond localhost.`);
}

const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.jsonl': 'text/plain; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
};

const server = http.createServer(async (req, res) => {
  try {
    let path = decodeURIComponent((req.url || '/').split('?')[0]);
    if (path === '/' || path === '') path = '/index.html';
    // Refuse any dot-segment: blocks '..' traversal AND dotfiles like .server.json
    // (which carries the absolute repo path/pid — never expose it over HTTP).
    if (path.split('/').some((seg) => seg.startsWith('.'))) { res.writeHead(404).end('not found'); return; }
    // Lexical containment to ROOT…
    const full = normalize(join(ROOT, path));
    if (full !== ROOT && !full.startsWith(ROOT + (ROOT.endsWith(sep) ? '' : sep))) {
      res.writeHead(403).end('forbidden'); return;
    }
    const s = await stat(full).catch(() => null);
    if (!s || !s.isFile()) { res.writeHead(404).end('not found'); return; }
    // …then symlink-aware containment: a symlink inside ROOT must not escape it.
    const realFull = await realpath(full);
    if (realFull !== REAL_ROOT && !realFull.startsWith(REAL_ROOT + sep)) {
      res.writeHead(403).end('forbidden'); return;
    }
    const ext = full.slice(full.lastIndexOf('.'));
    const body = await readFile(full);
    // No Access-Control-Allow-Origin: the viewer is same-origin; ACAO:* would let
    // any web page the developer visits read this localhost server cross-origin.
    res.writeHead(200, {
      'Content-Type': TYPES[ext] || 'application/octet-stream',
      'Cache-Control': 'no-store, must-revalidate',
    });
    res.end(body);
  } catch {
    res.writeHead(500).end('server error');
  }
});

// ── Port-safe listen: advance to the next free port unless --strict ──────────
// Each attempt pairs its own error/listening handlers and removes the sibling on
// the outcome, so a failed attempt's stale 'listening' callback can never fire
// later with the wrong port when a subsequent bind succeeds.
function listenFrom(port, triesLeft) {
  const onError = (e) => {
    if (e.code !== 'EADDRINUSE') {
      server.removeListener('listening', onListening);
      console.error(`[progress] cannot bind ${HOST}:${port} — ${e.code || e.message}`);
      process.exit(1);
    }
    server.removeListener('listening', onListening); // drop this attempt's pending success
    if (STRICT || triesLeft <= 1) {
      console.error(`[progress] port ${port} is in use.` +
        (STRICT ? ' (--strict: not auto-advancing)' : ' No free port found in range.'));
      console.error(`[progress] Inspect the holder with:  lsof -nP -iTCP:${port} -sTCP:LISTEN`);
      process.exit(1);
    }
    listenFrom(port + 1, triesLeft - 1);
  };
  const onListening = async () => {
    server.removeListener('error', onError);
    const url = `http://${HOST === '0.0.0.0' ? 'localhost' : HOST}:${port}/`;
    try {
      await writeFile(join(ROOT, '.server.json'),
        JSON.stringify({ pid: process.pid, port, url, root: ROOT, startedAt: new Date().toISOString() }, null, 2) + '\n');
    } catch { /* non-fatal: the URL is still printed below */ }
    console.log(`[progress] serving ${ROOT}`);
    if (port !== PREFERRED) console.log(`[progress] preferred port ${PREFERRED} was busy — using ${port}`);
    console.log(`[progress] ${url}`);
  };
  server.once('error', onError);
  server.once('listening', onListening);
  server.listen(port, HOST);
}
listenFrom(PREFERRED, MAX_TRIES);
