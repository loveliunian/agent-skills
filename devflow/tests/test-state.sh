#!/usr/bin/env bash
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== devflow state tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
hash_file_test() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
# v3.14.0: 版本单一事实源，夹具收据版本随 SKILL.md 派生，避免每次发版改测试
SKILL_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
# v3.15.1: 夹具收据须含 SKILL_TREE（== init 冻结树，即当前树）
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")

if command -v jq >/dev/null 2>&1 && \
   WORKSPACE="$TMP/basic" bash "$ROOT/scripts/devflow-state.sh" init state-fixture >/dev/null && \
   # v3.15.2: 基线收据不再构成 P0 证据——夹具写真实 s0 格式 Gate 收据（覆盖 init 基线）
   printf "EXIT_CODE=0\nVERSION=p0@%s\nPHASE=P0\nSKILL_TREE=%s\n" "$SKILL_VER" "$TREE" > "$TMP/basic/.devflow/state-fixture/gates/P0/receipt.txt" && \
   gj_bind_lines state-fixture "$TMP/basic" P0 >> "$TMP/basic/.devflow/state-fixture/gates/P0/receipt.txt" && \
   WORKSPACE="$TMP/basic" bash "$ROOT/scripts/devflow-state.sh" checkpoint state-fixture "P0 passed" >/dev/null && \
   WORKSPACE="$TMP/basic" bash "$ROOT/scripts/devflow-state.sh" complete state-fixture P0 >/dev/null && \
   jq -e '.current_phase == "P0b" and .phases.P0.status == "completed" and .checkpoints[0].note == "P0 passed"' "$TMP/basic/.devflow/state-fixture.state.json" >/dev/null; then
  ok "state preserves checkpoint arguments and advances the main P0 phase"
else
  bad "state preserves checkpoint arguments and advances the main P0 phase"
fi

if command -v jq >/dev/null 2>&1 && \
   WORKSPACE="$TMP/p3cd" bash "$ROOT/scripts/devflow-state.sh" init p3cd-fixture >/dev/null && \
   mkdir -p "$TMP/p3cd/.devflow/p3cd-fixture/gates/P3cd" && \
   printf 'p3cd evidence\n' > "$TMP/p3cd/p3cd-report.md" && \
   printf "EXIT_CODE=0\nVERSION=p3-full@${SKILL_VER}\nPHASE=P3cd\nSKILL_TREE=%s\nARTIFACT_HASH=no-artifacts\nEVIDENCE_PATH=p3cd-report.md\nEVIDENCE_SHA256=%s\n" "$TREE" "$(hash_file_test "$TMP/p3cd/p3cd-report.md")" > "$TMP/p3cd/.devflow/p3cd-fixture/gates/P3cd/receipt.txt" && \
   gj_bind_lines p3cd-fixture "$TMP/p3cd" P3cd >> "$TMP/p3cd/.devflow/p3cd-fixture/gates/P3cd/receipt.txt" && \
   jq '.current_phase = "P3c" | .phases.P0.status="completed" | .phases.P0b.status="completed" | .phases.P1.status="completed" | .phases.P2.status="completed" | .phases.P2a.status="completed" | .phases.P2b.status="completed" | .phases.P3.status="completed" | .phases.P3b.status="completed" | .phases.P3c.status = "in_progress"' "$TMP/p3cd/.devflow/p3cd-fixture.state.json" > "$TMP/p3cd/state.tmp" && \
   mv "$TMP/p3cd/state.tmp" "$TMP/p3cd/.devflow/p3cd-fixture.state.json" && \
   WORKSPACE="$TMP/p3cd" bash "$ROOT/scripts/devflow-state.sh" complete p3cd-fixture P3cd >/dev/null && \
   jq -e '.current_phase == "P4" and .phases.P3c.status == "completed" and .phases.P3d.status == "completed" and (.phases.P3cd | not) and (.phases[""] | not)' "$TMP/p3cd/.devflow/p3cd-fixture.state.json" >/dev/null; then
  ok "P3cd completes composite state without an empty phase"
else
  bad "P3cd completes composite state without an empty phase"
fi

if command -v jq >/dev/null 2>&1 && \
   WORKSPACE="$TMP/repair" bash "$ROOT/scripts/devflow-state.sh" init repair-fixture >/dev/null && \
   mkdir -p "$TMP/repair/.devflow/repair-fixture/gates/P3cd" && \
   printf 'EXIT_CODE=0\nARTIFACT_HASH=no-artifacts\n' > "$TMP/repair/.devflow/repair-fixture/gates/P3cd/receipt.txt" && \
   jq '.phases.P3c.status = "completed" | .phases.P3d.status = "completed" | .phases[""] = {"status":"in_progress"}' "$TMP/repair/.devflow/repair-fixture.state.json" > "$TMP/repair/state.tmp" && \
   mv "$TMP/repair/state.tmp" "$TMP/repair/.devflow/repair-fixture.state.json" && \
   WORKSPACE="$TMP/repair" bash "$ROOT/scripts/devflow-state.sh" repair repair-fixture >/dev/null && \
   jq -e '(.phases | has("") | not)' "$TMP/repair/.devflow/repair-fixture.state.json" >/dev/null; then
  ok "state repair removes historical empty phase"
else
  bad "state repair removes historical empty phase"
fi


# v3.15.13（第 12 轮审查 P1-1）: generate 直调纵深防御负回归——
# devflow-state-template.sh 绕过 dispatcher 直调时，feature/输出路径穿越必须被拒
GENTMP="$TMP/gen"; mkdir -p "$GENTMP/.devflow"
G1=$(cd "$GENTMP" && bash "$ROOT/scripts/devflow-state-template.sh" generate "../evil" P0 "$TMP/pwned1.md" 2>&1); G1RC=$?
if [ "$G1RC" -ne 0 ] && [ ! -f "$TMP/pwned1.md" ]; then
  ok "template generate rejects traversal feature (rc=$G1RC)"; else bad "template generate rejects traversal feature (${G1:-rc=$G1RC})"; fi
G2=$(cd "$GENTMP" && bash "$ROOT/scripts/devflow-state-template.sh" generate foo P0 "$TMP/pwned2.md" 2>&1); G2RC=$?
if [ "$G2RC" -ne 0 ] && [ ! -f "$TMP/pwned2.md" ] && printf '%s' "$G2" | grep -q "越出 workspace"; then
  ok "template generate rejects out-of-workspace output (rc=$G2RC)"; else bad "template generate rejects out-of-workspace output"; fi
G3=$(cd "$GENTMP" && bash "$ROOT/scripts/devflow-state-template.sh" generate foo P0 "../pwned3.md" 2>&1); G3RC=$?
if [ "$G3RC" -ne 0 ] && [ ! -f "$TMP/pwned3.md" ]; then
  ok "template generate rejects ../ relative escape (rc=$G3RC)"; else bad "template generate rejects ../ relative escape (${G3:-rc=$G3RC})"; fi
G4=$(cd "$GENTMP" && bash "$ROOT/scripts/devflow-state-template.sh" generate foo P0 "docs/requirements/foo-clar.md" 2>&1); G4RC=$?
if [ "$G4RC" -eq 0 ] && [ -f "$GENTMP/docs/requirements/foo-clar.md" ]; then
  ok "template generate still works for in-workspace output"; else bad "template generate still works for in-workspace output (${G4:-rc=$G4RC})"; fi

# v3.15.13（第 12 轮审查 P1-2）: checkpoint 假成功负回归——python3 失败时 save
# 必须 exit 1 且不落盘（中断恢复链路拒绝假成功）
CKPT="$TMP/ckpt"; mkdir -p "$CKPT/.devflow" "$CKPT/fakebin"
printf '#!/bin/sh\nexit 127\n' > "$CKPT/fakebin/python3"; chmod +x "$CKPT/fakebin/python3"
C1=$(cd "$CKPT" && PATH="$CKPT/fakebin:$PATH" bash "$ROOT/scripts/checkpoint-state.sh" save foo P3 build 1 2>&1); C1RC=$?
if [ "$C1RC" -ne 0 ] && printf '%s' "$C1" | grep -q "FAILED" && [ ! -f "$CKPT/.devflow/foo/state.json" ]; then
  ok "checkpoint save fails loud when python3 fails (rc=$C1RC)"; else bad "checkpoint save fails loud when python3 fails"; fi
C2=$(cd "$CKPT" && bash "$ROOT/scripts/checkpoint-state.sh" save foo P3 build 0 2>&1); C2RC=$?
# v3.15.22（第 19 轮 P3-2）: resume/list 兄弟分支 fail-closed——死 python3 时
# 不得空输出 rc=0 假成功（save 分支 P1 修复同口径）
if [ "$C2RC" -eq 0 ] && "${DEVFLOW_PY[@]}" -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if len(d["checkpoints"])==1 else 1)' "$CKPT/.devflow/foo/state.json" 2>/dev/null; then
  ok "checkpoint save still works when python3 healthy"; else bad "checkpoint save still works when python3 healthy (${C2:-rc=$C2RC})"; fi
printf '{"feature":"foo","blockers":["x"],"checkpoints":[]}
' > "$CKPT/.devflow/foo/state.json"
CR=$(cd "$CKPT" && PATH="$CKPT/fakebin:$PATH" bash "$ROOT/scripts/checkpoint-state.sh" resume foo 2>&1); CRRC=$?
if [ "$CRRC" -ne 0 ] && printf '%s' "$CR" | grep -q "fail-closed"; then
  ok "checkpoint resume fails loud when python3 fails (rc=$CRRC)"; else bad "checkpoint resume fails loud when python3 fails"; fi
CL=$(cd "$CKPT" && PATH="$CKPT/fakebin:$PATH" bash "$ROOT/scripts/checkpoint-state.sh" list foo 2>&1); CLRC=$?
if [ "$CLRC" -ne 0 ] && printf '%s' "$CL" | grep -q "fail-closed"; then
  ok "checkpoint list fails loud when python3 fails (rc=$CLRC)"; else bad "checkpoint list fails loud when python3 fails"; fi
CRN=$(cd "$CKPT" && bash "$ROOT/scripts/checkpoint-state.sh" resume foo >/dev/null 2>&1; echo $?)
CLN=$(cd "$CKPT" && bash "$ROOT/scripts/checkpoint-state.sh" list foo >/dev/null 2>&1; echo $?)
if [ "$CRN" -eq 0 ] && [ "$CLN" -eq 0 ]; then
  ok "checkpoint resume/list still work when python3 healthy"; else bad "checkpoint resume/list healthy-path broken (resume=$CRN list=$CLN)"; fi

finish STATE
