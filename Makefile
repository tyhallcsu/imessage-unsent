RUFF := $(shell if command -v ruff >/dev/null 2>&1; then echo ruff; elif command -v uvx >/dev/null 2>&1; then echo "uvx ruff"; else echo ruff; fi)

.PHONY: fixture test shellcheck python-check swift-test

fixture:
	./tests/fixtures/build-fixture.sh

shellcheck:
	shellcheck --severity=warning scripts/recover.sh scripts/lib/*.sh scripts/install-daemon.sh scripts/uninstall-daemon.sh tests/fixtures/build-fixture.sh script/build_and_run.sh

python-check:
	$(RUFF) check scripts/decode.py scripts/lib/wal_extract.py scripts/lib/json_report.py tests/python/test_decode.py
	python3 -m py_compile scripts/decode.py scripts/lib/wal_extract.py scripts/lib/json_report.py

swift-test:
	swift test --package-path daemon
	swift test --package-path gui

test: shellcheck python-check
	@if command -v bats >/dev/null; then bats tests/bats; else echo "bats not installed; skipping bats tests"; fi
	@if command -v pytest >/dev/null; then pytest tests/python; else echo "pytest not installed; skipping pytest tests"; fi
	$(MAKE) swift-test
