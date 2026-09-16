#!/usr/bin/env bash
# =============================================================================
# review-receipt.sh · 独立评审收据（编排器产生，Gate 验证）——两阶段协议
# v3.20.8: 两阶段协议引入（历史记录，详见 CHANGELOG）。
# =============================================================================
# v3.16.26 解决的问题：P2a 报告中的 AUTHOR_ID / REVIEWER_ID / REVIEW_SESSION_ID
# 只是报告作者自填的普通字符串，Gate 验证编排器收据而非相信报告自报 ID。
#
# v3.20.3 收口的伪造通道（审计实证）：
#   ① 旧 create 单阶段要求输出报告已存在 → started_at 必为报告完成后补写；
#      同一编排器可在报告定稿后整批补写六份收据全部 PASS。
#   ② feature/session/agent-id 无白名单：--feature ../escape 可在 STATE_DIR 外写文件。
#   ③ 角色集合不校验"恰好"：缺角色/重复角色/多余角色未全部拦截。
#
# 两阶段协议：
#   begin    输出报告尚不存在时登记（role/agent/input SHA/started_at），并锁定
#            session 台账中的 role→agent 映射。输出文件已存在即拒绝——
#            强制"先 begin 全部角色、后产出报告"，started_at 由脚本时钟产生。
#   complete 绑定输出报告 SHA 与 completed_at；输入 SHA 必须与 begin 一致
#            （评审期间详设被改 → 拒绝）。
#   verify   角色集合恰等于 AUTHOR+5（缺/重/多均 FAIL）；六条收据两阶段齐备；
#            输入/输出 SHA 与当前产物一致；时间窗单调；agent 唯一；
#            评审者 != 作者；session 台账映射一致。
#
# 路径安全：feature/session/agent 必须匹配 ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$
# 且不得为 "."/".."；收据根 realpath 必须落在 STATE_DIR 内（containment）。
# 原子性：全部 JSON 经 mktemp+mv 落盘；并发 begin 以锁目录串行化。
#
# 用法（编排器）：
#   review-receipt.sh begin    --feature F --role 架构师 --agent-id A1 \
#       --session-id S1 --input <design.md> --output <review-report.md>
#   review-receipt.sh complete --feature F --role 架构师 --agent-id A1 \
#       --session-id S1 --input <design.md> --output <review-report.md>
#   review-receipt.sh verify   --feature F --session-id S1 \
#       --input <design.md> --output <review-report.md>
#   review-receipt.sh status   --feature F --session-id S1
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

# P2a 规范角色集（与 p2a_design_review_gate.sh 一致）
CANONICAL_ROLES="架构师 后端专家 前端专家 测试开发 DBA AUTHOR"

usage() { sed -n '2,47p' "$0"; exit 2; }

sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

fail() { echo "[RECEIPT-ERR] $*" >&2; exit 1; }

now_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

# v3.20.3: 路径段白名单——收据目录由 feature/session/agent 拼接，任何一段
# 允许 "/" 或 ".." 都等于收据可写到 STATE_DIR 外（实证：--feature ../escape）。
safe_segment() {
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || return 1
  [ "$1" != "." ] && [ "$1" != ".." ] || return 1
  return 0
}

# containment：解析后的路径必须位于 base 之下（或相等）
contained_under() {
  local p base
  p=$(realpath "$1" 2>/dev/null) || return 1
  base=$(realpath "$2" 2>/dev/null) || return 1
  [ "$p" = "$base" ] && return 0
  case "$p" in "$base"/*) return 0 ;; *) return 1 ;; esac
}

# 绝对路径归一化（目标可不存在；父目录存在时解析真实父路径）
abs_path() {
  local p="$1" dir base
  case "$p" in /*) ;; *) p="$(pwd -P)/$p" ;; esac
  dir=$(dirname "$p"); base=$(basename "$p")
  [ -d "$dir" ] && dir=$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")
  printf '%s/%s' "$dir" "$base"
}

atomic_json_write() {
  # atomic_json_write <path> <json>
  local target="$1" content="$2" tmp dir
  dir=$(dirname "$target")
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp=$(mktemp "$dir/.tmp-receipt.XXXXXX") || fail "cannot create temp file in $dir"
  printf '%s\n' "$content" > "$tmp" || { rm -f "$tmp"; fail "write failed: $tmp"; }
  mv "$tmp" "$target" || { rm -f "$tmp"; fail "atomic move failed: $target"; }
}

RECEIPTS_BASE() {
  # RECEIPTS_BASE <feature>
  echo "${STATE_DIR:-.devflow}/${1}/review-sessions"
}

# 公共参数解析与校验（begin/complete/verify/status 共用）
parse_common() {
  FEATURE="" ROLE="" AGENT_ID="" SESSION_ID="" INPUT_F="" OUTPUT_F="" ATTESTATION=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --feature)    [ "$#" -ge 2 ] || fail "--feature requires a value"; FEATURE="$2"; shift 2 ;;
      --role)       [ "$#" -ge 2 ] || fail "--role requires a value"; ROLE="$2"; shift 2 ;;
      --agent-id)   [ "$#" -ge 2 ] || fail "--agent-id requires a value"; AGENT_ID="$2"; shift 2 ;;
      --session-id) [ "$#" -ge 2 ] || fail "--session-id requires a value"; SESSION_ID="$2"; shift 2 ;;
      --input)      [ "$#" -ge 2 ] || fail "--input requires a value"; INPUT_F="$2"; shift 2 ;;
    --output)     [ "$#" -ge 2 ] || fail "--output requires a value"; OUTPUT_F="$2"; shift 2 ;;
    --attestation) [ "$#" -ge 2 ] || fail "--attestation requires a value"; ATTESTATION="$2"; shift 2 ;;
      *) fail "unknown arg: $1" ;;
    esac
  done
  command -v jq >/dev/null 2>&1 || fail "jq required"
  command -v realpath >/dev/null 2>&1 || fail "realpath required"

  [ -n "$FEATURE" ] || fail "--feature required"
  [ -n "$SESSION_ID" ] || fail "--session-id required"
  # 白名单：目录拼接段全部拒绝越权字符（../、绝对路径、空白、控制字符）
  safe_segment "$FEATURE" || fail "invalid --feature '$FEATURE'（须匹配 ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$）"
  safe_segment "$SESSION_ID" || fail "invalid --session-id '$SESSION_ID'（须匹配 ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$）"

  [ -n "$INPUT_F" ] && [ -f "$INPUT_F" ] || fail "--input file missing: $INPUT_F"
  [ -n "$OUTPUT_F" ] || fail "--output required"

  # containment：收据根必须落在（解析后的）STATE_DIR 内
  local base root
  base="${STATE_DIR:-.devflow}"
  mkdir -p "$base" || fail "cannot create STATE_DIR: $base"
  root="$(RECEIPTS_BASE "$FEATURE")"
  mkdir -p "$root" || fail "cannot create receipts root: $root"
  contained_under "$root" "$base" || fail "receipts root escapes STATE_DIR (feature rejected): $FEATURE"
  dir_receipts=$(realpath "$root")
}

cmd_begin() {
  parse_common "$@"
  [ -n "$ROLE" ] || fail "begin requires --role"
  [ -n "$AGENT_ID" ] || fail "begin requires --agent-id"
  local role_match=0 r
  for r in $CANONICAL_ROLES; do [ "$r" = "$ROLE" ] && role_match=1; done
  [ "$role_match" -eq 1 ] || fail "invalid --role '${ROLE}'（须为: ${CANONICAL_ROLES}）"
  safe_segment "$AGENT_ID" || fail "invalid --agent-id '$AGENT_ID'（须匹配 ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$）"

  # ① begin 先于报告：输出文件必须尚不存在（started_at 由此获得真实语义，
  #    报告定稿后整批补写收据的伪造通道被物理关闭）
  [ -e "$OUTPUT_F" ] && fail "output report already exists at begin: ${OUTPUT_F}（协议要求先 begin 全部角色、后产出报告）"

  local dir receipt_file session_file lockdir waited=0 rc
  dir="$dir_receipts/${SESSION_ID}"
  receipt_file="$dir/${AGENT_ID}.json"
  session_file="$dir/session.json"
  mkdir -p "$dir"
  [ -f "$receipt_file" ] && fail "receipt already exists: ${receipt_file}（同一 agent 不可重复 begin；如需重来须换 session-id）"

  local input_sha now input_real output_real attestation_sha attestation_copy
  input_sha=$(sha256 "$INPUT_F") || fail "cannot hash input: $INPUT_F"
  attestation_sha=$(bash "$(cd "$(dirname "$0")" && pwd)/review-attestation.sh" verify \
    --event begin --feature "$FEATURE" --session-id "$SESSION_ID" --role "$ROLE" --agent-id "$AGENT_ID" \
    --input-sha "$input_sha" --output-sha "" --attestation "$ATTESTATION") || fail "begin attestation is invalid"
  mkdir -p "$dir/attestations" || fail "cannot create attestation directory"
  attestation_copy="$dir/attestations/${AGENT_ID}.begin.json"
  cp "$ATTESTATION" "$attestation_copy" || fail "cannot retain begin attestation"
  now=$(now_utc)
  input_real=$(abs_path "$INPUT_F")
  output_real=$(abs_path "$OUTPUT_F")

  # ② 锁目录串行化（并发 begin 竞争 session 台账）
  lockdir="$dir/.lock"
  until mkdir "$lockdir" 2>/dev/null; do
    waited=$((waited + 1))
    [ "$waited" -ge 100 ] && fail "lock timeout: $lockdir"
    sleep 0.1
  done
  rc=0
  # ③ session 台账：首个 begin 创建（nonce+输入基线冻结），后续追加 role→agent 映射
  if [ -f "$session_file" ]; then
    local s_input mapped_agent mapped_role
    s_input=$(jq -r '.input_artifact_sha // empty' "$session_file")
    [ "$s_input" = "$input_sha" ] || { rmdir "$lockdir" 2>/dev/null; fail "session input artifact changed since session creation（评审基线漂移，换新 session）"; }
    mapped_agent=$(jq -r --arg r "$ROLE" '.roles[$r] // empty' "$session_file")
    if [ -n "$mapped_agent" ] && [ "$mapped_agent" != "$AGENT_ID" ]; then
      rmdir "$lockdir" 2>/dev/null
      fail "role $ROLE already mapped to agent $mapped_agent in session $SESSION_ID"
    fi
    mapped_role=$(jq -r --arg a "$AGENT_ID" '.roles | to_entries[] | select(.value==$a) | .key' "$session_file" | head -1)
    if [ -n "$mapped_role" ] && [ "$mapped_role" != "$ROLE" ]; then
      rmdir "$lockdir" 2>/dev/null
      fail "agent $AGENT_ID already holds role $mapped_role in session $SESSION_ID"
    fi
  fi

  # ④ 收据（begin 态）：原子写
  local content
  content=$(jq -n \
    --arg agent_id "$AGENT_ID" \
    --arg session_id "$SESSION_ID" \
    --arg feature "$FEATURE" \
    --arg role "$ROLE" \
    --arg input_artifact_path "$input_real" \
    --arg input_artifact_sha "$input_sha" \
    --arg output_report_path "$output_real" \
    --arg attestation_sha256 "$attestation_sha" \
    --arg begin_attestation_path "$(abs_path "$attestation_copy")" \
    --arg started_at "$now" \
    --arg status "begin" \
    '{agent_id:$agent_id, session_id:$session_id, feature:$feature, role:$role,
      input_artifact_path:$input_artifact_path, input_artifact_sha:$input_artifact_sha,
      output_report_path:$output_report_path,
      attestation_sha256:$attestation_sha256,
      begin_attestation_path:$begin_attestation_path,
      started_at:$started_at, completed_at:null,
      output_report_sha:null, status:$status}') || { rmdir "$lockdir" 2>/dev/null; fail "jq failed"; }
  atomic_json_write "$receipt_file" "$content"

  # ⑤ session 台账更新（原子写）
  local new_session
  if [ -f "$session_file" ]; then
    new_session=$(jq --arg r "$ROLE" --arg a "$AGENT_ID" '.roles[$r]=$a' "$session_file")
  else
    local nonce
    nonce=$(printf '%s-%s-%s-%s' "$(date +%s)" "$$" "$RANDOM" "${AGENT_ID}-${ROLE}" | shasum -a 256 2>/dev/null | awk '{print $1}')
    new_session=$(jq -n \
      --arg session_id "$SESSION_ID" --arg feature "$FEATURE" \
      --arg input_artifact_path "$input_real" --arg input_artifact_sha "$input_sha" \
      --arg created_at "$now" --arg nonce "$nonce" \
      --arg role "$ROLE" --arg agent "$AGENT_ID" \
      '{session_id:$session_id, feature:$feature,
        input_artifact_path:$input_artifact_path, input_artifact_sha:$input_artifact_sha,
        created_at:$created_at, nonce:$nonce,
        roles:{($role): $agent}}')
  fi
  atomic_json_write "$session_file" "$new_session"
  rmdir "$lockdir" 2>/dev/null
  echo "[RECEIPT] begin: $ROLE/$AGENT_ID -> $receipt_file"
  return $rc
}

cmd_complete() {
  parse_common "$@"
  [ -n "$ROLE" ] || fail "complete requires --role"
  [ -n "$AGENT_ID" ] || fail "complete requires --agent-id"
  [ -f "$OUTPUT_F" ] || fail "--output file missing: ${OUTPUT_F}（complete 必须绑定真实产物）"

  local dir receipt_file session_file
  dir="$dir_receipts/${SESSION_ID}"
  receipt_file="$dir/${AGENT_ID}.json"
  session_file="$dir/session.json"
  [ -f "$receipt_file" ] || fail "no begin receipt for agent ${AGENT_ID}（必须先 begin 后 complete）"
  [ -f "$session_file" ] || fail "session ledger missing: $session_file"

  local r_status r_role r_input r_output_path r_started
  r_status=$(jq -r '.status // empty' "$receipt_file")
  r_role=$(jq -r '.role // empty' "$receipt_file")
  r_input=$(jq -r '.input_artifact_sha // empty' "$receipt_file")
  r_output_path=$(jq -r '.output_report_path // empty' "$receipt_file")
  r_started=$(jq -r '.started_at // empty' "$receipt_file")
  [ "$r_status" = "begin" ] || fail "receipt ${receipt_file} status=${r_status}（重复 complete 或 begin 缺失）"
  [ "$r_role" = "$ROLE" ] || fail "role mismatch: receipt=$r_role arg=$ROLE"
  [ "$r_output_path" = "$(abs_path "$OUTPUT_F")" ] || fail "output path differs from begin: receipt=$r_output_path arg=$(abs_path "$OUTPUT_F")"

  local now output_sha input_sha_now attestation_sha attestation_copy
  now=$(now_utc)
  output_sha=$(sha256 "$OUTPUT_F") || fail "cannot hash output: $OUTPUT_F"
  input_sha_now=$(sha256 "$INPUT_F") || fail "cannot hash input: $INPUT_F"
  [ "$input_sha_now" = "$r_input" ] || fail "input artifact changed since begin（评审基线漂移）: $INPUT_F"
  attestation_sha=$(bash "$(cd "$(dirname "$0")" && pwd)/review-attestation.sh" verify \
    --event complete --feature "$FEATURE" --session-id "$SESSION_ID" --role "$ROLE" --agent-id "$AGENT_ID" \
    --input-sha "$input_sha_now" --output-sha "$output_sha" --attestation "$ATTESTATION") || fail "complete attestation is invalid"
  mkdir -p "$dir/attestations" || fail "cannot create attestation directory"
  attestation_copy="$dir/attestations/${AGENT_ID}.complete.json"
  cp "$ATTESTATION" "$attestation_copy" || fail "cannot retain complete attestation"
  { [ "$r_started" \< "$now" ] || [ "$r_started" = "$now" ]; } || fail "clock anomaly: started_at $r_started > now $now"

  local content
  content=$(jq -n \
    --slurpfile prev "$receipt_file" \
    --arg output_report_sha "$output_sha" \
    --arg completed_at "$now" \
    --arg status "complete" \
    --arg attestation_sha256 "$attestation_sha" \
    --arg complete_attestation_path "$(abs_path "$attestation_copy")" \
    '$prev[0] + {output_report_sha:$output_report_sha, completed_at:$completed_at, status:$status, complete_attestation_sha256:$attestation_sha256, complete_attestation_path:$complete_attestation_path}') || fail "jq failed"
  atomic_json_write "$receipt_file" "$content"
  echo "[RECEIPT] complete: $ROLE/$AGENT_ID (output sha bound)"
}

cmd_verify() {
  parse_common "$@"
  [ -f "$OUTPUT_F" ] || fail "--output file missing: $OUTPUT_F"

  local dir expected_input expected_output problems=0
  dir="$dir_receipts/${SESSION_ID}"
  [ -d "$dir" ] || fail "no receipts for session $SESSION_ID under $dir_receipts"
  expected_input=$(sha256 "$INPUT_F") || fail "cannot hash input"
  expected_output=$(sha256 "$OUTPUT_F") || fail "cannot hash output"

  # 0) session 台账存在且输入基线一致
  local session_file="$dir/session.json"
  [ -f "$session_file" ] || { echo "session ledger missing (begin 从未执行): $session_file"; problems=$((problems+1)); }
  if [ -f "$session_file" ]; then
    local s_input
    s_input=$(jq -r '.input_artifact_sha // empty' "$session_file")
    [ "$s_input" = "$expected_input" ] || { echo "session ledger input sha mismatch（评审基线在会话后被改写）"; problems=$((problems+1)); }
  fi

  # 收据文件清单（排除 session 台账本身）
  local receipts=() rf
  for rf in "$dir"/*.json; do
    [ -f "$rf" ] || continue
    [ "$(basename "$rf")" = "session.json" ] && continue
    receipts+=("$rf")
  done

  # 1) 角色集合恰等于 AUTHOR+5：缺、重、多均 FAIL
  local role found r_role known
  for role in $CANONICAL_ROLES; do
    found=0
    for rf in ${receipts[@]+"${receipts[@]}"}; do
      r_role=$(jq -r '.role // empty' "$rf" 2>/dev/null || true)
      [ "$r_role" = "$role" ] && found=$((found+1))
    done
    if [ "$found" -eq 0 ]; then echo "missing receipt for role: $role"; problems=$((problems+1));
    elif [ "$found" -gt 1 ]; then echo "duplicate receipts for role: $role ($found)"; problems=$((problems+1)); fi
  done
  # 多余角色（不在规范集合内）
  for rf in ${receipts[@]+"${receipts[@]}"}; do
    r_role=$(jq -r '.role // empty' "$rf" 2>/dev/null || true)
    known=0
    for role in $CANONICAL_ROLES; do [ "$r_role" = "$role" ] && known=1; done
    [ "$known" -eq 1 ] || [ -z "$r_role" ] || { echo "unexpected role in receipts: $r_role"; problems=$((problems+1)); }
  done

  # 2) 每条收据：两阶段齐备、SHA 匹配当前产物、时间窗单调
  local r_agent r_in r_out r_start r_end r_status r_begin_att r_complete_att r_begin_sha r_complete_sha
  local author_agent=""
  for rf in ${receipts[@]+"${receipts[@]}"}; do
    r_agent=$(jq -r '.agent_id // empty' "$rf")
    r_role=$(jq -r '.role // empty' "$rf")
    r_in=$(jq -r '.input_artifact_sha // empty' "$rf")
    r_out=$(jq -r '.output_report_sha // empty' "$rf")
    r_start=$(jq -r '.started_at // empty' "$rf")
    r_end=$(jq -r '.completed_at // empty' "$rf")
    r_status=$(jq -r '.status // empty' "$rf")
    r_begin_att=$(jq -r '.begin_attestation_path // empty' "$rf")
    r_complete_att=$(jq -r '.complete_attestation_path // empty' "$rf")
    r_begin_sha=$(jq -r '.attestation_sha256 // empty' "$rf")
    r_complete_sha=$(jq -r '.complete_attestation_sha256 // empty' "$rf")
    [ -n "$r_agent" ] || { echo "receipt $rf missing agent_id"; problems=$((problems+1)); }
    [ "$r_status" = "complete" ] || { echo "receipt $rf not completed (status=$r_status) — complete 阶段缺失"; problems=$((problems+1)); }
    [ -n "$r_start" ] || { echo "receipt $rf missing started_at（begin 记录不可缺）"; problems=$((problems+1)); }
    [ "$r_in" = "$expected_input" ] || { echo "receipt $rf input_artifact_sha mismatch (评审必须基于当前详设)"; problems=$((problems+1)); }
    [ "$r_out" = "$expected_output" ] || { echo "receipt $rf output_report_sha mismatch (报告在收据后被改写或 complete 从未执行)"; problems=$((problems+1)); }
    [ -f "$r_begin_att" ] && [ "$(sha256 "$r_begin_att")" = "$r_begin_sha" ] || { echo "receipt $rf begin attestation missing or changed"; problems=$((problems+1)); }
    [ -f "$r_complete_att" ] && [ "$(sha256 "$r_complete_att")" = "$r_complete_sha" ] || { echo "receipt $rf complete attestation missing or changed"; problems=$((problems+1)); }
    if [ -f "$r_begin_att" ]; then
      bash "$(cd "$(dirname "$0")" && pwd)/review-attestation.sh" verify --event begin --feature "$FEATURE" --session-id "$SESSION_ID" --role "$r_role" --agent-id "$r_agent" --input-sha "$r_in" --output-sha "" --attestation "$r_begin_att" >/dev/null 2>&1 || { echo "receipt $rf begin attestation signature invalid"; problems=$((problems+1)); }
    fi
    if [ -f "$r_complete_att" ]; then
      bash "$(cd "$(dirname "$0")" && pwd)/review-attestation.sh" verify --event complete --feature "$FEATURE" --session-id "$SESSION_ID" --role "$r_role" --agent-id "$r_agent" --input-sha "$r_in" --output-sha "$r_out" --attestation "$r_complete_att" >/dev/null 2>&1 || { echo "receipt $rf complete attestation signature invalid"; problems=$((problems+1)); }
    fi
    { [ "$r_start" \< "$r_end" ] || [ "$r_start" = "$r_end" ]; } || { echo "receipt $rf time window invalid: $r_start > $r_end"; problems=$((problems+1)); }
    [ "$r_role" = "AUTHOR" ] && author_agent="$r_agent"
  done

  # agent_id 唯一性（仅收据，不含 session 台账）
  local dup rf
  dup=$(for rf in ${receipts[@]+"${receipts[@]}"}; do jq -r '.agent_id // empty' "$rf"; done | sort | uniq -d | head -3)
  [ -n "$dup" ] && { echo "duplicate agent_id in session: $dup"; problems=$((problems+1)); }

  # 3) 评审者 != 作者 + 台账映射一致性
  local r_mapped
  for rf in ${receipts[@]+"${receipts[@]}"}; do
    r_role=$(jq -r '.role // empty' "$rf")
    r_agent=$(jq -r '.agent_id // empty' "$rf")
    case "$r_role" in
      AUTHOR) ;;
      *) { [ -n "$author_agent" ] && [ "$r_agent" = "$author_agent" ]; } && { echo "role $r_role reviewed by AUTHOR agent ($r_agent) — 独立性被破坏"; problems=$((problems+1)); } ;;
    esac
    if [ -f "$session_file" ]; then
      r_mapped=$(jq -r --arg r "$r_role" '.roles[$r] // empty' "$session_file")
      [ "$r_mapped" = "$r_agent" ] || { echo "receipt agent disagrees with session ledger for role $r_role: ledger=$r_mapped receipt=$r_agent"; problems=$((problems+1)); }
    fi
  done

  [ "$problems" -eq 0 ] || { echo "[RECEIPT] verify FAILED: $problems problem(s)" >&2; exit 1; }
  echo "[RECEIPT] verify PASS: session=$SESSION_ID (${#receipts[@]} receipts, two-phase)"
}

cmd_status() {
  parse_common "$@"
  local dir rf
  dir="$dir_receipts/${SESSION_ID}"
  [ -d "$dir" ] || fail "no receipts for session $SESSION_ID"
  for rf in "$dir"/*.json; do
    [ -f "$rf" ] || continue
    printf '%s\t%s\t%s\n' \
      "$(jq -r '.role // "??"' "$rf")" \
      "$(jq -r '.agent_id // "??"' "$rf")" \
      "$(jq -r '.status // "??"' "$rf")"
  done | LC_ALL=C sort
}

case "${1:-}" in
  begin)    shift; cmd_begin "$@" ;;
  complete) shift; cmd_complete "$@" ;;
  verify)   shift; cmd_verify "$@" ;;
  status)   shift; cmd_status "$@" ;;
  roles)    echo "$CANONICAL_ROLES" ;;
  # v3.20.3: 旧 create 已移除——单阶段收据可在报告完成后整批补写（伪造通道①）
  create)   fail "create removed in v3.20.3: 使用 begin（spawn 前，报告须不存在）+ complete（产物落盘后）两阶段" ;;
  -h|--help|help|"") usage ;;
  *) fail "unknown command: ${1:-} (begin|complete|verify|status|roles)" ;;
esac
