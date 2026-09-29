#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVELOP_REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

exec python3 -m unittest discover -s "$DEVELOP_REPO_ROOT/develop/tests" -p 'test_*.py' -v
