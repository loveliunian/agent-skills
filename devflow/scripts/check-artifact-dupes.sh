#!/usr/bin/env bash
# =============================================================================
# check-artifact-dupes.sh · 产物去重检查（v3.29.4）
# -----------------------------------------------------------------------------
# 背景（m01-base 复盘）：单模块产出 80 份文档/1.7MB，其中大量近重复——EN/CN 孪生
# （m01-base-test-cases.md 与 m01-base-测试用例.md 并存）、INDEX 与 -auto 副本、
# .md/.txt 双写。重复产物稀释信源、放大维护面；且孪生内容会漂移，字节级查重抓不到。
# 检查三类模式（内容漂移也命中）：
#   ① 同目录同词干 .md + .txt 双写
#   ② 同目录 <X>.md + <X>-auto.md 副本并存
#   ③ 同 feature 的 CN/EN 等价产物并存（经 devflow_paths.sh 的 kind 后缀映射；
#      需传 <feature>，P9 Gate 会传入）
# 另含字节级相同文件组检测（sha256 一致）。
# 豁免：docs/<feature>/gates/（收据镜像为设计内双写，受 cmp 一致性校验约束）。
# 已接入 P9 artifact gate。
# 用法：bash check-artifact-dupes.sh <docs-dir> [feature]
# =============================================================================
set -uo pipefail
DOCS="${1:-docs}"
FEATURE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FAIL=0

[ -d "$DOCS" ] || { echo "[DUPES] no docs dir — PASS(skip)"; exit 0; }

hash256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# ① 同词干 .md/.txt 双写；② -auto 副本（内容漂移也命中——文件名模式判定）
# 注：用 sub() 剥后缀而非 length/substr——macOS awk 对多字节文件名 length 按字符、
# substr 按字节，二者错位会产生残缺词干（实测中文目录下漏报）。
while IFS= read -r line; do
  [ -n "$line" ] || continue
  kind="${line%%|*}"; a="${line#*|}"; b="${a#*|}"; a="${a%%|*}"
  case "$kind" in
    md-txt) echo "[DUPES][FAIL] .md/.txt 双写: $a <-> $b"; FAIL=$((FAIL + 1)) ;;
    auto)   echo "[DUPES][FAIL] -auto 副本并存: $a <-> ${b}（自动生成副本与手写版二选一）"; FAIL=$((FAIL + 1)) ;;
  esac
done < <(cd "$DOCS" && find . -type f ! -name '.DS_Store' | grep -vE '(^|/)gates/' | sed 's|^\./||' | sort | awk '
  { files[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      for (j = i + 1; j <= NR; j++) {
        a = files[i]; b = files[j]
        if (a ~ /\.md$/) { t = a; sub(/\.md$/, ".txt", t); if (b == t) print "md-txt|" a "|" b }
        if (a ~ /-auto\.md$/) { t = a; sub(/-auto\.md$/, ".md", t); if (b == t) print "auto|" a "|" b }
      }
    }
  }')

# ③ CN/EN 等价产物并存（需 feature；kind 后缀映射复用 devflow_paths.sh 单一事实源）
if [ -n "$FEATURE" ] && [ -f "$SCRIPT_DIR/devflow_paths.sh" ]; then
  # shellcheck source=devflow_paths.sh
  source "$SCRIPT_DIR/devflow_paths.sh"
  KINDS="clarification acceptance constraints prd_review tech_selection design design_review_report demo_signoff code_review_report security_audit_report performance_audit_report load_test validation_report prd_vs_code prd_vs_code_warnings test_cases client_journey_report e2e_report unit_report integration_report staging_report final_verification deploy_record monitor_config docs_index retro sharing"
  for kind in $KINDS; do
    cn_suffix=$(df_zh_suffix "$kind" 2>/dev/null || true)
    en_suffixes=$(df_en_suffix "$kind" 2>/dev/null || true)
    [ -n "$cn_suffix" ] || continue
    cn_file=$(cd "$DOCS" 2>/dev/null && find . -type f -name "${FEATURE}-${cn_suffix}.md" | grep -vE '(^|/)gates/' | head -1 | sed 's|^\./||' || true)
    [ -n "$cn_file" ] || continue
    for en in $en_suffixes; do
      en_file=$(cd "$DOCS" 2>/dev/null && find . -type f -name "${FEATURE}-${en}.md" | grep -vE '(^|/)gates/' | head -1 | sed 's|^\./||' || true)
      if [ -n "$en_file" ]; then
        echo "[DUPES][FAIL] CN/EN 孪生产物并存: ${cn_file} <-> ${en_file}（中文优先，英文版应删除）"
        FAIL=$((FAIL + 1))
      fi
    done
  done
fi

# 字节级相同文件组（sha256 一致；内容完全一样的双写没有任何存在理由）
TMP=$(mktemp -t dupes.XXXXXX)
trap 'rm -f "$TMP"' EXIT
find "$DOCS" -type f ! -name '.DS_Store' | grep -vE '(^|/)gates/' 2>/dev/null | sort | while IFS= read -r f; do
  printf '%s  %s\n' "$(hash256 "$f")" "$f"
done > "$TMP"
DUPES=$(awk '{h=$1; $1=""; sub(/^  /,""); files[h]=files[h] "\n    " $0; cnt[h]++}
  END { for (h in cnt) if (cnt[h] > 1) printf "%s (%d 份)%s\n", h, cnt[h], files[h] }' "$TMP")
if [ -n "$DUPES" ]; then
  echo "[DUPES][FAIL] docs/ 下发现字节级重复产物："
  printf '%s\n' "$DUPES"
  FAIL=$((FAIL + 1))
fi

if [ "$FAIL" -gt 0 ]; then
  echo "[DUPES] FAIL: $FAIL 类重复产物（单一事实只保留一份；收据镜像 gates/ 已豁免）"
  exit 1
fi
echo "[DUPES] PASS"
