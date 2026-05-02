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

## Reporting a vulnerability

If you find a defect in the recovery scripts (e.g., a command-injection bug in the bash wrapper, a path-traversal bug in the Python decoder, a way the script could damage `chat.db` despite operating only on snapshot copies), please open a GitHub issue or email the maintainer. Do not include real `chat.db` contents in the report.

## Data hygiene

The repository's `.gitignore` excludes:

- `chat.db`, `chat.db-wal`, `chat.db-shm` — the live SQLite database family.
- `recovered.txt`, `report.txt`, `msi.bin`, `msi.xml`, `ab.bin` — recovery output that may contain message content, GUIDs, phone numbers, or contact identifiers.
- `imessage-recovery/` — the conventional working directory used by the script.

If you fork this repo and run the script, **never push the `imessage-recovery/` working tree**. Verify with `git status` before committing.
