#!/usr/bin/env bash
set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(dirname "$SCRIPT_DIR")"
EXPECTED="${1:-$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)}"
FAIL=0

check_file() {
  local file="$1" version
  version=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$file" | head -1)
  if [ "$version" = "$EXPECTED" ]; then
    echo "[PASS] ${file#$ROOT/}: $version"
  else
    echo "[FAIL] ${file#$ROOT/}: ${version:-missing} expected $EXPECTED"
    FAIL=$((FAIL + 1))
  fi
}

check_file "$ROOT/SKILL.md"
check_file "$ROOT/concepts/PRD实施方法论.md"
for dir in commands phases subagents; do
  for file in "$ROOT/$dir"/*.md; do
    [ -f "$file" ] && check_file "$file"
  done
done

if grep -qE "^## v${EXPECTED//./\.}([[:space:]]|$)" "$ROOT/references/CHANGELOG.md"; then echo "[PASS] changelog v$EXPECTED"; else echo "[FAIL] changelog missing v$EXPECTED"; FAIL=$((FAIL + 1)); fi

# v3.16.11（P2 版本漂移）: 命令文档标题版本扫描——frontmatter Gate 只查 YAML，
# 发现不了 ROUTING.md 标题 v3.15.1 这类展示层漂移。范围：commands/*.md 的首个
# 标题行（^# 开头）；scripts 头注释中的 vX.Y.Z 多为历史引入记录（描述性），
# 不强制——主入口脚本（release.sh）头注释已对齐且由人工评审保证。
# v3.17.0（展示层漂移扩展）: 扫描面从 commands/ 扩到 SKILL.md 本体 + phases/ +
# subagents/ 首个标题行——实测主入口标题 v3.16.25 落后元数据 3.16.26、
# prd-review-committee.md 标题停在 v3.14.0，均未被旧扫描捕获。
_STALE_FILES=''
while IFS= read -r _m; do
  [ -f "$_m" ] || continue
  _title=$(grep -m1 -E '^# ' "$_m" 2>/dev/null || true)
  # v3.16.11: 提取标题内全部 vX.Y.Z（全角括号紧贴版本同样命中——防盲区）
  if [ -n "$_title" ] && printf '%s' "$_title" | grep -qE 'v[0-9]+\.[0-9]+\.[0-9]+'; then
    _ts=$(printf '%s' "$_title" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -u)
    printf '%s\n' "$_ts" | grep -qv "v${EXPECTED//./\.}" && _STALE_FILES="$_STALE_FILES
  ${_m#$ROOT/}: $_title"
  fi
done < <({ printf '%s\n' "$ROOT"/SKILL.md; ls "$ROOT"/commands/*.md "$ROOT"/phases/*.md "$ROOT"/subagents/*.md 2>/dev/null; })
if [ -n "$_STALE_FILES" ]; then
  echo "[FAIL] 文档标题版本漂移（≠ v${EXPECTED}）:$_STALE_FILES"
  FAIL=$((FAIL + 1))
else
  echo "[PASS] 文档标题版本一致（SKILL.md + commands + phases + subagents）"
fi

frontmatter_chars=$(awk 'BEGIN{n=0;f=0} /^---$/{f++; if(f==2){print n; exit} next} f==1{n+=length($0)+1}' "$ROOT/SKILL.md")
words=$(wc -w < "$ROOT/SKILL.md" | tr -d ' ')
[ "$frontmatter_chars" -le 1024 ] || { echo "[FAIL] frontmatter chars=$frontmatter_chars"; FAIL=$((FAIL + 1)); }
[ "$words" -le 500 ] || { echo "[FAIL] SKILL words=$words"; FAIL=$((FAIL + 1)); }

# v3.16.26: 脚本 banner 版本漂移扫描——脚本前两行的"身份版本"（如 `release.sh · v3.16.24`）
# 必须等于当前版本；第 4 行起的历史修复注记（v3.14.0: 推导…）属 CHANGELOG 范畴不在此扫描。
_STALE_BANNERS=''
while IFS= read -r _sh; do
  _banner_ver=$(sed -n '2,3p' "$_sh" 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | sort -u | grep -v "v${EXPECTED//./\.}" | head -3)
  if [ -n "$_banner_ver" ]; then
    _STALE_BANNERS="$_STALE_BANNERS
  ${_sh#$ROOT/}: $_banner_ver"
  fi
done < <(find "$ROOT/scripts" "$ROOT/checks" "$ROOT/maintenance" -maxdepth 1 -name '*.sh' 2>/dev/null)
if [ -n "$_STALE_BANNERS" ]; then
  echo "[FAIL] 脚本 banner 版本漂移（≠ v${EXPECTED}，历史版本应写入 CHANGELOG 而非 banner）:$_STALE_BANNERS"
  FAIL=$((FAIL + 1))
else
  echo "[PASS] 脚本 banner 版本一致"
fi

echo "VERSION GATE: expected=$EXPECTED fail=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
