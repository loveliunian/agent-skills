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

# mk_acceptance_json <feature> <workspace> — v3.25.1(P1-a)：为 s0 Gate 生成
# 结构化验收点正本（.devflow/<feature>/acceptance.json）。points 从 criteria
# Markdown 的 M-ID 集合派生（中文/英文路径均尝试），保证双正本集合全等。
mk_acceptance_json() {
  local feature="$1" ws="$2" crit rel
  crit="$ws/docs/需求/$feature-验收点.md"
  [ -f "$crit" ] || crit="$ws/docs/requirements/$feature-acceptance-criteria.md"
  if [ ! -f "$crit" ]; then
    echo "[mk_acceptance_json] criteria 不存在: $feature" >&2
    return 1
  fi
  mkdir -p "$ws/.devflow/$feature"
  # 相对路径——绝对路径含 mktemp 的字面 XXXXXX 会撞占位话术黑名单
  rel="${crit#"$ws"/}"
  python3 - "$feature" "$crit" "$ws/.devflow/$feature/acceptance.json" "$rel" <<'PY'
import json, re, sys
feature, crit, out, rel = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
text = open(crit, encoding="utf-8").read()
ids = sorted(set(re.findall(r"M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}", text))) or ["M-01-F01-A01"]
d = {
    "feature": feature, "generated_at": "2026-09-17T00:00:00Z",
    "template": {"id": "验收点-模板", "version": "1"},
    "feature_name": feature, "module": "01",
    "prd_doc": rel, "date": "2026-09-17", "splitter": "fixture",
    "points": [{"id": i, "description": "fixture 验收点 " + i, "verify_method": "API",
                "prd_anchor": rel + "#L1", "status": "FROZEN"} for i in ids],
    "reviews": [{"round": 1, "reviewer": "fixture", "date": "2026-09-17",
                 "verdict": "通过", "leftovers": "无"}],
    "signoffs": [{"role": "fixture", "name": "fixture", "date": "2026-09-17"}],
    "zero_results": [],
}


json.dump(d, open(out, "w", encoding="utf-8"), ensure_ascii=False)
PY
}
