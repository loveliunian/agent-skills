#!/usr/bin/env bash
# secret-scan.sh · v3.26.6 · 高置信度明文秘密扫描（fail-closed、输出脱敏）
# 语义契约见 references/sensitive-data-policy.md。
# 用法：secret-scan.sh [path ...]；无参数时扫描本 skill 发布树。
# 输出：SECRET_FOUND|<type>|<file>:<line>|VALUE=<redacted>；任一命中退出码 1。
# 例外：同一行写 `secret-scan: allow` 并说明理由（仅限文档举例）。
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
else
  TARGETS=("$DEFAULT_ROOT")
fi

PATTERN_TYPES=(
  "private_key"
  "aws_access_key"
  "github_token"
  "slack_token"
  "openai_key"
  "assigned_secret"
)
PATTERN_REGS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  '(ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,})'
  'xox[baprs]-[A-Za-z0-9-]{10,}'
  'sk-[A-Za-z0-9]{32,}'
  "(api[_-]?key|apikey|secret|token|password|passwd|passphrase)[\"']?[[:space:]]*[:=][[:space:]]*[\"']?[A-Za-z0-9!@#%^&*_+./-]{16,}"
)

collect_files() {
  local t="$1"
  if [ -d "$t" ]; then
    # v3.26.1: logs/、manifest/ 仅在扫描 skill 自身发布树时排除（自树 tests/logs 含
    # 夹具假秘密）；扫用户项目时同名目录不再 prune——日志恰是泄密高发面，盲区即漏报。
    local base_prunes=(-name .git -o -name _archive -o -name .backups -o -name node_modules -o -name .devflow)
    if [ "$t" = "$DEFAULT_ROOT" ]; then
      base_prunes+=(-o -name logs -o -name manifest)
    fi
    find "$t" -type d \( "${base_prunes[@]}" \) -prune \
      -o -type f -size -2M -print 2>/dev/null
  elif [ -f "$t" ]; then
    printf '%s\n' "$t"
  fi
}

FOUND=0
while IFS= read -r file; do
  [ -n "$file" ] || continue
  [ "${file##*/}" = "secret-scan.sh" ] && continue
  for i in "${!PATTERN_TYPES[@]}"; do
    ptype="${PATTERN_TYPES[$i]}"
    pre="${PATTERN_REGS[$i]}"
    hits=$(grep -InE "$pre" "$file" 2>/dev/null | grep -v 'secret-scan: allow' | cut -d: -f1 || true)
    [ -n "$hits" ] || continue
    while IFS= read -r ln; do
      [ -n "$ln" ] || continue
      printf 'SECRET_FOUND|%s|%s:%s|VALUE=<redacted>\n' "$ptype" "$file" "$ln"
      FOUND=$((FOUND + 1))
    done <<< "$hits"
  done
done < <(for t in "${TARGETS[@]}"; do collect_files "$t"; done)

if [ "$FOUND" -gt 0 ]; then
  echo "SECRET SCAN: FAIL (${FOUND} finding(s)) — 不得持久化明文秘密；仅允许 SECRET_SOURCE/SECRET_FINGERPRINT"
  exit 1
fi
echo "SECRET SCAN: PASS (no high-confidence secret pattern found)"
exit 0
