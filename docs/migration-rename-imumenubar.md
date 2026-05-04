# Migration — `IMUMenuBar.app` → `iMessage Unsent.app`

Closes [#93](https://github.com/tyhallcsu/imessage-unsent/issues/93).

The GUI bundle was renamed from the codename `IMUMenuBar.app` to the user-facing name `iMessage Unsent.app`. This page explains the user-side and operator-side migration steps.

## What changed

| Surface | Before | After |
|---|---|---|
| `.app` bundle name | `IMUMenuBar.app` | `iMessage Unsent.app` (with space, Apple convention) |
| Display name in menus / About / Dock | `IMUMenuBar` | `iMessage Unsent` |
| `CFBundleName` / `CFBundleDisplayName` | `IMUMenuBar` | `iMessage Unsent` |
| `CFBundleIdentifier` | `com.imessage-unsent.MenuBar` | `com.imessage-unsent.app` |
| Release zip filename | `IMUMenuBar-vX.Y.Z.zip` | `iMessage-Unsent-vX.Y.Z.zip` (dash, URL-safe) |
| Executable inside the bundle | `IMUMenuBar` | **unchanged** — still `IMUMenuBar` (keeps shell paths space-free) |
| Daemon (`imu-watcher`, `com.imu.watcher`) | unchanged | unchanged |

## What this means for an existing user

Because **`CFBundleIdentifier` changed**, macOS treats the new app as a brand-new identity for TCC, Notification Center, Login Items, etc. Anything you previously authorized for the old `com.imessage-unsent.MenuBar` does not carry over.

**You will need to re-grant:**

1. **Notifications.** Settings → Notifications shows the GUI banner permission. The new bundle id won't have a record. Open the app → Settings → Notifications → click **Enable notifications** (or use the new flow added in [#90](https://github.com/tyhallcsu/imessage-unsent/issues/90) which also handles the suppressed-prompt case).
2. **Contacts.** First time you open the History window, macOS asks for Contacts permission again because the bundle id is new. Allow it so display names and avatars resolve.
3. **Full Disk Access** (only if you ever granted FDA to the *GUI* — most users only granted it to the *daemon binary*, which is unaffected by this rename).

The daemon (`imu-watcher`, bundle id `com.imu.watcher`) **does not move**. Its FDA grant, LaunchAgent registration, and `state.json` carry through unchanged.

## What stays on disk after upgrade

- `/Applications/IMUMenuBar.app` (the **old** bundle) is left in place. Drag it to the Trash whenever you're satisfied with the new one.
- `~/Library/Application Support/imessage-unsent/archives/` (recovery archives) — unchanged. The daemon owns this path.
- `~/Library/Application Support/imessage-unsent/bin/imu-watcher` — daemon binary, unchanged.
- `~/.config/imessage-unsent/config.toml` and `state.json` — unchanged.
- `~/Library/LaunchAgents/com.imu.watcher.plist` — unchanged.

## What stays on disk that's now stale

- The **old** TCC/Notifications records keyed to `com.imessage-unsent.MenuBar`. macOS keeps these around indefinitely; they're harmless, but they show up as a stale entry in System Settings → Notifications next to the new one. You can right-click → remove the old entry once you've authorized the new one.
- Any apps that registered as `imu://` URL handlers will see two registrations (old bundle id + new) until you delete the old `.app`. Use the [Default Apps for files and links](https://support.apple.com/guide/mac-help/change-the-app-that-opens-a-file-mh35597/mac) pane if you need to disambiguate.

## Operator (maintainer) checklist

When pushing the next release:

1. Tag (e.g. `v0.3.0` or `v0.3.0-rc1`) and push as usual. The release workflow already produces `iMessage-Unsent-vX.Y.Z.zip` instead of `IMUMenuBar-vX.Y.Z.zip` automatically.
2. **Release notes must include this migration page** (or a paraphrased version) under a "Breaking" or "Migration" heading. Users need a heads-up about the re-grant.
3. Bump `CFBundleShortVersionString` to v0.3.0 (or higher) — the rename is a meaningful enough change that a minor-version bump is appropriate. The release workflow injects this from the tag automatically.

## Why the dash in the zip name but a space in the .app name

- **Bundle name has a space** — Apple convention (e.g. "App Store.app", "System Settings.app", "Microsoft Word.app"). Users see this in Launchpad / Dock and expect natural spacing.
- **Zip filename uses a dash** — URLs shouldn't carry encoded spaces (`%20`), and shell completion in `unzip` is annoying with quoted spaces. Dash matches the daemon tarball convention (`imu-watcher-v0.3.0-arm64.tar.gz`) and the source tarball (`imessage-unsent-v0.3.0-source.tar.gz`).

## Why the executable name didn't change

The Swift target is still `IMUMenuBar` because:

1. **Shell scripts** in `script/build_and_run.sh`, `scripts/install-daemon.sh`, `scripts/sign-release.sh` would otherwise need extensive quoting — `pkill -x "iMessage Unsent"` is awkward and error-prone.
2. **Process listing** (`ps`, `pgrep`, `Activity Monitor`) shows the executable name. `IMUMenuBar` is a clear short identifier for ops; `iMessage Unsent` would wrap.
3. **`gui/Package.swift`** wouldn't gain anything from renaming the target — the user-visible surface is the bundle name and `CFBundleDisplayName`, both of which are now `iMessage Unsent`.

If we ever want a fully spaceless display name (e.g. "iMessageUnsent"), it can be a tiny follow-up — but the current split is the standard Apple pattern.
