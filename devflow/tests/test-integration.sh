#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"

bash "$TEST_DIR/test-contracts.sh"
bash "$TEST_DIR/test-state.sh"
bash "$TEST_DIR/test-client-platforms.sh"
bash "$TEST_DIR/test-phase-gates.sh"
bash "$TEST_DIR/test-v3140-regressions.sh"
