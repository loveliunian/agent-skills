#!/usr/bin/env bash
# gate-version.sh · 输出当前 skill 版本（单一事实源 = SKILL.md frontmatter）
# 用法: VERSION=<gate>@$(bash "$(dirname "$0")/gate-version.sh")
OUT=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
if [ -z "$OUT" ]; then
  echo "[gate-version] FATAL: 无法从 SKILL.md 解析版本——拒绝产出空版本收据" >&2
  exit 2
fi
printf '%s\n' "$OUT"
