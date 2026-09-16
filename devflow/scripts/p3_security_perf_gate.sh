#!/usr/bin/env bash
# P3c/P3d 安全+性能 Gate（合并版）· 版本随 SKILL.md
# 功能：安全审计（@PreAuthorize覆盖率）+ 性能审计（N+1/P95）
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_ROOT="${SKILL_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
# v3.15.9: WORK_DIR 跟随 STATE_DIR 取默认——隔离部署（STATE_DIR 自定义）下报告不再回退
# .devflow 读宿主项目数据（跨工作区污染）；显式 WORK_DIR 仍可覆盖
WORK_DIR="${WORK_DIR:-${STATE_DIR:-.devflow}}"
FAIL=0; PASS=0; WARN=0; SKIP=0
FEATURE=""; SERVICE=""; SKIP_CHECKS=""; WAIVER_FILE=""; CHECK_MODE="full"
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok() { echo -e "${GREEN}[PASS]${NC} $1"; PASS=$((PASS+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; WARN=$((WARN+1)); }
p0() { echo -e "${RED}[P0]  ${NC} $1"; FAIL=$((FAIL+1)); }
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
usage() { cat <<'EOF'; exit 2; }
Usage: p3_security_perf_gate.sh <feature> [--service <svc>] [--mode security|performance|full] [--waiver <file>]
P3c+P3d 安全+性能 Gate · v3.9.1
  --service <svc>  后端服务名
  --mode <mode>    security / performance 只生成分项报告；full（默认）签发 P3cd receipt
  --skip=<check>   仅与显式 waiver 一起使用：security|perf|n1|response
  --waiver <file>  含 P3CD_SECURITY=NOT_APPLICABLE / P3CD_PERFORMANCE=NOT_APPLICABLE
EOF
# v3.9.6 修复：usage 原为 exit 0 —— 无参调用会被 main() 误判为 gate PASS
[ $# -eq 0 ] && usage
FEATURE="$1"; shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.8: 带值 flag 缺值时 shift 2 失败且不改位置参数（bash 语义），set -u 无 -e 吞错
    # → while 永真死循环（实测 3s 进程仍存活）。前置 $# 检查 fail-closed。
    --service) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --service requires a non-flag value" >&2; exit 2; }; SERVICE="$2"; shift 2 ;;
    --mode)    [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --mode requires a non-flag value" >&2; exit 2; }; CHECK_MODE="$2"; shift 2 ;;
    --waiver)  [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --waiver requires a non-flag value" >&2; exit 2; }; WAIVER_FILE="$2"; shift 2 ;;
    --skip=*) SKIP_CHECKS="${SKIP_CHECKS} ${1#--skip=}"; shift ;;
    *) echo "[ERR] unknown argument: $1"; exit 2 ;;
  esac
done
case "$CHECK_MODE" in security|performance|full) ;; *) echo "[ERR] invalid mode: $CHECK_MODE"; exit 2 ;; esac
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
devflow_feature_validate "$FEATURE" || exit 2
REPORT_DIR="${WORK_DIR}/${FEATURE}"
REPORT_FILE="${REPORT_DIR}/p3-security-perf-report.md"
mkdir -p "$REPORT_DIR"
should_skip() { echo "$SKIP_CHECKS" | grep -q "$1"; }
has_waiver() {
  local key="$1"
  [ -f "$WAIVER_FILE" ] && grep -qx "P3CD_${key}=NOT_APPLICABLE" "$WAIVER_FILE"
}
not_applicable_or_fail() {
  local key="$1" message="$2"
  if has_waiver "$key"; then
    warn "${message}（已由 $WAIVER_FILE 明确豁免）"
    SKIP=$((SKIP+1))
  else
    p0 "${message}（需 $key 证据，或 --waiver 声明不适用）"
  fi
}

check_security() {
  echo ""; echo "=== §1 安全审计 — @PreAuthorize 权限覆盖 ==="
  should_skip "security" && { not_applicable_or_fail SECURITY "security 检查被跳过"; return; }
  local svc_dir="${SERVICE:-backend}"
  local ctrls
  ctrls=$(find "$svc_dir" -name "*Controller.java" -type f 2>/dev/null | grep -v '/test/')
  [ -z "$ctrls" ] && { not_applicable_or_fail SECURITY "未找到 Controller"; return; }
  local write_total=0; local secured_write=0
  while IFS= read -r c; do
    [ -z "$c" ] && continue
    local method_counts
    method_counts=$(awk '
      function tick() { if (auth_ttl > 0) auth_ttl--; if (mapping_ttl > 0) mapping_ttl-- }
      /@(PreAuthorize|Secured|RolesAllowed)/ { auth_ttl=12 }
      /@(PostMapping|PutMapping|PatchMapping|DeleteMapping)/ || /@RequestMapping[^)]*method[[:space:]]*=[^)]*(POST|PUT|PATCH|DELETE)/ { mapping_ttl=12; mapping_auth=(auth_ttl > 0) }
      mapping_ttl > 0 && /^[[:space:]]*public[[:space:]]/ && /\([^)]*\)/ {
        total++
        if (mapping_auth || auth_ttl > 0) secured++
        mapping_ttl=0; mapping_auth=0
      }
      { tick() }
      END { print total+0, secured+0 }
    ' "$c")
    set -- $method_counts
    write_total=$((write_total + ${1:-0}))
    secured_write=$((secured_write + ${2:-0}))
  done <<< "$ctrls"
  local coverage
  coverage=0; [ "$write_total" -gt 0 ] && coverage=$((secured_write * 100 / write_total))
  echo "| 写操作总数 | $write_total |" >> "$REPORT_FILE"
  echo "| @PreAuthorize 覆盖率 | $coverage% |" >> "$REPORT_FILE"
  if [ "$coverage" -eq 100 ] && [ "$write_total" -gt 0 ]; then ok "安全 Gate PASS：@PreAuthorize 覆盖率 $coverage%";
  elif [ "$write_total" -eq 0 ]; then ok "无写操作，跳过"; SKIP=$((SKIP+1));
  else p0 "安全 Gate FAIL：覆盖率 $coverage%（需要 100%）"; fi
}

check_n_plus_one() {
  echo ""; echo "=== §2 性能审计 — N+1 查询检测 ==="
  should_skip "n1" || should_skip "perf" && { not_applicable_or_fail PERFORMANCE "N+1 检查被跳过"; return; }
  local svc_dir="${SERVICE:-backend}"
  local svcs
  svcs=$(find "$svc_dir" -name "*Service.java" -type f 2>/dev/null | grep -v '/test/' | head -30)
  [ -z "$svcs" ] && { not_applicable_or_fail PERFORMANCE "未找到 Service"; return; }
  local suspicious=0
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    local count
    count=$(grep -cE "for[[:space:]]*\([^)]+\)[[:space:]]*\{[^}]*\.(find|get|select|load|query)" "$s" 2>/dev/null || true)
    [ "$count" -gt 0 ] && { suspicious=$((suspicious + 1)); warn "N+1 可疑: $s"; }
  done <<< "$svcs"
  echo "| N+1 可疑模式数 | $suspicious |" >> "$REPORT_FILE"
  [ "$suspicious" -eq 0 ] && ok "N+1 检测 PASS" || p0 "N+1 检测 FAIL：发现 $suspicious 处"
}

check_response_time() {
  echo ""; echo "=== §3 性能审计 — API 响应时间 ==="
  should_skip "response" || should_skip "perf" && { not_applicable_or_fail PERFORMANCE "响应时间检查被跳过"; return; }
  local perf="docs/test/${FEATURE}-load-test-report.md"
  echo "| P95 | 见 $perf |" >> "$REPORT_FILE"
  if [ -f "$perf" ]; then
    local p95
    # v3.15.5: 旧管道提取的第一个数字是字面 "P95" 里的 95——[ 95 -le 500 ] 恒真，阈值校验形同虚设；
    # 且 ERE 无非贪婪 .*?。改为 sed 捕获 P95 标签后的首个数字（[[:space:]] 口径，BSD/GNU sed 通用）。
    p95=$(sed -nE 's/.*P95[^0-9]*([0-9]+)[[:space:]]*ms.*/\1/p' "$perf" 2>/dev/null | head -1 || echo "")
    if [ -n "$p95" ]; then
      echo "| P95 实测 | ${p95}ms |" >> "$REPORT_FILE"
      [ "$p95" -le 500 ] && ok "API P95 = ${p95}ms（< 500ms），PASS" || p0 "API P95 = ${p95}ms（> 500ms）"
    else
      p0 "压测报告未提供可解析 P95: $perf"
    fi
  else
    not_applicable_or_fail PERFORMANCE "未找到压测报告: $perf"
  fi
}

check_sql_injection() {
  echo ""; echo "=== §4 安全审计 — SQL 注入检测 ==="
  should_skip "security" && { SKIP=$((SKIP+1)); return; }
  local svc_dir="${SERVICE:-backend}"
  local count
  count=$( (find "$svc_dir" -name "*.java" -type f 2>/dev/null | grep -v '/test/' | xargs grep -lE "createQuery[[:space:]]*\([[:space:]]*[\"'].*\{|\.createNativeQuery" 2>/dev/null || true) | wc -l | tr -d ' ' )
  echo "| SQL 原生查询文件数 | $count |" >> "$REPORT_FILE"
  [ "$count" -eq 0 ] && ok "SQL 注入检测 PASS" || warn "发现 $count 处原生 SQL"
}

check_sensitive_data() {
  echo ""; echo "=== §5 安全审计 — 敏感数据暴露 ==="
  should_skip "security" && { SKIP=$((SKIP+1)); return; }
  local dto_dir="${SERVICE:-backend}/src/main/java"
  local count
  count=$( (find "$dto_dir" -type f \( -name "*DTO.java" -o -name "*VO.java" \) -exec grep -lE "password|secret|token|key" {} + 2>/dev/null || true) | wc -l | tr -d ' ' )
  echo "| 含敏感字段的 DTO 数 | $count |" >> "$REPORT_FILE"
  [ "$count" -eq 0 ] && ok "敏感数据暴露检测 PASS" || warn "发现 $count 个 DTO 含敏感字段"
}

main() {
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  P3c+P3d 安全+性能 Gate · v3.14.0"
  echo "  Feature: $FEATURE"
  echo "══════════════════════════════════════════════════"
  { echo "# P3c+P3d 安全+性能 Gate 报告";
    echo "## Feature: $FEATURE | $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo ""; } > "$REPORT_FILE"
  case "$CHECK_MODE" in
    security) check_security; check_sql_injection; check_sensitive_data ;;
    performance) check_n_plus_one; check_response_time ;;
    full) check_security; check_n_plus_one; check_response_time; check_sql_injection; check_sensitive_data ;;
  esac
  echo ""; echo "RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
  echo "报告: $REPORT_FILE"
  # ---------- 收据双写（v3.9.6：与其他 gate 对齐） ----------
  STATE_DIR="${STATE_DIR:-.devflow}"
  case "$CHECK_MODE" in
    security) RECEIPT_PHASE="P3c" ;;
    performance) RECEIPT_PHASE="P3d" ;;
    full) RECEIPT_PHASE="P3cd" ;;
  esac
  RECEIPT_DIR="$STATE_DIR/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/$RECEIPT_PHASE"
  mkdir -p "$RECEIPT_DIR" 2>/dev/null
  {
    echo "EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)"
    echo "VERSION=p3-${CHECK_MODE}@$(bash "$(dirname "$0")/gate-version.sh")"
    echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
    echo "MODE=$CHECK_MODE"
    echo "PHASE=$RECEIPT_PHASE"
    echo "EVIDENCE_PATH=$REPORT_FILE"
    echo "EVIDENCE_SHA256=$(hash_file "$REPORT_FILE")"
    echo "PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
    echo "CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$RECEIPT_DIR/receipt.txt" 2>/dev/null
  echo "[RECEIPT] Generated: $RECEIPT_DIR/receipt.txt"
  DOCS_MIRROR="docs/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/$RECEIPT_PHASE"
  mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null && echo "[RECEIPT] Mirrored: $DOCS_MIRROR/receipt.txt"
  [ "$FAIL" -gt 0 ] && { echo "GATE: FAIL（阻塞）"; exit 1; }
  [ "$WARN" -gt 0 ] && { echo "GATE: WARN（非阻塞）"; exit 0; }
  echo "GATE: PASS"; exit 0
}
main
