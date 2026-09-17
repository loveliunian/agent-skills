#!/usr/bin/env bash
set -euo pipefail
# devflow pre-commit hook（安装源：skill 仓库 hooks/pre-commit-devflow.sh）
# Windows / macOS / Linux 通用
# 用途：在 commit 前自动跑 v2.1 完成度自检的核心 5 项，强制开发者不可绕过。
#
# 安装（开发者）：
#   cp <skill-仓库>/hooks/pre-commit-devflow.sh .git/hooks/pre-commit
#   chmod +x .git/hooks/pre-commit
#
# 行为：
#   - 仅在 backend/ 或 frontend/ 文件改动时触发
#   - 跑 5 项核心 grep + 1 项跨平台兼容性检查
#   - 任一 FAIL = exit 1，commit 被阻止
#   - SKIP 环境变量：SKIP_DEVFLOW_AUDIT=1 可跳过本检查（CI 用；等效显式豁免，留痕自负）
#   - 平台：Git Bash / WSL / macOS Terminal / Linux 通用（PowerShell / CMD 不支持）

set +e  # 禁用 errexit（避免 grep 0 匹配中断脚本）

if [ "${1:-}" = "--self-test" ]; then
  SELF_TEST=1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

# 自检函数
check() {
  local name="$1"
  local result="$2"
  local expect="$3"

  echo -n "[devflow-audit] $name: "
  result=$(printf '%s' "$result" | tr -d ' ')

  if [ "$result" = "$expect" ] || { [ -z "$expect" ] && [ -z "$result" ]; }; then
    echo -e "${GREEN}PASS${NC}"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAIL${NC} (实际: '$result', 预期: '$expect')"
    FAILED=$((FAILED + 1))
  fi
}

# v3.14.0: 真实自测——实际执行 check() 三支判定，而非打印 PASS 即退出
if [ "${SELF_TEST:-0}" = "1" ]; then
  command -v git >/dev/null 2>&1 || exit 1
  check "self-test: 相等" "1" "1"
  check "self-test: 空值相等" "" ""
  check "self-test: 空值不相等" "x" ""
  if [ "$PASSED" -eq 2 ] && [ "$FAILED" -eq 1 ]; then
    printf 'devflow pre-commit self-test: PASS\n'
    exit 0
  fi
  printf 'devflow pre-commit self-test: FAIL (PASS=%s FAIL=%s)\n' "$PASSED" "$FAILED"
  exit 1
fi

# 0. 跳过检查
if [ "${SKIP_DEVFLOW_AUDIT:-0}" = "1" ]; then
  echo -e "${YELLOW}[devflow-audit] SKIP_DEVFLOW_AUDIT=1, 跳过自检${NC}"
  exit 0
fi

# 0.5 明文秘密扫描（所有暂存文件；契约见 references/sensitive-data-policy.md）
# v3.23.0: 与 scripts/secret-scan.sh 同口径的高置信度模式；命中即阻断入库。
# 例外：同一行写 `secret-scan: allow` 并说明理由（仅限文档举例）。
SECRET_PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-[A-Za-z0-9]{32,}'
  "(api[_-]?key|apikey|secret|token|password|passwd|passphrase)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9!@#%^&*_+./-]{16,}"
)
SECRET_HITS=0
while IFS= read -r sf; do
  [ -n "$sf" ] || continue
  [ -f "$sf" ] || continue
  case "$sf" in */secret-scan.sh) continue ;; esac
  for sp in "${SECRET_PATTERNS[@]}"; do
    slines=$(grep -InE "$sp" "$sf" 2>/dev/null | grep -v 'secret-scan: allow' | cut -d: -f1 || true)
    [ -n "$slines" ] || continue
    while IFS= read -r sl; do
      [ -n "$sl" ] || continue
      echo -e "${RED}[devflow-audit] FAIL${NC} SECRET_FOUND|high-confidence|$sf:$sl|VALUE=<redacted>"
      SECRET_HITS=$((SECRET_HITS + 1))
    done <<< "$slines"
  done
done < <(git diff --cached --name-only --diff-filter=ACM -z 2>/dev/null | tr '\0' '\n')
if [ "$SECRET_HITS" -gt 0 ]; then
  echo -e "${RED}[devflow-audit] 发现疑似明文秘密 $SECRET_HITS 处，阻塞 commit。仅允许登记 SECRET_SOURCE/SECRET_FINGERPRINT。${NC}"
  exit 1
fi

# 1. 仅在 backend/frontend 改动时跑
if ! git diff --cached --name-only 2>/dev/null | grep -qE "^(backend|frontend)/"; then
  echo "[devflow-audit] 无 backend/frontend 改动，跳过"
  exit 0
fi

echo "[devflow-audit] 检测到 backend/frontend 改动，运行 v2.2 完成度自检..."

# ===== v2.2 POSIX 通用命令 =====

# 跨平台兼容性（验证 grep -E 可用）
ERE_COUNT=$(printf 'test\n' | grep -E 'test' | wc -l | tr -d ' ')
check "grep -E 可用" "$ERE_COUNT" "1"

# TODO 残留（如有 backend/<service> 改动）
if git diff --cached --name-only | grep -qE "^backend/[a-z-]+/src/main/java/"; then
  SERVICE=$(git diff --cached --name-only | grep -oE "^backend/[a-z-]+" | head -1 | cut -d/ -f2 || true)
  echo "[devflow-audit] 检测到服务: $SERVICE"

  # 1. TODO 残留（仅本次新增文件；存量文件不追溯，文件名空格安全）
  TODO_COUNT=$(git diff --cached --name-only --diff-filter=A -z | xargs -0 grep -l "TODO" 2>/dev/null | wc -l | tr -d ' ' || true)
  check "新文件 TODO 残留 = 0" "$TODO_COUNT" "0"

  # 2. Controller @PreAuthorize 覆盖
  # v3.15.16: mktemp 失败不再回退可预测文件名（/tmp/devflow_controllers_$$.txt 可
  # 预测 → 符号链接竞争风险）——fail-closed 计入 FAILED 阻塞 commit
  if ! TMP_CONTR=$(mktemp 2>/dev/null); then
    echo -e "${RED}[devflow-audit] FAIL${NC} mktemp 失败（tmp 不可写）——环境异常，跳过 Controller 检查"
    FAILED=$((FAILED + 1))
  else
    git diff --cached --name-only | grep "Controller.java$" | grep "/main/java/" > "$TMP_CONTR" 2>/dev/null
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [ -f "$f" ] && ! grep -q "@PreAuthorize" "$f"; then
        echo -e "${RED}[devflow-audit] FAIL${NC} Controller 无 @PreAuthorize: $f"
        FAILED=$((FAILED + 1))
      fi
    done < "$TMP_CONTR"
    rm -f "$TMP_CONTR"
  fi
fi

# 汇总
echo ""
echo "[devflow-audit] 通过: $PASSED, 失败: $FAILED"

if [ "$FAILED" -gt 0 ]; then
  echo -e "${RED}[devflow-audit] 阻塞 commit。请修复后重试；确需豁免：SKIP_DEVFLOW_AUDIT=1 git commit（显式豁免，留痕自负）。${NC}"
  exit 1
fi

echo -e "${GREEN}[devflow-audit] 全部通过 OK${NC}"
exit 0
