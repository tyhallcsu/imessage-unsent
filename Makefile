RUFF := $(shell if command -v ruff >/dev/null 2>&1; then echo ruff; elif command -v uvx >/dev/null 2>&1 && uvx --offline ruff --version >/dev/null 2>&1; then echo "uvx --offline ruff"; elif command -v uvx >/dev/null 2>&1; then echo "uvx ruff"; else echo ruff; fi)
PYTEST := $(shell if python3 -m pytest --version >/dev/null 2>&1; then echo "python3 -m pytest"; elif command -v uvx >/dev/null 2>&1 && uvx --offline pytest --version >/dev/null 2>&1; then echo "uvx --offline pytest"; elif command -v uvx >/dev/null 2>&1; then echo "uvx pytest"; else echo "python3 -m pytest"; fi)
BATS := $(shell command -v bats 2>/dev/null)
# Glob so newly-added modules are linted/compiled by default. Previously a
# hardcoded list silently skipped shipped code (e.g. scripts/lib/wal_merge_candidates.py
# and tests/python/test_json_report.py were never ruff/py_compile checked). See #116.
# The glob already covers this PR's scripts/edit-history.py + tests/python/test_edit_history.py.
PYTHON_SOURCES := $(wildcard scripts/*.py scripts/lib/*.py tests/python/*.py)
SHELL_SOURCES := scripts/*.sh scripts/lib/*.sh script/*.sh tests/fixtures/*.sh tests/bats/helpers.bash

.PHONY: fixture fixture-check shellcheck python-check bats python-test test \
	daemon-build daemon-test daemon-install daemon-uninstall \
	gui-build gui-test gui-run swift-test \
	doctor rc-smoke icon \
	release release-notes

fixture:
	./tests/fixtures/build-fixture.sh

fixture-check: fixture
	./tests/fixtures/check-fixture.sh

shellcheck:
	shellcheck --severity=warning $(SHELL_SOURCES)

python-check:
	$(RUFF) check $(PYTHON_SOURCES)
	python3 -m py_compile $(PYTHON_SOURCES)

bats:
ifdef BATS
	$(BATS) tests/bats
else
	@echo "bats not found; skipping tests/bats (install bats-core to run locally)"
endif

python-test:
	$(PYTEST) tests/python

test: shellcheck python-check fixture-check bats python-test

daemon-build:
	swift build --package-path daemon -c release

daemon-test:
	swift test --package-path daemon

daemon-install: daemon-build
	bash scripts/install-daemon.sh

daemon-uninstall:
	bash scripts/uninstall-daemon.sh

gui-build:
	swift build --package-path gui -c release

gui-test:
	swift test --package-path gui

gui-run:
	bash script/build_and_run.sh run

# Regenerate gui/.build/icon/AppIcon.icns from assets/MacOS_AppIcon_iMessage_Unsent.png.
# Useful when iterating on the icon; build-release.sh and build_and_run.sh
# also invoke this script automatically, so this target is rarely needed
# directly.
icon:
	bash scripts/build-app-icon.sh

swift-test: daemon-test gui-test

# Headless subset of the GUI's App Doctor — useful when the menu bar app can't
# launch (FDA prompt loop, Gatekeeper) or for SSH troubleshooting. Output
# matches the GUI's Diagnostics report so users can paste either source into a
# GitHub issue.
doctor:
	bash scripts/app_doctor.sh

# Local "release-candidate smoke" — runs shellcheck + both swift test suites,
# builds the daemon tarball + GUI .app zip via build-release.sh, generates
# release notes, runs app_doctor, and validates artifact integrity. Defaults
# to a temp output dir wiped on success; pass VERSION=v0.4.0-rc1 to test a
# real RC string and OUTPUT_DIR=dist (or set IMU_RC_KEEP_DIST=1) to keep
# artifacts.
#   make rc-smoke
#   make rc-smoke VERSION=v0.4.0-rc1
#   make rc-smoke VERSION=v0.4.0-rc1 OUTPUT_DIR=dist
rc-smoke:
	# Env-passed, not positional: `make rc-smoke OUTPUT_DIR=dist` without
	# VERSION= used to feed the dir as the version string and exit 2.
	VERSION="$(VERSION)" OUTPUT_DIR="$(OUTPUT_DIR)" bash scripts/rc_smoke.sh

# Build distributable release artifacts (daemon tarball + GUI .app zip + sha256s).
# Usage: make release VERSION=v0.4.0
# Output goes under ./dist/.
release:
ifndef VERSION
	$(error VERSION is required, e.g. make release VERSION=v0.4.0)
endif
	bash scripts/build-release.sh $(VERSION) dist

# Generate Markdown release notes from conventional commits since the previous
# tag, to stdout. Usage: make release-notes VERSION=v0.4.0
release-notes:
ifndef VERSION
	$(error VERSION is required, e.g. make release-notes VERSION=v0.4.0)
endif
	@bash scripts/release-notes.sh $(VERSION)
