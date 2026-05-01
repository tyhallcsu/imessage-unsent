# Security & Scope

## Intended use

This repository documents and implements a **defensive / personal forensics** technique for recovering iMessage content that was retracted ("unsent") on a Mac you own. Intended uses:

- Recovering a message you received that the sender unsent before you could read it.
- Forensic understanding of how Apple implements message retraction.
- Personal data archaeology against your own iCloud-synced devices.

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

The Swift daemon and menu bar app keep the same boundary. The daemon owns all reads of the Messages database family and writes only to per-event archives under `~/Library/Application Support/imessage-unsent/archives/`. The GUI talks to the daemon socket and does not read `chat.db` directly. Restore/write-back behavior remains out of scope for the shipped default mode.
