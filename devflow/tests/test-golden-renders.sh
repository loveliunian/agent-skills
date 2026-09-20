#!/usr/bin/env bash
# test-golden-renders.sh · v3.27.12 渲染黄金样本回归
# 目的：把全部 kind 的确定性渲染输出钉为逐字节黄金样本——渲染器任何非预期改动
#（章节、表头、机器行、文案）都会在此暴露；有意变更须同步重生成 tests/golden/。
# 生成方式（变更后重跑）：bash tests/test-golden-renders.sh --regen
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

KINDS="acceptance clarification code-review constraints demo-signoff deployment \
design-review docs-index execution-plan monitoring performance prd-review \
prd-validation retrospective security self-check sharing tech-selection test-cases verification"

REGEN=0
[ "${1:-}" = "--regen" ] && REGEN=1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/devflow-golden.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

check_file() { # <golden-rel> <generated-path> <label>
  local golden="$ROOT/tests/golden/$1" got="$2" label="$3"
  if [ "$REGEN" = "1" ]; then
    cp "$got" "$golden"; ok "regen: $label"
    return
  fi
  # 审计指纹行含输入样例 SHA-256——样例随版本 bump 变化，比对前归一化，升版即免疫
  _norm() { sed -E 's/sha256=[0-9a-f]{64}/sha256=<SHA>/' "$1"; }
  if diff -q <(_norm "$golden") <(_norm "$got") >/dev/null 2>&1; then
    ok "golden match: $label"
  else
    bad "golden mismatch: ${label}（diff -u tests/golden/$1 <生成物>；有意变更用 --regen 重生成）"
    diff -u <(_norm "$golden") <(_norm "$got") | head -12 | sed 's/^/    /'
  fi
}

echo "=== 渲染黄金样本回归（v3.27.12） ==="
for k in $KINDS; do
  if ! "${DEVFLOW_PY[@]}" "$ROOT/scripts/df_render.py" "$k" \
       --input "$ROOT/examples/structured/$k.sample.json" --out "$TMP/$k.md" >/dev/null 2>&1; then
    bad "render failed: $k"
    continue
  fi
  check_file "$k.md" "$TMP/$k.md" "$k"
done

# small-change：md + env + scan 三件套
if "${DEVFLOW_PY[@]}" "$ROOT/scripts/df_render.py" small-change \
     --input "$ROOT/examples/structured/small-change.sample.json" \
     --out "$TMP/small-change.md" --out-env "$TMP/small-change.env" \
     --out-scan "$TMP/small-change-scan.txt" >/dev/null 2>&1; then
  check_file "small-change.md" "$TMP/small-change.md" "small-change md"
  check_file "small-change.env" "$TMP/small-change.env" "small-change env"
  check_file "small-change-scan.txt" "$TMP/small-change-scan.txt" "small-change scan"
else
  bad "render failed: small-change"
fi

# design：骨架 + 块拼接（确定性层整体重写；DDR/追溯在附属文档——v3.28.1）
cp "$ROOT/examples/structured/design.skeleton.md" "$TMP/design.md"
cp "$ROOT/examples/structured/数据库设计决策.skeleton.md" "$TMP/数据库设计决策.md"
cp "$ROOT/examples/structured/需求追溯.skeleton.md" "$TMP/需求追溯.md"
if "${DEVFLOW_PY[@]}" "$ROOT/scripts/df_render.py" design \
     --input "$ROOT/examples/structured/design.sample.json" --doc "$TMP/design.md" \
     --db-doc "$TMP/数据库设计决策.md" --trace-doc "$TMP/需求追溯.md" >/dev/null 2>&1; then
  check_file "design.md" "$TMP/design.md" "design（块拼接）"
  check_file "database-design.md" "$TMP/数据库设计决策.md" "数据库设计决策（ddr 块拼接）"
  check_file "traceability.md" "$TMP/需求追溯.md" "需求追溯（trace 块拼接）"
else
  bad "render failed: design"
fi

echo "=== GOLDEN_RENDERS RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
