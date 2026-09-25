#!/usr/bin/env bash
# test-python-units.sh · Python 单测编排（v3.31.2）——pytest 可用则跑 tests/pytest/，
# 不可用则跳过（Windows/精简环境无 pytest 不阻断；CI matrix 已装）。
set -uo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "[PASS] $1"; }
bad() { FAIL=$((FAIL+1)); echo "[FAIL] $1"; }

source "$ROOT/scripts/py_runtime.sh"

if "${DEVFLOW_PY[@]}" -m pytest --version >/dev/null 2>&1; then
  if (cd "$ROOT" && "${DEVFLOW_PY[@]}" -m pytest tests/pytest -q --tb=short >/tmp/pytest-out.$$ 2>&1); then
    N=$(grep -oE "[0-9]+ passed" /tmp/pytest-out.$$ | head -1)
    ok "Python 单测 ${N}"
  else
    bad "Python 单测失败："; tail -8 /tmp/pytest-out.$$
  fi
  rm -f /tmp/pytest-out.$$
else
  ok "pytest 不可用——跳过（环境无 pytest 不阻断，CI matrix 覆盖）"
fi

# Gate Registry 一致性（kind/capability 与 devflow_receipt 映射抽查）
if "${DEVFLOW_PY[@]}" - "$ROOT" <<'PYEOF'
import json, sys
root = sys.argv[1]
reg = {g["stage"]: g for g in json.load(open(f"{root}/references/phase-registry.json"))["gates"]}
# kind ↔ verify_stage_json_binding 的 TAG 前缀一致性（抽查 5 组）
expect = {"P5": "test-cases", "P0b": "prd-review", "P2a": "design-review", "P10": "retrospective+sharing", "P3cd": "security+performance"}
for st, kind in expect.items():
    assert reg[st].get("kind") == kind, f"{st}.kind={reg[st].get('kind')} ≠ {kind}"
# capability ↔ profile gate_bindings 键一致性
prof = json.load(open(f"{root}/runtime-profiles/node-express-prisma.json"))["gate_bindings"]
for st in ("P3-build", "P3-completion"):
    g = reg.get(st) or {}
    if g.get("capability"):
        assert g["capability"] in prof or g["capability"].startswith("P3c"), f"{st}.capability={g['capability']} 不在 profile bindings"
print("registry-consistent")
PYEOF
then ok "Gate Registry 一致性（kind/capability 对账）"
else bad "Gate Registry 与映射不一致"; fi

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
