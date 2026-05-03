# Release process

This document describes how to cut a release of `imessage-unsent`. The
process is mostly automated by the [`Release` workflow](../.github/workflows/release.yml)
that triggers on `v*.*.*` tag pushes.

## End-state target

A `git tag vX.Y.Z && git push origin vX.Y.Z` produces a draft GitHub Release
containing:

- `imu-watcher-vX.Y.Z-arm64.tar.gz` — daemon binary + recovery scripts +
  LaunchAgent template
- `IMUMenuBar-vX.Y.Z.zip` — menu bar app bundle
- `imessage-unsent-vX.Y.Z-source.tar.gz` — source archive (preserved for
  packagers and forks)
- A `.sha256` companion next to each artifact
- Auto-generated release notes from conventional commits since the previous tag

The release is created as a **draft** so a maintainer can review the
artifacts, polish the notes, and then publish.

## Prerequisites

| Requirement | Why |
|---|---|
| macOS runner | The GUI .app bundle and the daemon both build via `swift build`. The Release workflow pins `runs-on: macos-latest`. |
| Conventional-commits style | `feat:` / `fix:` / `docs:` prefixes on commits ensure the notes generator categorizes them correctly. |
| Pushed tag matching `vMAJOR.MINOR.PATCH` (or `vMAJOR.MINOR.PATCH-rc1` for pre-releases) | Triggers the workflow and is validated by the workflow itself. |

## Cutting a release

```bash
# 1. Make sure main is in the state you want to ship.
git checkout main && git pull --ff-only

# 2. Tag and push. The workflow does the rest.
git tag v0.4.0
git push origin v0.4.0

# 3. Wait for the Release workflow to finish, then publish the draft from
#    https://github.com/tyhallcsu/imessage-unsent/releases
```

For a pre-release, append `-rcN` (or any other identifier matching
`-[A-Za-z0-9.]+`):

```bash
git tag v0.4.0-rc1
git push origin v0.4.0-rc1
```

Pre-release tags are flagged as `--prerelease` on the GitHub Release.

## Building artifacts locally

The CI workflow uses `scripts/build-release.sh`; you can run the same script
on your own Mac to produce identical artifacts:

```bash
make release VERSION=v0.4.0
# or directly:
bash scripts/build-release.sh v0.4.0 dist
```

To preview the generated release notes without creating a release:

```bash
make release-notes VERSION=v0.4.0
```

## Signing and notarization

The release pipeline signs the daemon binary and the GUI `.app` with
Developer ID + Hardened Runtime, then submits the GUI to `xcrun notarytool`
and staples the ticket — but **only when the operator has provisioned the
Apple secrets** (see below). If any required secret is absent the sign step
logs `Skipping codesign + notarize` and the workflow proceeds with unsigned
artifacts, so forks and dry-run builds are never blocked.

The signing pipeline itself is implemented in
[`scripts/sign-release.sh`](../scripts/sign-release.sh) and documented in
detail in [`docs/code-signing.md`](code-signing.md), which is the source of
truth for:

- The six `APPLE_*` secrets to set in repo Actions secrets.
- How to provision the Developer ID Application certificate and an
  app-specific password for `notarytool`.
- How to verify a signed build (`codesign --verify`, `spctl --assess`,
  `xcrun stapler validate`).
- Troubleshooting the common failure modes.

The artifact section of the auto-generated release notes is labelled
honestly: `(UNSIGNED)`, `(SIGNED)`, or `(SIGNED & NOTARIZED)` based on a
`SIGNING_STATUS` file that `sign-release.sh` writes into the dist directory.

## What the workflow does, in order

1. **Verify the tag** matches `vMAJOR.MINOR.PATCH(-prerelease)?`. Reject otherwise.
2. **Restore caches** for `daemon/.build` and `gui/.build`.
3. **Run tests** for both Swift packages — a red test gates the release.
4. **`scripts/build-release.sh`** builds release-mode binaries, assembles the
   GUI .app bundle (with `CFBundleShortVersionString` and `CFBundleVersion`
   set from the tag), invokes `scripts/sign-release.sh` to codesign +
   (optionally) notarize and staple, then produces tarball + zip + sha256s.
   The sign step writes `dist/SIGNING_STATUS` (`unsigned` / `signed` /
   `signed-and-notarized`) for downstream consumers.
5. **`scripts/release-notes.sh`** generates Markdown notes from conventional
   commits since the previous tag, reading `dist/SIGNING_STATUS` to label
   artifacts honestly.
6. **Build a source tarball** (preserved from the v0.1 release process for
   downstream packagers).
7. **`gh release create --draft`** uploads everything and creates a draft
   release for review.

## Troubleshooting

- **Tag rejected as not semver** — the tag must start with `v` and use three
  numeric components (`v0.4.0`), with an optional `-prerelease` suffix
  (`v0.4.0-rc1`). Double-check for typos like `0.4.0` or `v0.4`.
- **Tests fail in the workflow but pass locally** — the workflow uses cached
  `.build` directories. Bump cache keys or delete the cache from the Actions
  UI to force a clean build.
- **Release exists already** — the workflow uses `gh release create`, which
  fails if the tag already has a release. Delete the existing release (and
  the underlying tag if needed) before re-running. Don't re-tag the same
  commit silently.
