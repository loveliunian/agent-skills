#!/usr/bin/env bash
# =============================================================================
# sql_dialect_lint.sh · 多方言迁移 SQL 静态检查（v3.30.6）
# -----------------------------------------------------------------------------
# 背景（m01-base 复盘）：AUTO_INCREMENT/TINYINT 残留在 Flyway 迁移运行时才暴露
# （H2 PG 模式直接失败），P3 返工一轮。本脚本把这类错误拦在「SQL 写完即检」——
# 已接入 build-watchdog.sh gate（P3-build），也可单独运行。
#
# 检查范围：<root>（默认 .）下所有 db/migration/{h2,postgresql,oracle,kingbase}/
# 目录中的 .sql——四方言均为非 MySQL 目标，MySQL-only 语法一律报错。
# 黑名单：AUTO_INCREMENT / TINYINT / MEDIUMINT / UNSIGNED / ENGINE= / CHARSET /
#         ON DUPLICATE KEY / REPLACE INTO / 反引号标识符 / 列内联 COMMENT '...'
# 无多方言迁移目录时 PASS（SKIP 语义，适配非 Flyway profile）。
# 用法：bash sql_dialect_lint.sh [root]
# =============================================================================
set -uo pipefail
ROOT="${1:-.}"
FAIL=0

# shell 注释行（-- 开头）不算
# 注：不用 find -path（可维护性门禁禁用）；先按目录名找方言目录再按迁移路径过滤
VENDOR_DIRS=$(find "$ROOT" -type d \( -name h2 -o -name postgresql -o -name oracle -o -name kingbase \) 2>/dev/null | grep '/db/migration/' | grep -v '/target/' | sort -u || true)
[ -n "$VENDOR_DIRS" ] || { echo "[SQL-LINT] no multi-dialect migration dirs under $ROOT — PASS(skip)"; exit 0; }

PATTERN='AUTO_INCREMENT|TINYINT|MEDIUMINT|UNSIGNED|ENGINE[[:space:]]*=|DEFAULT[[:space:]]+CHARSET|CHARSET[[:space:]]*=|ON[[:space:]]+DUPLICATE[[:space:]]+KEY|REPLACE[[:space:]]+INTO|`[^`]+`|COMMENT[[:space:]]+'"'"''

while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  while IFS= read -r sql; do
    [ -n "$sql" ] || continue
    hits=$(grep -nvE '^[[:space:]]*--' "$sql" 2>/dev/null | grep -iE "$PATTERN" || true)
    if [ -n "$hits" ]; then
      echo "[SQL-LINT][FAIL] $sql"
      printf '%s\n' "$hits" | head -5 | sed 's/^/    /'
      FAIL=$((FAIL + 1))
    fi
  done < <(find "$dir" -maxdepth 1 -name '*.sql' -type f 2>/dev/null | sort)
done <<< "$VENDOR_DIRS"

if [ "$FAIL" -gt 0 ]; then
  echo "[SQL-LINT] FAIL: $FAIL 个迁移文件含 MySQL-only 语法（四方言目标：h2/postgresql/oracle/kingbase）"
  exit 1
fi
echo "[SQL-LINT] PASS"
