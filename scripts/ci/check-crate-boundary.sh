#!/usr/bin/env bash
# Hard rule 3 dependency boundary: harness-core (lead, scheduler, adapters) must have no dependency path to the
# pty-view crate (PTY spawn and write), through normal, build or dev edges.
#
#   scripts/ci/check-crate-boundary.sh                  # run `cargo tree` on src-tauri/Cargo.toml
#   scripts/ci/check-crate-boundary.sh --tree-file F    # check a saved `cargo tree --prefix none` output (self-test)
#
# Exit 0 = boundary holds, 1 = violation or the tree could not be produced (fail closed), 2 = usage error.
set -uo pipefail

TREE_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tree-file)
      [ $# -ge 2 ] || { echo "check-crate-boundary: --tree-file needs a path" >&2; exit 2; }
      TREE_FILE="$2"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "check-crate-boundary: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -n "$TREE_FILE" ]; then
  [ -f "$TREE_FILE" ] || { echo "check-crate-boundary: no such file: $TREE_FILE" >&2; exit 2; }
  tree="$(cat -- "$TREE_FILE")"
else
  ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  if [ -d /opt/homebrew/opt/rustup/bin ]; then PATH="/opt/homebrew/opt/rustup/bin:$PATH"; fi
  if ! tree="$(cargo tree --manifest-path "$ROOT/src-tauri/Cargo.toml" -p harness-core \
      -e normal,build,dev --prefix none 2>&1)"; then
    echo "check-crate-boundary: cargo tree failed (fail closed):" >&2
    printf '%s\n' "$tree" | tail -5 >&2
    exit 1
  fi
fi

# Sanity: the tree must be harness-core's, or the check proves nothing.
if ! printf '%s\n' "$tree" | grep -Eq '^harness-core v'; then
  echo "check-crate-boundary: the tree does not start at harness-core (fail closed)" >&2
  exit 1
fi

if printf '%s\n' "$tree" | grep -Eq '(^|[[:space:]])pty[-_]view[[:space:]]+v'; then
  echo "RULE 3 (crate boundary): harness-core depends on pty-view:" >&2
  printf '%s\n' "$tree" | grep -E '(^|[[:space:]])pty[-_]view[[:space:]]+v' | head -5 >&2
  exit 1
fi

echo "check-crate-boundary: harness-core has no path to pty-view"
exit 0
