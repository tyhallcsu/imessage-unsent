RUFF := $(shell if command -v ruff >/dev/null 2>&1; then echo ruff; elif command -v uvx >/dev/null 2>&1 && uvx --offline ruff --version >/dev/null 2>&1; then echo "uvx --offline ruff"; elif command -v uvx >/dev/null 2>&1; then echo "uvx ruff"; else echo ruff; fi)
PYTEST := $(shell if python3 -m pytest --version >/dev/null 2>&1; then echo "python3 -m pytest"; elif command -v uvx >/dev/null 2>&1 && uvx --offline pytest --version >/dev/null 2>&1; then echo "uvx --offline pytest"; elif command -v uvx >/dev/null 2>&1; then echo "uvx pytest"; else echo "python3 -m pytest"; fi)
BATS := $(shell command -v bats 2>/dev/null)
PYTHON_SOURCES := scripts/decode.py scripts/lib/wal_extract.py scripts/lib/json_report.py scripts/lib/batch_report.py scripts/lib/iphone_backup.py tests/python/conftest.py tests/python/test_decode.py
SHELL_SOURCES := scripts/*.sh scripts/lib/*.sh tests/fixtures/*.sh tests/bats/helpers.bash

.PHONY: fixture fixture-check shellcheck python-check bats python-test test \
	daemon-build daemon-test daemon-install daemon-uninstall \
	gui-build gui-test gui-run swift-test

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

swift-test: daemon-test gui-test
