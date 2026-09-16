#!/usr/bin/env bash
# v3.21.2 release-integrity regression suite
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

REAL=$(env -u RUN_TESTS_ACTIVE -u DEVFLOW_SKILL_TREE_SHA -u DEVFLOW_SKILL_TREE_ROOT \
  bash "$ROOT/scripts/gate-skill-tree.sh")
FORGED=$(RUN_TESTS_ACTIVE=1 \
  DEVFLOW_SKILL_TREE_SHA=0000000000000000000000000000000000000000000000000000000000000000 \
  DEVFLOW_SKILL_TREE_ROOT="$ROOT" \
  bash "$ROOT/scripts/gate-skill-tree.sh")

if [ "$FORGED" = "$REAL" ] && [ "$FORGED" != "0000000000000000000000000000000000000000000000000000000000000000" ]; then
  ok "production tree hash ignores test-cache environment injection"
else
  bad "production tree hash accepts forged test-cache environment injection"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'design\n' > "$TMP/design.md"
if STATE_DIR="$TMP/state" bash "$ROOT/scripts/review-receipt.sh" begin \
  --feature strict --role AUTHOR --agent-id self-declared --session-id strict-session \
  --input "$TMP/design.md" --output "$TMP/report.md" >/dev/null 2>&1; then
  bad "strict reviewer receipt accepts an unsigned self-declared identity"
else
  ok "strict reviewer receipt blocks an unsigned self-declared identity"
fi

grep -q 'scripts/check-copies.sh' "$ROOT/scripts/release.sh" \
  && ok "release gate verifies copy links (check-copies)" \
  || bad "release gate lost copy link verification"
grep -q '副本终验漂移"; FAIL=1; B_ROLLBACK_NEEDED=1' "$ROOT/scripts/release.sh" \
  && ok "B2 copy drift requests rollback" \
  || bad "B2 copy drift can leave an activated manifest"
if python3 - "$ROOT/agents/openai.yaml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
raise SystemExit(0 if all(k in d for k in ("interface", "policy", "dependencies")) else 1)
PY
then
  ok "Codex metadata uses documented top-level keys"
else
  bad "Codex metadata lacks documented top-level keys"
fi

finish V3212_INTEGRITY
