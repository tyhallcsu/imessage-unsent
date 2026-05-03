# Legal and ethics statement

> [!IMPORTANT]
> **This document is not legal advice.** It explains the *intended* use of `imessage-unsent` and surveys the laws operators most often ask about, so you have a starting framework. Whether running this tool in your specific situation is lawful depends on your jurisdiction, the device you run it on, the relationship between you and the message sender, and facts this document cannot anticipate. **If in doubt, consult a lawyer in your jurisdiction.**

## TL;DR

| | |
|---|---|
| **Designed for** | Recovering messages **you received** on a Mac **you own**, where the sender retracted ("unsent") the message before you could read it. |
| **Default mode** | **Notify-only**: the live `chat.db` is opened read-only and never modified; recovered text is archived under your user data directory; macOS notifications surface results. |
| **Off-limits**  | Any device you do not own; any message you were not the intended recipient of; mutation of `chat.db` (gated behind `experimental.restore_mode = true` and a consent flow tracked in [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16)); intercepting messages in transit (this tool **cannot** do that — APNs payloads are end-to-end encrypted). |

The remainder of this document expands these into operational guidance, surveys the relevant US federal and state statutes plus GDPR/UK DPA scope notes, and proposes the language that the GUI's first-run consent dialog should display.

## 1. Scope of intended use

This tooling is designed for one operator profile:

- You own the Mac on which `chat.db` lives.
- You are signed in to Messages on that Mac with your own Apple ID.
- The messages you intend to recover are messages you **received** in conversations you are a participant in.
- You have no expectation of redistributing the recovered text to anyone else, and no expectation that recovery somehow voids the sender's wish to retract — Apple's UI continues to truthfully say *"X unsent a message"*; only your private archive holds the recovered text.

If all four of those are true, recovering a retracted message that landed on your own device is functionally similar to consulting your own memory of a phone call, your own notes, or a screenshot you happened to take before retraction landed. The technical mechanism is more sophisticated, but the data is the same data the sender voluntarily delivered to your device.

## 2. Out-of-scope / not-supported uses

This tool **must not** be used for:

- **Devices you do not own or are not authorized to access.** Running this on a partner's, child's, employee's, or family member's Mac without their knowledge is the kind of access that statutes like the CFAA and ECPA were written to prosecute.
- **Conversations you are not a participant in.** If the `chat.db` belongs to someone else and you are not a recipient on the messages you're recovering, you are reading other people's mail.
- **Defeating device or account security.** No path in this codebase tries to bypass FileVault, escalate privilege, or work around macOS's Full Disk Access prompt — and none ever will. If you are tempted to add such a path, do not.
- **Building a surveillance or stalkerware product.** This tool is published openly so you can audit what it does and does not do. It does not exfiltrate, upload, transmit, or report to any third party, and the maintainers will not accept patches that add such capabilities.
- **Producing court-admissible forensic evidence.** This is a tactical script for personal use, not a forensic suite. There is no chain-of-custody, no input hashing, no signed report. If you need court-admissible artifacts, use a real forensic product and a qualified examiner.

If any of those describe what you are about to do — **stop and consult a lawyer first**. The fact that this tool exists is not a permission slip.

## 3. The technical distinction that matters most

Three different technical actions get conflated in casual conversation. The legal posture of each is materially different.

| Action | What this tool does | Notes |
|---|---|---|
| **Passive read of `chat.db` on your own device** | ✅ Yes (Notify-only / Recover mode, default and only shipped behaviour). Opens with `SQLITE_OPEN_READONLY`, copies WAL frames into an isolated working directory, never writes back. | This is reading data Apple wrote to your own filesystem. The data is yours to read on your machine in the same way any other file in `~/Library` is. |
| **Mutation of `chat.db`** (writing recovered text back into the live row) | 🚧 Gated. Tracked by [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16); requires both `experimental.restore_mode = true` in config **and** a per-invocation consent dialog (yet to ship). | A different posture: you are now causing changes on your own device that may iCloud-sync to other devices including the sender's. See README's [Modes — Recover vs Restore](../README.md#modes--recover-vs-restore) section for why the project ships Notify-only as the default. |
| **Interception of messages in transit** | ❌ **Not possible** with this tool. iMessage payloads delivered over APNs (Apple Push Notification service) are end-to-end encrypted between the sender's and recipient's devices. This tool reads the *result* after delivery, not the channel. | Tools that intercept messages in transit fall under the federal Wiretap Act and many state equivalents. This is the bright line the project will not cross. |

Treat anything in the second column as the entire scope of what the published code does. Anything in the third column is excluded by design.

## 4. US federal statutes commonly raised

The following are the statutes operators most often ask about. None of these summaries is legal advice — they exist to point you at the right reading material.

### 4.1 Computer Fraud and Abuse Act — [18 U.S.C. § 1030](https://www.law.cornell.edu/uscode/text/18/1030)

Prohibits "unauthorized access" or "exceeding authorized access" to a "protected computer" (which courts have read to include nearly any internet-connected device). The element courts return to repeatedly is **authorization**.

- Reading data on a Mac you own, signed in with your own Apple ID, where Apple has delivered messages to your local `chat.db` for you to consume in the Messages app, is the strongest position available under § 1030's authorization element.
- Reading `chat.db` on a Mac you do **not** own — even if the device is unattended, even if you can physically reach the keyboard — is the kind of fact pattern that has been prosecuted as a CFAA violation.

The post-*Van Buren* (2021) consensus narrowed CFAA's "exceeds authorized access" prong, but it did not narrow "unauthorized access" itself. If your access starts unauthorized, CFAA still applies.

### 4.2 Electronic Communications Privacy Act / Wiretap Act — [18 U.S.C. § 2511](https://www.law.cornell.edu/uscode/text/18/2511) and [§ 2701](https://www.law.cornell.edu/uscode/text/18/2701)

Two prongs matter:

- **§ 2511 (Wiretap)** prohibits the **interception of electronic communications in transit**. Because this tool only ever reads `chat.db` *after* a message has been delivered to the recipient device, it is functionally a stored-communications operation, not an interception. Courts have generally analyzed reading a stored message on the recipient's own device, by the recipient, as a stored-communications question rather than an interception.
- **§ 2701 (Stored Communications Act)** prohibits unauthorized access to stored electronic communications held in "electronic storage" by a "remote computing service." Local files on your own laptop are generally not what § 2701 is aimed at, but the analysis becomes more delicate the moment a third party's device or a cloud service is involved.

The "intended recipient" question is load-bearing for both prongs. If you are the intended recipient of a message and you read your own copy of it on your own device, the wiretap risk is low. If you are not the intended recipient — you are reading someone else's `chat.db` — the calculation changes.

### 4.3 State analogues

State laws frequently mirror or expand on the federal statutes, sometimes substantially. A non-exhaustive sample:

- **California**: [Penal Code § 502](https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=PEN&sectionNum=502) (computer access — broader than CFAA in places). [Penal Code § 632](https://leginfo.legislature.ca.gov/faces/codes_displaySection.xhtml?lawCode=PEN&sectionNum=632) (two-party consent for confidential communications). § 632's reach into post-delivery *storage* of communications is fact-specific; the canonical risk surface is at the moment of recording or interception, not at later passive reads of already-stored data on the recipient's own device.
- **Other two-party-consent states** (e.g., Florida, Illinois, Maryland, Massachusetts, Pennsylvania, Washington) have similar communication-privacy frameworks. These typically apply to interception in transit, but the broader privacy-tort posture in these jurisdictions can affect how a recovered-message disclosure is later used.
- Many states have their own computer-misuse statutes that operate alongside § 1030.

If your jurisdiction is in this set and the situation is non-routine — for example, you are considering disclosing recovered text in a dispute, or recovering messages from a shared family computer — that is the moment to talk to a lawyer.

## 5. Apple's iCloud Terms of Service

Running `imessage-unsent` does not require an Apple account separate from the one you already use to receive Messages, and it does not call any Apple-operated cloud API. It reads the local SQLite files Apple's own software writes to your device. That said:

- **iCloud Messages sync** is the relevant Apple feature when considering Restore mode (§ 3 above). Writing to your local `chat.db` while iCloud Messages is enabled may resync the modified row outward; the exact propagation is mode-dependent and not fully documented by Apple, which is itself a reason to treat any future Restore-mode write as a potential change to other people's local data. The published Notify-only mode never writes, so this is forward-looking caution about Restore mode.
- The iCloud Terms of Service govern your relationship with Apple as a service provider. Apple has no general prohibition on reading data on your own device; Apple's terms primarily restrict abuse of Apple-operated services. But Apple's terms are updated periodically and you are responsible for the version in force when you run the tool. The current terms are linked from System Settings → Apple ID → Media & Purchases → Terms and Conditions.

## 6. EU / UK scope notes (GDPR, UK DPA 2018)

If you, the message sender, or the message subject is in the EU or UK at the time of recovery, the General Data Protection Regulation (GDPR) and the UK Data Protection Act 2018 may treat the recovered text as personal data.

- The **household exemption** ([GDPR Art. 2(2)(c)](https://gdpr-info.eu/art-2-gdpr/)) generally excludes processing by a natural person "in the course of a purely personal or household activity." Recovering messages you yourself received and keeping them for your personal records typically falls inside this exemption.
- The exemption does **not** cover redistribution, publication, or use of the recovered text in commercial or quasi-commercial contexts. The moment you forward, post, or publish, GDPR/DPA become relevant and you become a controller of the personal data of the original sender (and any other named parties).
- If you are recovering messages on behalf of an organization, the household exemption does not apply at all and you should be talking to your data-protection officer, not reading this document.

UK DPA 2018 maps closely onto GDPR for these purposes; the mental model is the same.

## 7. Consent-flow language for the GUI

The acceptance criteria in [#22](https://github.com/tyhallcsu/imessage-unsent/issues/22) ask this document to specify the language the GUI's first-run consent dialog must surface. Two dialogs are in scope: the **first-run scope acknowledgement** (always shown), and the **Restore-mode per-invocation consent** (only shown if the user has flipped `experimental.restore_mode = true`, and only after [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16) ships).

### 7.1 First-run scope acknowledgement (always shown)

Required content (the Swift implementer is free to refine wording, but the four bullets below must be present and the user must explicitly check or click to acknowledge):

> ## About `imessage-unsent`
>
> This tool recovers iMessage content that was retracted ("unsent") on a Mac you own. Before you continue:
>
> - **Use this only on your own Mac**, with your own Apple ID, on conversations you participate in. Using it on someone else's device or messages may violate the federal CFAA, ECPA, state privacy laws, or equivalent statutes outside the US.
> - **Recovered text stays on this device**, in your user data directory. The tool does not upload, transmit, or share recovered content with anyone.
> - **Apple's Messages UI will still say *"X unsent a message."*** This tool does not write back to the live message database. Messages will continue to truthfully reflect the sender's retraction in the Apple UI.
> - **This tool is not legal advice.** If your situation is non-routine — disputes, shared devices, employer-managed Macs — consult a lawyer first.
>
> See the project's [Legal and ethics statement](https://github.com/tyhallcsu/imessage-unsent/blob/main/docs/legal-and-ethics.md) and [Security & Scope](https://github.com/tyhallcsu/imessage-unsent/blob/main/SECURITY.md) for the full framing.
>
> ☐ I understand and accept this scope.       \[Continue]   \[Quit]

The dialog must default to ☐ unchecked and to the **Quit** button. The user must take an affirmative action to advance.

### 7.2 Restore-mode per-invocation consent (gated, future)

Restore mode is **not yet shipped**. When [#16](https://github.com/tyhallcsu/imessage-unsent/issues/16) lands, the per-invocation dialog should display before *each* attempted write to `chat.db` (not once-per-session — every time):

> ## Restore mode is about to modify your live `chat.db`
>
> You are about to write **recovered text** back into the live `chat.db` for **conversation X with handle Y**. Before this proceeds:
>
> - **iCloud Messages may sync this change to your other devices and to the sender's device.** That changes someone else's local data without their consent. If you are not certain iCloud Messages is disabled on your account, cancel.
> - **Messages.app must not be running.** A live mutation while the app is running can corrupt its index. Quit Messages first.
> - **Forensic value erodes the moment you write.** A row whose `text` was nulled by Apple and re-populated by this tool is not evidence of either the retraction or the original message; it is a hybrid no admissible report can rely on.
> - **This is irreversible without a backup.** The tool's own snapshot of the pre-mutation `chat.db` lives in your archive directory. If anything goes wrong, restore from that snapshot.
>
> Type the conversation handle exactly to confirm: \[\_\_\_\_\_\_\_\_\_\_]
>
> \[Cancel]   \[Write to `chat.db`]

The dialog must require typing the handle, must default to **Cancel**, and must log the consent event to the daemon's archive directory along with a hash of the pre-mutation row. The implementation MUST call [`RestoreModeGuard.requireRestoreMode`](../daemon/Sources/IMUCore/RestoreModeGuard.swift) and verify the consent record before any UPDATE statement.

## 8. What to do if you are unsure

The honest answer to "is it legal for me to recover this message?" is "it depends on facts that the codebase cannot see." Practical defaults:

1. **If you own the device and you were the recipient**, you are squarely within the intended use. Run the tool.
2. **If anything else is true** — shared device, work device, conversation you weren't part of, dispute or litigation in progress, EU/UK individuals involved, planning to disclose the recovered text to anyone — pause and consult a lawyer in your jurisdiction *before* running the tool. Recovered text is not unrecoverable. A 30-minute consult is cheaper than the alternative.
3. **If you are recovering a message on someone else's behalf**, get their written authorization first, narrow the scope to the specific conversation, and document what you did. Do not use this tool as part of an undisclosed investigation.

## See also

- [SECURITY.md](../SECURITY.md) — operating-mode invariants, daemon control-socket threat model, data hygiene.
- [README.md](../README.md) — project scope, Modes (Recover vs Restore) comparison, limitations.
- [`RestoreModeGuard.swift`](../daemon/Sources/IMUCore/RestoreModeGuard.swift) — the codified Restore-mode gate.
- [`60-guardrail-no-chatdb-writes.bats`](../tests/bats/60-guardrail-no-chatdb-writes.bats) — the CI-checked invariant that Notify-only never mutates `chat.db`.
