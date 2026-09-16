#!/usr/bin/env bash
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0
FAIL=0

ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
expect_file() { [ -f "$ROOT/$1" ] && ok "file $1" || bad "missing file $1"; }
expect_contains() { grep -qE "$2" "$ROOT/$1" 2>/dev/null && ok "$3" || bad "$3"; }
expect_not_contains() { if grep -qE "$2" "$ROOT/$1" 2>/dev/null; then bad "$3"; else ok "$3"; fi; }
finish() {
  echo "=== $1 RESULT PASS=$PASS FAIL=$FAIL ==="
  [ "$FAIL" -eq 0 ] || exit 1
}
