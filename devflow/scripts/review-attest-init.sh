#!/usr/bin/env bash
# =============================================================================
# review-attest-init.sh · P2a 独立评审证明引导（v3.30.0 · L-EFF-001）
# -----------------------------------------------------------------------------
# 背景：review-receipt.sh 两阶段收据要求平台证明（REVIEW_ATTESTATION_PUBKEY +
# 逐事件 attestation）。协议规定"评审发起方持有私钥"；本脚本把 keygen/签名/
# begin-all/complete-all 封装为一行命令，避免每次手写。
# 本 skill 永不自签——私钥由发起方（用户会话）持有，落盘路径在项目 .devflow 下。
# 信任模型（v3.28.9 明示）：私钥落盘在项目内 → 签名证明的是「编排流程走了两阶段
# 协议且证据未被误改」，不构成对抗恶意编排者的密码学保证；对抗「仪式化评审」的
# 是时长/同输入/时钟三道机检（见 review-receipt.sh），不是签名本身。
#
# 用法：
#   bash review-attest-init.sh keygen  <feature>                     # 生成发起方密钥对
#   bash review-attest-init.sh env     <feature>                     # 打印 REVIEW_ATTESTATION_PUBKEY
#   bash review-attest-init.sh begin-all   <feature> <session> <design.md> <report.md> \
#        "AUTHOR:author-01,架构师:arch-01,后端专家:backend-01,前端专家:frontend-01,测试开发:tester-01,DBA:dba-01" \
#        ["<同输入重评豁免原因>"]   # v3.28.9：仅在 input SHA 与历史 session 相同且确需重审时提供
#   bash review-attest-init.sh complete-all <feature> <session> <design.md> <report.md> "<同上角色表>"
#     （角色表与 begin-all 相同；报告必须在 begin 之后产出）
#
# v3.28.9（m01-base 复盘）：
#   - attest 临时文件名改用 agent_id（ASCII）——旧实现以中文 role 经 tr -c 清洗，
#     「架构师」→ 9 个下划线、「测试开发」→ 12 个下划线，同字数角色会互相覆盖；
#   - 透传 --rerun-reason（同输入重评豁免）；
#   - complete-all 受最短评审时长门禁约束（DEVFLOW_REVIEW_MIN_SECONDS，默认 60s）。
# =============================================================================
set -euo pipefail
LC_ALL=C
export LC_ALL

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FAIL() { echo "[ATTEST-INIT-ERR] $*" >&2; exit 1; }
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

CMD="${1:-}"; FEATURE="${2:-}"
[ -n "$CMD" ] && [ -n "$FEATURE" ] || { sed -n '2,20p' "$0"; exit 2; }
printf '%s' "$FEATURE" | grep -qE '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || FAIL "feature 非法"
KEYS=".devflow/$FEATURE/review-keys"
PRIV="$KEYS/attest.pem"; PUB="$KEYS/attest.pub.pem"
TMPD="$(mktemp -d)"; trap 'rm -rf "$TMPD"' EXIT

sign_event() { # <role> <agent> <event> <in_sha> <out_sha> <out.json>
  local role="$1" agent="$2" event="$3" isha="$4" osha="$5" out="$6"
  local session="${SESSION:?}" nonce now
  nonce="$(openssl rand -hex 16)"; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n --arg s "devflow-review-attestation-v1" --arg f "$FEATURE" --arg sess "$session" \
        --arg r "$role" --arg a "$agent" --arg e "$event" --arg i "$isha" --arg o "$osha" \
        --arg t "$now" --arg n "$nonce" \
        '{schema:$s,feature:$f,session_id:$sess,role:$r,agent_id:$a,event:$e,input_sha:$i,output_sha:$o,issued_at:$t,nonce:$n}' \
    | jq -cS '.' > "$TMPD/payload.json"
  local sig
  sig="$(openssl dgst -sha256 -sign "$PRIV" "$TMPD/payload.json" | openssl base64 -A)"
  jq -n --slurpfile p "$TMPD/payload.json" --arg sig "$sig" '{payload:$p[0], signature_b64:$sig}' > "$out"
}

case "$CMD" in
  keygen)
    mkdir -p "$KEYS"
    openssl genrsa -out "$PRIV" 2048 2>/dev/null
    openssl rsa -in "$PRIV" -pubout -out "$PUB" 2>/dev/null
    echo "[OK] 发起方密钥对已生成：${PRIV}（私钥，勿入库到公开仓）/ ${PUB}"
    ;;
  env)
    [ -f "$PUB" ] || FAIL "公钥不存在：${PUB}（先 keygen）"
    echo "REVIEW_ATTESTATION_PUBKEY=$PUB"
    ;;
  begin-all|complete-all)
    SESSION="${3:?}"; DESIGN="${4:?}"; REPORT="${5:?}"; ROLES="${6:?}"
    RERUN_REASON="${7:-}"
    [ -f "$PUB" ] || FAIL "公钥不存在：${PUB}（先 keygen）"
    export REVIEW_ATTESTATION_PUBKEY="$PUB"
    local_isha="$(sha256 "$DESIGN")"
    event="begin"; osha=""
    [ "$CMD" = "complete-all" ] && { event="complete"; [ -f "$REPORT" ] || FAIL "报告不存在（begin 之后再产出）"; osha="$(sha256 "$REPORT")"; }
    if [ "$CMD" = "begin-all" ] && [ -f "$REPORT" ]; then FAIL "报告已存在——协议要求先 begin 全部角色再产出报告"; fi
    EXTRA=()
    [ -n "$RERUN_REASON" ] && EXTRA=(--rerun-reason "$RERUN_REASON")
    echo "$ROLES" | tr ',' '\n' | while IFS=: read -r role agent; do
      [ -n "$role" ] && [ -n "$agent" ] || continue
      # v3.28.9: tag 用 ASCII agent_id——中文 role 经 tr -c 清洗成下划线会碰撞覆盖
      bash "$SCRIPT_DIR/review-attest-init.sh" __sign "$FEATURE" "$SESSION" "$role" "$agent" "$event" "$local_isha" "$osha" "$TMPD/a.json" >/dev/null
      cp "$TMPD/a.json" "$TMPD/attest-$agent.$event.json"
      bash "$SCRIPT_DIR/review-receipt.sh" "$event" --feature "$FEATURE" --role "$role" --agent-id "$agent" \
        --session-id "$SESSION" --input "$DESIGN" --output "$REPORT" \
        --attestation "$TMPD/attest-$agent.$event.json" \
        ${EXTRA[@]+"${EXTRA[@]}"} >/dev/null \
        && echo "[OK] $event $role" || FAIL "$event $role 失败"
    done
    ;;
  __sign) # 内部：跳过 SESSION 校验直调 sign_event
    SESSION="$3"; shift 3
    sign_event "$@" ;;
  verify)
    SESSION="${3:?}"; DESIGN="${4:?}"; REPORT="${5:?}"
    export REVIEW_ATTESTATION_PUBKEY="$PUB"
    [ -f "$PUB" ] || FAIL "公钥不存在：${PUB}（先 keygen）"
    bash "$SCRIPT_DIR/review-receipt.sh" verify --feature "$FEATURE" --session-id "$SESSION" \
      --input "$DESIGN" --output "$REPORT"
    ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
