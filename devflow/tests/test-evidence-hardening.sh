#!/usr/bin/env bash
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"
# v3.16.5: 收据契约函数（receipt_evidence_tree/verify_receipt_evidence）——夹具在 L143 即需调用，须在文件头部 source
source "$ROOT/scripts/devflow_receipt.sh"
SKILL_VER=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)

# v3.14.11: 收据双写助手——内部收据 + docs 镜像（audit-receipts 全链一致性要求）
# v3.15.1: 收据含 SKILL_TREE（== 当前树；init 冻结值与之相等，见 R19 断言）
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")
mkrc() { # mkrc <feature> <phase> [evidence-file]
  local f="$1" ph="$2" ev="${3:-}" d="$PWD"
  mkdir -p "$d/.devflow/$f/gates/$ph" "$d/docs/$f/gates/$ph"
  if [ -n "$ev" ]; then
    printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=%s\nSKILL_TREE=%s\nEVIDENCE_PATH=%s\nEVIDENCE_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n" \
      "$ph" "$TREE" "$ev" "$(hash_file_test "$d/$ev" 2>/dev/null || true)" > "$d/.devflow/$f/gates/$ph/receipt.txt"
  else
    printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=%s\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n" "$ph" "$TREE" > "$d/.devflow/$f/gates/$ph/receipt.txt"
  fi
  cp "$d/.devflow/$f/gates/$ph/receipt.txt" "$d/docs/$f/gates/$ph/receipt.txt"
}

echo "=== devflow hardening tests (v${SKILL_VER}) ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# v3.28.9: 状态机合成收据无 git 检查点——显式关闭（新门禁在 git-checkpoint/complete 单独验证）
export DEVFLOW_GIT_CHECKPOINT=off
hash_file_test() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

CURRENT_VER=$(sed -n 's/^  version: "\(.*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
[ "$CURRENT_VER" = "$SKILL_VER" ] && ok "release version is $SKILL_VER" || bad "release version is $SKILL_VER (actual=$CURRENT_VER)"

WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" init phase-fixture --frontend=not-applicable >/dev/null
for phase in P2 P2a P2b P6; do
  mkdir -p "$TMP/state/.devflow/phase-fixture/gates/$phase"
  printf "EXIT_CODE=0\nVERSION=g@${SKILL_VER}\nPHASE=%s\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\n" "$phase" "$TREE" > "$TMP/state/.devflow/phase-fixture/gates/$phase/receipt.txt"
done
jq '.current_phase = "P2" | .phases.P0.status = "completed" | .phases.P0b.status = "completed" | .phases.P1.status = "completed" | .phases.P2.status = "in_progress"' "$TMP/state/.devflow/phase-fixture.state.json" > "$TMP/state/state.tmp" && \
  mv "$TMP/state/state.tmp" "$TMP/state/.devflow/phase-fixture.state.json"
if WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" complete phase-fixture P2 >/dev/null && \
   [ "$(jq -r '.current_phase' "$TMP/state/.devflow/phase-fixture.state.json")" = "P2a" ] && \
   WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" complete phase-fixture P2a >/dev/null && \
   [ "$(jq -r '.current_phase' "$TMP/state/.devflow/phase-fixture.state.json")" = "P2b" ] && \
   WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" complete phase-fixture P2b >/dev/null && \
   [ "$(jq -r '.current_phase' "$TMP/state/.devflow/phase-fixture.state.json")" = "P3" ]; then
  ok "state enforces P2 -> P2a -> P2b -> P3"
else
  bad "state enforces P2 -> P2a -> P2b -> P3"
fi

WORKSPACE="$TMP/jump" bash "$ROOT/scripts/devflow-state.sh" init jump-fixture --frontend=not-applicable >/dev/null
mkdir -p "$TMP/jump/.devflow/jump-fixture/gates/P10" "$TMP/jump/.devflow/jump-fixture/feedback"
printf 'feedback\n' > "$TMP/jump/.devflow/jump-fixture/feedback/feedback.md"
jump_sha=$(hash_file_test "$TMP/jump/.devflow/jump-fixture/feedback/feedback.md")
printf "EXIT_CODE=0\nVERSION=p10-feedback@${SKILL_VER}\nPHASE=P10\nEVIDENCE_PATH=.devflow/jump-fixture/feedback/feedback.md\nEVIDENCE_SHA256=%s\n" "$jump_sha" > "$TMP/jump/.devflow/jump-fixture/gates/P10/receipt.txt"
jq '.current_phase = "P10" | .phases.P10.status = "in_progress"' "$TMP/jump/.devflow/jump-fixture.state.json" > "$TMP/jump/state.tmp" && mv "$TMP/jump/state.tmp" "$TMP/jump/.devflow/jump-fixture.state.json"
if WORKSPACE="$TMP/jump" bash "$ROOT/scripts/devflow-state.sh" complete jump-fixture P10 >/dev/null 2>&1; then
  bad "state rejects a direct jump to P10"
else
  ok "state rejects a direct jump to P10"
fi

mkdir -p "$TMP/docs/test" "$TMP/docs/requirements" "$TMP/docs/retrospectives" "$TMP/docs/knowledge" "$TMP/.devflow/foo/feedback" "$TMP/scripts"
cat > "$TMP/docs/test/foo-validation-report.md" <<'EOF'
# Foo PRD 验证报告

## P0 阻断项
P0_BLOCKERS=0
VALIDATION_EVIDENCE=docs/test/foo-evidence.txt
P4_CMD=make p4-verify
P4_RESULTS_PATH=docs/test/foo-p4-results.tsv
EOF
printf 'validation-run\n' > "$TMP/docs/test/foo-evidence.txt"
printf '| M-01-F01-A01 | x |\n' > "$TMP/docs/requirements/foo-acceptance-criteria.md"
# v3.28.4(P1-9)：./scripts/* 自建脚本不再是受信 runner——改用 make（需 Makefile）
cat > "$TMP/Makefile" <<'EOF'
p4-verify:
	printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > docs/test/foo-p4-results.tsv
	printf 'P4 fixture executed\n'
EOF
if (cd "$TMP" && bash "$ROOT/scripts/p4_validation_gate.sh" foo >/dev/null) && \
   [ -f "$TMP/.devflow/foo/gates/P4/receipt.txt" ]; then
  ok "P4 validation gate writes a P4 receipt"
else
  bad "P4 validation gate writes a P4 receipt"
fi
WORKSPACE="$TMP" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null
jq '.current_phase = "P4" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status = "in_progress"' "$TMP/.devflow/foo.state.json" > "$TMP/foo-state.tmp" && \
  mv "$TMP/foo-state.tmp" "$TMP/.devflow/foo.state.json"
printf 'P0_BLOCKERS=9\nVALIDATION_EVIDENCE=deleted\n' > "$TMP/docs/test/foo-validation-report.md"
if WORKSPACE="$TMP" bash "$ROOT/scripts/devflow-state.sh" complete foo P4 >/dev/null 2>&1; then
  bad "state rejects tampered P4 evidence"
else
  ok "state rejects tampered P4 evidence"
fi
# v3.16.8: 还原报告（篡改负向后）——P4 收据 REPORT_SHA256 与报告须一致，
# 供后续 complete foo P10 链复查（verify_evidence_receipt 含 REPORT_PATH 校验，
# v3.16.7 软口径不验 REPORT 曾掩盖此夹具污染）
printf 'P0_BLOCKERS=0
VALIDATION_EVIDENCE=docs/test/foo-evidence.txt
P4_CMD=make p4-verify
P4_RESULTS_PATH=docs/test/foo-p4-results.tsv
' > "$TMP/docs/test/foo-validation-report.md"
if (cd "$TMP" && bash "$ROOT/scripts/p4_validation_gate.sh" foo >/dev/null); then
  ok "P4 evidence is reissued after report recovery"
else
  bad "P4 evidence is reissued after report recovery"
fi

cat > "$TMP/docs/retrospectives/foo-retro.md" <<'EOF'
# Foo 复盘
## 上次遗漏了什么
无。
## 本次新发现
无。
EOF
printf '# Foo 知识分享\n\n- lesson\n- lesson\n- lesson\n' > "$TMP/docs/knowledge/foo-sharing.md"
mkdir -p "$TMP/docs/需求" "$TMP/docs/详细设计"
printf 'clarification\n' > "$TMP/docs/需求/foo-需求澄清.md"
printf 'acceptance\n' > "$TMP/docs/需求/foo-验收点.md"
printf 'design\n' > "$TMP/docs/详细设计/foo-详细设计.md"
printf 'tech-selection\n' > "$TMP/docs/详细设计/foo-设计决策.md"
cat > "$TMP/.devflow/foo/feedback/feedback.md" <<'EOF'
FEEDBACK_ID=FB-001
ROOT_CAUSE=详设未覆盖边界场景
TARGET_FILES=scripts/p2b_demo_gate.sh
DECISION=fix
SCOPE=project
STATUS=PROPOSED
EOF
if (cd "$TMP" && bash "$ROOT/scripts/p10_feedback_gate.sh" foo >/dev/null) && \
   [ -f "$TMP/.devflow/foo/gates/P10/receipt.txt" ]; then
  ok "P10 feedback gate writes a P10 receipt without mutating the skill"
else
  bad "P10 feedback gate writes a P10 receipt without mutating the skill"
fi
jq '.current_phase = "P10" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="completed" | .phases.P7.status="completed" | .phases.P8.status="completed" | .phases.P9.status="completed" | .phases.P10.status = "in_progress"' "$TMP/.devflow/foo.state.json" > "$TMP/foo-state.tmp" && \
  mv "$TMP/foo-state.tmp" "$TMP/.devflow/foo.state.json"
# v3.14.11: complete P10 需完整前置链 P0-P6 + P6-credential（含镜像）
(
  cd "$TMP" || exit 1
  # v3.16.8（N29-P2-1/2）: 契约阶段（P0b/P3b/P3cd/P4b/P5）带 ev（映射硬口径——
  # P4 若已被真实 gate 产出则 continue 跳过，其收据自带绑定）
  for _ph in P0 P1 P2 P2a P2b P3 P6; do
    [ -f ".devflow/foo/gates/$_ph/receipt.txt" ] && continue
    mkrc foo "$_ph"
  done
  mkdir -p docs/test-cases; printf 'test case
' > docs/test-cases/x.md
  for _ph in P0b P3b P3cd P4 P4b P5; do
    [ -f ".devflow/foo/gates/$_ph/receipt.txt" ] && continue
    mkrc foo "$_ph" docs/test-cases/x.md
  done
  mkrc foo P6-credential
  # v3.16.6（N27-P1-3）: P7+ 前置链新增 P6-final/ARCH-PITFALLS 复查——夹具补齐
  # ARCH-PITFALLS 用真实 gate 产物（绑定+证据+镜像，exit 0）
  bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt foo >/dev/null 2>&1 || true
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/foo/final-verification.tsv
  printf 'ENVIRONMENT=staging\n' > .devflow/foo/test-evidence.env
  _FJ=$(jq -cn --arg a ".devflow/foo/final-verification.tsv" --arg b ".devflow/foo/test-evidence.env" '[$a,$b]')
  _FT=$(receipt_evidence_tree .devflow/foo/final-verification.tsv .devflow/foo/test-evidence.env)
  mkdir -p .devflow/foo/gates/P6-final docs/foo/gates/P6-final
  printf "EXIT_CODE=0\nVERSION=p6-final@${SKILL_VER}\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n" "$TREE" "$_FJ" "$_FT" > .devflow/foo/gates/P6-final/receipt.txt
  cp .devflow/foo/gates/P6-final/receipt.txt docs/foo/gates/P6-final/receipt.txt
)
if WORKSPACE="$TMP" bash "$ROOT/scripts/devflow-state.sh" complete foo P10 >/dev/null && \
   [ "$(jq -r '.current_phase' "$TMP/.devflow/foo.state.json")" = "COMPLETED" ]; then
  ok "state consumes the P10 receipt and enters terminal state"
else
  bad "state consumes the P10 receipt and enters terminal state"
fi

WORKSPACE="$TMP/p6" bash "$ROOT/scripts/devflow-state.sh" init p6-fixture --frontend=not-applicable >/dev/null
mkdir -p "$TMP/p6/.devflow/p6-fixture/gates/P6"
printf "EXIT_CODE=0\nVERSION=p6@${SKILL_VER}\nPHASE=P6\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\n" "$TREE" > "$TMP/p6/.devflow/p6-fixture/gates/P6/receipt.txt"
jq '.current_phase = "P6" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status = "in_progress"' "$TMP/p6/.devflow/p6-fixture.state.json" > "$TMP/p6/state.tmp" && \
  mv "$TMP/p6/state.tmp" "$TMP/p6/.devflow/p6-fixture.state.json"
(
  cd "$TMP/p6" || exit 1
  for _ph in P0 P0b P1 P2 P2a P2b P3 P3b P3cd P4 P4b P5; do
    [ -f ".devflow/p6-fixture/gates/$_ph/receipt.txt" ] && continue
    mkrc p6-fixture "$_ph"
  done
  mkdir -p .devflow/p6-fixture/gates/P6-credential docs/p6-fixture/gates/P6-credential
  printf "EXIT_CODE=0\nVERSION=p6-credential@${SKILL_VER}\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=2 FAIL=0 WARN=0\n" "$TREE" > .devflow/p6-fixture/gates/P6-credential/receipt.txt
  cp .devflow/p6-fixture/gates/P6-credential/receipt.txt docs/p6-fixture/gates/P6-credential/receipt.txt
  # v3.16.1: P6-final 终验收据（complete P6 强制组成——devflow-state-complete 同口径）
  # v3.16.5: 补证据绑定（_verify_p6_final 拉平 verify_receipt_evidence 后必需）
  printf 'ID\tSTATUS\nA01\tPASS\n' > .devflow/p6-fixture/final-verification.tsv
  printf 'ENVIRONMENT=staging\n' > .devflow/p6-fixture/test-evidence.env
  _P6FJ=$(jq -cn --arg a ".devflow/p6-fixture/final-verification.tsv" --arg b ".devflow/p6-fixture/test-evidence.env" '[$a,$b]')
  _P6FT=$(receipt_evidence_tree .devflow/p6-fixture/final-verification.tsv .devflow/p6-fixture/test-evidence.env)
  mkdir -p .devflow/p6-fixture/gates/P6-final docs/p6-fixture/gates/P6-final
  printf "EXIT_CODE=0\nVERSION=p6-final@${SKILL_VER}\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n" "$TREE" "$_P6FJ" "$_P6FT" > .devflow/p6-fixture/gates/P6-final/receipt.txt
  cp .devflow/p6-fixture/gates/P6-final/receipt.txt docs/p6-fixture/gates/P6-final/receipt.txt
)
# v3.16.5: complete 须在 workspace 根 cwd 执行——P6-final 相对证据路径（.devflow/...）
# 仅在 workspace 根可解析（T22c/d 同模式；s6 gate 生产路径同样 workspace 根）
if (cd "$TMP/p6" && WORKSPACE="$TMP/p6" bash "$ROOT/scripts/devflow-state.sh" complete p6-fixture P6 >/dev/null) && \
   [ "$(jq -r '.current_phase' "$TMP/p6/.devflow/p6-fixture.state.json")" = "P7" ]; then
  ok "state treats P6 as one receipt-backed phase"
else
  bad "state treats P6 as one receipt-backed phase"
fi

WORKSPACE="$TMP/legacy" bash "$ROOT/scripts/devflow-state.sh" init legacy-fixture --frontend=not-applicable >/dev/null
jq 'del(.phases.P2a,.phases.P2b,.phases.P6) | .phases.P6a = {"name":"单元测试","status":"in_progress","started_at":null,"completed_at":null} | .phases.P2.status = "completed" | .current_phase = "P6a"' "$TMP/legacy/.devflow/legacy-fixture.state.json" > "$TMP/legacy/state.tmp" && \
  mv "$TMP/legacy/state.tmp" "$TMP/legacy/.devflow/legacy-fixture.state.json"
if WORKSPACE="$TMP/legacy" bash "$ROOT/scripts/devflow-state.sh" repair legacy-fixture >/dev/null && \
   jq -e '(.phases | has("P6a") | not) and (.phases | has("P6")) and (.phases.P6.status == "in_progress") and (.current_phase == "P2a")' "$TMP/legacy/.devflow/legacy-fixture.state.json" >/dev/null; then
  ok "repair migrates partial legacy P6 and rewinds missing P2 review evidence"
else
  bad "repair migrates partial legacy P6 and rewinds missing P2 review evidence"
fi

# ---------- v3.15.1: SKILL_TREE 硬门禁负向回归（篡改/缺失/不一致均拒绝） ----------
WTR="$TMP/treegate"
WORKSPACE="$WTR" bash "$ROOT/scripts/devflow-state.sh" init tree-fixture --frontend=not-applicable >/dev/null
jq '.current_phase = "P2" | .phases.P0.status = "completed" | .phases.P0b.status = "completed" | .phases.P1.status = "completed" | .phases.P2.status = "in_progress"' \
  "$WTR/.devflow/tree-fixture.state.json" > "$WTR/s.tmp" && mv "$WTR/s.tmp" "$WTR/.devflow/tree-fixture.state.json"
mk_tree_receipt() { # mk_tree_receipt <skill-tree-value; 空串=缺行>
  mkdir -p "$WTR/.devflow/tree-fixture/gates/P2" "$WTR/docs/tree-fixture/gates/P2"
  if [ -n "$1" ]; then
    printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P2\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\n" "$SKILL_VER" "$1" > "$WTR/.devflow/tree-fixture/gates/P2/receipt.txt"
  else
    printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P2\nARTIFACT_HASH=no-artifacts\n" "$SKILL_VER" > "$WTR/.devflow/tree-fixture/gates/P2/receipt.txt"
  fi
  cp "$WTR/.devflow/tree-fixture/gates/P2/receipt.txt" "$WTR/docs/tree-fixture/gates/P2/receipt.txt"
}
mk_tree_receipt "deadbeef"
if WORKSPACE="$WTR" bash "$ROOT/scripts/devflow-state.sh" complete tree-fixture P2 >/dev/null 2>&1; then
  bad "complete 拒绝篡改的 SKILL_TREE（deadbeef）"
else
  ok "complete 拒绝篡改的 SKILL_TREE（deadbeef）"
fi
mk_tree_receipt ""
if WORKSPACE="$WTR" bash "$ROOT/scripts/devflow-state.sh" complete tree-fixture P2 >/dev/null 2>&1; then
  bad "complete 拒绝缺失 SKILL_TREE 的收据"
else
  ok "complete 拒绝缺失 SKILL_TREE 的收据"
fi
FAKE_TREE=$(printf '1%.0s' $(seq 1 64))
mk_tree_receipt "$FAKE_TREE"
if WORKSPACE="$WTR" bash "$ROOT/scripts/devflow-state.sh" complete tree-fixture P2 >/dev/null 2>&1; then
  bad "complete 拒绝与 state 冻结树不一致的收据树"
else
  ok "complete 拒绝与 state 冻结树不一致的收据树"
fi

# ---------- v3.15.1: migrate-tree 显式迁移链（升级后旧收据凭迁移收据放行） ----------
WMG="$TMP/migtree"
WORKSPACE="$WMG" bash "$ROOT/scripts/devflow-state.sh" init mig-fixture --frontend=not-applicable >/dev/null
OLD_TREE=$(printf 'b%.0s' $(seq 1 64))
jq --arg t "$OLD_TREE" '.scope.skill_tree_sha256 = $t | .current_phase = "P2" | .phases.P0.status = "completed" | .phases.P0b.status = "completed" | .phases.P1.status = "completed" | .phases.P2.status = "in_progress"' \
  "$WMG/.devflow/mig-fixture.state.json" > "$WMG/s.tmp" && mv "$WMG/s.tmp" "$WMG/.devflow/mig-fixture.state.json"
mkdir -p "$WMG/.devflow/mig-fixture/gates/P2" "$WMG/docs/mig-fixture/gates/P2"
printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P2\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\n" "$SKILL_VER" "$TREE" > "$WMG/.devflow/mig-fixture/gates/P2/receipt.txt"
cp "$WMG/.devflow/mig-fixture/gates/P2/receipt.txt" "$WMG/docs/mig-fixture/gates/P2/receipt.txt"
if WORKSPACE="$WMG" bash "$ROOT/scripts/devflow-state.sh" complete mig-fixture P2 >/dev/null 2>&1; then
  bad "skill 升级（冻结树漂移）未迁移时 complete 阻断"
else
  ok "skill 升级（冻结树漂移）未迁移时 complete 阻断"
fi
if WORKSPACE="$WMG" bash "$ROOT/scripts/devflow-state.sh" migrate-tree mig-fixture >/dev/null 2>&1 \
   && [ -f "$WMG/.devflow/mig-fixture/gates/SKILL-TREE-MIGRATION/receipt.txt" ] \
   && [ "$(jq -r '.scope.skill_tree_sha256' "$WMG/.devflow/mig-fixture.state.json")" = "$TREE" ]; then
  ok "migrate-tree 写入迁移收据并更新冻结树"
else
  bad "migrate-tree 写入迁移收据并更新冻结树"
fi
printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P2\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\n" "$SKILL_VER" "$OLD_TREE" > "$WMG/.devflow/mig-fixture/gates/P2/receipt.txt"
cp "$WMG/.devflow/mig-fixture/gates/P2/receipt.txt" "$WMG/docs/mig-fixture/gates/P2/receipt.txt"
if WORKSPACE="$WMG" bash "$ROOT/scripts/devflow-state.sh" complete mig-fixture P2 >/dev/null 2>&1 \
   && [ "$(jq -r '.current_phase' "$WMG/.devflow/mig-fixture.state.json")" = "P2a" ]; then
  ok "旧树收据经 SKILL-TREE-MIGRATION 迁移收据放行"
else
  bad "旧树收据经 SKILL-TREE-MIGRATION 迁移收据放行"
fi

# ---------- v3.15.1: repair 不得覆盖冻结树 hash ----------
WRP="$TMP/repairtree"
WORKSPACE="$WRP" bash "$ROOT/scripts/devflow-state.sh" init rep-fixture --frontend=not-applicable >/dev/null
jq --arg t "$OLD_TREE" '.scope.skill_tree_sha256 = $t' "$WRP/.devflow/rep-fixture.state.json" > "$WRP/s.tmp" && mv "$WRP/s.tmp" "$WRP/.devflow/rep-fixture.state.json"
WORKSPACE="$WRP" bash "$ROOT/scripts/devflow-state.sh" repair rep-fixture >/dev/null 2>&1
if [ "$(jq -r '.scope.skill_tree_sha256' "$WRP/.devflow/rep-fixture.state.json")" = "$OLD_TREE" ]; then
  ok "repair 不覆盖 state 冻结树 hash（原始溯源锚点不可变）"
else
  bad "repair 不覆盖 state 冻结树 hash"
fi

# ---------- v3.15.1: manifest 不可变 + 明细全量校验 ----------
MC="$TMP/man"; rm -rf "$MC"; cp -R "$ROOT" "$MC"; rm -rf "$MC/tests/logs" "$MC/.git" "$MC/.backups" "$MC/_archive" "$MC/scripts/__pycache__"
if [ ! -f "$MC/references/manifest/${SKILL_VER}.json" ]; then
  (cd "$MC" && bash scripts/gen-skill-manifest.sh generate >/dev/null 2>&1) || bad "manifest generate（副本首建）成功"
fi
MANIFEST_FILE="$MC/references/manifest/${SKILL_VER}.json"
MH1=$(hash_file_test "$MANIFEST_FILE")
if (cd "$MC" && bash scripts/gen-skill-manifest.sh generate >/dev/null 2>&1); then
  bad "manifest generate 拒绝同版本覆盖重写"
else
  ok "manifest generate 拒绝同版本覆盖重写"
fi
MH2=$(hash_file_test "$MANIFEST_FILE")
if [ "$MH1" = "$MH2" ]; then
  ok "被拒绝的 generate 不改写既有 manifest"
else
  bad "被拒绝的 generate 改写了 manifest"
fi
jq '.files["README.md"] = "0000000000000000000000000000000000000000000000000000000000000000"' "$MANIFEST_FILE" > "$MANIFEST_FILE.tmp" && mv "$MANIFEST_FILE.tmp" "$MANIFEST_FILE"
if (cd "$MC" && bash scripts/gen-skill-manifest.sh check >/dev/null 2>&1); then
  bad "manifest check 拦截明细哈希篡改"
else
  ok "manifest check 拦截明细哈希篡改"
fi
printf '\n' >> "$MC/README.md"
if (cd "$MC" && bash scripts/gen-skill-manifest.sh check >/dev/null 2>&1); then
  bad "manifest check 拦截树漂移"
else
  ok "manifest check 拦截树漂移"
fi

if (cd "$TMP" && bash "$ROOT/scripts/p3_security_perf_gate.sh" empty-feature >/dev/null 2>&1); then
  bad "P3cd rejects missing security and performance evidence"
else
  ok "P3cd rejects missing security and performance evidence"
fi

mkdir -p "$TMP/p7/docs/deploy" "$TMP/p7/.devflow"
printf '# deploy\n2026-08-24 health\n' > "$TMP/p7/docs/deploy/foo-deploy-record.md"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo >/dev/null 2>&1); then
  bad "P7 rejects a keyword-only deployment record"
else
  ok "P7 rejects a keyword-only deployment record"
fi
WORKSPACE="$TMP/p7" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null
# v3.28.4(P0-1)：P7 gate 机检发布授权收据——正向夹具必须携带有效 release.json
mkdir -p "$TMP/p7/.devflow/foo/authorizations"
printf '{"feature":"foo","target":"staging","authorized_by":"user","authorization_source":"explicit-user-request","authorized_at":"%s","scope":["deploy"]}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP/p7/.devflow/foo/authorizations/release.json"
# v3.14.11: 完整前置链 P0-P6 + P6-credential，内部+docs 镜像双写（audit-receipts 要求）
mkdir -p "$TMP/p7/docs/test-cases"; printf 'test case\n' > "$TMP/p7/docs/test-cases/x.md"
(
  cd "$TMP/p7" || exit 1
  # v3.16.4: P3b 收据须携带证据绑定（audit 新契约 stage+版本判定后强制）
  # v3.16.8（N29-P2-1/2）: P0b/P4b 补绑定（映射表硬口径——三处校验点含链复查）；
  # 本子 shell cwd=$TMP 而 ev 文件原建在 $TMP/p7 下（空哈希→空 SHA 假绑定，
  # v3.16.7 的 rc=3 软口径放行掩盖）——补建 $TMP 侧 ev 文件使哈希真实
  mkdir -p "$TMP/docs/test-cases"; printf 'test case
' > "$TMP/docs/test-cases/x.md"
  for _ph in P1 P2 P2a P2b P3; do mkrc foo "$_ph"; done
  for _ph in P0b P3b P3cd P4 P4b P5 P6; do mkrc foo "$_ph" docs/test-cases/x.md; done
  mkdir -p .devflow/foo/gates/P6-credential docs/foo/gates/P6-credential
  printf "EXIT_CODE=0\nVERSION=p6-credential@${SKILL_VER}\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=2 FAIL=0 WARN=0\n" "$TREE" > .devflow/foo/gates/P6-credential/receipt.txt
  cp .devflow/foo/gates/P6-credential/receipt.txt docs/foo/gates/P6-credential/receipt.txt
)

# v3.14.6/9: 先起本地 health 探测服务，再写部署记录（HEALTH_URL 指向它）
HPF="$TMP/p7/hport"
mkdir -p "$TMP/p7/healthsite"
printf 'ok\n' > "$TMP/p7/healthsite/index.html"
"${DEVFLOW_PY[@]}" - "$HPF" "$TMP/p7/healthsite" >>"$TMP/p7/server.log" 2>&1 <<'PY' &
import http.server, socketserver, sys, os
pf, site = sys.argv[1], sys.argv[2]
os.chdir(site)
class H(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *a): pass
srv = socketserver.ThreadingTCPServer(('127.0.0.1', 0), H)
open(pf, 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
HPID=$!
for _ in $(seq 1 50); do [ -s "$HPF" ] && break; sleep 0.2; done
HPORT=$(cat "$HPF" 2>/dev/null || true)
if [ -z "$HPORT" ]; then
  bad "P7 health 探测服务未启动（HPORT 缺失）——server.log 头部见上方"
  finish EVIDENCE_HARDENING
fi

mkdir -p "$TMP/p7/artifacts"
printf 'artifact\n' > "$TMP/p7/artifacts/foo.bin"
P7_ART_SHA=$(hash_file_test "$TMP/p7/artifacts/foo.bin")
printf 'deploy-run-001\nfinished_at=2026-08-26T12:00:00Z\nartifact_bytes=9\nexit=0\n' > "$TMP/p7/release.out"
# v3.15.1: BUILD_INFO 静态回显文件（含制品 SHA 与部署 ID——绑定运行实例与制品）
printf '{"service":"foo","deployment_id":"deploy-001","artifact_sha256":"%s"}\n' "$P7_ART_SHA" > "$TMP/p7/healthsite/buildinfo.json"
cat > "$TMP/p7/docs/deploy/foo-deploy-record.md" <<EOF
DEPLOYMENT_ID=deploy-001
ARTIFACT_PATH=artifacts/foo.bin
ARTIFACT_SHA256=$P7_ART_SHA
ENVIRONMENT=staging
DEV_PRIVILEGED=false
HEALTH_HTTP_STATUS=200
HEALTH_URL=http://127.0.0.1:$HPORT/
BUILD_INFO_URL=http://127.0.0.1:$HPORT/buildinfo.json
RELEASE_EVIDENCE_PATH=release.out
EOF
printf 'deploy-run-001\nfinished_at=2026-08-26T12:00:00Z\nartifact_bytes=9\nexit=0\n' > "$TMP/p7/release.out"
mv "$TMP/p7/.devflow/foo/authorizations/release.json" "$TMP/p7/.devflow/foo/authorizations/release.json.bak"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo >/dev/null 2>&1); then
  bad "P7 无发布授权收据仍放行（review P0-1）"
else
  ok "P7 缺 release.json 授权收据被拒（review P0-1）"
fi
mv "$TMP/p7/.devflow/foo/authorizations/release.json.bak" "$TMP/p7/.devflow/foo/authorizations/release.json"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo >/dev/null); then
  ok "P7 accepts deployment evidence with identity artifact environment health and build-info binding"
else
  bad "P7 accepts deployment evidence with identity artifact environment health and build-info binding :: $(cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo 2>&1 | grep -E "\[P0\]" | head -2 | tr '\n' ' ')"
fi
# v3.15.1 负向：BUILD_INFO 回显与本制品无关（任意 200 服务不算运行证据）
printf '{"service":"another-app","build":"v0"}\n' > "$TMP/p7/healthsite/buildinfo.json"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo >/dev/null 2>&1); then
  bad "P7 拒绝未回显本制品标识的 BUILD_INFO（任意 200 不构成运行证据）"
else
  ok "P7 拒绝未回显本制品标识的 BUILD_INFO（任意 200 不构成运行证据）"
fi
# v3.15.1 负向：缺失 BUILD_INFO_URL 即阻断（不再 WARN 放行）
grep -v '^BUILD_INFO_URL=' "$TMP/p7/docs/deploy/foo-deploy-record.md" > "$TMP/p7/docs/deploy/foo-deploy-record.md.tmp" && mv "$TMP/p7/docs/deploy/foo-deploy-record.md.tmp" "$TMP/p7/docs/deploy/foo-deploy-record.md"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P7 foo >/dev/null 2>&1); then
  bad "P7 缺失 BUILD_INFO_URL 时阻断"
else
  ok "P7 缺失 BUILD_INFO_URL 时阻断"
fi
# 还原正向部署记录（后续 P8/P9 复用同一 feature 工作区）
printf '{"service":"foo","deployment_id":"deploy-001","artifact_sha256":"%s"}\n' "$P7_ART_SHA" > "$TMP/p7/healthsite/buildinfo.json"
cat > "$TMP/p7/docs/deploy/foo-deploy-record.md" <<EOF
DEPLOYMENT_ID=deploy-001
ARTIFACT_PATH=artifacts/foo.bin
ARTIFACT_SHA256=$P7_ART_SHA
ENVIRONMENT=staging
DEV_PRIVILEGED=false
HEALTH_HTTP_STATUS=200
HEALTH_URL=http://127.0.0.1:$HPORT/
BUILD_INFO_URL=http://127.0.0.1:$HPORT/buildinfo.json
RELEASE_EVIDENCE_PATH=release.out
EOF

# ---------- v3.15.1: P8 证据实质化（正/负） ----------
printf '# HELP foo_request_total requests\n# TYPE foo_request_total counter\nfoo_request_total{op="list"} 12\nfoo_request_total{op="get"} 34\nfoo_request_duration_seconds_count 10\nfoo_request_duration_seconds_sum 0.5\nfoo_error_total 0\nfoo_active_users 3\n' > "$TMP/p7/healthsite/metrics.txt"
cat > "$TMP/p7/log-query-result.txt" <<'EOF'
2026-08-27T10:00:00Z traceId=t1 GET /api/foo/list 200 12ms
2026-08-27T10:00:05Z traceId=t2 GET /api/foo/list 200 8ms
EOF
cat > "$TMP/p7/alert-rules.yml" <<'EOF'
groups:
  - name: foo
    rules:
      - alert: FooHighErrorRate
        expr: rate(foo_error_total[5m]) > 0
        for: 5m
EOF
cat > "$TMP/p7/alert-test-out.txt" <<'EOF'
ALERT_TRIGGERED=foo-high-error-rate fired at 2026-08-27T10:30:00Z (rate=0.06)
NOTIFICATION_CONFIRMED=duty-phone ack by op-owner at 2026-08-27T10:31:00Z
RECOVERY_RECORDED=alert resolved at 2026-08-27T10:45:00Z after rollback
EOF
cat > "$TMP/p7/docs/deploy/foo-monitor-config.md" <<EOF
METRICS_ENDPOINT=http://127.0.0.1:$HPORT/metrics.txt
LOG_QUERY=foo-error-rate-dashboard
LOG_QUERY_EVIDENCE=log-query-result.txt
ALERT_RULE=alert-rules.yml
ALERT_TESTED=PASS
ALERT_TEST_OUTPUT=alert-test-out.txt
EOF
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo >/dev/null 2>&1); then
  ok "P8 accepts real Prometheus samples + log evidence + alert rule file + trigger/notification/recovery records"
else
  bad "P8 accepts real Prometheus samples + log evidence + alert rule file + trigger/notification/recovery records :: $(cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo 2>&1 | grep -E "\[P0\]" | head -3 | tr '\n' ' ')"
fi
# 负向①：空白告警输出文件
: > "$TMP/p7/alert-test-out.txt"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo >/dev/null 2>&1); then
  bad "P8 拒绝空白告警输出文件"
else
  ok "P8 拒绝空白告警输出文件"
fi
# 负向②：输出缺三要素（只记录触发，无通知确认/恢复记录）
printf 'ALERT_TRIGGERED=foo-high-error-rate fired\n' > "$TMP/p7/alert-test-out.txt"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo >/dev/null 2>&1); then
  bad "P8 拒绝缺少通知确认/恢复记录的告警输出"
else
  ok "P8 拒绝缺少通知确认/恢复记录的告警输出"
fi
# 负向③：HELP/TYPE 头但无采样行（伪 Prometheus 内容）
printf '# HELP foo_request_total requests\n# TYPE foo_request_total counter\n' > "$TMP/p7/healthsite/metrics.txt"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo >/dev/null 2>&1); then
  bad "P8 拒绝仅含 HELP/TYPE 头的伪 Prometheus 响应"
else
  ok "P8 拒绝仅含 HELP/TYPE 头的伪 Prometheus 响应"
fi
# 负向④：不可达 metrics 端点（原有回归保持）
cat > "$TMP/p7/docs/deploy/foo-monitor-config.md" <<'EOF'
METRICS_ENDPOINT=https://example.test/metrics
LOG_QUERY=dashboard-log-query
ALERT_RULE=alert-rule-001
ALERT_TESTED=PASS
EOF
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P8 foo >/dev/null 2>&1); then
  bad "P8 rejects a nonexistent metrics endpoint"
else
  ok "P8 rejects a nonexistent metrics endpoint"
fi

# ---------- v3.15.1: P9 语义章节 + 目标哈希（正/负） ----------
mkdir -p "$TMP/p7/docs/guides"
cat > "$TMP/p7/docs/guides/user.md" <<'EOF'
# foo 用户指南

## 快速开始
本节说明 foo 功能的使用步骤。
步骤一：使用账号登录系统。
步骤二：进入 foo 查询页面。
步骤三：填写条件并提交查询。

## 常见问题
使用过程中遇到报错时请联系管理员处理。
EOF
cat > "$TMP/p7/docs/guides/developer.md" <<'EOF'
# foo 开发指南

## 本地构建
本节说明开发环境的搭建与构建流程。
步骤一：安装 JDK 17 与 Node 20。
步骤二：执行 mvn clean package 打包后端。
步骤三：执行 npm run build 构建前端。

## 调试
开发调试时开启 trace 级别日志定位问题。
EOF
cat > "$TMP/p7/docs/guides/api.md" <<'EOF'
# foo API 参考

## 接口清单
本节列出 foo 模块对外暴露的全部接口。
GET /api/foo/list 分页查询接口。
POST /api/foo 新增接口。
PUT /api/foo/{id} 更新接口。

## 参数说明
接口参数校验规则与响应结构见下表说明。
EOF
cat > "$TMP/p7/docs/guides/operations.md" <<'EOF'
# foo 运维手册

## 部署与扩容
本节说明 foo 服务的部署拓扑与扩容步骤。
单实例部署：kubectl apply -f deploy/foo.yaml。
扩容操作：调整 replicas 后观察监控大盘。
发布前确认迁移脚本已全部执行完成。

## 告警与故障处置
收到 P0 告警后按 runbook 执行故障处置流程。
处置完成后须回写故障时间线记录。
EOF
cat > "$TMP/p7/docs/guides/release.md" <<'EOF'
# foo 发布说明

## 本版本变更
本节记录 foo 本次交付的变更内容。
新增 foo 分页查询功能与权限控制。
修复历史遗留的空指针缺陷。
调整了接口分页参数的默认取值。

## 已知问题
当前版本暂不支持导出能力，下版本规划发布。
导出能力的兼容方案正在评审中。
EOF
cat > "$TMP/p7/docs/foo-docs-index.md" <<EOF
USER_DOC=docs/guides/user.md
USER_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/user.md")
DEVELOPER_DOC=docs/guides/developer.md
DEVELOPER_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/developer.md")
API_DOC=docs/guides/api.md
API_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/api.md")
OPERATIONS_DOC=docs/guides/operations.md
OPERATIONS_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/operations.md")
RELEASE_NOTES=docs/guides/release.md
RELEASE_NOTES_SHA256=$(hash_file_test "$TMP/p7/docs/guides/release.md")
EOF
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P9 foo >/dev/null); then
  ok "P9 accepts five substantive semantic documents with verified target hashes"
else
  bad "P9 accepts five substantive semantic documents with verified target hashes :: $(cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P9 foo 2>&1 | grep -E "\[P0\]" | head -3 | tr '\n' ' ')"
fi
# 负向①：占位级文档（标题+line1~4，sha 同步修正后仍须因 placeholder 拦截）
printf '# user\nline1\nline2\nline3\nline4\n' > "$TMP/p7/docs/guides/user.md"
sed "s|^USER_DOC_SHA256=.*|USER_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/user.md")|" "$TMP/p7/docs/foo-docs-index.md" > "$TMP/p7/docs/foo-docs-index.md.tmp" && mv "$TMP/p7/docs/foo-docs-index.md.tmp" "$TMP/p7/docs/foo-docs-index.md"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P9 foo >/dev/null 2>&1); then
  bad "P9 拒绝占位级文档（sha 一致仍拦截）"
else
  ok "P9 拒绝占位级文档（sha 一致仍拦截）"
fi
# 负向②：目标哈希漂移（改文档内容但不更新 index sha）
cat > "$TMP/p7/docs/guides/user.md" <<'EOF'
# foo 用户指南

## 快速开始
本节说明 foo 功能的使用步骤。
步骤一：使用账号登录系统。
步骤二：进入 foo 查询页面。
步骤三：填写条件并提交查询并导出结果。

## 常见问题
使用过程中遇到报错时请联系管理员处理。
EOF
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P9 foo >/dev/null 2>&1); then
  bad "P9 拒绝目标文档哈希漂移"
else
  ok "P9 拒绝目标文档哈希漂移"
fi
# 负向③：缺类别语义章节（重写为不含接口关键词的 substantive 文档并修正 sha）
cat > "$TMP/p7/docs/guides/api.md" <<'EOF'
# foo 内部说明

## 数据结构
本节说明内部数据结构组织方式。
实体 foo 映射数据库表 foo。
字段 id 与 page 均为业务字段。

## 演进计划
后续将补充更多说明内容与示例。
EOF
sed "s|^API_DOC_SHA256=.*|API_DOC_SHA256=$(hash_file_test "$TMP/p7/docs/guides/api.md")|" "$TMP/p7/docs/foo-docs-index.md" > "$TMP/p7/docs/foo-docs-index.md.tmp" && mv "$TMP/p7/docs/foo-docs-index.md.tmp" "$TMP/p7/docs/foo-docs-index.md"
if (cd "$TMP/p7" && bash "$ROOT/scripts/artifact_gate.sh" P9 foo >/dev/null 2>&1); then
  bad "P9 拒绝缺类别语义章节的 API 文档"
else
  ok "P9 拒绝缺类别语义章节的 API 文档"
fi

mkdir -p "$TMP/mini/pages/home" "$TMP/mini-true/pages/home"
printf '{"pages":["pages/home/index"]}\n' > "$TMP/mini/app.json"
printf '<view/>\n' > "$TMP/mini/pages/home/index.wxml"
printf '{"platform":"mini-program","commands":{"build":["./command.sh"],"test":["./command.sh"],"release":["./command.sh"]},"pages":["pages/not-real/index"],"release_evidence":"artifact=a;version=1;location=b"}\n' > "$TMP/mini/devflow-client.json"
printf '{"pages":["pages/home/index"]}\n' > "$TMP/mini-true/app.json"
printf '<view/>\n' > "$TMP/mini-true/pages/home/index.wxml"
printf '{"platform":"mini-program","commands":{"build":["true"],"test":["true"],"release":["true"]},"pages":["pages/home/index"],"release_evidence":"artifact=a;version=1;location=b"}\n' > "$TMP/mini-true/devflow-client.json"
if bash "$ROOT/scripts/client-adapter.sh" validate mini-program "$TMP/mini" --strict >/dev/null 2>&1; then
  bad "mini-program validation rejects manifest/app.json page drift"
else
  ok "mini-program validation rejects manifest/app.json page drift"
fi
if bash "$ROOT/scripts/client-adapter.sh" release mini-program "$TMP/mini-true" --strict >/dev/null 2>&1; then
  bad "client adapter rejects placeholder true release commands"
else
  ok "client adapter rejects placeholder true release commands"
fi

mkdir -p "$TMP/backend/demo/src/main/java/example"
cat > "$TMP/backend/demo/src/main/java/example/FooController.java" <<'EOF'
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
class FooController {
  @PostMapping("/foo")
  public ResponseEntity<Void> create() { return null; }
}
EOF
if (cd "$TMP" && bash "$ROOT/scripts/p3_security_perf_gate.sh" foo --mode security --service backend/demo >/dev/null 2>&1); then
  bad "security gate catches unsecured ResponseEntity write method"
else
  ok "security gate catches unsecured ResponseEntity write method"
fi

mkdir -p "$TMP/entity-copy/devflow"
printf 'stale\n' > "$TMP/entity-copy/devflow/SKILL.md"
if DEVFLOW_COPY_TARGETS="$TMP/entity-copy/devflow" bash "$ROOT/scripts/check-copies.sh" >/dev/null 2>&1; then
  bad "check-copies rejects an entity copy"
else
  [ "$(cat "$TMP/entity-copy/devflow/SKILL.md" 2>/dev/null)" = "stale" ] && ok "check-copies rejects an entity copy (read-only)" || bad "check-copies modified the entity copy"
fi

if bash "$ROOT/hooks/pre-commit-devflow.sh" --self-test >/dev/null 2>&1; then
  ok "pre-commit hook self-test is runnable"
else
  bad "pre-commit hook self-test is runnable"
fi

if grep -q '^MODE="collect"' "$ROOT/maintenance/s8b_feedback_gate.sh" && \
   grep -q 'APPLY_AUTHORIZED' "$ROOT/maintenance/s8b_feedback_gate.sh"; then
  ok "feedback application requires explicit authorization"
else
  bad "feedback application requires explicit authorization"
fi

for template in \
  templates/详细设计-完整版-模板.md \
  templates/详细设计-总分总文档-模板.md \
  templates/详细设计-总分分文档-模板.md; do
  if grep -q '成熟组件复用' "$ROOT/$template" && \
     grep -q '公共服务与公共组件' "$ROOT/$template"; then
    ok "design template carries component-reuse/common-extraction sections: $template"
  else
    bad "design template carries component-reuse/common-extraction sections: $template"
  fi
done
# v3.28.1：规范遵循移入技术选型报告（结构化字段+渲染），详设不再含
if grep -q '"standards"' "$ROOT/schemas/tech-selection.schema.json" && \
   grep -q '规范遵循' "$ROOT/scripts/df_render.py"; then
  ok "standards baseline moved to tech-selection report (schema + renderer)"
else
  bad "standards baseline moved to tech-selection report (schema + renderer)"
fi
# v3.28.1：DDR 与数据库迁移移出详设，统一在数据库设计决策模板
if grep -q '设计决策记录（DDR）' "$ROOT/templates/数据库设计决策-模板.md" && \
   grep -q '数据库迁移' "$ROOT/templates/数据库设计决策-模板.md"; then
  ok "db design doc template carries DDR + migration sections"
else
  bad "db design doc template carries DDR + migration sections"
fi

# v3.14.6: 结束前关闭 P7 探测服务（若本轮启动过）
[ -n "${HPID:-}" ] && kill "$HPID" 2>/dev/null || true

# ---------- v3.15.2: 收据契约对齐负向回归（第一轮子 agent 实证绕过全量封堵） ----------

# T1: complete 拒绝 init 基线收据（state-init@ 不构成 Gate 证据，P0 验收不可跳过）
W52="$TMP/v3152a"
WORKSPACE="$W52" bash "$ROOT/scripts/devflow-state.sh" init base52 --frontend=not-applicable >/dev/null 2>&1
if WORKSPACE="$W52" bash "$ROOT/scripts/devflow-state.sh" complete base52 P0 >/dev/null 2>&1; then
  bad "complete 拒绝 init 基线收据（P0 验收不可跳过）"
else
  ok "complete 拒绝 init 基线收据（P0 验收不可跳过）"
fi

# T2: s0 真实格式收据（p0@ + PHASE=P0）可被 complete 消费（正向闭环，防误伤）
W52b="$TMP/v3152b"
WORKSPACE="$W52b" bash "$ROOT/scripts/devflow-state.sh" init gate52 --frontend=not-applicable >/dev/null 2>&1
printf "EXIT_CODE=0\nVERSION=p0@%s\nPHASE=P0\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n" "$SKILL_VER" "$TREE" > "$W52b/.devflow/gate52/gates/P0/receipt.txt"
if WORKSPACE="$W52b" bash "$ROOT/scripts/devflow-state.sh" complete gate52 P0 >/dev/null 2>&1 && \
   [ "$(jq -r '.current_phase' "$W52b/.devflow/gate52.state.json")" = "P0b" ]; then
  ok "s0 格式 Gate 收据（PHASE=P0）可完成 P0（正向闭环）"
else
  bad "s0 格式 Gate 收据（PHASE=P0）可完成 P0"
fi

# T3: reconcile 拒绝基线收据（P0 不被推进）
W53="$TMP/v3152c"
WORKSPACE="$W53" bash "$ROOT/scripts/devflow-state.sh" init rec52 --frontend=not-applicable >/dev/null 2>&1
WORKSPACE="$W53" bash "$ROOT/scripts/devflow-state.sh" reconcile rec52 --apply >/dev/null 2>&1
if [ "$(jq -r '.phases.P0.status' "$W53/.devflow/rec52.state.json")" = "completed" ]; then
  bad "reconcile 拒绝基线收据（P0 不被推进）"
else
  ok "reconcile 拒绝基线收据（P0 不被推进）"
fi

# T4: reconcile --apply 缺 P6-credential 时拒绝推进 P6（此前仅 complete 校验，构成校验洼地）
# v3.15.3: P3cd/P4/P5/P6 收据补 EVIDENCE_PATH/SHA——证据阶段缺 EVIDENCE 会让 reconcile
# 在 P3cd 提前 break，P6-credential 分支从未执行（T4 原夹具是假保护，删除修复代码后仍绿）
W54="$TMP/v3152d"
WORKSPACE="$W54" bash "$ROOT/scripts/devflow-state.sh" init rec56 --frontend=not-applicable >/dev/null 2>&1
printf 'rec56-evidence\n' > "$W54/rec56-ev.txt"
EV54=$(hash_file_test "$W54/rec56-ev.txt")
for _ph in P0 P0b P1 P2 P2a P2b P3 P3b P3cd P4 P4b P5 P6; do
  mkdir -p "$W54/.devflow/rec56/gates/$_ph" "$W54/docs/rec56/gates/$_ph"
  case "$_ph" in
    P3cd|P4|P5|P6)
      printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=%s\nSKILL_TREE=%s\nEVIDENCE_PATH=rec56-ev.txt\nEVIDENCE_SHA256=%s\n" "$SKILL_VER" "$_ph" "$TREE" "$EV54" > "$W54/.devflow/rec56/gates/$_ph/receipt.txt" ;;
    *)
      printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=%s\nSKILL_TREE=%s\n" "$SKILL_VER" "$_ph" "$TREE" > "$W54/.devflow/rec56/gates/$_ph/receipt.txt" ;;
  esac
  cp "$W54/.devflow/rec56/gates/$_ph/receipt.txt" "$W54/docs/rec56/gates/$_ph/receipt.txt"
done
# P6 主收据与 P6-final 均有效，但故意不写 P6-credential（v3.16.1 起 P6-final 同为强制组成）
mkdir -p "$W54/.devflow/rec56/gates/P6-final" "$W54/docs/rec56/gates/P6-final"
printf "EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nPASS=8 FAIL=0 WARN=0\n" "$SKILL_VER" "$TREE" > "$W54/.devflow/rec56/gates/P6-final/receipt.txt"
cp "$W54/.devflow/rec56/gates/P6-final/receipt.txt" "$W54/docs/rec56/gates/P6-final/receipt.txt"
WORKSPACE="$W54" bash "$ROOT/scripts/devflow-state.sh" reconcile rec56 --apply >/dev/null 2>&1
if [ "$(jq -r '.phases.P6.status' "$W54/.devflow/rec56.state.json")" = "completed" ]; then
  bad "reconcile --apply 缺 P6-credential 时拒绝推进 P6"
else
  ok "reconcile --apply 缺 P6-credential 时拒绝推进 P6"
fi

# T5: DEVFLOW_VERSION 运行时篡改被拒绝（版本口径单一事实源 = SKILL.md）
W55="$TMP/v3152e"
mkdir -p "$W55/.devflow/dev52/gates/P0" "$W55/docs/dev52/gates/P0"
printf "EXIT_CODE=0\nVERSION=p0@3.9.0\nPHASE=P0\nSKILL_TREE=%s\n" "$TREE" > "$W55/.devflow/dev52/gates/P0/receipt.txt"
cp "$W55/.devflow/dev52/gates/P0/receipt.txt" "$W55/docs/dev52/gates/P0/receipt.txt"
AUD52=$(cd "$W55" && DEVFLOW_VERSION=3.9.0 bash "$ROOT/scripts/audit-receipts.sh" dev52 .devflow docs 2>&1 || true)
if printf '%s' "$AUD52" | grep -q 'version=p0@3.9.0'; then
  ok "DEVFLOW_VERSION 运行时篡改被拒绝（版本口径单一事实源）"
else
  bad "DEVFLOW_VERSION 运行时篡改被拒绝"
fi

# T6: run-all-checks --only 非法名 fail-closed（此前清空数组后零执行 + 假绿 exit 0）
W57="$TMP/v3152f"; mkdir -p "$W57"
(cd "$W57" && bash "$ROOT/checks/run-all-checks.sh" --only bogus-check >/dev/null 2>&1)
rc52=$?
[ "$rc52" -eq 2 ] && ok "run-all-checks --only 非法名 fail-closed（exit 2）" || bad "run-all-checks --only 非法名 fail-closed（exit=${rc52}）"

# T7: run-all-checks --only 合法子集真正执行（不再零执行假绿）
OUT57=$(cd "$W57" && bash "$ROOT/checks/run-all-checks.sh" --only n+1 2>&1 || true)
if printf '%s' "$OUT57" | grep -q '>>> n+1'; then
  ok "run-all-checks --only 精确执行选中子集（不再零执行假绿）"
else
  bad "run-all-checks --only 精确执行选中子集"
fi

# T8: run-all-checks 参数解析不吞后续 flag（旧逻辑 --only 多 shift 一个参数）
OUT58=$(cd "$W57" && bash "$ROOT/checks/run-all-checks.sh" --only n+1 --no-frontend 2>&1 || true)
if printf '%s' "$OUT58" | grep -q '跳过前端'; then
  ok "run-all-checks 参数解析不再吞后续 flag（--only 与 --no-frontend 共存）"
else
  bad "run-all-checks 参数解析不再吞后续 flag"
fi

# T9: P6-credential 形近版本绕过被拒（版本点号曾是正则通配符，3x15y2 可冒充 3.15.2）
W59="$TMP/v3153a"
WORKSPACE="$W59" bash "$ROOT/scripts/devflow-state.sh" init fakever --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P6" | .phases |= map_values(if . == null or .status == null then . else .status = "completed" end) | .phases.P6.status = "in_progress"' "$W59/.devflow/fakever.state.json" > "$W59/s.tmp" && mv "$W59/s.tmp" "$W59/.devflow/fakever.state.json"
printf 'fakever-ev\n' > "$W59/fakever-ev.txt"
EV59=$(hash_file_test "$W59/fakever-ev.txt")
mkdir -p "$W59/.devflow/fakever/gates/P6"
printf "EXIT_CODE=0\nVERSION=g@%s\nPHASE=P6\nSKILL_TREE=%s\nEVIDENCE_PATH=fakever-ev.txt\nEVIDENCE_SHA256=%s\n" "$SKILL_VER" "$TREE" "$EV59" > "$W59/.devflow/fakever/gates/P6/receipt.txt"
# 3.15.2 -> 3x15y2（点号位置换成形近字符；$var 后跟多字节字符必须花括号——本 skill 自有规则）
FORMVER="${SKILL_VER/./x}"; FORMVER="${FORMVER/./y}"
mkdir -p "$W59/.devflow/fakever/gates/P6-credential" "$W59/docs/fakever/gates/P6-credential"
printf "EXIT_CODE=0\nVERSION=p6-credential@%s\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=2 FAIL=0 WARN=0\n" "$FORMVER" "$TREE" > "$W59/.devflow/fakever/gates/P6-credential/receipt.txt"
cp "$W59/.devflow/fakever/gates/P6-credential/receipt.txt" "$W59/docs/fakever/gates/P6-credential/receipt.txt"
MSG59="${FORMVER} 冒充 ${SKILL_VER} 被拒"
if WORKSPACE="$W59" bash "$ROOT/scripts/devflow-state.sh" complete fakever P6 >/dev/null 2>&1; then
  bad "P6-credential 形近版本绕过被拒 ${MSG59}"
else
  ok "P6-credential 形近版本绕过被拒 ${MSG59}"
fi

# ---------- v3.15.4/v3.23.0: 审查修复回归（P0-1 apply 原子性 / P1 参数校验与同口径 / check-copies 直连口径） ----------

# T10 (v3.23.0): check-copies 检出"指向他处"的软链（直连口径，只读不改动）
W10="$TMP/v323cp"; mkdir -p "$W10/skills" "$W10/other"
ln -s "$W10/other" "$W10/skills/devflow"
OUT10=$(DEVFLOW_COPY_TARGETS="$W10/skills/devflow" bash "$ROOT/scripts/check-copies.sh" 2>&1); rc10=$?
if [ "$rc10" -eq 1 ] && printf '%s' "$OUT10" | grep -q '指向他处'; then
  ok "check-copies 检出指向他处的软链（rc=1）"
else
  bad "check-copies 未检出指向他处的软链（rc=${rc10}）"
fi

# T11 (v3.23.0): check-copies 空目标 fail-closed（不允许零执行"通过"假绿）
OUT11=$(DEVFLOW_COPY_TARGETS="" bash "$ROOT/scripts/check-copies.sh" 2>&1); rc11=$?
if [ "$rc11" -eq 2 ] && ! printf '%s' "$OUT11" | grep -q '通过'; then
  ok "check-copies 空目标 fail-closed（不再零执行假绿）"
else
  bad "check-copies 空目标 fail-closed（exit=${rc11}）"
fi

# T12 (v3.23.0): check-copies 悬空软链结构性错误 fail-closed（rc=2）
W60="$TMP/v323dangling"; mkdir -p "$W60/skills"
ln -s "$W60/nonexistent-target" "$W60/skills/devflow"
OUT60=$(DEVFLOW_COPY_TARGETS="$W60/skills/devflow" bash "$ROOT/scripts/check-copies.sh" 2>&1); rc60=$?
if [ "$rc60" -eq 2 ] && printf '%s' "$OUT60" | grep -q '悬空'; then
  ok "check-copies 悬空软链结构性错误（rc=2）"
else
  bad "check-copies 悬空软链未 fail-closed（rc=${rc60}）"
fi

# T13: s8b/p10 拒绝路径穿越 feature 名（P1-5：../evil 写穿项目外 + grep -E 正则注入）
W61="$TMP/v3154b"; mkdir -p "$W61/nest"
(cd "$W61/nest" && bash "$ROOT/maintenance/s8b_feedback_gate.sh" '../evil' --collect >/dev/null 2>&1); rc13a=$?
(cd "$W61/nest" && bash "$ROOT/scripts/p10_feedback_gate.sh" '../../evil' >/dev/null 2>&1); rc13b=$?
if [ "$rc13a" -eq 2 ] && [ "$rc13b" -eq 2 ] && [ ! -d "$W61/nest/evil" ] && [ ! -d "$TMP/evil" ]; then
  ok "s8b/p10 拒绝路径穿越 feature 名（exit 2 且无越界目录）"
else
  bad "s8b/p10 路径穿越拦截失效（s8b=${rc13a} p10=${rc13b}）"
fi

# T14: s8b patch 失败恢复原文件且不遗留 .rej/.orig（P1-6：.rej 会污染树哈希并经 sync 进副本）
W62="$TMP/v3154c"; FK="$W62/skill"; WD="$W62/work"
mkdir -p "$FK/templates" "$WD/.devflow/t14feat/s8b/diff/templates"
printf 'original line\n' > "$FK/templates/T.md"
printf '# devflow\n' > "$FK/SKILL.md"
printf 'diff --git a/templates/T.md b/templates/T.md\n--- a/templates/T.md\n+++ b/templates/T.md\n@@ -1 +1 @@\n-nonexistent context\n+patched line\n' > "$WD/.devflow/t14feat/s8b/diff/templates/T.md.patch"
(cd "$WD" && SKILL_ROOT="$FK" WORK_DIR=".devflow" bash "$ROOT/maintenance/s8b_feedback_gate.sh" t14feat --apply --authorize-apply --write >/dev/null 2>&1)
if [ "$(cat "$FK/templates/T.md" 2>/dev/null)" = "original line" ] && \
   [ ! -f "$FK/templates/T.md.rej" ] && [ ! -f "$FK/templates/T.md.orig" ]; then
  ok "s8b patch 失败恢复原文件且不遗留 .rej/.orig"
else
  bad "s8b patch 失败遗留 .rej/.orig 或未恢复"
fi

# T15 (v3.23.0): s8b VERIFY_FAILED 回滚源——副本为直连软链自动跟随（apply 原子性闭环）
W63="$TMP/v3154d"; FK2="$W63/skill"; WD2="$W63/work"
mkdir -p "$FK2/templates" "$FK2/tests" "$FK2/scripts" "$WD2/.devflow/t15feat/s8b/diff/templates" "$W63/skills"
printf 'original\n' > "$FK2/templates/T.md"
printf '# devflow\n' > "$FK2/SKILL.md"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FK2/tests/run-tests.sh"
cp "$ROOT/scripts/check-copies.sh" "$FK2/scripts/check-copies.sh"
ln -s "$FK2" "$W63/skills/devflow"
printf 'diff --git a/templates/T.md b/templates/T.md\n--- a/templates/T.md\n+++ b/templates/T.md\n@@ -1 +1,2 @@\n original\n+new line\n' > "$WD2/.devflow/t15feat/s8b/diff/templates/T.md.patch"
(cd "$WD2" && SKILL_ROOT="$FK2" WORK_DIR=".devflow" DEVFLOW_COPY_TARGETS="$W63/skills/devflow" bash "$ROOT/maintenance/s8b_feedback_gate.sh" t15feat --apply --authorize-apply --write >/dev/null 2>&1)
T15SRC=$(cat "$FK2/templates/T.md" 2>/dev/null)
T15CPY=$(cat "$W63/skills/devflow/templates/T.md" 2>/dev/null)
T15ST=$(sed -n 's/^STATUS=//p' "$WD2/.devflow/t15feat/s8b/s8b-apply-receipt.env" 2>/dev/null | head -1)
if [ "$T15SRC" = "original" ] && [ "$T15CPY" = "original" ] && [ "$T15ST" = "VERIFY_FAILED" ]; then
  ok "s8b VERIFY_FAILED 回滚源，副本直连自动跟随（apply 原子性闭环）"
else
  bad "s8b 回滚/副本跟随失效（src=${T15SRC} copy=${T15CPY} status=${T15ST}）"
fi

# T16: p10 拒绝悬挂 STATUS=APPLIED 的 s8b 应用收据（P1-8：文档声称的硬门禁落地）
W64="$TMP/v3154e"
mkdir -p "$W64/docs/retrospectives" "$W64/docs/knowledge" "$W64/.devflow/t16feat/feedback" "$W64/.devflow/t16feat/s8b"
mkdir -p "$W64/docs/需求" "$W64/docs/详细设计"
printf 'clarification\n' > "$W64/docs/需求/t16feat-需求澄清.md"
printf 'acceptance\n' > "$W64/docs/需求/t16feat-验收点.md"
printf 'design\n' > "$W64/docs/详细设计/t16feat-详细设计.md"
printf 'tech-selection\n' > "$W64/docs/详细设计/t16feat-技术选型.md"
printf '## 上次遗漏了什么\nx\n\n## 本次新发现\ny\n' > "$W64/docs/retrospectives/t16feat-retro.md"
printf -- '- a\n- b\n- c\n' > "$W64/docs/knowledge/t16feat-sharing.md"
printf 'FEEDBACK_ID=FB-20260827-001\nSCOPE=project\nSTATUS=PROPOSED\nROOT_CAUSE=x\nTARGET_FILES=a.md\nDECISION=fix\n' > "$W64/.devflow/t16feat/feedback/feedback.md"
printf 'STATUS=APPLIED\n' > "$W64/.devflow/t16feat/s8b/s8b-apply-receipt.env"
if (cd "$W64" && bash "$ROOT/scripts/p10_feedback_gate.sh" t16feat >/dev/null 2>&1); then
  bad "p10 拒绝悬挂 STATUS=APPLIED 的 s8b 收据"
else
  ok "p10 拒绝悬挂 STATUS=APPLIED 的 s8b 收据（verify 闭环强制）"
fi

# T17: pc-web validate 与 mini-program/app 同口径（P1-7：缺 manifest 被拒，含合法 manifest 通过）
W65="$TMP/v3154f"; mkdir -p "$W65/web/tests"
printf '{"scripts":{"build":"true","type-check":"true","test":"true"}}\n' > "$W65/web/package.json"
printf 'export {}\n' > "$W65/web/tests/smoke.test.ts"
if bash "$ROOT/scripts/client-adapter.sh" validate pc-web "$W65/web" >/dev/null 2>&1; then
  bad "pc-web validate 缺 manifest 被拒"
else
  ok "pc-web validate 缺 manifest 被拒（冻结哈希不再被绕过）"
fi
printf '{"platform":"pc-web","commands":{"build":["npm","run","build"],"test":["npm","run","test"],"release":["npm","run","build"]},"pages":["src/App.vue"]}\n' > "$W65/web/devflow-client.json"
if bash "$ROOT/scripts/client-adapter.sh" validate pc-web "$W65/web" >/dev/null 2>&1; then
  ok "pc-web validate 含合法 manifest 通过"
else
  bad "pc-web validate 含合法 manifest 误拒"
fi

# ---- v3.16.3（第 24 轮 N-P3-3）: 行为级负回归——v3.16.1/2 修复此前仅有工件钉 ----
# T17: complete P6 缺 P6-final 收据必须拒绝（M1 变异行为钉）
W64="$TMP/v3163p6f"; WORKSPACE="$W64" bash "$ROOT/scripts/devflow-state.sh" init p63 --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P6" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status = "in_progress"' "$W64/.devflow/p63.state.json" > "$W64/s.tmp" && mv "$W64/s.tmp" "$W64/.devflow/p63.state.json"
mkdir -p "$W64/.devflow/p63/gates/P6" "$W64/docs/p63/gates/P6" "$W64/.devflow/p63/gates/P6-credential" "$W64/docs/p63/gates/P6-credential"
printf "EXIT_CODE=0\nVERSION=p6@${SKILL_VER}\nPHASE=P6\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n" "$TREE" > "$W64/.devflow/p63/gates/P6/receipt.txt"
cp "$W64/.devflow/p63/gates/P6/receipt.txt" "$W64/docs/p63/gates/P6/"
printf "EXIT_CODE=0\nVERSION=p6-credential@${SKILL_VER}\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=2 FAIL=0 WARN=0\n" "$TREE" > "$W64/.devflow/p63/gates/P6-credential/receipt.txt"
cp "$W64/.devflow/p63/gates/P6-credential/receipt.txt" "$W64/docs/p63/gates/P6-credential/"
if WORKSPACE="$W64" bash "$ROOT/scripts/devflow-state.sh" complete p63 P6 >/dev/null 2>&1; then
  bad "complete P6 缺 P6-final 终验收据被拒绝（M1 行为钉）"
else
  ok "complete P6 缺 P6-final 终验收据被拒绝（M1 行为钉）"
fi

# T18: 剥绑定行+删证据后审计必须 FAIL（N-P1-2 行为钉）
W65="$TMP/v3163strip"; mkdir -p "$W65/docs/review" "$W65/docs/detailed-design" "$W65/docs/requirements" "$W65/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W65/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W65/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W65/docs/review/foo-code-review-report.md"
(cd "$W65" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
rm "$W65/docs/review/foo-code-review-report.md"
for _rf in "$W65/.devflow/foo/gates/P3b/receipt.txt" "$W65/docs/foo/gates/P3b/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d' "$_rf"
done
if (cd "$W65" && bash "$ROOT/scripts/audit-receipts.sh" foo .devflow docs >/dev/null 2>&1); then
  bad "剥绑定行+删证据后审计阻断（N-P1-2 行为钉）"
else
  ok "剥绑定行+删证据后审计阻断（N-P1-2 行为钉）"
fi

# T19: --receipt feature 穿越（N-P1-1）——项目外不得写收据
W66="$TMP/v3163trav"; mkdir -p "$W66"
(cd "$W66" && bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt '../../evil66' >/dev/null 2>&1)
if [ -e "$TMP/evil66" ]; then
  bad "arch --receipt 路径穿越被拒绝（N-P1-1 行为钉）"
else
  ok "arch --receipt 路径穿越被拒绝（N-P1-1 行为钉）"
fi

# T20: complete P3b 缺 ARCH-PITFALLS 收据必须拒绝（N-P2-1 接线钉）
W67="$TMP/v3163p3b"; WORKSPACE="$W67" bash "$ROOT/scripts/devflow-state.sh" init p3b3 --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W67/.devflow/p3b3.state.json" > "$W67/s.tmp" && mv "$W67/s.tmp" "$W67/.devflow/p3b3.state.json"
mkdir -p "$W67/.devflow/p3b3/gates/P3b" "$W67/docs/p3b3/gates/P3b"
printf "EXIT_CODE=0\nVERSION=p3b@${SKILL_VER}\nPHASE=P3b\nSKILL_TREE=%s\nPASS=8 FAIL=0 WARN=0\n" "$TREE" > "$W67/.devflow/p3b3/gates/P3b/receipt.txt"
cp "$W67/.devflow/p3b3/gates/P3b/receipt.txt" "$W67/docs/p3b3/gates/P3b/"
if WORKSPACE="$W67" bash "$ROOT/scripts/devflow-state.sh" complete p3b3 P3b >/dev/null 2>&1; then
  bad "complete P3b 缺 ARCH-PITFALLS 收据被拒绝（N-P2-1 接线钉）"
else
  ok "complete P3b 缺 ARCH-PITFALLS 收据被拒绝（N-P2-1 接线钉）"
fi

# T21: 假 jq（exit 127 可执行）生成器必须 exit 2（v3.16.2 结果守卫行为钉）
W68="$TMP/v3163jq"; mkdir -p "$W68/fbj" "$W68/.devflow/foo"
printf '#!/bin/sh\nexit 127\n' > "$W68/fbj/jq"; chmod +x "$W68/fbj/jq"
printf 'ID\tSTATUS\nA01\tPASS\n' > "$W68/.devflow/foo/final-verification.tsv"
printf 'ENVIRONMENT=dev\n' > "$W68/.devflow/foo/test-evidence.env"
_JQ1=$(cd "$W68" && PATH="$W68/fbj:$PATH" bash "$ROOT/scripts/s6_final_verification_gate.sh" foo >/dev/null 2>&1; echo $?)
[ "$_JQ1" = "2" ] && ok "s6-final 假 jq → exit 2（结果守卫钉）" || bad "s6-final 假 jq rc=${_JQ1}（结果守卫钉）"
_JQ2=$(cd "$W68" && PATH="$W68/fbj:$PATH" bash "$ROOT/checks/check-arch-pitfalls.sh" --all --receipt foo >/dev/null 2>&1; echo $?)
[ "$_JQ2" = "2" ] && ok "arch --receipt 假 jq → exit 2（结果守卫钉）" || bad "arch --receipt 假 jq rc=${_JQ2}（结果守卫钉）"

# ---- v3.16.4（第 25 轮）: 行为钉 T22 ----
# T22a: 剥三行（含 PRODUCER_ROLE）+ 删证据 → 审计必须阻断（N25-P1-1 标记升级钉）
W69="$TMP/v3164strip3"; mkdir -p "$W69/docs/review" "$W69/docs/detailed-design" "$W69/docs/requirements" "$W69/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W69/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W69/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W69/docs/review/foo-code-review-report.md"
(cd "$W69" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
rm "$W69/docs/review/foo-code-review-report.md"
for _rf in "$W69/.devflow/foo/gates/P3b/receipt.txt" "$W69/docs/foo/gates/P3b/receipt.txt"; do
  sed -i '' '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d;/^PRODUCER_ROLE=/d' "$_rf" 2>/dev/null || sed -i '/^EVIDENCE_PATHS_JSON=/d;/^EVIDENCE_TREE_SHA256=/d;/^PRODUCER_ROLE=/d' "$_rf"
done
if (cd "$W69" && bash "$ROOT/scripts/audit-receipts.sh" foo .devflow docs >/dev/null 2>&1); then
  bad "剥三行（含 PRODUCER_ROLE）+删证据后审计阻断（N25-P1-1 钉）"
else
  ok "剥三行（含 PRODUCER_ROLE）+删证据后审计阻断（N25-P1-1 钉）"
fi

# T22b: reconcile 缺 ARCH-PITFALLS 推进 P3b 必须拒绝（N25-P1-2 洼地钉）
W70="$TMP/v3164rec"; WORKSPACE="$W70" bash "$ROOT/scripts/devflow-state.sh" init rb4 --frontend=not-applicable >/dev/null 2>&1
for _ph in P0 P0b P1 P2 P2a P2b P3 P3b; do
  mkdir -p "$W70/.devflow/rb4/gates/$_ph" "$W70/docs/rb4/gates/$_ph"
  printf 'EXIT_CODE=0\nVERSION=g@%s\nPHASE=%s\nSKILL_TREE=%s\n' "$SKILL_VER" "$_ph" "$TREE" > "$W70/.devflow/rb4/gates/$_ph/receipt.txt"
  cp "$W70/.devflow/rb4/gates/$_ph/receipt.txt" "$W70/docs/rb4/gates/$_ph/"
done
WORKSPACE="$W70" bash "$ROOT/scripts/devflow-state.sh" reconcile rb4 --apply >/dev/null 2>&1
if [ "$(jq -r '.phases.P3b.status' "$W70/.devflow/rb4.state.json")" = "completed" ]; then
  bad "reconcile 缺 ARCH-PITFALLS 推进 P3b 被拒绝（N25-P1-2 钉）"
else
  ok "reconcile 缺 ARCH-PITFALLS 推进 P3b 被拒绝（N25-P1-2 钉）"
fi

# T22c: 两行伪造 ARCH-PITFALLS 收据 → complete P3b 拒绝（N25-P2-1 契约钉）
# v3.16.5（N26-P3-1）: 隔离化改造——主收据用真实 gate 产物（绑定+证据齐备），
# 唯一变量为 ARCH-PITFALLS 契约（此前无绑定主收据被 L252 主收据守卫先行拦截，
# M3 变异删 ARCH 契约守卫后测试仍全绿——钉不隔离）；workspace 根 cwd 执行
W71="$TMP/v3164fake"; mkdir -p "$W71/docs/review" "$W71/docs/detailed-design" "$W71/docs/requirements" "$W71/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W71/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W71/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W71/docs/review/foo-code-review-report.md"
(cd "$W71" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
WORKSPACE="$W71" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W71/.devflow/foo.state.json" > "$W71/s.tmp" && mv "$W71/s.tmp" "$W71/.devflow/foo.state.json"
printf 'EXIT_CODE=0\nPHASE=ARCH-PITFALLS\n' > "$W71/.devflow/foo/gates/ARCH-PITFALLS/receipt.txt"
cp "$W71/.devflow/foo/gates/ARCH-PITFALLS/receipt.txt" "$W71/docs/foo/gates/ARCH-PITFALLS/"
if (cd "$W71" && WORKSPACE="$W71" bash "$ROOT/scripts/devflow-state.sh" complete foo P3b >/dev/null 2>&1); then
  bad "两行伪造 ARCH-PITFALLS 收据被拒（N25-P2-1 契约钉，隔离化）"
else
  ok "两行伪造 ARCH-PITFALLS 收据被拒（N25-P2-1 契约钉，隔离化）"
fi

# T22d: 删 P3b 绑定证据 → complete P3b 拒绝（N25-P2-2 重验钉）
# v3.16.5（N26-P3-1）: 隔离化改造——ARCH-PITFALLS 用真实 gate 产物（合法），
# 唯一变量为主收据证据删除（此前 skill 根 cwd 使相对证据路径恒不可解析，被
# 侧翼守卫垫背，M4 变异后测试仍全绿）
W72="$TMP/v3164del"; mkdir -p "$W72/docs/review" "$W72/docs/detailed-design" "$W72/docs/requirements" "$W72/backend/svc/src/main/java"
printf '# d\nM-01-F01-A01\n' > "$W72/docs/detailed-design/foo-design.md"
printf '# c\nM-01-F01-A01\n' > "$W72/docs/requirements/foo-acceptance-criteria.md"
printf '# r\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$W72/docs/review/foo-code-review-report.md"
(cd "$W72" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
WORKSPACE="$W72" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P3b" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="in_progress"' "$W72/.devflow/foo.state.json" > "$W72/s.tmp" && mv "$W72/s.tmp" "$W72/.devflow/foo.state.json"
rm "$W72/docs/review/foo-code-review-report.md"
if (cd "$W72" && WORKSPACE="$W72" bash "$ROOT/scripts/devflow-state.sh" complete foo P3b >/dev/null 2>&1); then
  bad "删 P3b 绑定证据后 complete P3b 被拒（N25-P2-2 重验钉，隔离化）"
else
  ok "删 P3b 绑定证据后 complete P3b 被拒（N25-P2-2 重验钉，隔离化）"
fi

# T22f (v3.16.5 → v3.16.6 重写): 删 P6-final 证据 → complete P6 拒绝（N26-P2-1 钉）
# v3.16.6（N27-P3-1）: 修复双重空转——①JSON 与树哈希统一相对口径（此前哈希用绝对
# 路径名、JSON 记相对路径，而 receipt_evidence_tree 把路径名掺入哈希 → 口径分裂致基线
# 恒败）；②基线成功纳入断言（此前仅打印）；③攻击前回滚 state（此前基线推进后二次
# complete 被「阶段顺序」侧翼拦截——修复在否测试都绿，M8 变异存活实证）
W74="$TMP/v3166p6f"; mkdir -p "$W74/.devflow/pf65/gates/P6" "$W74/.devflow/pf65/gates/P6-credential" "$W74/.devflow/pf65/gates/P6-final" "$W74/docs/pf65/gates/P6" "$W74/docs/pf65/gates/P6-credential" "$W74/docs/pf65/gates/P6-final"
printf 'ID\tSTATUS\nA01\tPASS\n' > "$W74/.devflow/pf65/final-verification.tsv"
printf 'ENVIRONMENT=staging\n' > "$W74/.devflow/pf65/test-evidence.env"
WORKSPACE="$W74" bash "$ROOT/scripts/devflow-state.sh" init pf65 --frontend=not-applicable >/dev/null 2>&1
jq '.current_phase = "P6" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status="completed" | .phases.P3d.status="completed" | .phases.P4.status="completed" | .phases.P4b.status="completed" | .phases.P5.status="completed" | .phases.P6.status="in_progress"' "$W74/.devflow/pf65.state.json" > "$W74/s.tmp" && mv "$W74/s.tmp" "$W74/.devflow/pf65.state.json"
printf 'EXIT_CODE=0\nVERSION=p6@%s\nPHASE=P6\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$W74/.devflow/pf65/gates/P6/receipt.txt"
printf 'EXIT_CODE=0\nVERSION=p6-credential@%s\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=2 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$W74/.devflow/pf65/gates/P6-credential/receipt.txt"
# JSON 与树哈希统一相对口径（cd workspace 内计算，与收据记录形式一致）
(cd "$W74" && \
  _P6J=$(jq -cn --arg a ".devflow/pf65/final-verification.tsv" --arg b ".devflow/pf65/test-evidence.env" '[$a,$b]') && \
  _P6T=$(receipt_evidence_tree .devflow/pf65/final-verification.tsv .devflow/pf65/test-evidence.env) && \
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPRODUCER_ROLE=final-verifier\nSESSION_ID=s1\nENVIRONMENT=staging\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_P6J" "$_P6T" > .devflow/pf65/gates/P6-final/receipt.txt && \
  cp .devflow/pf65/gates/P6-final/receipt.txt docs/pf65/gates/P6-final/receipt.txt)
for _ph in P6 P6-credential; do cp "$W74/.devflow/pf65/gates/$_ph/receipt.txt" "$W74/docs/pf65/gates/$_ph/"; done
# 基线：证据齐备 → complete P6 成功且推进 P7（基线失败即测试无效）
if WORKSPACE="$W74" bash "$ROOT/scripts/devflow-state.sh" complete pf65 P6 >/dev/null 2>&1 \
   && [ "$(jq -r '.current_phase' "$W74/.devflow/pf65.state.json")" = "P7" ]; then
  _P6BASE=ok
else
  _P6BASE=bad
fi
# 攻击前回滚 state 到 P6（隔离变量——不回滚则被「阶段顺序」侧翼拦截，断言空转）
jq '.current_phase = "P6" | .phases.P6.status = "in_progress" | .phases.P6.completed_at = null | .phases.P7.status = "pending" | .phases.P7.started_at = null' "$W74/.devflow/pf65.state.json" > "$W74/s.tmp" && mv "$W74/s.tmp" "$W74/.devflow/pf65.state.json"
rm -f "$W74/.devflow/pf65/final-verification.tsv" "$W74/.devflow/pf65/test-evidence.env"
if [ "$_P6BASE" = ok ] && WORKSPACE="$W74" bash "$ROOT/scripts/devflow-state.sh" complete pf65 P6 >/dev/null 2>&1; then
  bad "删 P6-final 证据后 complete P6 被拒（N26-P2-1 钉；基线=${_P6BASE}——基线失败=测试无效）"
else
  ok "删 P6-final 证据后 complete P6 被拒（N26-P2-1 钉；基线=${_P6BASE}）"
fi

# T22g (v3.16.5): EXIT_CODE 值降级+一致篡改 → audit 阻断（N26-P3-2 钉）
W75="$TMP/v3165deg"; WORKSPACE="$W75" bash "$ROOT/scripts/devflow-state.sh" init dg65 --frontend=not-applicable >/dev/null 2>&1
jq '.phases.P3b.status = "completed"' "$W75/.devflow/dg65.state.json" > "$W75/s.tmp" && mv "$W75/s.tmp" "$W75/.devflow/dg65.state.json"
mkdir -p "$W75/.devflow/dg65/gates/P3b" "$W75/docs/dg65/gates/P3b"
# v3.16.6（N27-P3-4）: 夹具纯净化——补证据绑定（使值降级成为唯一 FAIL 变量；
# 此前无绑定行时 audit 同时触发「新契约缺绑定行」FAIL，断言测的是两条守卫的混合）
printf 'ID\tSTATUS\nA01\tPASS\n' > "$W75/.devflow/dg65/final-dg65.tsv"
(cd "$W75" && \
  _DGJ=$(jq -cn --arg a ".devflow/dg65/final-dg65.tsv" '[$a]') && \
  _DGT=$(receipt_evidence_tree .devflow/dg65/final-dg65.tsv) && \
  printf 'EXIT_CODE=0\nVERSION=p3b@%s\nPHASE=P3b\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPASS=8 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$_DGJ" "$_DGT" > .devflow/dg65/gates/P3b/receipt.txt && \
  cp .devflow/dg65/gates/P3b/receipt.txt docs/dg65/gates/P3b/receipt.txt)
for _rf in "$W75/.devflow/dg65/gates/P3b/receipt.txt" "$W75/docs/dg65/gates/P3b/receipt.txt"; do
  sed -i '' 's/^EXIT_CODE=0/EXIT_CODE=1/' "$_rf" 2>/dev/null || sed -i 's/^EXIT_CODE=0/EXIT_CODE=1/' "$_rf"
done
_DEG=$(cd "$W75" && bash "$ROOT/scripts/audit-receipts.sh" dg65 .devflow docs 2>&1)
if printf '%s' "$_DEG" | grep -q '值降级'; then
  ok "EXIT_CODE 值降级+一致篡改被审计阻断（N26-P3-2 钉）"
else
  bad "EXIT_CODE 值降级+一致篡改被审计阻断（N26-P3-2 钉）"
fi

finish EVIDENCE_HARDENING_CORE
