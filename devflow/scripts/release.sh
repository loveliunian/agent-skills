#!/usr/bin/env bash
# release.sh · 唯一发布入口（版本随 SKILL.md 单一事实源动态读取，本文件不写死版本号；当前 v3.25.0）
# 通用化发布链（Runtime Profile + 发布授权 + Secret scan；详见 CHANGELOG）。
# 原子事务化（自 v3.20.8）——旧流程第 5 步落不可变 manifest、第 6 步才查副本，
# 中途失败留下"manifest 已占位、副本未同步"的半发布态。现改为两段式：
#   Phase A（只读预检，任一失败即退出，仓库零改动）：
#     1 完整测试 → 2 版本一致性 → 3 Release Audit → 4 Secret scan → 5 ShellCheck
#     → 6 state 冻结对照 → 7 stage 临时 manifest（不落盘）→ 8 副本直连校验
#   Phase B（提交，任一失败自动回滚 manifest+台账）：
#     B1 activate 原子落盘 manifest + 追加 CHAIN 台账
#     → B2 终复核（manifest check + 副本直连校验 + 树 hash）
# 回滚安全性：manifest 内容与 chain_hash 由 (version, tree, parent chain) 决定性
# 生成——回滚后重跑产出逐字节一致的 manifest，不会产生台账分叉。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FAIL=0
step() { echo ""; echo "═══════════════════════════════════════"; echo "  $1"; echo "═══════════════════════════════════════"; }

RELEASE_VERSION=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
RELEASE_MANIFEST="$ROOT/references/manifest/${RELEASE_VERSION}.json"
STAGED_MANIFEST=$(mktemp -t devflow-staged.XXXXXX) || { echo "[FAIL] 无法创建 stage 临时文件"; exit 1; }
trap 'rm -f "$STAGED_MANIFEST"' EXIT

# ---------- Phase A：只读预检 ----------
step "1/8 完整测试套件 (run-tests.sh)"
if bash "$ROOT/tests/run-tests.sh"; then echo "  [OK] 完整测试 PASS"; else echo "  [FAIL] 完整测试 FAIL"; FAIL=1; fi

step "2/8 版本一致性 (check-skill-version.sh)"
if bash "$ROOT/scripts/check-skill-version.sh"; then echo "  [OK] 版本一致性 PASS"; else echo "  [FAIL] 版本一致性 FAIL"; FAIL=1; fi

step "3/8 Release Audit (release-audit.sh)"
if bash "$ROOT/scripts/release-audit.sh"; then echo "  [OK] Release Audit PASS"; else echo "  [FAIL] Release Audit FAIL"; FAIL=1; fi

step "4/8 Secret scan（明文秘密，契约见 references/sensitive-data-policy.md）"
if bash "$ROOT/scripts/secret-scan.sh"; then echo "  [OK] 无高置信度明文秘密"; else echo "  [FAIL] 发现明文秘密——禁止发布"; FAIL=1; fi

step "5/8 ShellCheck（全量脚本）"
if command -v shellcheck >/dev/null 2>&1; then
  if find "$ROOT/scripts" "$ROOT/hooks" "$ROOT/tests" "$ROOT/maintenance" -type f -name '*.sh' ! -name '*.bak-*' -exec shellcheck -S warning {} + 2>&1; then
    echo "  [OK] ShellCheck 全量 PASS"
  else
    echo "  [FAIL] ShellCheck 发现告警"; FAIL=1
  fi
else
  echo "  [FAIL] shellcheck 不可用——ShellCheck 门禁不可跳过"; FAIL=1
fi

step "6/8 树 hash 一致性（state 冻结对照——硬门禁）"
# v3.15.1: ① skill 发布树内不得包含任何项目 state 文件（测试垃圾入库即 FAIL）；
# ② 显式提供的外部 state（DEVFLOW_RELEASE_STATES，冒号或换行分隔）冻结树必须等于当前发布树。
# v3.20.3: 移入只读预检段（原第 7 步在 manifest 落盘后，失败同样制造半发布态）。
EMBEDDED_STATES=$(find "$ROOT" -name "*.state.json" 2>/dev/null | head -5)
if [ -n "$EMBEDDED_STATES" ]; then
  echo "  [FAIL] 发布树内发现项目 state 文件（测试垃圾不得入库）:"
  printf '    %s\n' $EMBEDDED_STATES
  FAIL=1
elif [ -n "${DEVFLOW_RELEASE_STATES:-}" ]; then
  STATE_LIST_FILE=$(mktemp) || { echo "  [FAIL] 无法创建 DEVFLOW_RELEASE_STATES 临时清单"; FAIL=1; STATE_LIST_FILE=""; }
  if [ -n "$STATE_LIST_FILE" ]; then
    # 保留路径中的空格；Windows 盘符路径使用换行分隔，避免冒号被拆开。
    if printf '%s' "$DEVFLOW_RELEASE_STATES" | grep -qE '(^|[[:space:]])[A-Za-z]:[\\/]'; then
      printf '%s\n' "$DEVFLOW_RELEASE_STATES" | while IFS= read -r _line; do
        _line="${_line%$'\r'}"
        [ -n "$_line" ] && printf '%s\n' "$_line"
      done > "$STATE_LIST_FILE"
    else
      printf '%s\n' "$DEVFLOW_RELEASE_STATES" | tr ':' '\n' > "$STATE_LIST_FILE"
    fi
  fi
  CURRENT_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null || true)
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    [ -f "$st" ] || { echo "  [FAIL] DEVFLOW_RELEASE_STATES 路径不存在: $st"; FAIL=1; continue; }
    FROZEN=$(jq -r '.scope.skill_tree_sha256 // empty' "$st" 2>/dev/null)
    if [ -z "$FROZEN" ]; then
      echo "  [FAIL] $st 缺少冻结 skill 树锚点——运行 devflow-state.sh migrate-tree <feature>"
      FAIL=1
    elif [ "$FROZEN" != "$CURRENT_TREE" ]; then
      echo "  [FAIL] $st 冻结树 hash 与当前发布树不同——运行 devflow-state.sh migrate-tree <feature> 显式迁移"
      FAIL=1
    else
      echo "  [OK] $st 冻结树与发布树一致"
    fi
  done < "${STATE_LIST_FILE:-/dev/null}"
  [ -z "$STATE_LIST_FILE" ] || rm -f "$STATE_LIST_FILE"
else
  echo "  [OK] 发布树无项目 state 文件（项目侧 state 在各自工作区；需对照时设 DEVFLOW_RELEASE_STATES）"
fi

MANIFEST_EXISTS=0
if [ -z "$RELEASE_VERSION" ]; then
  echo ""
  echo "  [FAIL] 无法解析发布版本，拒绝生成或校验 manifest"
  FAIL=1
fi

step "7/8 stage 临时 manifest（只读——activate 前不落盘）"
if [ "$FAIL" -ne 0 ]; then
  echo "  [SKIP] 前置门禁失败，不 stage manifest"
elif [ -f "$RELEASE_MANIFEST" ]; then
  MANIFEST_EXISTS=1
  if bash "$ROOT/scripts/gen-skill-manifest.sh" check; then
    echo "  [OK] 已发布 manifest 树 hash 一致（不可重写；发布为增量同步模式）"
  else
    echo "  [FAIL] 已发布 manifest 与当前树漂移——必须升版，不得重写旧 manifest"; FAIL=1
  fi
else
  if bash "$ROOT/scripts/gen-skill-manifest.sh" stage "$STAGED_MANIFEST"; then
    echo "  [OK] manifest 已 stage（$(jq -r '.version' "$STAGED_MANIFEST")，tree_hash=$(jq -r '.tree_hash' "$STAGED_MANIFEST")）"
  else
    echo "  [FAIL] manifest stage 失败"; FAIL=1
  fi
fi

step "8/8 副本直连校验（只读判定）"
if [ "$FAIL" -ne 0 ]; then
  echo "  [SKIP] 前置门禁失败"
else
  # v3.23.0 瘦身：副本形态为直连软链（不再是 rsync 实体副本），发布树即副本内容，
  # 不存在"首发预期漂移"——必须直连口径全绿（check-copies：1=漂移，2=结构错误）。
  if bash "$ROOT/scripts/check-copies.sh"; then
    echo "  [OK] 副本直连校验一致"
  else
    CP_RC=$?
    echo "  [FAIL] 副本直连校验失败（rc=${CP_RC}）——跑仓库级 sync.sh 修复后重试"
    FAIL=1
  fi
fi

# ---------- Phase A/B 分界 ----------
if [ "$FAIL" -ne 0 ]; then
  echo ""
  echo "RELEASE GATE: FAIL — 禁止发布（Phase A 只读预检未通过，仓库零改动）"
  exit 1
fi

echo ""
echo "═══════════════════════════════════════"
echo "  Phase A 只读预检全部通过 — 进入 Phase B 提交"
echo "═══════════════════════════════════════"

# ---------- Phase B：提交（失败回滚） ----------
B_ROLLBACK_NEEDED=0

do_rollback() {
  # 仅新版本首发需要回滚；已发布版本 Phase B 只做终复核，不动 manifest。
  if [ "$MANIFEST_EXISTS" -eq 0 ] && [ -f "$RELEASE_MANIFEST" ]; then
    LEDGER="$ROOT/references/manifest/CHAIN.json"
    if [ -f "$LEDGER" ] && command -v jq >/dev/null 2>&1; then
      LEDGER_TMP=$(mktemp)
      if jq --arg v "$RELEASE_VERSION" '.entries |= map(select(.version != $v))' "$LEDGER" > "$LEDGER_TMP"; then
        mv "$LEDGER_TMP" "$LEDGER"
        echo "  [ROLLBACK] 台账已移除本次条目: $RELEASE_VERSION"
      else
        rm -f "$LEDGER_TMP"
        echo "  [ROLLBACK][WARN] 台账条目移除失败，须手工核对 CHAIN.json"
      fi
    fi
    rm -f "$RELEASE_MANIFEST"
    echo "  [ROLLBACK] manifest 已回滚: ${RELEASE_MANIFEST}（重跑 release.sh 将产出逐字节一致的 manifest，无台账分叉）"
  fi
}

step "B1/2 activate manifest（原子落盘 + 台账追加）"
if [ "$MANIFEST_EXISTS" -eq 1 ]; then
  echo "  [SKIP] 已发布版本（增量同步模式，不重写不可变 manifest）"
else
  if bash "$ROOT/scripts/gen-skill-manifest.sh" activate "$STAGED_MANIFEST"; then
    echo "  [OK] manifest 已激活并入链"
  else
    echo "  [FAIL] activate 失败"
    FAIL=1
  fi
fi

step "B2/2 终复核（manifest check + 副本直连校验 + 树 hash）"
if [ "$FAIL" -ne 0 ]; then
  echo "  [SKIP] 前置提交失败"
else
  if bash "$ROOT/scripts/gen-skill-manifest.sh" check >/dev/null 2>&1; then
    echo "  [OK] manifest check 终验通过"
  else
    echo "  [FAIL] manifest check 终验失败"; FAIL=1; B_ROLLBACK_NEEDED=1
  fi
  if bash "$ROOT/scripts/check-copies.sh" >/dev/null 2>&1; then
    echo "  [OK] 副本终验一致"
  else
    echo "  [FAIL] 副本终验漂移"; FAIL=1; B_ROLLBACK_NEEDED=1
  fi
  FINAL_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh" 2>/dev/null || true)
  STAGED_TREE=$(jq -r '.tree_hash' "$STAGED_MANIFEST" 2>/dev/null || true)
  if [ "$MANIFEST_EXISTS" -eq 1 ]; then
    echo "  [OK] 树 hash 稳定（增量同步模式）"
  elif [ -n "$FINAL_TREE" ] && [ "$FINAL_TREE" = "$STAGED_TREE" ]; then
    echo "  [OK] 树 hash 与 stage 一致（发布过程无漂移）"
  else
    echo "  [FAIL] 发布过程树漂移：stage=$STAGED_TREE final=$FINAL_TREE"; FAIL=1; B_ROLLBACK_NEEDED=1
  fi
fi

if [ "$FAIL" -ne 0 ] && [ "$B_ROLLBACK_NEEDED" -eq 1 ]; then
  echo ""
  echo "  Phase B 失败——执行回滚"
  do_rollback
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "RELEASE GATE: ALL GREEN — 发布完成（manifest+台账+副本直连一致）"
  exit 0
fi
echo "RELEASE GATE: FAIL — 已回滚 manifest 占位；副本失联时跑仓库级 sync.sh 修复后重跑（check-copies.sh 只读幂等）"
exit 1
