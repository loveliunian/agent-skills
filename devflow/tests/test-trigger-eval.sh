#!/usr/bin/env bash
# test-trigger-eval.sh · v3.23.0 触发评测语料结构校验
# 说明：模型触发率需要真实运行记录（每条 ≥3 次）；本套件只做确定性结构校验，
#       防止语料缺 prompt/should_trigger、正负样例失衡或被误删。
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

CASES="$ROOT/tests/trigger-cases.yaml"

expect_file "tests/trigger-cases.yaml"

POS=$(grep -cE '^[[:space:]]*- prompt:' "$CASES" 2>/dev/null || true)
TRIG=$(grep -cE '^[[:space:]]*should_trigger: true' "$CASES" 2>/dev/null || true)
NOTRIG=$(grep -cE '^[[:space:]]*should_trigger: false' "$CASES" 2>/dev/null || true)
ROUTES=$(grep -cE '^[[:space:]]*expected_route:' "$CASES" 2>/dev/null || true)

if [ "${POS:-0}" -ge 12 ]; then ok "trigger corpus has >=12 cases ($POS)"; else bad "trigger corpus too small ($POS)"; fi
# 正样例（should_trigger: true）必须全部带 expected_route；负样例不需要
if [ "${TRIG:-0}" -gt 0 ] && [ "${ROUTES:-0}" -ge "${TRIG:-0}" ]; then
  ok "every should-trigger case declares expected_route ($ROUTES/$TRIG)"
else
  bad "should-trigger cases missing expected_route (routes=$ROUTES triggers=$TRIG)"
fi
if [ "${TRIG:-0}" -ge 8 ] && [ "${NOTRIG:-0}" -ge 3 ]; then
  ok "corpus balances positive/negative samples (${TRIG}/${NOTRIG})"
else
  bad "corpus positive/negative balance broken (${TRIG}/${NOTRIG})"
fi
if grep -qE '^[[:space:]]*trigger_recall:' "$CASES" &&
   grep -qE '^[[:space:]]*trigger_precision:' "$CASES" &&
   grep -qE '^[[:space:]]*false_positive_rate:' "$CASES"; then
  ok "corpus declares precision/recall/false-positive targets"
else
  bad "corpus missing trigger metric targets"
fi

# should-trigger 覆盖自然语言场景（不需要提到 devflow）
if grep -q '帮我把订单详情页加一个备注字段' "$CASES" &&
   grep -q '修复这个 bug' "$CASES" &&
   grep -q '实现这个需求' "$CASES"; then
  ok "corpus covers natural-language triggers without /devflow"
else
  bad "corpus lacks core natural-language trigger coverage"
fi

finish TRIGGER-EVAL
