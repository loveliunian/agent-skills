#!/usr/bin/env bash
# Compare gate outcomes by normalized phase rather than raw receipt filenames.
set -uo pipefail

FEATURE="${1:-}"
STATE_DIR="${2:-.devflow}"
DOCS_DIR="${3:-docs}"
# v3.15.2: 版本单一事实源 = SKILL.md frontmatter——移除 DEVFLOW_VERSION 环境覆盖。
# 运行时变量可让被审计方伪造版本口径（旧版收据设 DEVFLOW_VERSION=<旧版> 即通过），
# 与 complete/reconcile 的 devflow_version() 保持单一口径。
_seen_other_version=0
_has_migration_receipt=0
# v3.27.5: pre-scan 迁移收据（排序无关联——迁移收据可能在排序末尾但需在主循环前生效）
for _mf in "$STATE_DIR"/*/gates/SKILL-TREE-MIGRATION/receipt.txt; do
  [ -f "$_mf" ] && { _has_migration_receipt=1; break; }
done
EXPECTED_VERSION=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
[ -n "$EXPECTED_VERSION" ] || { echo "[FAIL] 无法解析 SKILL.md 版本——版本源读取失败时拒绝审计"; exit 2; }
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature> [state-dir] [docs-dir]"; exit 2; }
# v3.15.12: feature 白名单共享校验——全树最后漏网（读侧：../../evil 会对外部目录 find/
# grep/shasum 信息探测 + 审计对象调包；唯一调用方 artifact_gate.sh 已校验，此处封手动调用）
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh" || { echo "[FAIL] devflow_feature.sh 加载失败" >&2; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
# v3.16.0: 统一收据契约共享库——与 complete/reconcile 共用同一证据校验函数
source "$(cd "$(dirname "$0")" && pwd)/devflow_receipt.sh" || { echo "[FAIL] devflow_receipt.sh 加载失败" >&2; exit 2; }

FAIL=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

normalize_stage() {
  # v3.14.6: 辅助收据（P5-migration/P6-credential）不再归一为主阶段——
  # 防止辅助收据在审计中掩盖主收据缺失。P3-build 与 P3 同证同源，保留归一。
  case "$1" in
    P3-build) echo "P3" ;;
    P3c|P3d) echo "P3cd" ;;
    *) echo "$1" ;;
  esac
}

collect_receipts() {
  local gate_root="$1"
  [ -d "$gate_root" ] || return 0
  find "$gate_root" -type f -name '*receipt*.txt' 2>/dev/null | while IFS= read -r receipt; do
    local stage exit_code
    stage=$(normalize_stage "$(basename "$(dirname "$receipt")")")
    exit_code=$(grep '^EXIT_CODE=' "$receipt" 2>/dev/null | head -1 | cut -d= -f2)
    [ -n "$exit_code" ] || exit_code="MISSING"
    printf '%s\t%s\n' "$stage" "$exit_code"
  done | sort -u
}

collect_receipt_hashes() {
  local root="$1"
  [ -d "$root" ] || return 0
  find "$root" -type f -name '*receipt*.txt' 2>/dev/null | while IFS= read -r receipt; do
    local stage hash
    stage=$(normalize_stage "$(basename "$(dirname "$receipt")")")
    if command -v shasum >/dev/null 2>&1; then hash=$(shasum -a 256 "$receipt" | awk '{print $1}'); else hash=$(sha256sum "$receipt" | awk '{print $1}'); fi
    printf '%s\t%s\t%s\n' "$stage" "$(basename "$receipt")" "$hash"
  done | sort -u
}

# v3.15.1: SKILL_TREE 迁移收据覆盖判定——旧树收据经显式迁移（FROM=收据树, TO=state 冻结树）放行
_tree_migration_covers() {
  local rc_tree="$1" state_tree="$2"
  local mig="$STATE_DIR/$FEATURE/gates/SKILL-TREE-MIGRATION/receipt.txt"
  [ -f "$mig" ] || return 1
  local m_exit m_phase m_from m_to
  m_exit=$(grep '^EXIT_CODE=' "$mig" | head -1 | cut -d= -f2)
  m_phase=$(sed -n 's/^PHASE=//p' "$mig" | head -1)
  m_from=$(sed -n 's/^FROM_TREE=//p' "$mig" | head -1)
  m_to=$(sed -n 's/^TO_TREE=//p' "$mig" | head -1)
  [ "$m_exit" = "0" ] && [ "$m_phase" = "SKILL-TREE-MIGRATION" ] \
    && [ "$m_from" = "$rc_tree" ] && [ "$m_to" = "$state_tree" ]
}

check_versions() {
  local root="$1"
  [ -d "$root" ] || return 0
  # v3.15.1: 树锚点优先级 = state 冻结树 > 当前树（无 state 时以当前树为准）
  local state_tree="" cur_tree="" state_file
  state_file="$STATE_DIR/$FEATURE.state.json"
  if [ -f "$state_file" ]; then
    # v3.16.6（N27-P2-3）: state 存在但不可解析 → fail（此前静默空值降级为仅对当前树的弱校验）
    if ! command -v jq >/dev/null 2>&1; then
      fail "state 文件存在但 jq 缺失——冻结树锚点不可读（fail-closed）: $state_file"
    else
      _ST_RC=0
      state_tree=$(jq -r '.scope.skill_tree_sha256 // empty' "$state_file" 2>/dev/null) || _ST_RC=1
      [ "$_ST_RC" -eq 0 ] || fail "state JSON 不可解析——冻结树锚点失效（fail-closed）: $state_file"
    fi
  fi
  cur_tree=$(bash "$(cd "$(dirname "$0")" && pwd)/gate-skill-tree.sh" 2>/dev/null || true)
  # v3.15.4: 当前树不可得时 fail-closed（哨兵值）——否则无 state 场景下树漂移校验被静默跳过
  [ -n "$cur_tree" ] || cur_tree="__UNAVAILABLE__"
  while IFS= read -r receipt; do
    local version stage
    stage=$(basename "$(dirname "$receipt")")
    version=$(sed -n 's/^VERSION=//p' "$receipt" | head -1)
    # v3.14.0: 无版本戳的收据不再静默跳过（code02/code03 同链 3.9.x/3.13.x 混用教训）
    if [ -z "$version" ]; then
      fail "$(basename "$(dirname "$receipt")")/$(basename "$receipt") missing VERSION stamp"
      continue
    fi
    if ! printf '%s' "$version" | grep -qE "@${EXPECTED_VERSION//./\\.}$"; then
      fail "$(basename "$(dirname "$receipt")") receipt version=$version expected @${EXPECTED_VERSION}"
    fi
    # v3.15.1: SKILL_TREE 硬门禁（从 WARN 升级）——迁移收据自身凭 FROM/TO 记录，豁免 SKILL_TREE 行
    if [ "$stage" = "SKILL-TREE-MIGRATION" ]; then
      _has_migration_receipt=1
      continue
    fi
    local rc_tree
    rc_tree=$(sed -n 's/^SKILL_TREE=//p' "$receipt" | head -1)
    if [ -z "$rc_tree" ] || ! printf '%s' "$rc_tree" | grep -qE '^[0-9a-f]{64}$'; then
      fail "$stage/$(basename "$receipt") missing/invalid SKILL_TREE (v3.15.1 收据契约)"
      continue
    fi
    if [ -n "$state_tree" ]; then
      if [ "$rc_tree" != "$state_tree" ]; then
        if _tree_migration_covers "$rc_tree" "$state_tree"; then
          echo "  [NOTE] $stage 收据树属迁移前旧树，经 SKILL-TREE-MIGRATION 收据放行"
        elif [ "$_has_migration_receipt" = "1" ]; then
          echo "  [NOTE] $stage receipt tree is pre-migration (tracked by SKILL-TREE-MIGRATION)"
        else
          fail "$stage receipt SKILL_TREE mismatch: receipt=$rc_tree state=$state_tree (skill 升级需 devflow-state.sh migrate-tree 显式迁移)"
        fi
      fi
    elif [ "$cur_tree" = "__UNAVAILABLE__" ]; then
      fail "$stage 树漂移校验不可用（gate-skill-tree 计算失败）——fail-closed"
    elif [ "$rc_tree" != "$cur_tree" ]; then
      fail "$stage receipt SKILL_TREE drift vs current tree: receipt=$rc_tree current=$cur_tree"
    fi
  done < <(find "$root" -type f -name '*receipt*.txt' 2>/dev/null)
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
INTERNAL="$TMP_DIR/internal.tsv"
MIRROR="$TMP_DIR/mirror.tsv"
collect_receipts "$STATE_DIR/$FEATURE/gates" > "$INTERNAL"
collect_receipts "$DOCS_DIR/$FEATURE/gates" > "$MIRROR"

INTERNAL_HASHES="$TMP_DIR/internal-hashes.tsv"
MIRROR_HASHES="$TMP_DIR/mirror-hashes.tsv"
collect_receipt_hashes "$STATE_DIR/$FEATURE/gates" > "$INTERNAL_HASHES"
collect_receipt_hashes "$DOCS_DIR/$FEATURE/gates" > "$MIRROR_HASHES"
check_versions "$STATE_DIR/$FEATURE/gates"
# v3.30.6: 钉定复查——state 中 completed 阶段的 receipt_sha256 与收据实哈希对账
# （子代理实证：audit 此前从不读钉，收据+正本+镜像三方自洽改写在 COMPLETED 后永久隐形）
if command -v jq >/dev/null 2>&1 && [ -f "$STATE_DIR/$FEATURE.state.json" ]; then
  while IFS=$'\t' read -r _pstage _ppin; do
    [ -n "$_pstage" ] || continue
    case "$_pstage" in P3c|P3d) _prcpt="$STATE_DIR/$FEATURE/gates/P3cd/receipt.txt" ;;
      *) _prcpt="$STATE_DIR/$FEATURE/gates/${_pstage}/receipt.txt" ;; esac
    if [ ! -f "$_prcpt" ]; then
      fail "pin check: ${_pstage} 已钉定但收据缺失（pin=${_ppin:0:12}…）: $_prcpt"
      continue
    fi
    _pcur=$(hash_file "$_prcpt" 2>/dev/null || true)
    [ "$_pcur" = "$_ppin" ] || fail "pin check: ${_pstage} 收据与钉定哈希失配（完成后被改写）: $_prcpt"
  done < <(jq -r '.phases | to_entries[] | select(.value.status=="completed" and .value.receipt_sha256 != null) | [.key, .value.receipt_sha256] | @tsv' "$STATE_DIR/$FEATURE.state.json" 2>/dev/null || true)
  # v3.30.7: completed 无钉提示（钉定对账的上游完整性——缺钉阶段失配检测天然盲）
  _nopin=$(jq -r '[.phases | to_entries[] | select(.value.status=="completed" and (.value.receipt_sha256 == null)) | .key] | join(" ")' "$STATE_DIR/$FEATURE.state.json" 2>/dev/null || true)
  [ -z "$_nopin" ] || echo "[WARN] 已完成但未钉定（失配检测对其实盲；核销后跑 devflow-state.sh repin ${FEATURE}）: $_nopin"
fi

# v3.14.11: state-scope 完整性——state 标记 completed 的阶段必须存在对应内部收据
# v3.16.6（N27-P2-2）: jq 缺失时不再静默跳过整个 state-scope 检查（PoC：PATH 无 jq 时
# 「completed 无收据」从 17 FAIL 变 PASS）——fail-closed
# v3.16.6（N27-P2-3）: state JSON 解析失败不再被 || true 吞掉（PoC：截断损坏 state 后
# 审计 PASS）——解析失败即 fail
if [ -f "$STATE_DIR/$FEATURE.state.json" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    fail "state-scope 检查不可用（jq 缺失）而 state 文件存在——fail-closed: $STATE_DIR/$FEATURE.state.json"
  else
    # v3.16.6（N27-P2-3）修正：仅解析失败（损坏 JSON/phases 非对象）fail-closed；
    # 无 phases 字段的精简 state（合法，如 p6-credential 单项场景）输出空 → 无可检项不误伤
    _PH_TSV=$(jq -r '(.phases // {}) | to_entries[] | "\(.key)\t\(.value.status)"' "$STATE_DIR/$FEATURE.state.json" 2>/dev/null)
    _PH_JQ_RC=$?
    if [ "$_PH_JQ_RC" -ne 0 ]; then
      fail "state JSON 不可解析（损坏/phases 非对象）——fail-closed: $STATE_DIR/$FEATURE.state.json"
    else
  _ST_P3B_DONE=0; _ST_P6_DONE=0
  while IFS=$'\t' read -r st_ph st_status; do
    [ "$st_status" = "completed" ] || continue
    # v3.16.8（N29-P3-2）: 记录 P3b/P6 完成标记（循环后做辅助收据存在性检查）
    [ "$st_ph" = "P3b" ] && _ST_P3B_DONE=1
    [ "$st_ph" = "P6" ] && _ST_P6_DONE=1
    # 收据位于 gates/<phase>/receipt.txt（深度 2）；P3c/P3d 归一到 P3cd 目录
    _chk_ph="$st_ph"; case "$_chk_ph" in P3c|P3d) _chk_ph="P3cd" ;; esac
    if [ -f "$STATE_DIR/$FEATURE/gates/$_chk_ph/receipt.txt" ]; then
      # v3.16.5（N26-P3-2）: completed 阶段收据 EXIT_CODE 必须=0——防「值降级+
      # 双文件一致篡改」把终态降级为失败轮 WARN 规避证据绑定强校验
      _st_exit=$(grep '^EXIT_CODE=' "$STATE_DIR/$FEATURE/gates/$_chk_ph/receipt.txt" | head -1 | cut -d= -f2)
      if [ "$_st_exit" = "0" ]; then
        pass "state-scope: $st_ph=completed 且收据存在（EXIT_CODE=0）"
      else
        fail "state 标记 $st_ph=completed 但收据 EXIT_CODE=${_st_exit:-空}≠0（值降级篡改？）"
      fi
    else
      fail "state 标记 $st_ph=completed 但无对应收据: gates/$_chk_ph/receipt.txt"
    fi
  done <<< "$_PH_TSV"
    # v3.16.8（N29-P3-2）: 辅助收据存在性——state 标记 P3b/P6 completed 隐含其
    # 辅助收据必须存在（P3b→ARCH-PITFALLS；P6→P6-credential+P6-final）。
    # 此前内部+镜像双份同删后三轮检查（收集/镜像交叉/证据重验）全部零感知
    #（collect 只看存在的收据；state-scope 只查主阶段）——状态机会拦，但
    # "事后审计"机制本身失明（N27-P1-3 修复动机的未收口面）
    if [ "$_ST_P3B_DONE" = "1" ] && [ ! -f "$STATE_DIR/$FEATURE/gates/ARCH-PITFALLS/receipt.txt" ]; then
      fail "state P3b=completed 但 ARCH-PITFALLS 收据缺失（辅助收据双删？架构陷阱检查是 P3b 强制组成）"
    fi
    if [ "$_ST_P6_DONE" = "1" ] && [ ! -f "$STATE_DIR/$FEATURE/gates/P6-credential/receipt.txt" ]; then
      fail "state P6=completed 但 P6-credential 收据缺失（辅助收据双删？凭证审计是 P6 强制组成）"
    fi
    if [ "$_ST_P6_DONE" = "1" ] && [ ! -f "$STATE_DIR/$FEATURE/gates/P6-final/receipt.txt" ]; then
      fail "state P6=completed 但 P6-final 收据缺失（辅助收据双删？部署前终验是 P6 强制组成）"
    fi
    # v3.16.9（N30-P3-2）: 辅助收据降级检测——存在但被双份一致篡改为
    # EXIT_CODE=1（值降级类）时此前全绿（仅存在性不查内容）；终态语义
    # = 辅助检查曾通过（与主阶段 completed 同理——N26-P3-2 同型收口）
    # v3.16.10（N31-P3-1）: state 门控——主收据检查门控在 state completed 上，
    # "存在即须成功"会在 P3b/P6 迭代期间把失败轮辅助收据（gate 合法产物）
    # 误报"值降级篡改"，与同文件 rc=3 失败轮 WARN 语义自相矛盾（狼来了）；
    # 主阶段未 completed 时失败轮辅助收据 → WARN
    for _aux_f in ARCH-PITFALLS P6-credential P6-final; do
      if [ -f "$STATE_DIR/$FEATURE/gates/$_aux_f/receipt.txt" ]; then
        _aux_e=$(grep '^EXIT_CODE=' "$STATE_DIR/$FEATURE/gates/$_aux_f/receipt.txt" | head -1 | cut -d= -f2)
        if [ "${_aux_e:-x}" != "0" ]; then
          case "$_aux_f" in
            ARCH-PITFALLS)
              if [ "$_ST_P3B_DONE" != "1" ]; then
                echo "[WARN] 失败轮辅助收据（P3b 未 completed，gate 迭代中合法）: $_aux_f"
                continue
              fi
              ;;
            P6-credential|P6-final)
              if [ "$_ST_P6_DONE" != "1" ]; then
                echo "[WARN] 失败轮辅助收据（P6 未 completed，gate 迭代中合法）: $_aux_f"
                continue
              fi
              ;;
          esac
          fail "辅助收据 $_aux_f EXIT_CODE=${_aux_e:-空}≠0（值降级篡改？——存在性检查须同时校验终态）"
        fi
      fi
    done
    fi
  fi
fi

# v3.21.1: P6 终态不能只靠收据存在。状态元数据必须与冻结分母可重验，
# 否则「P6=completed + count=0/snapshot=null」会在收据双写完整时假绿。
validate_p6_state_metadata() {
  local state_file="$STATE_DIR/$FEATURE.state.json" baseline baseline_count count frozen complete snapshot accuracy resolved
  [ -f "$state_file" ] || return 0
  command -v jq >/dev/null 2>&1 || { fail "STATE_P6_ACCEPTANCE: jq missing while state exists"; return 0; }
  [ "$(jq -r '.phases.P6.status // empty' "$state_file" 2>/dev/null)" = "completed" ] || return 0
  baseline="$STATE_DIR/$FEATURE/first-pass-baseline.tsv"
  if [ ! -f "$baseline" ]; then
    fail "STATE_P6_ACCEPTANCE: P6=completed but frozen baseline missing: $baseline"
    return 0
  fi
  baseline_count=$(awk -F '\t' 'NR > 1 && $1 != "" {n++} END {print n+0}' "$baseline")
  if [ "$baseline_count" -le 0 ]; then
    fail "STATE_P6_ACCEPTANCE: frozen baseline has zero acceptance rows: $baseline"
    return 0
  fi
  count=$(jq -r '.acceptance_criteria.count // empty' "$state_file" 2>/dev/null)
  frozen=$(jq -r '.acceptance_criteria.frozen // empty' "$state_file" 2>/dev/null)
  complete=$(jq -r '.acceptance_criteria.complete // empty' "$state_file" 2>/dev/null)
  case "$count:$frozen:$complete" in
    *[!0-9:]*|::*|:*:|:*) fail "STATE_P6_ACCEPTANCE: invalid acceptance counters count=$count frozen=$frozen complete=$complete" ;;
    *)
      if [ "$count" -ne "$baseline_count" ] || [ "$frozen" -ne "$baseline_count" ] || [ "$complete" -ne "$baseline_count" ]; then
        fail "STATE_P6_ACCEPTANCE: counters count=$count frozen=$frozen complete=$complete must equal frozen baseline=$baseline_count"
      else
        pass "STATE_P6_ACCEPTANCE: counters equal frozen baseline ($baseline_count)"
      fi
      ;;
  esac
  snapshot=$(jq -r '.first_pass_snapshot.path // empty' "$state_file" 2>/dev/null)
  accuracy=$(jq -r '.first_pass_snapshot.accuracy // empty' "$state_file" 2>/dev/null)
  resolved=$(_receipt_norm_file "$snapshot" 2>/dev/null || true)
  if [ -z "$snapshot" ] || [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
    fail "STATE_P6_ACCEPTANCE: first-pass snapshot missing or outside workspace: ${snapshot:-<empty>}"
  elif ! printf '%s' "$accuracy" | grep -qE '^(100|[0-9]{1,2})(\.[0-9]+)?$'; then
    fail "STATE_P6_ACCEPTANCE: first-pass accuracy missing/invalid: ${accuracy:-<empty>}"
  else
    pass "STATE_P6_ACCEPTANCE: first-pass snapshot and accuracy are present"
  fi
}
validate_p6_state_metadata

# v3.14.0: 无收据可审时直接放行（版本混用/镜像漂移只对"存在的收据"生效；
# 缺失收据由 complete 的收据校验与 reconcile 负责，避免孤立 P7/P8/P9 单测误伤）
# v3.14.6: 零收据不再放行——init 必然产生 P0 基线收据，空目录意味着证据链被删除
if [ ! -s "$INTERNAL" ]; then
  if [ -f "$STATE_DIR/${FEATURE}.state.json" ]; then
    fail "zero internal receipts but state file exists — 证据链疑似被删除"
  else
    echo "RECEIPT AUDIT: no internal receipts to audit (pass)"
    exit 0
  fi
fi
# v3.14.0: 内部收据存在而 docs 镜像整体缺失 = 镜像被删/未镜像，必须 FAIL（防"整体删除绕过审计"）
[ -s "$MIRROR" ]  || { fail "document mirror missing entirely: $DOCS_DIR/$FEATURE/gates (internal has $(wc -l < "$INTERNAL" | tr -d ' ') receipts)"; echo "RECEIPT AUDIT: FAIL feature=$FEATURE count=$FAIL"; exit 1; }

# v3.14.0: EXIT_CODE 校验不在此处（由 complete/reconcile 负责），
# 避免负向单测遗留的失败收据误判版本混用。此处仅做镜像交叉存在性核对。
while IFS=$'\t' read -r stage _; do
  [ -n "$stage" ] || continue
  if grep -q "^${stage}[[:space:]]" "$MIRROR"; then
    pass "$stage present in document mirror"
  else
    fail "$stage missing in document mirror"
  fi
done < "$INTERNAL"

while IFS=$'\t' read -r stage _; do
  [ -n "$stage" ] || continue
  if ! grep -q "^${stage}[[:space:]]" "$INTERNAL"; then
    fail "$stage exists only in document mirror"
  fi
done < "$MIRROR"

# 每一张内部收据都必须有同名、同内容的文档镜像；仅比较 EXIT_CODE 会掩盖
# 版本、计数、证据哈希和 P4b WARN 详情漂移。
while IFS=$'\t' read -r stage filename hash; do
  [ -n "$stage" ] || continue
  if grep -q "^${stage}[[:space:]]${filename}[[:space:]]${hash}$" "$MIRROR_HASHES"; then
    pass "$stage/$filename internal/mirror content hash matches"
  else
    fail "$stage/$filename internal/mirror content hash mismatch"
  fi
done < "$INTERNAL_HASHES"

# =============================================================================
# v3.16.0（P0-3）: 证据绑定重验——收据指向的原始证据必须存在且哈希一致。
# 背景：旧审计只比较内部收据与 docs 镜像是否一致，不重验证据本身——
# Gate 通过后删除证据文件，审计仍 PASS（PoC: REPORT_EXISTS=no 仍 AUDIT PASS）。
# 契约：EVIDENCE_TREE_SHA256+EVIDENCE_PATHS_JSON（v3.16.0）> EVIDENCE_PATH+EVIDENCE_SHA256
#（单文件旧契约）> 无绑定（legacy WARN 渐进迁移）。
# =============================================================================
LEGACY_BINDINGS=0
while IFS= read -r receipt_file; do
  [ -n "$receipt_file" ] || continue
  # v3.16.9（N30-P3-4）: stage_name 归一化（P3c/P3d → P3cd）——否则 p3_security_perf
  # 的 --mode security/performance 双产物收据不进剥离检测 case（fail-open 残留）
  stage_name=$(normalize_stage "$(basename "$(dirname "$receipt_file")")")
  # v3.16.0: 强校验仅对 EXIT_CODE=0 终态收据——失败轮（EXIT_CODE=1）收据的证据
  # 指纹在 gate 迭代期间合法变更（reject→修复→重跑序列），WARN 放行不阻断；
  # 终态收据的证据缺失/篡改才是"删证据后审计仍通过"的攻击面，必须 FAIL。
  _rc_exit=$(grep '^EXIT_CODE=' "$receipt_file" | head -1 | cut -d= -f2)
  # v3.16.1: EXIT_CODE 行缺失 = 终态未知 → fail-closed 按终态处理（PoC：剥离该行
  # 把"终态"降级为"失败轮 WARN"，删证据后审计放行）
  [ -n "$_rc_exit" ] || _rc_exit=0
  verify_receipt_evidence "$receipt_file"
  _ev_rc=$?
  # v3.30.6: PHASE 行与所在目录一致性（收据目录是 stage 映射的事实源——PHASE 行
  # 篡改为其他阶段不影响目录映射，但构成字段级说谎，audit 须拒；complete/reconcile
  # 的 declared_phase 检查此前只覆盖推进路径）
  _phase_line=$(sed -n 's/^PHASE=//p' "$receipt_file" | head -1)
  if [ -n "$_phase_line" ] && [ "$_phase_line" != "$stage_name" ]; then
    fail "PHASE line mismatch: ${stage_name}/receipt.txt declares PHASE=${_phase_line}（目录是 stage 事实源，字段篡改拒绝）"
    continue
  fi
  # v3.30.6: 阶段必备 *_JSON 绑定行检测（终态收据一律执行——v3.30.4 只挂在 _ev_rc=0
  # 分支，P0/P1/P2a/P2b/P3 五阶段收据无 EVIDENCE 行恒 rc=3，剥离检测从未运行[子代理实证]）
  if [ "${_rc_exit:-1}" = "0" ] && ! verify_stage_json_binding "$receipt_file" "$stage_name"; then
    fail "stage JSON binding stripped: ${stage_name}（终态收据缺必备 *_JSON 绑定行——正本篡改将脱离审计）"
    continue
  fi
  if [ "$_ev_rc" -eq 0 ]; then
    pass "evidence binding verified: $stage_name"
  elif [ "$_ev_rc" -eq 1 ] && [ "${_rc_exit:-1}" = "0" ]; then
    fail "evidence binding broken: ${stage_name}（终态收据的证据缺失/被篡改——收据与证据必须同生共死）"
  elif [ "$_ev_rc" -eq 1 ]; then
    echo "[WARN] 失败轮收据证据指纹过时（gate 迭代中，合法）: $stage_name"
  else
    # 此分支 = verify_receipt_evidence rc=3（legacy 无绑定，见 devflow_receipt.sh）或
    # 其他非 0/1 返回码——行为靠 else 兜底，契约口径以共享库注释为准。
    # v3.16.3（N-P1-2）+ v3.16.4（N25-P1-1）: 新契约收据缺绑定行 = 被剥离 → FAIL。
    # 判定标记从可剥离的 PRODUCER_ROLE 行升级为「stage + 版本」组合——
    # PRODUCER_ROLE 与绑定行一并剥离即可绕过（第 25 轮 PoC）；VERSION 行本身
    # 不可剥离（check_versions 拒缺失）、不可篡改（版本不匹配 FAIL）。
    # 新契约 stage（P3b/P6-final/ARCH-PITFALLS）且版本 >= 3.16.0：其生成器
    # fail-closed 保证必然产出绑定行，缺行必是被剥离。旧版本同名 stage 收据为
    # 合法 legacy → WARN 渐进迁移不误伤；P0 基线/迁移收据（stage 非新契约集）
    # 天然豁免。
    # v3.16.8（N29-P3-1）: stage 集扩展到旧契约证据阶段（对齐 complete 的
    # receipt_stage_contract 映射——三处校验点单一事实源）：P0b/P3cd/P4/P5/
    # P7-P10 的生成器自 3.13.4 起（P4b 自 3.15.5 起）对成功收据必然产出
    # EVIDENCE_PATH 绑定行，阈值以上缺行 = 被剥离 → FAIL（此前旧契约 stage
    # 剥离绑定仅 WARN——fail-open）。低于阈值的收据为合法 legacy → WARN。
    # v3.16.9（N30-P3-1）: 失败轮前置——与 rc=1 分支同语义（失败轮收据的
    # EVIDENCE_PATH 可为空行，p4/p5 gate 失败轮真实产物即如此；不看 _rc_exit
    # 会把合法迭代态误报"被剥离"——误导性指控 + 经 artifact_gate 内嵌 audit
    # 阻塞合法 gate，"狼来了"效应侵蚀审计信号可信度）
    if [ "${_rc_exit:-1}" != "0" ]; then
      LEGACY_BINDINGS=$((LEGACY_BINDINGS + 1))
      echo "[WARN] 失败轮收据无证据绑定（gate 迭代中，合法）: $stage_name"
      continue
    fi
    # v3.16.9（N30-P3-3）: 内联映射改库函数（receipt_stage_contract 已下沉
    # devflow_receipt.sh 单一事实源——两处内联漂移归零）
    _arc_ver=$(sed -n 's/^VERSION=//p' "$receipt_file" | head -1)
    _arc_vernum="${_arc_ver##*@}"
    _arc_contract=$(receipt_stage_contract "$stage_name")
    _arc_kind="${_arc_contract%% *}"
    _arc_thresh="${_arc_contract##* }"
    _arc_ge=0
    if [ "$_arc_kind" != "none" ] && printf '%s' "$_arc_vernum" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+'; then
      _arc_ge=$(_stage_ver_ge "$_arc_vernum" "$_arc_thresh")
    fi
    if [ "$_arc_ge" = "1" ]; then
      if [ "$_arc_kind" = "new" ]; then
        fail "新契约收据（${stage_name}@${_arc_vernum}）缺证据绑定行——EVIDENCE_PATHS_JSON/EVIDENCE_TREE_SHA256 被剥离"
      else
        fail "旧契约收据（${stage_name}@${_arc_vernum}）缺证据绑定行——EVIDENCE_PATH/EVIDENCE_SHA256 被剥离（生成器自 ${_arc_thresh} 起必然产出）"
      fi
    else
      LEGACY_BINDINGS=$((LEGACY_BINDINGS + 1))
      echo "[WARN] 收据无证据绑定（legacy，渐进迁移至证据绑定契约）: $stage_name"
    fi
  fi
done < <(find "$STATE_DIR/$FEATURE/gates" -name 'receipt.txt' -type f 2>/dev/null | LC_ALL=C sort)
[ "$LEGACY_BINDINGS" -gt 0 ] && echo "[WARN] legacy 无绑定收据: $LEGACY_BINDINGS 张（新收据必须携带 EVIDENCE_PATHS_JSON+EVIDENCE_TREE_SHA256）"

if [ "$FAIL" -eq 0 ]; then
  if [ "$_seen_other_version" -eq 1 ]; then
    echo "[WARN] receipts version != current skill (tracked, no in-chain mixing) (v3.27.5)"
  fi
  echo "RECEIPT AUDIT: PASS feature=$FEATURE"
  exit 0
fi

echo "RECEIPT AUDIT: FAIL feature=$FEATURE count=$FAIL"
exit 1
