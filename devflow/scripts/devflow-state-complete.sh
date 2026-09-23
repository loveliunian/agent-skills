#!/usr/bin/env bash
# ============================================================
# devflow-state-complete.sh · 状态机「完成/对账」函数库
# ------------------------------------------------------------
# 用途：阶段完成校验（complete）、状态↔收据对账（reconcile）、验收点/快照/准确率/
#       图谱/阻塞项更新。入口分发在本文件尾部；init/checkpoint/resume/status/list/
#       repair/migrate-tree 等生命周期命令见 devflow-state-core.sh。
# 用法（经 devflow-state.sh 分发）：
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" complete <feature> <phase>   # 校验收据并标记完成
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" reconcile <feature> [--apply] # 状态↔收据对账
#   bash "$SKILL_ROOT/scripts/devflow-state.sh" acceptance|snapshot|accuracy|graph|block ...
# ============================================================

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$SCRIPT_DIR/..}"
# v3.16.4: 统一收据契约库——complete/reconcile 的 P3b/ARCH-PITFALLS 证据绑定重验共用
source "$SCRIPT_DIR/devflow_receipt.sh" 2>/dev/null || { echo "[FATAL] devflow_receipt.sh 加载失败" >&2; exit 2; }
WORKSPACE="${WORKSPACE:-$(pwd)}"
STATE_DIR="${STATE_DIR:-$WORKSPACE/.devflow}"
mkdir -p "$STATE_DIR"

# 颜色定义
GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; BLUE='\033[34m'; NC='\033[0m'
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
success(){ echo -e "${GREEN}[OK]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
# ─────────────────────────────────────────────────────────────────────────────

# v3.15.2: P6-credential 收据契约——complete 与 reconcile 共用（防校验洼地）。
# 此前仅 cmd_complete 校验凭证收据，reconcile --apply 推进 P6 时不校验，可越权跳过凭证审计。
# 统一证据契约校验（三处校验点共用）：
# v3.16.9（N30-P3-3）: 映射表 receipt_stage_contract/_stage_ver_ge 已下沉至
# devflow_receipt.sh（单一事实源——audit 剥离检测同源消费，消除两处内联漂移）
#   0 = 通过（绑定齐备且证据一致，或 stage 无契约要求，或低于阈值的 legacy 收据）
#   1 = 阻断（绑定行被剥离 / 证据缺失/篡改/越界 / 版本不可解析）
# new 契约走 verify_receipt_evidence（新旧绑定形式均按 rc=0 通过）；
# old 契约走 verify_evidence_receipt（保留 REPORT_PATH 校验）。
verify_stage_evidence_contract() {
  local receipt="$1" stage="$2"
  # v3.30.4: 阶段必备 *_JSON 绑定行（剥离即拒——与 audit-receipts 同口径，阈值 3.30.0）
  verify_stage_json_binding "$receipt" "$stage" || return 1
  local contract kind threshold ver vernum ge
  contract=$(receipt_stage_contract "$stage")
  [ "$contract" != "none" ] || return 0
  kind="${contract%% *}"; threshold="${contract##* }"
  ver=$(sed -n 's/^VERSION=//p' "$receipt" | head -1)
  vernum="${ver##*@}"
  # 版本不可解析（无 @x.y.z 结构）→ fail-closed
  printf '%s' "$vernum" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' \
    || { error "收据版本不可解析（契约阈值判定失败）: ${ver:-空}（收据 ${receipt}）"; return 1; }
  ge=$(_stage_ver_ge "$vernum" "$threshold")
  if [ "$ge" != "1" ]; then
    # 低于阈值的合法 legacy 收据——渐进放行
    return 0
  fi
  # 阈值以上：绑定行必须存在且验证一致（缺绑定=剥离必拒——N29-P2-3 rc=3 分裂收口）
  # 不吞底层诊断输出（verify_* 的错误详情进 complete/reconcile 输出——断言可定位拦截点）
  case "$kind" in
    new)
      if [ "$stage" = "P4" ]; then
        grep -q '^EVIDENCE_PATHS_JSON=\[' "$receipt" \
          && grep -q '^EVIDENCE_TREE_SHA256=[0-9a-f]\{64\}$' "$receipt" \
          || { error "${stage} 新证据树字段缺失（EVIDENCE_PATHS_JSON/EVIDENCE_TREE_SHA256）: ${receipt}"; return 1; }
      fi
      verify_receipt_evidence "$receipt" \
        || { error "${stage} 收据证据绑定校验失败（证据缺失/被篡改/越界/绑定被剥离）: ${receipt}"; return 1; }
      ;;
    old|old4b)
      verify_evidence_receipt "$receipt" "$stage" \
        || { error "${stage} 收据证据绑定校验失败（证据缺失/被篡改/越界/绑定被剥离）: ${receipt}"; return 1; }
      ;;
  esac
  return 0
}

_verify_p6_credential() {
  local feature="$1" state_file="$2"
  local cred="$STATE_DIR/${feature}/gates/P6-credential/receipt.txt"
  local cred_mirror="${WORKSPACE:-$PWD}/docs/${feature}/gates/P6-credential/receipt.txt"
  local cred_exit cred_ver cred_phase
  if [ ! -f "$cred" ]; then
    error "P6-credential 收据缺失: $cred —— 凭证 Gate 是 P6 的强制组成部分"
    return 1
  fi
  cred_exit=$(grep '^EXIT_CODE=' "$cred" | head -1 | cut -d= -f2 || true)
  [ "$cred_exit" = "0" ] || { error "P6-credential 收据非成功（EXIT_CODE=${cred_exit}）"; return 1; }
  cred_ver=$(grep '^VERSION=' "$cred" | head -1 | cut -d= -f2 || true)
  # v3.15.3: 版本点号必须转义（3.15.2 中 . 是正则通配符，形近版本 3x15y2 可绕过凭证审计）
  local _exp_ver
  _exp_ver=$(devflow_version)
  if ! printf '%s' "$cred_ver" | grep -qE "@${_exp_ver//./\.}$"; then
    error "P6-credential 收据版本不匹配: $cred_ver (expected @$_exp_ver)"
    return 1
  fi
  cred_phase=$(grep '^PHASE=' "$cred" | head -1 | cut -d= -f2 || true)
  [ "$cred_phase" = "P6-credential" ] || { error "P6-credential 收据 PHASE 不匹配: ${cred_phase:-空}"; return 1; }
  grep -qE '^PASS=[0-9]+ FAIL=[0-9]+( WARN=[0-9]+)?$' "$cred" \
    || { error "P6-credential 收据缺少合法 PASS/FAIL/WARN 计数行"; return 1; }
  # v3.15.1: P6-credential 收据同样受 SKILL_TREE 硬门禁约束
  verify_skill_tree_receipt "$cred" "$state_file" || return 1
  if [ ! -f "$cred_mirror" ] || ! cmp -s "$cred" "$cred_mirror"; then
    error "P6-credential 收据 docs 镜像缺失或不一致: $cred_mirror"
    return 1
  fi
  return 0
}

# v3.16.3: ARCH-PITFALLS 收据校验（P3b 强制组成——§6 检查由 p3b 以 --receipt
# 组合产出；缺收据 = 架构陷阱检查未执行，拒绝推进 P3b）
# v3.16.4（N25-P2-1）: 契约对齐 _verify_p6_credential/_verify_p6_final——此前仅查
# EXIT_CODE/PHASE/镜像，两行伪造收据（无 VERSION/SKILL_TREE/绑定）即可放行
_verify_arch_pitfalls() {
  local feature="$1" state_file="$2"
  local arc="$STATE_DIR/${feature}/gates/ARCH-PITFALLS/receipt.txt"
  local arc_mirror="${WORKSPACE:-$PWD}/docs/${feature}/gates/ARCH-PITFALLS/receipt.txt"
  local arc_exit arc_ver arc_phase _exp_ver
  [ -f "$arc" ] || { error "ARCH-PITFALLS 收据缺失: $arc —— 架构陷阱检查是 P3b 的强制组成部分（v3.16.3 起）"; return 1; }
  arc_exit=$(grep '^EXIT_CODE=' "$arc" | head -1 | cut -d= -f2)
  [ "$arc_exit" = "0" ] || { error "ARCH-PITFALLS 收据非成功（EXIT_CODE=${arc_exit:-空}）"; return 1; }
  arc_ver=$(grep '^VERSION=' "$arc" | head -1 | cut -d= -f2)
  [ -n "$arc_ver" ] || { error "ARCH-PITFALLS 收据缺 VERSION 戳"; return 1; }
  _exp_ver=$(devflow_version)
  printf '%s' "$arc_ver" | grep -qE "@${_exp_ver//./\.}$" || { error "ARCH-PITFALLS 收据版本不匹配: $arc_ver (expected @$_exp_ver)"; return 1; }
  arc_phase=$(grep '^PHASE=' "$arc" | head -1 | cut -d= -f2)
  [ "$arc_phase" = "ARCH-PITFALLS" ] || { error "ARCH-PITFALLS 收据 PHASE 不匹配: ${arc_phase:-空}"; return 1; }
  verify_skill_tree_receipt "$arc" "$state_file" || return 1
  # 证据绑定重验（新契约共享函数——证据缺失/篡改/绑定剥离即拒）
  verify_receipt_evidence "$arc" >/dev/null 2>&1 \
    || { error "ARCH-PITFALLS 收据证据绑定校验失败（证据缺失/被篡改/绑定被剥离）: $arc"; return 1; }
  if [ ! -f "$arc_mirror" ] || ! cmp -s "$arc" "$arc_mirror"; then
    error "ARCH-PITFALLS 收据 docs 镜像缺失或不一致: $arc_mirror"; return 1
  fi
  return 0
}

# v3.16.1: P6-final 终验收据校验（与 _verify_p6_credential 同模式）——
# 用户 PoC 复现：零终验证据（final-verification.tsv/test-evidence.env 均缺失）时
# s6_first_pass 80% 过线即可 complete P6 进入 P7，终验 gate 从未被要求。
_verify_p6_final() {
  local feature="$1" state_file="$2"
  local fin="$STATE_DIR/${feature}/gates/P6-final/receipt.txt"
  local fin_mirror="${WORKSPACE:-$PWD}/docs/${feature}/gates/P6-final/receipt.txt"
  local fin_exit fin_ver fin_phase _exp_ver
  if [ ! -f "$fin" ]; then
    error "P6-final 终验收据缺失: $fin —— 部署前终验（FAIL=0+五类测试证据）是 P6 的强制组成部分（v3.16.0 起）"
    return 1
  fi
  fin_exit=$(grep '^EXIT_CODE=' "$fin" | head -1 | cut -d= -f2)
  [ "$fin_exit" = "0" ] || { error "P6-final 终验收据非成功（EXIT_CODE=${fin_exit:-空}）"; return 1; }
  fin_ver=$(grep '^VERSION=' "$fin" | head -1 | cut -d= -f2)
  _exp_ver=$(devflow_version)
  printf '%s' "$fin_ver" | grep -qE "@${_exp_ver//./\.}$" || { error "P6-final 收据版本不匹配: $fin_ver (expected @$_exp_ver)"; return 1; }
  fin_phase=$(grep '^PHASE=' "$fin" | head -1 | cut -d= -f2)
  [ "$fin_phase" = "P6-final" ] || { error "P6-final 收据 PHASE 不匹配: ${fin_phase:-空}"; return 1; }
  verify_skill_tree_receipt "$fin" "$state_file" || return 1
  # v3.16.5（N26-P2-1）: 证据绑定重验——与 _verify_arch_pitfalls 同口径（此前删
  # final-verification.tsv/test-evidence.env 后 complete P6 仍推进 P7；P6 是部署
  # 就绪关口，"删证据后状态机仍推进"与 N25-P2-2 同攻击面）
  verify_receipt_evidence "$fin" >/dev/null 2>&1 \
    || { error "P6-final 收据证据绑定校验失败（证据缺失/被篡改/绑定被剥离）: $fin"; return 1; }
  if [ ! -f "$fin_mirror" ] || ! cmp -s "$fin" "$fin_mirror"; then
    error "P6-final 收据 docs 镜像缺失或不一致: $fin_mirror"; return 1
  fi
  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# v3.28.9（m01-base 复盘·收据防补票）：complete 时把收据哈希钉进 state
# （phases[P].receipt_sha256）；此后任何重跑/改写都会使哈希失配，
# reconcile 与 P7+ 链复查据此检出「阶段完成后收据被改写」。
# 返回 0=通过/未钉（legacy state 无钉）；1=失配（已打印错误）。
_receipt_pinned_ok() { # <state_file> <phase> <receipt_file>
  local state_file="$1" phase="$2" receipt="$3"
  local pinned cur
  pinned=$(jq -r --arg p "$phase" '.phases[$p].receipt_sha256 // empty' "$state_file" 2>/dev/null || true)
  [ -n "$pinned" ] || return 0   # 未钉（legacy/新写入前的过渡）——不阻断
  if [ ! -f "$receipt" ]; then
    error "收据被删除（阶段完成后）：${receipt}（钉定哈希 ${pinned}）"
    return 1
  fi
  cur=$(hash_file "$receipt")
  if [ "$cur" != "$pinned" ]; then
    error "收据在阶段完成后被改写（补票/重跑覆盖）：$receipt"
    echo "  钉定: $pinned"
    echo "  当前: $cur"
    echo "  唯一合法路径：修复问题后按 Gate 契约重跑并走 devflow-state.sh repair/reconcile 显式核销"
    return 1
  fi
  return 0
}

# v3.28.9（m01-base 复盘·收据时序）：收据生成时间必须晚于阶段开始时间——
# 拒绝「阶段开始前就存在的旧收据」复用（收据早于 started_at 即可疑）。
# 返回 0=通过/无法判定（收据无时间行）；1=时序违规。
_receipt_time_ordered() { # <state_file> <phase> <receipt_file>
  local state_file="$1" phase="$2" receipt="$3"
  local rc_time phase_started
  rc_time=$(sed -n 's/^CHECKED_AT=//p' "$receipt" | head -1)
  [ -n "$rc_time" ] || rc_time=$(sed -n 's/^AT=//p' "$receipt" | head -1)
  [ -n "$rc_time" ] || rc_time=$(sed -n 's/^FINISHED_AT=//p' "$receipt" | head -1)
  [ -n "$rc_time" ] || return 0
  phase_started=$(jq -r --arg p "$phase" '.phases[$p].started_at // empty' "$state_file" 2>/dev/null || true)
  [ -n "$phase_started" ] || return 0
  local t_rc t_ph
  t_rc=$(jq -rn --arg t "$rc_time" 'try ($t | fromdateiso8601) catch ""' 2>/dev/null || true)
  t_ph=$(jq -rn --arg t "$phase_started" 'try ($t | fromdateiso8601) catch ""' 2>/dev/null || true)
  { [ -z "$t_rc" ] || [ -z "$t_ph" ]; } && return 0
  if [ "$t_rc" -lt "$t_ph" ]; then
    error "收据时序违规：收据时间 $rc_time 早于阶段开始 ${phase_started}（旧收据复用？）: $receipt"
    return 1
  fi
  return 0
}

# v3.28.9（m01-base 复盘·git 检查点强制）：P2/P3/P6/P10 完成前必须有 git-checkpoint 台账
# 条目（Gate PASS 后运行 scripts/git-checkpoint.sh <feature> <phase>）。
# 豁免：DEVFLOW_GIT_CHECKPOINT=off，或 .devflow/<feature>/skip-log.txt 有对应授权。
_verify_git_checkpoint() { # <feature> <phase>
  local feature="$1" phase="$2"
  if [ "${DEVFLOW_GIT_CHECKPOINT:-on}" = "off" ]; then
    warn "DEVFLOW_GIT_CHECKPOINT=off——git 检查点校验被显式豁免${phase}"
    return 0
  fi
  if [ -f "$STATE_DIR/$feature/skip-log.txt" ] && grep -q "git-checkpoint.*$phase" "$STATE_DIR/$feature/skip-log.txt" 2>/dev/null; then
    warn "git-checkpoint $phase 已在 skip-log 显式授权跳过"
    return 0
  fi
  command -v git >/dev/null 2>&1 || { error "git 不可用——回滚能力是硬要求（m01-base 教训：6.7h 零 commit 无回滚点）"; return 1; }
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { error "非 git 仓库——先 git init；确需豁免：DEVFLOW_GIT_CHECKPOINT=off 或 skip-log 授权"; return 1; }
  local tsv="$STATE_DIR/$feature/git-checkpoints.tsv"
  [ -f "$tsv" ] || { error "缺 git 检查点台账：${tsv}——Gate PASS 后运行 bash '$SKILL_ROOT/scripts/git-checkpoint.sh' $feature $phase"; return 1; }
  local commit
  commit=$(awk -F'\t' -v p="$phase" '$2 == p {print $3; exit}' "$tsv" 2>/dev/null || true)
  [ -n "$commit" ] || { error "台账中无 $phase 的检查点条目——运行 bash '$SKILL_ROOT/scripts/git-checkpoint.sh' $feature $phase"; return 1; }
  [ "$commit" = "no-dirty-files" ] && return 0
  git cat-file -e "${commit}^{commit}" 2>/dev/null || { error "台账指向的 commit 不存在: ${commit}（台账与仓库漂移）"; return 1; }
  return 0
}

# === Complete commands ===
cmd_complete() {
  local feature="$1"
  local phase="$2"
  local state_file
  state_file=$(get_state_file "$feature")
  
  if [ ! -f "$state_file" ]; then
    error "工作流 '$feature' 不存在"
    return 1
  fi
  
  # 只接受状态机中定义的阶段；P3cd 是 P3c/P3d 共用 gate 的兼容别名。
  case "$phase" in
    P0|P0b|P1|P2|P2a|P2b|P3|P3b|P3cd|P4|P4b|P5|P6|P7|P8|P9|P10) ;;
    *)
      error "无效的 phase: $phase (应为状态机定义的阶段，例如 P3cd)"
      return 1
      ;;
  esac

  command -v jq >/dev/null 2>&1 || { error "complete 需要 jq"; return 1; }
  local current_phase
  current_phase=$(jq -r '.current_phase // empty' "$state_file")
  local required_phases=""
  case "$phase" in
    P0) required_phases="" ;;
    P0b) required_phases="P0" ;;
    P1) required_phases="P0 P0b" ;;
    P2) required_phases="P0 P0b P1" ;;
    P2a) required_phases="P0 P0b P1 P2" ;;
    P2b) required_phases="P0 P0b P1 P2 P2a" ;;
    P3) required_phases="P0 P0b P1 P2 P2a P2b" ;;
    P3b) required_phases="P0 P0b P1 P2 P2a P2b P3" ;;
    P3cd) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b" ;;
    P4) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d" ;;
    P4b) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4" ;;
    P5) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b" ;;
    P6) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5" ;;
    P7) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5 P6" ;;
    P8) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5 P6 P7" ;;
    P9) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5 P6 P7 P8" ;;
    P10) required_phases="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5 P6 P7 P8 P9" ;;
  esac
  for required in $required_phases; do
    [ "$(jq -r --arg p "$required" '.phases[$p].status // "pending"' "$state_file")" = "completed" ] || {
      error "前置阶段未完成: ${required}，不能完成 $phase"
      return 1
    }
  done
  if [ "$phase" = "P3cd" ]; then
    case "$current_phase" in P3c|P3d) ;; *) error "阶段顺序错误: 当前为 ${current_phase:-unknown}，不能完成 P3cd"; return 1 ;; esac
  elif [ "$phase" != "$current_phase" ]; then
    error "阶段顺序错误: 当前为 ${current_phase:-unknown}，不能完成 $phase"
    return 1
  fi
  
  # P0-6 修复: Gate 收据检查
  local receipt_file
  receipt_file="$(get_stage_gate_receipt "$feature" "$phase")"
  
  # 检查 Gate 收据存在
  if [ ! -f "$receipt_file" ]; then
    error "Gate 收据不存在: $receipt_file"
    echo "请先运行该阶段的 Gate 再完成: $feature/$phase"
    echo "提示: 运行对应的 audit 或 completion gate 脚本"
    return 1
  fi
  
  # 验证 Gate 退出码
  local gate_exit_code
  gate_exit_code=$(grep "^EXIT_CODE=" "$receipt_file" 2>/dev/null | cut -d= -f2 || true)
  if [ -z "$gate_exit_code" ]; then
    error "Gate 收据格式错误，缺少 EXIT_CODE"
    return 1
  fi
  if [ "$gate_exit_code" != "0" ]; then
    error "Gate 失败，退出码: $gate_exit_code"
    echo "必须修复 Gate 才能完成阶段"
    local gate_output
    gate_output=$(grep "^OUTPUT=" "$receipt_file" | cut -d= -f2- || true)
    [ -n "$gate_output" ] && echo "  Gate 输出: $gate_output"
    return 1
  fi

  # v3.14.6: 全阶段统一收据契约——VERSION 戳必须匹配当前版本、PHASE 必须与完成阶段一致。
  # 此前仅 P3cd/P4/P7-P10 校验，旧版本/错 PHASE 收据可在其余阶段越权推进（负向夹具实证）。
  local rc_version rc_phase expected_ver
  rc_version=$(sed -n 's/^VERSION=//p' "$receipt_file" | head -1)
  rc_phase=$(sed -n 's/^PHASE=//p' "$receipt_file" | head -1)
  expected_ver=$(devflow_version)
  if [ -z "$rc_version" ]; then
    error "Gate 收据缺少 VERSION 戳: $receipt_file"
    return 1
  fi
  if ! printf '%s' "$rc_version" | grep -qE "@${expected_ver//./\\.}$"; then
    error "Gate 收据版本不匹配: $rc_version (expected @$expected_ver)"
    return 1
  fi
  # v3.15.2: 收据来源门禁——state-init 基线收据不是 Gate 证据（P0 验收必须跑真 Gate）。
  # 此前 init 自带的基线收据（state-init@版本 + PHASE=P0 + 当前树）可直接 complete P0，
  # 整体跳过 s0 的验收点检查（负向夹具实证绕过）。
  if printf '%s' "$rc_version" | grep -qE '^state-init@'; then
    error "init 基线收据不构成 Gate 证据: $receipt_file"
    echo "请先运行该阶段的 Gate（P0 = s0_acceptance_gate.sh）生成真实收据"
    return 1
  fi
  local check_phase="$phase"
  case "$check_phase" in P3c|P3d) check_phase="P3cd" ;; esac
  if [ -z "$rc_phase" ]; then
    error "Gate 收据缺少 PHASE 行: $receipt_file"
    return 1
  fi
  if [ "$rc_phase" != "$check_phase" ]; then
    error "Gate 收据 PHASE 不匹配: $rc_phase != $check_phase"
    return 1
  fi

  # v3.15.1: SKILL_TREE 硬门禁（全阶段）——收据必须携带 SKILL_TREE 且等于 state 冻结树；
  # 不一致必须 BLOCKED（唯一放行路径：显式 SKILL-TREE-MIGRATION 迁移收据）
  verify_skill_tree_receipt "$receipt_file" "$state_file" || return 1

  # v3.14.9: P5 收据携带 EVIDENCE_PATH/SHA，纳入强校验白名单（R20 N1）
  # v3.16.8（N29-P2-1/2/3）: 白名单改映射表驱动（P0b/P4b 补入；P3b 软硬口径统一）
  verify_stage_evidence_contract "$receipt_file" "$phase" || return 1

  # v3.28.9: 收据时序——收据时间必须晚于阶段开始（旧收据复用即拒）
  local _pin_phase="$phase"
  case "$_pin_phase" in P3c|P3d) _pin_phase="P3cd" ;; esac
  _receipt_time_ordered "$state_file" "$_pin_phase" "$receipt_file" || return 1

  # v3.28.9: 关键阶段 git 检查点强制（m01-base 教训：全程零 commit 无回滚点）
  case "$phase" in
    P2|P3|P6|P10)
      _verify_git_checkpoint "$feature" "$phase" || return 1
      ;;
  esac

  # v3.14.11: P7-P10 前置收据链完整性——完整覆盖 P0..P6 全部阶段收据存在且 EXIT_CODE=0。
  # （P5-migration 依赖 B/C 场景，state 未冻结场景前无法机械判断，由 audit-receipts 对已存在收据审计）
  if printf '%s' "$phase" | grep -qE '^P[7-9]$|^P10$'; then
    local _pre _prc
    for _pre in P0 P0b P1 P2 P2a P2b P3 P3b P3cd P4 P4b P5 P6; do
      _prc="$(grep '^EXIT_CODE=' "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt" 2>/dev/null | head -1 | cut -d= -f2 || true)"
      if [ ! -f "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt" ] || [ "${_prc:-x}" != "0" ]; then
        error "证据链不完整: 前置阶段 ${_pre} 收据缺失或非成功——拒绝完成 $phase"
        return 1
      fi
      # v3.15.1: 前置链收据同样受 SKILL_TREE 硬门禁约束
      verify_skill_tree_receipt "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt" "$state_file" \
        || { error "证据链 ${_pre} 收据 SKILL_TREE 校验失败——拒绝完成 $phase"; return 1; }
      # v3.16.9（N30-P2-1）: 链收据 VERSION 钉——契约阈值判定以收据自报 VERSION
      # 为输入，「剥离绑定行 + VERSION 降级到阈值以下」双行攻击可绕过 v3.16.8
      # 收口（对齐 _reconcile_receipt_ok 的版本前置与 audit check_versions 口径）
      local _pre_ver _pre_exp
      _pre_ver=$(sed -n 's/^VERSION=//p' "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt" | head -1)
      _pre_exp=$(devflow_version)
      printf '%s' "$_pre_ver" | grep -qE "@${_pre_exp//./\\.}$" \
        || { error "证据链 ${_pre} 收据版本不匹配（自报降级绕过？）: ${_pre_ver:-空} (expected @$_pre_exp)——拒绝完成 $phase"; return 1; }
      # v3.16.7（N28-P2-1）: 主链证据阶段复查证据绑定——此前仅查存在+EXIT_CODE+
      # SKILL_TREE，删 P4 绑定证据后 complete P7 照常推进。
      # v3.16.8（N29-P2-3）: rc=3 放行口收口——链复查与主收据同映射同硬口径
      #（剥离绑定行使收据降级 legacy 绕过复查的 PoC 被拒；P0b/P4b 同步补入）
      if ! verify_stage_evidence_contract "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt" "$_pre"; then
        error "证据链 ${_pre} 证据绑定复查失败（缺失/被篡改/越界/绑定被剥离）——拒绝完成 $phase"
        return 1
      fi
      # v3.28.9: 链收据钉定复查——completed 阶段的收据若在完成后被改写（补票/重跑覆盖），拒绝推进
      if ! _receipt_pinned_ok "$state_file" "$_pre" "$STATE_DIR/${feature}/gates/${_pre}/receipt.txt"; then
        error "证据链 ${_pre} 收据钉定复查失败——拒绝完成 $phase"
        return 1
      fi
    done
    # v3.16.6（N27-P1-3/N27-P2-1）: 辅助收据全契约复查——复用与 complete P3b/P6 同口径
    # 的 _verify_*（此前 P6-credential 仅查文件存在、P6-final/ARCH-PITFALLS 完全不复查：
    # complete P6 后删辅助收据或降级 P6-credential EXIT_CODE，P7+ 照常推进且 audit 零感知，
    # 与 N25-P2-2「删证据后状态机不得推进」矛盾）
    _verify_p6_credential "$feature" "$state_file"       || { error "证据链 P6-credential 复查失败（缺失/被删/契约不符/EXIT_CODE 降级）——拒绝完成 $phase"; return 1; }
    _verify_p6_final "$feature" "$state_file"       || { error "证据链 P6-final 复查失败（终验收据缺失/被删/证据绑定失效）——拒绝完成 $phase"; return 1; }
    _verify_arch_pitfalls "$feature" "$state_file"       || { error "证据链 ARCH-PITFALLS 复查失败（架构陷阱收据缺失/被删/证据绑定失效）——拒绝完成 $phase"; return 1; }
  fi

  # v3.14.9: P6 完成必须同时持有有效的凭证 Gate 收据（防跳过凭证审计）
  # v3.15.2: 契约提取为 _verify_p6_credential（与 reconcile --apply 同口径，防校验洼地）
  if [ "$phase" = "P6" ]; then
    _verify_p6_credential "$feature" "$state_file" || return 1
    # v3.16.1: P6-final 终验（部署前 FAIL=0 + 五类测试证据）同为 P6 强制组成
    _verify_p6_final "$feature" "$state_file" || return 1
  fi
  # v3.16.3: P3b 推进须持有 ARCH-PITFALLS 收据（架构陷阱检查经 p3b --receipt 组合产出）
  if [ "$phase" = "P3b" ]; then
    _verify_arch_pitfalls "$feature" "$state_file" || return 1
  fi
  
  # 验证产物哈希 (仅当收据中有哈希时)
  if grep -q "^ARTIFACT_HASH=" "$receipt_file" 2>/dev/null; then
    local expected_hash
    expected_hash=$(grep "^ARTIFACT_HASH=" "$receipt_file" | cut -d= -f2 || true)
    if [ "$expected_hash" != "no-artifacts" ]; then
      local actual_hash
      actual_hash=$(compute_artifact_hash "$feature" "$phase")
      if [ "$expected_hash" != "$actual_hash" ]; then
        error "产物哈希不匹配"
        echo "  期望: $expected_hash"
        echo "  实际: $actual_hash"
        return 1
      fi
    fi
  fi
  
  # 所有验证通过，更新状态
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  if command -v jq &>/dev/null; then
    # v3.28.9: 收据哈希钉定——complete 时刻的收据内容固化进 state，此后改写即失配
    local _rsha
    _rsha=$(hash_file "$receipt_file")
    # P3cd 是一个 gate 收据，但状态模型仍保留可审计的 P3c/P3d 两个原子阶段。
    # v3.28.9: P3c/P3d 的 started_at 若为 null 一并补齐（m01-base 实测 P3d.started_at=null）。
    if [ "$phase" = "P3cd" ]; then
      jq --arg now "$now" --arg rsha "$_rsha" \
         '.phases.P3c.status = "completed"
          | .phases.P3c.completed_at = $now
          | .phases.P3c.started_at = (.phases.P3c.started_at // $now)
          | .phases.P3d.status = "completed"
          | .phases.P3d.completed_at = $now
          | .phases.P3d.started_at = (.phases.P3d.started_at // $now)
          | .phases.P3c.receipt_sha256 = $rsha
          | .phases.P3d.receipt_sha256 = $rsha
          | .current_phase = "P4"
          | .phases.P4.status = "in_progress"
          | .phases.P4.started_at = $now
          | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "P-Phase P3cd (安全与性能审计) 已标记完成"
      echo "  Gate 验证: 通过 (收据: $receipt_file)"
      echo "  下一个阶段: P4 ($(get_phase_name P4))"
      return 0
    fi

    jq --arg phase "$phase" --arg now "$now" --arg rsha "$_rsha" \
       '.phases[$phase].status = "completed" | .phases[$phase].completed_at = $now
        | .phases[$phase].receipt_sha256 = $rsha' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    
    # 确定下一个 phase
    local next_phase=""
    case "$phase" in
      P0)  next_phase="P0b" ;;
      P0b) next_phase="P1" ;;
      P1)  next_phase="P2" ;;
      P2)  next_phase="P2a" ;;
      P2a) next_phase="P2b" ;;
      P2b) next_phase="P3" ;;
      P3)  next_phase="P3b" ;;
      P3b) next_phase="P3c" ;;
      P3c) next_phase="P3d" ;;
      P3d) next_phase="P4" ;;
      P4)  next_phase="P4b" ;;
      P4b) next_phase="P5" ;;
      P5)  next_phase="P6" ;;
      P6)  next_phase="P7" ;;
      P7)  next_phase="P8" ;;
      P8)  next_phase="P9" ;;
      P9)  next_phase="P10" ;;
      P10) next_phase="COMPLETED" ;;
    esac
    
    if [ "$next_phase" != "COMPLETED" ]; then
      jq --arg next "$next_phase" --arg now "$now" \
         '.current_phase = $next | .phases[$next].status = "in_progress" | .phases[$next].started_at = $now | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    else
      jq --arg now "$now" '.current_phase = "COMPLETED" | .updated_at = $now' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    fi
    
    success "P-Phase $phase ($(get_phase_name "$phase")) 已标记完成"
    echo "  Gate 验证: 通过 (收据: $receipt_file)"
    
    if [ -n "$next_phase" ] && [ "$next_phase" != "COMPLETED" ]; then
      echo "  下一个阶段: $next_phase ($(get_phase_name "$next_phase"))"
    else
      echo "  工作流全部完成!"
    fi
  else
    error "jq 未安装，拒绝用不精确 sed 修改状态；请安装 jq"
    return 1
  fi
}

# Legacy compatibility alias. There is one authoritative phase state machine.
cmd_complete_s() {
  warn "complete-stage/complete-s 已废弃，将转发到主 phase 状态机"
  cmd_complete "$@"
}

# ========== v3.14.0: reconcile — 状态机与收据链对账 ==========
# 背景（code03 教训）：state 停留 P1 而收据已到 P10，"以 state 判定进度"失效。
# gate 收据与 state complete 是两条独立写入路径，必须周期性对账。
# 用法: devflow-state.sh reconcile <feature> [--apply]
#   默认只读报告漂移；--apply 仅自动推进"连续前缀"（前置全 completed 且收据 EXIT_CODE=0），
#   绝不回退或伪造任何状态；state 领先于收据时必须人工修复。
RECONCILE_ORDER="P0 P0b P1 P2 P2a P2b P3 P3b P3c P3d P4 P4b P5 P6 P7 P8 P9 P10"

_reconcile_receipt_path() {
  local feature="$1" phase="$2"
  local dir="$phase"
  case "$phase" in P3c|P3d) dir="P3cd" ;; esac
  echo "$STATE_DIR/${feature}/gates/${dir}/receipt.txt"
}

_reconcile_receipt_ok() {
  # v3.14.1 → v3.15.2: 完整契约校验与 cmd_complete 全面对齐——版本戳、基线收据拒绝、
  # 全阶段 PHASE 匹配（此前仅 7 个证据阶段）、EVIDENCE 哈希。P6-credential 由调用方校验。
  # 口径分裂曾是系统性后门：同一收据在 complete 被拒、在 reconcile 被接受（子 agent 实证）。
  local receipt="$1"
  [ -f "$receipt" ] || return 1
  [ "$(grep '^EXIT_CODE=' "$receipt" 2>/dev/null | head -1 | cut -d= -f2)" = "0" ] || return 1
  local version declared_phase expected_ver
  version=$(sed -n 's/^VERSION=//p' "$receipt" | head -1)
  [ -n "$version" ] || return 1
  # v3.15.2: state-init 基线收据不构成 Gate 证据（与 cmd_complete 同口径）
  printf '%s' "$version" | grep -qE '^state-init@' && return 1
  expected_ver=$(devflow_version)
  printf '%s' "$version" | grep -qE "@${expected_ver//./\\.}$" || return 1
  # v3.15.1: SKILL_TREE 硬门禁（收据树 == state 冻结树，或经迁移收据放行）
  if [ -n "$3" ] && ! verify_skill_tree_receipt "$receipt" "$3" >/dev/null 2>&1; then
    return 1
  fi
  # v3.15.2: PHASE 行全阶段强制（对齐 v3.14.6 全阶段收据契约，消除校验洼地）
  declared_phase=$(sed -n 's/^PHASE=//p' "$receipt" | head -1)
  [ "$declared_phase" = "$2" ] || return 1
  # v3.16.8（N29-P2-1/2/3）: 白名单改映射表驱动（与 cmd_complete/P7+ 链复查
  # 单一事实源——P0b/P4b 补入；三处口径分裂曾是系统性后门）
  verify_stage_evidence_contract "$receipt" "$2" || return 1
  return 0
}

cmd_reconcile() {
  local feature="$1"
  local mode="${2:-}"
  [ "$mode" = "--apply" ] || mode="report"
  local state_file
  state_file=$(get_state_file "$feature")
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "reconcile 需要 jq"; return 1; }

  local phase status receipt drift=0 behind="" ahead=""
  for phase in $RECONCILE_ORDER; do
    status=$(jq -r --arg p "$phase" '.phases[$p].status // "pending"' "$state_file")
    receipt=$(_reconcile_receipt_path "$feature" "$phase")
    local chk="$phase"; case "$chk" in P3c|P3d) chk="P3cd" ;; esac
    if _reconcile_receipt_ok "$receipt" "$chk" "$state_file" && [ "$status" != "completed" ]; then
      behind="$behind $phase"
      drift=$((drift + 1))
    elif ! _reconcile_receipt_ok "$receipt" "$chk" "$state_file" && [ "$status" = "completed" ]; then
      ahead="$ahead $phase"
      drift=$((drift + 1))
    fi
  done

  # v3.30.6: completed 阶段钉复查前移（旧版只在 drift>0 流程内可达——自洽改写无漂移时
  # 钉复查永远不执行[子代理实证]）
  local _pp _pdrift=0
  for _pp in $RECONCILE_ORDER; do
    [ "$(jq -r --arg p "$_pp" '.phases[$p].status // "pending"' "$state_file")" = "completed" ] || continue
    _prcpt=$(_reconcile_receipt_path "$feature" "$_pp")
    _receipt_pinned_ok "$state_file" "$_pp" "$_prcpt" || { _pdrift=1; break; }
  done
  if [ "$_pdrift" -ne 0 ]; then
    error "reconcile: 钉定复查失败（收据完成后被改写）——拒绝继续，须显式核销 (feature=$feature)"
    return 1
  fi
  if [ "$drift" -eq 0 ]; then
    success "reconcile: 状态机与收据链一致（含钉定复查）(feature=$feature)"
    return 0
  fi

  [ -n "$behind" ] && warn "state 落后于收据（有 EXIT_CODE=0 收据但未 completed）:$behind"
  [ -n "$ahead" ] && warn "state 领先于收据（completed 但无有效收据，需人工修复）:$ahead"

  if [ "$mode" != "--apply" ]; then
    echo "提示: 运行 'devflow-state.sh reconcile $feature --apply' 可自动推进连续前缀（只进不退）"
    return 1
  fi

  # --apply: 从头推进连续前缀——每个阶段仅当其收据有效且全部前序已在状态机 completed 时才标记。
  # v3.14.3: 链完整性守卫——已 completed 的阶段其收据也必须有效，否则链条断裂，
  #          拒绝继续推进（防止"删 P0 收据 + 手工置 completed"后 P0b 被越权推进）。
  local now advanced=0 stop=""
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  for phase in $RECONCILE_ORDER; do
    status=$(jq -r --arg p "$phase" '.phases[$p].status // "pending"' "$state_file")
    if [ "$status" = "completed" ]; then
      receipt=$(_reconcile_receipt_path "$feature" "$phase")
      local chk="$phase"; case "$chk" in P3c|P3d) chk="P3cd" ;; esac
      if ! _reconcile_receipt_ok "$receipt" "$chk" "$state_file"; then
        error "链完整性断裂: $phase 状态为 completed 但收据缺失/无效/契约不符——拒绝推进后续阶段（请恢复收据或人工核销该状态）"
        return 1
      fi
      # v3.28.9: 钉定复查——completed 阶段收据在完成后被改写（补票/重跑覆盖）即报漂移
      # v3.30.7: 失配改硬拒（旧版 drift++ 后无消费者，第 2 轮实证可越过失配继续推进）
      _receipt_pinned_ok "$state_file" "$phase" "$receipt" || {
        error "reconcile --apply: ${phase} 收据钉定失配（完成后被改写）——拒绝推进后续阶段，须显式核销"
        return 1
      }
      continue
    fi
    receipt=$(_reconcile_receipt_path "$feature" "$phase")
    local chk="$phase"; case "$chk" in P3c|P3d) chk="P3cd" ;; esac
    if ! _reconcile_receipt_ok "$receipt" "$chk" "$state_file"; then
      stop="$phase"
      break
    fi
    # v3.16.6（N27-P1-3）: P7+ 推进复查辅助收据——对齐 cmd_complete 前置链（此前
    # 删 P6-final/ARCH-PITFALLS 收据或降级 P6-credential 后 reconcile 仍可推进 P7+；
    # P6 分支的辅助校验只在推进 P6 本身时触发，P6 已 completed 后推进 P7 时不复检）
    case "$phase" in
      P7|P8|P9|P10)
        if ! _verify_p6_credential "$feature" "$state_file" 2>/dev/null; then
          error "P6-credential 收据复查失败——reconcile 拒绝推进 $phase"
          stop="$phase"; break
        elif ! _verify_p6_final "$feature" "$state_file" 2>/dev/null; then
          error "P6-final 终验收据复查失败——reconcile 拒绝推进 $phase"
          stop="$phase"; break
        elif ! _verify_arch_pitfalls "$feature" "$state_file" 2>/dev/null; then
          error "ARCH-PITFALLS 收据复查失败——reconcile 拒绝推进 $phase"
          stop="$phase"; break
        fi
        ;;
    esac
    # v3.15.2: P6 推进必须持有有效 P6-credential 收据（对齐 cmd_complete，防 reconcile 越权跳过凭证审计）
    if [ "$phase" = "P6" ]; then
      if ! _verify_p6_credential "$feature" "$state_file" 2>/dev/null; then
        error "P6-credential 收据缺失/无效——reconcile 拒绝推进 P6（凭证 Gate 是 P6 的强制组成部分）"
        stop="$phase"
        break
      elif ! _verify_p6_final "$feature" "$state_file" 2>/dev/null; then
        error "P6-final 终验收据缺失/无效——reconcile 拒绝推进 P6（部署前终验是 P6 的强制组成部分）"
        stop="$phase"
        break
      fi
    fi
    # v3.16.4（N25-P1-2）: P3b 推进须持有有效 ARCH-PITFALLS 收据——对齐
    # cmd_complete 的 P3b 分支（此前仅 complete 校验，reconcile 可越权跳过）
    if [ "$phase" = "P3b" ]; then
      if ! _verify_arch_pitfalls "$feature" "$state_file" 2>/dev/null; then
        error "ARCH-PITFALLS 收据缺失/无效——reconcile 拒绝推进 P3b（架构陷阱检查是 P3b 的强制组成部分）"
        stop="$phase"
        break
      fi
    fi
    # v3.30.6: 推进即写 receipt_sha256 钉（子代理实证：旧版只 complete 写钉，
    # reconcile 推进永久无钉 → 收据自洽改写对所有钉定消费者隐形）
    _rsha_rc=$(hash_file "$receipt")
    if [ "$phase" = "P3c" ] || [ "$phase" = "P3d" ]; then
      jq --arg now "$now" --arg rsha "$_rsha_rc" \
        '.phases.P3c.status = "completed" | .phases.P3c.completed_at = $now
         | .phases.P3c.receipt_sha256 = $rsha | .phases.P3d.receipt_sha256 = $rsha
         | .phases.P3d.status = "completed" | .phases.P3d.completed_at = $now
         | .current_phase = "P4" | .phases.P4.status = "in_progress" | .phases.P4.started_at = $now
         | .updated_at = $now' \
        "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      advanced=$((advanced + 1))
      continue
    else
      jq --arg p "$phase" --arg now "$now" --arg rsha "$_rsha_rc" \
        '.phases[$p].status = "completed" | .phases[$p].completed_at = $now
         | .phases[$p].receipt_sha256 = $rsha | .updated_at = $now' \
        "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    fi
    advanced=$((advanced + 1))
  done

  # 推进 current_phase 到第一个未完成阶段（P3c→P3d 的过渡由上面处理）
  local first_pending=""
  for phase in $RECONCILE_ORDER; do
    [ "$(jq -r --arg p "$phase" '.phases[$p].status // "pending"' "$state_file")" = "completed" ] || { first_pending="$phase"; break; }
  done
  if [ -n "$first_pending" ]; then
    jq --arg next "$first_pending" --arg now "$now" \
      '.current_phase = $next | .phases[$next].status = "in_progress" | .phases[$next].started_at = $now | .updated_at = $now' \
      "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  else
    jq --arg now "$now" '.current_phase = "COMPLETED" | .updated_at = $now' "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
  fi

  success "reconcile --apply: 已按收据链推进 $advanced 个阶段 (feature=$feature)"
  [ -n "$stop" ] && warn "停在 ${stop}：该阶段无有效收据，未推进。state 领先项仍需人工核销"
  return 0
}


# 更新验收点
cmd_acceptance() {
  local feature="$1"
  local action="$2"  # set-count | freeze | complete
  local value="${3:-}"
  local state_file
  state_file=$(get_state_file "$feature")
  
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "acceptance 需要 jq"; return 1; }
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  case "$action" in
    set-count)
      [ -z "$value" ] && { error "set-count 需要指定数量"; return 1; }
      printf '%s' "$value" | grep -qE '^[0-9]+$' || { error "set-count 数量必须为正整数: $value"; return 1; }
      jq --argjson count "$value" --arg now "$now" \
         '.acceptance_criteria.count = $count | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "验收点总数设置为: $value"
      ;;
    freeze)
      local frozen
      frozen=$(jq -r '.acceptance_criteria.count' "$state_file")
      jq --argjson frozen "$frozen" --arg now "$now" \
         '.acceptance_criteria.frozen = $frozen | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "验收点已冻结: $frozen 个"
      ;;
    complete)
      [ -z "$value" ] && { error "complete 需要指定数量"; return 1; }
      printf '%s' "$value" | grep -qE '^[0-9]+$' || { error "complete 数量必须为正整数: $value"; return 1; }
      # v3.26.2: 上界校验——complete 不得超过验收点总数（防统计口径失真）
      local _total
      _total=$(jq -r '.acceptance_criteria.count // 0' "$state_file")
      [ "$value" -le "$_total" ] || { error "complete 数量 ${value} 超过验收点总数 ${_total}"; return 1; }
      jq --argjson complete "$value" --arg now "$now" \
         '.acceptance_criteria.complete = $complete | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "验收点完成数设置为: $value"
      ;;
    inc)
      local current
      current=$(jq -r '.acceptance_criteria.complete' "$state_file")
      # v3.26.2: 上界校验——inc 不得超过验收点总数
      local _total
      _total=$(jq -r '.acceptance_criteria.count // 0' "$state_file")
      [ "$((current + 1))" -le "$_total" ] || { error "inc 后完成数 $((current + 1)) 超过验收点总数 ${_total}"; return 1; }
      jq --argjson next $((current + 1)) --arg now "$now" \
         '.acceptance_criteria.complete = $next | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
      success "验收点完成数: $((current + 1))"
      ;;
    *)
      error "未知 action: $action (支持: set-count, freeze, complete, inc)"
      return 1
      ;;
  esac
}

# 设置首轮快照
cmd_snapshot() {
  local feature="$1"
  local snapshot_path="${2:-}"
  local state_file
  state_file=$(get_state_file "$feature")
  
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "snapshot 需要 jq"; return 1; }
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  if [ -z "$snapshot_path" ]; then
    # 显示当前快照
    jq -r '.first_pass_snapshot | "路径: \(.path // "无")\n准确率: \(.accuracy // "无")\n创建: \(.created_at // "无")"' "$state_file"
  else
    # 设置快照
    jq --arg path "$snapshot_path" --arg now "$now" \
       '.first_pass_snapshot.path = $path | .first_pass_snapshot.created_at = $now | .updated_at = $now' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    success "首轮快照路径已设置: $snapshot_path"
  fi
}

# 更新首轮准确率
cmd_accuracy() {
  local feature="$1"
  local accuracy="${2:-}"
  local state_file
  state_file=$(get_state_file "$feature")
  
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "accuracy 需要 jq"; return 1; }
  
  if [ -z "$accuracy" ]; then
    local current
    current=$(jq -r '.first_pass_snapshot.accuracy' "$state_file")
    echo "当前首轮准确率: ${current:-无}"
  else
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s' "$accuracy" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { error "accuracy 必须为数字: $accuracy"; return 1; }
    # v3.26.2: 范围校验——准确率是百分比指标，须落在 [0,100]
    awk -v a="$accuracy" 'BEGIN{exit !(a+0 >= 0 && a+0 <= 100)}' \
      || { error "accuracy 必须在 0-100 之间: $accuracy"; return 1; }
    jq --argjson accuracy "$accuracy" --arg now "$now" \
       '.first_pass_snapshot.accuracy = $accuracy | .updated_at = $now' \
       "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    success "首轮准确率设置为: $accuracy%"
  fi
}

# 更新图谱状态
cmd_graph() {
  local feature="$1"
  local status="${2:-}"  # unknown | building | ready | healthy | degraded
  local health_score="${3:-}"
  local state_file
  state_file=$(get_state_file "$feature")
  
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "graph 需要 jq"; return 1; }
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  
  if [ -z "$status" ]; then
    jq -r '.graph_index | "状态: \(.status)\n健康分: \(.health_score // "无")\n索引路径: \(.index_path // "无")"' "$state_file"
  else
    if [ -n "$health_score" ]; then
      printf '%s' "$health_score" | grep -qE '^[0-9]+(\.[0-9]+)?$' || { error "health_score 必须为数字: $health_score"; return 1; }
      jq --arg now "$now" --arg status "$status" --argjson score "$health_score" \
         '.graph_index.status = $status | .graph_index.health_score = $score | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    else
      jq --arg now "$now" --arg status "$status" \
         '.graph_index.status = $status | .updated_at = $now' \
         "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"
    fi
    success "图谱状态已更新: $status"
    [ -n "$health_score" ] && echo "  健康分: $health_score"
  fi
}

# 添加阻塞项
cmd_block() {
  local feature="$1"
  local message="${2:-}"
  local state_file
  state_file=$(get_state_file "$feature")
  
  [ -f "$state_file" ] || { error "工作流 '$feature' 不存在"; return 1; }
  [ -z "$message" ] && { error "block 需要指定消息"; return 1; }
  command -v jq >/dev/null 2>&1 || { error "block 需要 jq"; return 1; }
  
  local now
  now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  local block_id
  block_id="block_$(date +%Y%m%d_%H%M%S)_$$"

  jq --arg id "$block_id" --arg msg "$message" --arg now "$now" \
     '.blocks += [{"id": $id, "message": $msg, "created_at": $now}] | .updated_at = $now' \
     "$state_file" > "$state_file.tmp" && mv "$state_file.tmp" "$state_file"

  success "阻塞项已添加: $message"
}

# ===== 入口分发（v3.9.6 修复：此前仅有函数定义无入口，全部命令静默 no-op exit 0）=====
# 依赖 core 的公共函数（get_state_file / get_phase_name / get_stage_name）
# core 入口有 BASH_SOURCE 守卫，source 时只加载函数库不执行命令
# shellcheck source=devflow-state-core.sh
source "$SCRIPT_DIR/devflow-state-core.sh"

# 调用方 devflow-state.sh 转发时 $@ 含子命令本身，故先 shift
case "${1:-help}" in
  complete)                shift; cmd_complete "$@" ;;
  complete-s|complete-stage) shift; cmd_complete_s "$@" ;;
  acceptance)              shift; cmd_acceptance "$@" ;;
  snapshot)                shift; cmd_snapshot "$@" ;;
  accuracy)                shift; cmd_accuracy "$@" ;;
  graph)                   shift; cmd_graph "$@" ;;
  block)                   shift; cmd_block "$@" ;;
  reconcile)               shift; cmd_reconcile "$@" ;;
  help|--help|-h)
    echo "用法: devflow-state.sh {complete|complete-stage|acceptance|snapshot|accuracy|graph|block|reconcile} <feature> <args>"
    ;;
  *)
    echo "ERROR: 未知命令: $1" >&2
    exit 2
    ;;
esac
