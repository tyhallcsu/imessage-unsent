# Security & Scope

## Intended use

This repository documents and implements a **defensive / personal forensics** technique for recovering iMessage content that was retracted ("unsent") on a Mac you own. Intended uses:

- Recovering a message you received that the sender unsent before you could read it.
- Forensic understanding of how Apple implements message retraction.
- Personal data archaeology against your own iCloud-synced devices.

## Operating mode — Notify-only

The shipped tooling (CLI + daemon) operates in **Notify-only / Recover** mode and **never modifies the live `chat.db`**. Retractions are observed read-only, the recovered text is archived under your data directory, and macOS notifications / webhooks surface the result. Apple's Messages UI continues to truthfully say "X unsent a message."

A future experimental "Restore" mode that *would* write the recovered text back into `chat.db` is tracked by [issue #16](https://github.com/tyhallcsu/imessage-unsent/issues/16) and gated behind both `experimental.restore_mode = true` and a per-invocation consent flow. Until #16 ships and is reviewed, no code path writes to live `chat.db`. The invariant is enforced by:

- bats test [`60-guardrail-no-chatdb-writes.bats`](tests/bats/60-guardrail-no-chatdb-writes.bats) — sha256 the live fixture before and after a full recovery run, assert equality.
- Swift test `RestoreModeGuardTests` — assert the daemon's `RestoreModeGuard.requireRestoreMode` throws under default config.

See the [Modes section in the README](README.md#modes--recover-vs-restore) for the full Recover-vs-Restore comparison.

## Out-of-scope / not-supported uses

Do **not** use this tooling to:

- Access another person's `chat.db` without their knowledge or consent.
- Recover messages on a device you do not own or are not authorized to access.
- Defeat device encryption, FileVault, or Apple ID security controls.
- Bypass macOS Full Disk Access prompts via privilege escalation.

The author does not condone, and will not provide support for, any use that violates the [Computer Fraud and Abuse Act](https://www.law.cornell.edu/uscode/text/18/1030), [ECPA](https://www.law.cornell.edu/uscode/text/18/2511), state privacy laws, or equivalent statutes in your jurisdiction.

## Legal & ethics

The operator-facing legal and ethics framework — intended scope, off-limits uses, the technical distinction between passive read / mutation / interception, statute-by-statute notes (CFAA, ECPA / Wiretap Act, California § 502 and § 632, Apple's iCloud ToS, GDPR / UK DPA 2018), and the language the GUI's first-run consent dialog must surface — lives in [`docs/legal-and-ethics.md`](docs/legal-and-ethics.md). That document is **not legal advice**; it exists to give operators a starting framework and to point you at the right reading material before you act in non-routine situations.

## Reporting a vulnerability

If you find a defect in the recovery scripts (e.g., a command-injection bug in the bash wrapper, a path-traversal bug in the Python decoder, a way the script could damage `chat.db` despite operating only on snapshot copies), please open a GitHub issue or email the maintainer. Do not include real `chat.db` contents in the report.

## Daemon control socket

The watcher daemon serves a Unix-domain socket at `~/Library/Application Support/imessage-unsent/daemon.sock` for the menu-bar GUI to read status and the recent-recoveries list. Threat model:

- The socket is created with mode `0600` and lives inside `~/Library/Application Support/imessage-unsent/` (also `0700`). Only your user can connect; another local user account on the same Mac cannot.
- The protocol is a hard allowlist (`ping`, `status`, `recent`). Anything else returns `{"ok":false,"error":{"code":"read_only",...}}`. There is no command surface that mutates `chat.db`, the daemon config, or anything on disk.
- The `recent` response carries the **recovered plaintext** of unsent messages — the same data already on disk under `~/Library/Application Support/imessage-unsent/archives/<dir>/recovery.json`. Any process running as your user could read that archive directly; the socket does not widen the blast radius. If you do not want plaintext available to other processes running as your user, do not run the daemon.
- No authentication token is required. Same-user trust on the local machine is the only boundary. If we ever cross user boundaries (e.g., a system-wide LaunchDaemon) this needs to change.

## Data hygiene

The repository's `.gitignore` excludes:

- `chat.db`, `chat.db-wal`, `chat.db-shm` — the live SQLite database family.
- `recovered.txt`, `report.txt`, `msi.bin`, `msi.xml`, `ab.bin` — recovery output that may contain message content, GUIDs, phone numbers, or contact identifiers.
- `imessage-recovery/` — the conventional working directory used by the script.

If you fork this repo and run the script, **never push the `imessage-recovery/` working tree**. Verify with `git status` before committing.
