# Local checks == CI checks. The Stop hook runs `make -s check-fast`; CI runs `make check`.
# Stack targets auto-detect what exists, so this works before and after the stack ADR (docs/adr/0001-stack.md).
# TODO(stack): once Tauri or Swift is chosen, delete the other branch below and make the checks unconditional.

SHELL := /bin/bash
# No .ONESHELL: macOS ships GNU make 3.81, which lacks it, so multi-line recipes use backslashes.
.PHONY: check-fast check compliance compliance-selftest spike-test stack-fast stack-full

check-fast: compliance stack-fast

check: compliance compliance-selftest spike-test stack-fast stack-full

compliance:
	@scripts/ci/compliance-scan.sh

compliance-selftest:
	@tests/compliance/selftest.sh

# Phase 0 spike suites (offline; none sets SPIKE_LIVE). Not in check-fast: together they take a few minutes.
spike-test:
	@set -eo pipefail; for t in spike/tests/*.sh; do echo "== $$t"; /bin/bash "$$t" 2>/dev/null | tail -1; done

stack-fast:
	@set -e; \
	if [ -f src-tauri/Cargo.toml ]; then \
	  cargo fmt --manifest-path src-tauri/Cargo.toml --all -- --check; \
	  cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings; \
	  cargo test --manifest-path src-tauri/Cargo.toml --lib; \
	fi; \
	if [ -f package.json ] && grep -q '"typecheck"' package.json; then pnpm -s typecheck; fi; \
	if [ -f Package.swift ]; then \
	  swift build; \
	  if swift format --help >/dev/null 2>&1; then swift format lint --recursive --strict Sources Tests; fi; \
	fi; \
	if [ ! -f src-tauri/Cargo.toml ] && [ ! -f Package.swift ]; then \
	  echo "make: no app stack yet (see docs/adr/README.md); compliance only"; \
	fi

stack-full:
	@set -e; \
	if [ -f src-tauri/Cargo.toml ]; then cargo test --manifest-path src-tauri/Cargo.toml; fi; \
	if [ -f package.json ]; then \
	  if grep -q '"lint"' package.json; then pnpm -s lint; fi; \
	  if grep -q '"test"' package.json; then pnpm -s test; fi; \
	fi; \
	if [ -f Package.swift ]; then swift test --parallel; fi
