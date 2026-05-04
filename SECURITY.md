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

## Daemon control socket

The watcher daemon serves a Unix-domain socket at `~/Library/Application Support/imessage-unsent/daemon.sock` for the menu-bar GUI to read status and the recent-recoveries list. Threat model:

- The socket is created with mode `0600` and lives inside `~/Library/Application Support/imessage-unsent/` (also `0700`). Only your user can connect; another local user account on the same Mac cannot.
- The protocol is a hard allowlist (`ping`, `status`, `recent`). Anything else returns `{"ok":false,"error":{"code":"read_only",...}}`. There is no command surface that mutates `chat.db`, the daemon config, or anything on disk.
- The `recent` response carries the **recovered plaintext** of unsent messages — the same data already on disk under `~/Library/Application Support/imessage-unsent/archives/<dir>/recovery.json`. Any process running as your user could read that archive directly; the socket does not widen the blast radius. If you do not want plaintext available to other processes running as your user, do not run the daemon.
- No authentication token is required. Same-user trust on the local machine is the only boundary. If we ever cross user boundaries (e.g., a system-wide LaunchDaemon) this needs to change.

## Webhook delivery security

When `[notifications].webhook` and `[notifications].webhook_signing_secret` are both set in `~/.config/imessage-unsent/config.toml`, each successful recovery causes the daemon to POST a JSON body to the configured URL. The implementation lives in [`daemon/Sources/IMUCore/RecoveryNotifier.swift`](daemon/Sources/IMUCore/RecoveryNotifier.swift) (`WebhookDelivery`).

**Signing**

- **Header**: `X-Imu-Signature`
- **Algorithm**: HMAC-SHA256 (Apple `CryptoKit`)
- **Key**: UTF-8 bytes of `notifications.webhook_signing_secret`
- **Bytes signed**: the exact `Content-Type: application/json` POST body, byte-for-byte
- **Encoding**: lowercase hex (no `sha256=` prefix, no base64)
- **When omitted**: if the signing secret is empty, the header is not sent. Verify on the receiving side that the header is present *and* valid; reject the delivery otherwise.
- **No replay protection.** There is no timestamp header and no nonce. If you need replay resistance, terminate the webhook on a private network or front it with a service that adds those guarantees.

**Retries**

A non-2xx response or transport error triggers up to 3 retries with exponential backoff (0.5s, 1.0s, 2.0s). Each retry sends the same body with the same signature. Idempotency on the receiving side is your responsibility.

**Verification — pseudocode (Python)**

```python
import hmac, hashlib

def verify(body: bytes, header_value: str, secret: str) -> bool:
    expected = hmac.new(
        secret.encode("utf-8"),
        body,
        hashlib.sha256,
    ).hexdigest()
    # Constant-time comparison — never use ==.
    return hmac.compare_digest(expected, header_value or "")
```

**Operational guidance**

- Generate the signing secret with at least 256 bits of entropy (e.g. `openssl rand -hex 32`). Treat it like a password — don't commit it, don't log it.
- Rotate by setting a new value in `config.toml` and restarting the daemon (e.g. via the GUI's Settings → Daemon → "Restart imu-watcher" button, or `make daemon-install`). There is no overlap window — the daemon signs every delivery with the currently configured secret.
- The webhook body contains the recovered message text (base64-encoded under `recovered.text_b64`). Anyone who can read the receiving endpoint's logs can read the recovered text. Lock that down accordingly.

## Data hygiene

The repository's `.gitignore` excludes:

- `chat.db`, `chat.db-wal`, `chat.db-shm` — the live SQLite database family.
- `recovered.txt`, `report.txt`, `msi.bin`, `msi.xml`, `ab.bin` — recovery output that may contain message content, GUIDs, phone numbers, or contact identifiers.
- `imessage-recovery/` — the conventional working directory used by the script.

If you fork this repo and run the script, **never push the `imessage-recovery/` working tree**. Verify with `git status` before committing.
