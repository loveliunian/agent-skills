#!/usr/bin/env bash
# Template-only dispatcher. State lifecycle logic lives in devflow-state-core.sh.
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$SCRIPT_DIR/..}"

# shellcheck source=devflow-state-core.sh
source "$SCRIPT_DIR/devflow-state-core.sh"

cmd_generate() {
  local feature="$1"
  local phase="$2"
  local output_path="$3"
  [ -n "$feature" ] && [ -n "$phase" ] && [ -n "$output_path" ] || {
    echo "Usage: $0 generate <feature> <phase> <output-path>" >&2
    return 2
  }
  generate_from_template "$feature" "$phase" "$output_path"
}

case "${1:-help}" in
  generate) shift; cmd_generate "$@" ;;
  list-templates) find "$SKILL_ROOT/templates" -maxdepth 1 -type f -name '*.md' -exec basename {} \; 2>/dev/null | sort || true ;;
  help|--help|-h) echo "Usage: $0 {generate|list-templates} ..." ;;
  *) echo "ERROR: unknown command: $1" >&2; exit 2 ;;
esac
