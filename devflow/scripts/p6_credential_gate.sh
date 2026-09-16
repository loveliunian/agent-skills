#!/usr/bin/env bash
# ============================================================
# P6 Credential Traceability Gate (版本随 SKILL.md)
# Replaces: commands/audit-completeness.md P6 §15 (36 lines)
# Usage: bash "$SKILL_ROOT/scripts/p6_credential_gate.sh" <feature>
# ============================================================
set -euo pipefail
export LC_ALL=C

FEATURE="${1:-}"
[ -z "$FEATURE" ] && echo "Usage: $0 <feature>" && exit 1
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2
STATE_DIR="${STATE_DIR:-.devflow}"
STATE_FILE="$STATE_DIR/${FEATURE}.state.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
CLIENT_PLATFORM="pc-web"
CLIENT_DIR="frontend"
CLIENT_HASH=""
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  CLIENT_PLATFORM=$(jq -r '.scope.frontend // "pc-web"' "$STATE_FILE")
  CLIENT_DIR=$(jq -r '.scope.frontend_dir // "frontend"' "$STATE_FILE")
  CLIENT_HASH=$(jq -r '.scope.client_manifest_sha256 // empty' "$STATE_FILE")
fi

echo "=== P6 Credential Traceability Gate (v3.14.0) ==="

# ---------- 计数器：收据必须持久化真实 PASS/WARN 计数 ----------
PASS_COUNT=0
WARN_COUNT=0
gate_pass() { echo "  [PASS] $1"; PASS_COUNT=$((PASS_COUNT+1)); }
gate_warn() { echo "  [WARN] $1"; WARN_COUNT=$((WARN_COUNT+1)); }

# 1. 测试报告不含盲猜模式（排除"已作废声明"元行）
# v3.22.0: 目录中英双语（docs/测试报告 优先，回退 docs/tests）
REPORT=""
P6_REPORT_DIRS=()
for _d in docs/测试报告 docs/tests; do [ -d "$_d" ] && P6_REPORT_DIRS+=("$_d"); done
if [ "${#P6_REPORT_DIRS[@]}" -gt 0 ]; then
  REPORT=$(find "${P6_REPORT_DIRS[@]}" \( -name "${FEATURE}-*测试报告*.md" -o -name "${FEATURE}-*-report.md" \) 2>/dev/null | head -1 || true)
fi
if [ -z "$REPORT" ]; then
  echo "  [FAIL] 测试报告不存在（docs/测试报告/${FEATURE}-*测试报告*.md）— P6 无凭证证据，拒绝放行"
  exit 1
else
  # v3.14.11-fix(jmmp2): 否定声明（如"无盲猜密码"）曾命中正向关键词被误判阳性——排除否定语境行
  if grep -vE "已作废|v[0-9] 修订|错误做法|反例引用" "$REPORT" \
     | grep -vE "(无|没有|未|不含|禁止|杜绝)[^。]{0,20}(盲猜|穷举|常见密码)" \
     | grep -qE "尝试.*admin[0-9]+|尝试.*常见密码|盲猜|穷举.*密码"; then
    echo "  [FAIL] $REPORT 含盲猜密码审计错误 — P0 阻断"
    exit 1
  else
    gate_pass "测试报告无盲猜密码"
  fi
fi

# 2. 测试用例文档"前置条件"必须含凭证三要素
# v3.22.0: 目录中英四目录双语
CASE_DIRS=""
for d in docs/测试用例 docs/test-cases docs/测试报告 docs/tests; do
  if [ -d "$d" ]; then CASE_DIRS="$CASE_DIRS $d"; fi
done
CASES=""
if [ -n "$CASE_DIRS" ]; then
  CASES=$(find $CASE_DIRS \
    \( -name "*${FEATURE}*端到端测试用例*.md" -o \
    -name "*${FEATURE}*test-cases*.md" \) 2>/dev/null | head -1 || true)
fi
if [ -n "$CASES" ] && [ -f "$CASES" ]; then
  HAS_USER=$(grep -cE "\| 用户名" "$CASES" || true)
  HAS_PWD=$(grep -cE "\| 密码" "$CASES" || true)
  HAS_SRC=$(grep -cE "代码来源|V[0-9].*__seed.*user|BuiltinDataInitializer|helpers\.ts" "$CASES" || true)
  if [ "$HAS_USER" -gt 0 ] && [ "$HAS_PWD" -gt 0 ] && [ "$HAS_SRC" -gt 0 ]; then
    gate_pass "凭证表三要素齐全"
  else
    echo "  [FAIL] 凭证表不完整（用户名=$HAS_USER 密码=$HAS_PWD 来源=${HAS_SRC}）"
    exit 1
  fi
else
  echo "  [FAIL] 端到端测试用例文档未找到（docs/test-cases|docs/tests 下 *${FEATURE}*）— 凭证三要素无从校验"
  exit 1
fi

# 3. 所有客户端测试/源码不得硬编码常见密码（PC Web、小程序、APP 统一适用）
E2E_SCRIPTS=""
if [ "$CLIENT_PLATFORM" != "not-applicable" ] && [ -d "$CLIENT_DIR" ]; then
E2E_SCRIPTS=$(find "$CLIENT_DIR" -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.dart' -o -name '*.swift' -o -name '*.kt' -o -name '*.wxml' \) 2>/dev/null | grep -vE '/(node_modules|dist|build|coverage)/' || true)
fi
HARDCODED=0
for f in $E2E_SCRIPTS; do
  if grep -qE "admin123|admin888|12345678" "$f" 2>/dev/null; then
    echo "  [FAIL] $f 硬编码常见密码"
    HARDCODED=1
  fi
done
[ "$HARDCODED" -eq 1 ] && exit 1 || gate_pass "E2E脚本无硬编码密码"

# 4. 平台客户端必须执行冻结 manifest 对应的测试命令；PC Web 在 P6 执行 npm test。
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  case "$CLIENT_PLATFORM" in
    pc-web)
      bash "$SCRIPT_DIR/client-adapter.sh" test pc-web "$CLIENT_DIR" --strict || { echo "  [FAIL] PC Web client test"; exit 1; }
      ;;
    mini-program|app)
      [ -n "$CLIENT_HASH" ] && [ "$CLIENT_HASH" != "null" ] || { echo "  [FAIL] client manifest not frozen"; exit 1; }
      bash "$SCRIPT_DIR/client-adapter.sh" test "$CLIENT_PLATFORM" "$CLIENT_DIR" --strict --expected-manifest-sha "$CLIENT_HASH" || { echo "  [FAIL] $CLIENT_PLATFORM client test"; exit 1; }
      ;;
    not-applicable) echo "  [PASS] client test not applicable"; PASS_COUNT=$((PASS_COUNT+1)) ;;
    *) echo "  [FAIL] invalid client platform: $CLIENT_PLATFORM"; exit 1 ;;
  esac
else
  echo "  [FAIL] state 文件缺失或 jq 不可用，无法确定客户端平台执行 client test"
  exit 1
fi

# ---------- 收据双写：结果、版本和阶段必须可审计（计数为真实值） ----------
RECEIPT_DIR="$STATE_DIR/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P6-credential"
mkdir -p "$RECEIPT_DIR" 2>/dev/null
{
  echo "EXIT_CODE=0"
  echo "VERSION=p6-credential@$(bash "$(dirname "$0")/gate-version.sh")"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P6-credential"
  echo "PASS=$PASS_COUNT FAIL=0 WARN=$WARN_COUNT"
  echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED: $RECEIPT_DIR/receipt.txt" >&2; exit 1; }
echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
DOCS_MIRROR="docs/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/P6-credential"
mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"

echo "P6 CREDENTIAL GATE: PASS"
