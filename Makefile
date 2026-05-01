RUFF := $(shell if command -v ruff >/dev/null 2>&1; then echo ruff; elif command -v uvx >/dev/null 2>&1; then echo "uvx ruff"; else echo ruff; fi)

.PHONY: fixture fixture-check shellcheck python-check

fixture:
	./tests/fixtures/build-fixture.sh

fixture-check: fixture
	./tests/fixtures/check-fixture.sh

shellcheck:
	shellcheck --severity=warning scripts/recover.sh scripts/lib/*.sh tests/fixtures/*.sh

python-check:
	$(RUFF) check scripts/decode.py scripts/lib/wal_extract.py scripts/lib/json_report.py
	python3 -m py_compile scripts/decode.py scripts/lib/wal_extract.py scripts/lib/json_report.py
