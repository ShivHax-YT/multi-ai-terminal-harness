# Local checks == CI checks. The Stop hook runs `make -s check-fast`; CI runs `make check`.
# Stack: Tauri 2 (docs/adr/0001-stack.md). Cargo workspace in src-tauri/, UI in src/ (pnpm).

SHELL := /bin/bash
# No .ONESHELL: macOS ships GNU make 3.81, which lacks it, so multi-line recipes use backslashes.

# Homebrew's rustup is keg-only; put it first on PATH when it exists so rust-toolchain.toml is honoured.
RUSTUP_BIN := /opt/homebrew/opt/rustup/bin
ifneq ($(wildcard $(RUSTUP_BIN)),)
export PATH := $(RUSTUP_BIN):$(PATH)
endif

CARGO_MANIFEST := --manifest-path src-tauri/Cargo.toml

.PHONY: check-fast check compliance compliance-selftest crate-boundary spike-test rust-fast rust-full ui-fast ui-full

check-fast: compliance crate-boundary rust-fast ui-fast

check: check-fast compliance-selftest spike-test rust-full ui-full

compliance:
	@scripts/ci/compliance-scan.sh

compliance-selftest:
	@tests/compliance/selftest.sh

# Rule 3: harness-core must have no dependency path (normal, build or dev) to the PTY crate.
crate-boundary:
	@scripts/ci/check-crate-boundary.sh

# Phase 0 spike suites (offline; none sets SPIKE_LIVE). Part of `make check`, not check-fast. Each suite runs under
# /bin/bash with its full output visible; every suite runs, one status line each, non-zero exit if any failed.
spike-test:
	@set -o pipefail; \
	shopt -s nullglob; \
	tests=(spike/tests/*.sh); \
	if [ "$${#tests[@]}" -eq 0 ]; then echo "spike-test: no spike tests"; exit 0; fi; \
	failed=0; \
	for t in "$${tests[@]}"; do \
	  echo "== $$t"; \
	  /bin/bash "$$t"; rc=$$?; \
	  echo "== $$t exit $$rc"; \
	  if [ "$$rc" -ne 0 ]; then failed=$$((failed + 1)); fi; \
	done; \
	if [ "$$failed" -ne 0 ]; then echo "spike-test: $$failed suite(s) failed" >&2; exit 1; fi

rust-fast:
	@set -e; \
	cargo fmt $(CARGO_MANIFEST) --all -- --check; \
	cargo clippy $(CARGO_MANIFEST) --workspace --all-targets -- -D warnings; \
	cargo test $(CARGO_MANIFEST) --workspace --lib

rust-full:
	@cargo test $(CARGO_MANIFEST) --workspace

ui-fast:
	@set -e; \
	pnpm -s typecheck; \
	pnpm -s lint; \
	pnpm -s test; \
	pnpm -s format:check

# The dev mock must never ship: fail if its sentinel reaches the production bundle.
ui-full:
	@set -e; \
	pnpm -s build; \
	if grep -rqF __HARNESS_MOCK__ dist; then \
	  echo "ui-full: the IPC mock (__HARNESS_MOCK__) is in dist/; it must never ship" >&2; exit 1; \
	fi; \
	echo "ui-full: dist/ is free of the IPC mock"
