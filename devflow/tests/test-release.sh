#!/usr/bin/env bash
set -euo pipefail

# v3.16.0（P2-2）: 发布审计去重——run-tests → release-audit 与 release.sh → release-audit
# 重复执行（ShellCheck 同样跑两遍）。正式审计仅 release.sh 执行一次；
# 测试侧默认跳过正跑（RELEASE_AUDIT_POSITIVE=1 可显式恢复），后续负向夹具在此追加。
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

if [ "${RELEASE_AUDIT_POSITIVE:-0}" = "1" ]; then
  bash "$ROOT/scripts/release-audit.sh"
else
  echo "[SKIP] release-audit positive run (dedup: 正式审计由 release.sh 独跑一次；设 RELEASE_AUDIT_POSITIVE=1 恢复)"
fi
