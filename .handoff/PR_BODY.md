Closes #96

This PR preserves the partially completed v0.3.0 final-polish work after the previous AI session hit the org monthly usage limit during PR creation.
It includes follow-up work tied to lower-priority audit items tracked under #96 and may need PR-body refinement before merge if the iPhone-backup retry work is split into its own follow-up.

## What changed
- fix(daemon): bound persisted detector state growth
- WIP/feat(gui): iPhone backup retry from recovery detail
- Added handoff artifacts under `.handoff/` to preserve local state, diffs, and test evidence
- Preserved the new retry runner and its focused tests exactly as they existed locally

## Verification
- [ ] CI green
- [ ] Acceptance criteria from #26 all checked
- [ ] Tested locally on macOS Sequoia (Darwin 24.x)
- [ ] Added/updated tests

Known prior good state:
- main was green before this branch work:
- bats 49/49
- pytest 4/4
- daemon Swift 79 tests
- GUI Swift 108 tests
- shellcheck clean
- ruff was not installed locally; CI handles it

Important:
- Review whether the iPhone-backup retry runner is complete.
- Review `RecoveryDetailView.swift` changes that were expected from the prior session but are not present in the current worktree.
- Review the new fake `recover.sh` test.
- Finish or split the iPhone-backup retry work if needed.
- Do not enable restore/writeback/security-sensitive behavior by default.

## Out of scope
- Completing the iPhone-backup retry feature end-to-end
- Any restore/writeback behavior
- Any cleanup or rebasing of unrelated local branches
