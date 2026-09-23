#!/usr/bin/env bash
# P3c/P3d 安全+性能 Gate（合并版）· 版本随 SKILL.md
# 功能：安全审计（@PreAuthorize覆盖率）+ 性能审计（N+1/P95）
set -uo pipefail
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
# v3.30.6: gj_enforce 双正本强制（path+SHA 配对行——旧版只写 SHA 单行，剥离/篡改不可重验）
source "$(dirname "${BASH_SOURCE[0]}")/gate_json_lib.sh"
# shellcheck disable=SC2034  # GJ_SKILL 由 gate_json_lib 函数消费
GJ_SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
    # v3.26.1: 接受 --service=<path> 等值形式（commands/security.md 历史示例用法）
    --service=*) [ -n "${1#--service=}" ] || { echo "[ERR] --service requires a non-flag value" >&2; exit 2; }; SERVICE="${1#--service=}"; shift ;;
    --mode)    [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --mode requires a non-flag value" >&2; exit 2; }; CHECK_MODE="$2"; shift 2 ;;
    --waiver)  [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --waiver requires a non-flag value" >&2; exit 2; }; WAIVER_FILE="$2"; shift 2 ;;
    --skip=*) SKIP_CHECKS="${SKIP_CHECKS} ${1#--skip=}"; shift ;;
    *) echo "[ERR] unknown argument: $1"; exit 2 ;;
  esac
done
case "$CHECK_MODE" in security|performance|full) ;; *) echo "[ERR] invalid mode: $CHECK_MODE"; exit 2 ;; esac
# v3.26.1: SERVICE 归一化——裸服务名（如 payment-service）在 backend/<name> 存在时
# 自动补全为路径，与 p3_completion_gate.sh 的服务名语义对齐（两种取值见 commands/security.md）。
if [ -n "$SERVICE" ] && [ ! -d "$SERVICE" ] && [ -d "backend/$SERVICE" ]; then
  SERVICE="backend/$SERVICE"
  info "SERVICE 归一化为路径: $SERVICE"
fi
# v3.15.5: feature 白名单共享校验（devflow_feature.sh）——封堵路径穿越（../evil 写穿项目外）与 grep -E 正则注入
source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
# v3.25.2: 证据树绑定（receipt_evidence_tree）——P3cd 收据纳入报告与两种 JSON
source "$SCRIPT_DIR/devflow_receipt.sh" 2>/dev/null || true
devflow_feature_validate "$FEATURE" || exit 2
REPORT_DIR="${WORK_DIR}/${FEATURE}"
REPORT_FILE="${REPORT_DIR}/p3-security-perf-report.md"
mkdir -p "$REPORT_DIR"
should_skip() { echo "$SKIP_CHECKS" | grep -q "$1"; }
has_waiver() {
  local key="$1"
  [ -f "$WAIVER_FILE" ] && grep -qx "P3CD_${key}=NOT_APPLICABLE" "$WAIVER_FILE"
}
# v3.28.4(P0-4)：waiver 纳入 skip-log 授权契约——waiver 文件 + skip-log 授权行二者缺一即 P0
_P3CD_WAIVED_KEYS=""
skiplog_authorized() {
  local key="$1" line reason by at evid
  local log="${STATE_DIR:-.devflow}/${FEATURE}/skip-log.txt"
  line=$(grep -E "^SKIP_P3CD_${key}=" "$log" 2>/dev/null | head -1)
  [ -n "$line" ] || return 1
  reason=$(echo "$line" | cut -d'|' -f1 | sed "s/^SKIP_P3CD_${key}=//")
  by=$(echo "$line" | grep -oE 'authorized-by=[^|]*' | cut -d= -f2)
  at=$(echo "$line" | grep -oE 'at=[^|]*' | cut -d= -f2)
  evid=$(echo "$line" | grep -oE 'approval=[^|]*' | cut -d= -f2)
  [ -n "$reason" ] && [ -n "${by//[[:space:]]/}" ] \
    && echo "$at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}([T ][0-9]{2}:[0-9]{2})?' \
    && [ -n "${evid//[[:space:]]/}" ]
}
not_applicable_or_fail() {
  local key="$1" message="$2"
  if has_waiver "$key"; then
    if skiplog_authorized "$key"; then
      warn "${message}（waiver=$WAIVER_FILE + skip-log 授权行齐备）"
      _P3CD_WAIVED_KEYS="${_P3CD_WAIVED_KEYS:+${_P3CD_WAIVED_KEYS},}${key}"
      SKIP=$((SKIP+1))
    else
      p0 "${message}（waiver 须配 skip-log 授权行：.devflow/${FEATURE}/skip-log.txt 一行 SKIP_P3CD_${key}=理由|authorized-by=授权人|at=日期|approval=审批证据）"
    fi
  else
    p0 "${message}（需 $key 证据，或 --waiver+skip-log 授权声明不适用）"
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
  # v3.26.1: 委托 checks/detect-n-plus-one.sh——旧单行 grep（for(...){...}.find 必须同行）
  # 对常规多行循环体全部漏检；检测器支持多行窗口 + JPA findById。检测器 rc=1（>5 处）
  # 或 strict 判 FAIL → P0；1-5 处 → WARN（与检测器容忍口径一致，waiver 可整项豁免）。
  local n1_script="$SCRIPT_DIR/../checks/detect-n-plus-one.sh"
  if [ -f "$n1_script" ]; then
    local n1_out n1_rc
    n1_out=$(bash "$n1_script" "$svc_dir" 2>&1); n1_rc=$?
    # 检测器两层 fail-closed 出口：shell 层"目录不存在"（backend 缺失）与
    # python 层"未发现服务目录"（目录在但无服务）——两者都不是 N+1 发现，
    # 走 NOT_APPLICABLE 判定（waiver 豁免 / 无 waiver 则 P0），勿误报超阈值。
    if printf '%s\n' "$n1_out" | grep -qE "未发现服务目录|目录不存在"; then
      not_applicable_or_fail PERFORMANCE "N+1 检测范围无服务目录（${svc_dir}）"
      return
    fi
    local n1_count
    n1_count=$(printf '%s\n' "$n1_out" | sed -n 's/.*发现 \([0-9]\{1,\}\) 处潜在 N+1.*/\1/p' | tail -1)
    n1_count="${n1_count:-0}"
    echo "| N+1 可疑模式数 | $n1_count |" >> "$REPORT_FILE"
    if [ "$n1_rc" -ne 0 ]; then
      p0 "N+1 检测 FAIL：超容忍阈值（详见 detect-n-plus-one.sh 输出）"
      printf '%s\n' "$n1_out" | grep -E '^\s+📄|^\s+L[0-9]+' | head -10 | sed 's/^/    /'
    elif [ "$n1_count" -gt 0 ]; then
      warn "N+1 可疑 ${n1_count} 处（≤5 容忍，建议优化；详见 detect-n-plus-one.sh 输出）"
    else
      ok "N+1 检测 PASS"
    fi
    return
  fi
  # 检测器缺失时回退旧单行 grep（保守降级，输出注明）
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
  echo "| N+1 可疑模式数 | ${suspicious}（单行回退模式） |" >> "$REPORT_FILE"
  [ "$suspicious" -eq 0 ] && ok "N+1 检测 PASS" || p0 "N+1 检测 FAIL：发现 $suspicious 处"
}

check_response_time() {
  echo ""; echo "=== §3 性能审计 — API 响应时间（JSON 正本对账） ==="
  should_skip "response" || should_skip "perf" && { not_applicable_or_fail PERFORMANCE "响应时间检查被跳过"; return; }
  # v3.25.2(P1)：以 performance.json 为唯一事实源——逐场景核对压测报告实测 P95
  # 与 JSON 一致（双事实源消除）；阈值判定来自 JSON（v3.25.2 前的固定 500ms 已废），
  # p95>threshold 的 PASS 由 df_validate check_performance 拦截，此处按场景断言 PASS。
  local pj="${STATE_DIR:-.devflow}/${FEATURE}/performance.json"
  if [ ! -f "$pj" ]; then
    p0 "performance.json 缺失（结构化正本，先走 df_pipeline.py performance）"
    return
  fi
  echo "| 正本 | $pj |" >> "$REPORT_FILE"
  local rt_out
  rt_out=$( (unset LC_ALL; "${DEVFLOW_PY[@]}" - "$pj" <<'PYEOF'
import json, re, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
rp = (d.get("report_path") or "").strip()
try:
    report = open(rp, encoding="utf-8", errors="replace").read()
except OSError:
    print(f"P0\treport_path 不可读: {rp}")
    sys.exit(0)
fail = 0
for s in d.get("scenarios", []):
    name, p95, thr, st = s.get("name"), s.get("p95_ms"), s.get("threshold_ms"), s.get("status")
    line = f"P95 {p95} ms"
    if line not in report:
        print(f"P0\t场景「{name}」实测 {line} 未在压测报告找到（JSON 与报告双正本漂移）")
        fail = 1
        continue
    if isinstance(p95, int) and isinstance(thr, int) and p95 > thr:
        print(f"P0\t场景「{name}」p95={p95}ms 超冻结阈值 {thr}ms")
        fail = 1
        continue
    print(f"OK\t场景「{name}」P95={p95}ms ≤ 阈值 {thr}ms，PASS")
sys.exit(1 if fail else 0)
PYEOF
) ) || true
  local row bad=0
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    case "$row" in
      P0*) p0 "${row#P0	}"; bad=1 ;;
      OK*) ok "${row#OK	}" ;;
    esac
  done <<< "$rt_out"
  [ "$bad" -eq 0 ] && echo "| 场景对账 | 全部通过 |" >> "$REPORT_FILE"
}

check_sql_injection() {
  echo ""; echo "=== §4 安全审计 — SQL 注入检测 ==="
  should_skip "security" && { SKIP=$((SKIP+1)); return; }
  local svc_dir="${SERVICE:-backend}"
  local count
  count=$( (find "$svc_dir" -name "*.java" -type f 2>/dev/null | grep -v '/test/' | xargs grep -lE "createQuery[[:space:]]*\([[:space:]]*[\"'].*\{|\.createNativeQuery" 2>/dev/null || true) | wc -l | tr -d ' ' )
  echo "| SQL 原生查询文件数 | $count |" >> "$REPORT_FILE"
  [ "$count" -eq 0 ] && ok "SQL 注入检测 PASS" || warn "发现 $count 处原生 SQL"
  # v3.26.1: MyBatis ${} 拼接扫描（fail-closed）——MyBatis 项目第一大注入面此前零覆盖。
  #   a) *Mapper.xml 中任意 ${param}；b) Java 注解 SQL @Select/@Update/@Insert/@Delete 含 ${}。
  #   正当用途（白名单排序等）在该行写 `mybatis-dollar: allow` 并说明理由；waiver 可整项豁免。
  local dollar_hits
  # 注意：不用 case——macOS/Git Bash 3.2 的 $() 内多行 case 语法不受支持（windows-compatibility 契约）
  dollar_hits=$( (find "$svc_dir" \( -name "*Mapper.xml" -o -name "*.java" \) -type f 2>/dev/null | grep -v '/test/' \
    | while IFS= read -r _f; do
        if [ "${_f%*Mapper.xml}" != "$_f" ]; then
          grep -nE '\$\{' "$_f" 2>/dev/null
        else
          grep -nE '@(Select|Update|Insert|Delete)\(.*\$\{' "$_f" 2>/dev/null
        fi
      done | grep -v 'mybatis-dollar: allow' || true) )
  if [ -n "$dollar_hits" ]; then
    local dollar_n
    dollar_n=$(printf '%s\n' "$dollar_hits" | grep -c . || true)
    echo "| MyBatis \${} 拼接 | $dollar_n 处 |" >> "$REPORT_FILE"
    p0 "MyBatis \${} 拼接注入风险：$dollar_n 处（改用 #{} 或白名单绑定；正当用途行内标注 mybatis-dollar: allow）"
    printf '%s\n' "$dollar_hits" | head -10 | sed 's/^/    /'
  else
    echo "| MyBatis \${} 拼接 | 0 处 |" >> "$REPORT_FILE"
    ok "MyBatis \${} 注入检测 PASS"
  fi
}

check_sensitive_data() {
  echo ""; echo "=== §5 安全审计 — 敏感数据暴露 ==="
  should_skip "security" && { SKIP=$((SKIP+1)); return; }
  # v3.26.2: dto_dir 修复——旧默认 "${SERVICE:-backend}/src/main/java" 在多模块布局下
  # 等于 backend/src/main/java（不存在）→ 扫 0 文件却报 PASS（假绿）。现与 §1/§4 同口径，
  # 在服务根（或 backend 全树）下递归找 DTO/VO。
  local dto_dir="${SERVICE:-backend}"
  local count
  count=$( (find "$dto_dir" -type f \( -name "*DTO.java" -o -name "*VO.java" \) -exec grep -lE "password|secret|token|key" {} + 2>/dev/null || true) | wc -l | tr -d ' ' )
  echo "| 含敏感字段的 DTO 数 | $count |" >> "$REPORT_FILE"
  [ "$count" -eq 0 ] && ok "敏感数据暴露检测 PASS" || warn "发现 $count 个 DTO 含敏感字段"
}

check_token_comparison() {
  echo ""; echo "=== §6 安全审计 — 令牌/密钥比较方式（L-STACK-004） ==="
  should_skip "security" && { SKIP=$((SKIP+1)); return; }
  # v3.26.3: L-STACK-004 入检——String.equals 短路比较令牌/密钥存在时序侧信道；
  # 常量时间比较（MessageDigest.isEqual / hmac.compare_digest）才安全。静态启发式
  # 仅按变量名判定，可能有误报 → WARN 级（P3b 复核），不直接 P0。
  local svc_dir="${SERVICE:-backend}"
  local hits
  hits=$( (find "$svc_dir" -name "*.java" -type f 2>/dev/null | grep -v '/test/' \
    | xargs grep -inE '(token|secret|password|passwd|apikey|api_key|credential|sign)[A-Za-z_]*\.equals\(' 2>/dev/null || true) )
  if [ -n "$hits" ]; then
    local n
    n=$(printf '%s\n' "$hits" | grep -c . || true)
    echo "| 敏感凭据 equals 比较处数 | $n |" >> "$REPORT_FILE"
    warn "发现 $n 处敏感凭据疑似 String.equals 比较（时序侧信道，须改 MessageDigest.isEqual 常量时间比较，P3b 逐条复核）"
    printf '%s\n' "$hits" | head -8 | sed 's/^/    /'
  else
    echo "| 敏感凭据 equals 比较处数 | 0 |" >> "$REPORT_FILE"
    ok "令牌/密钥比较方式检测 PASS"
  fi
}

main() {
  echo ""; echo "══════════════════════════════════════════════════"
  echo "  P3c+P3d 安全+性能 Gate · v3.14.0"
  echo "  Feature: $FEATURE"
  echo "══════════════════════════════════════════════════"
  { echo "# P3c+P3d 安全+性能 Gate 报告";
    echo "## Feature: $FEATURE | $(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo ""; } > "$REPORT_FILE"
  # ---------- v3.25.2(P1-b): 结构化产物层 security/performance JSON 失败关闭 ----------
  # SKILL.md「全阶段结构化产物」契约的 P3c/P3d 落地：JSON 缺失或校验失败即 P0，
  # 手写审计报告必须由 df_pipeline.py security/performance 从 JSON 正本渲染派生。
  GATE_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
  STATE_DIR="${STATE_DIR:-.devflow}"
  SECURITY_JSON="${STATE_DIR}/${FEATURE}/security.json"
  PERFORMANCE_JSON="${STATE_DIR}/${FEATURE}/performance.json"
  # v3.30.7: waiver+skip-log 授权 NOT_APPLICABLE 时跳过对应 kind 的强制（第 2 轮实证：
  # 旧版 gj_enforce 无条件先行，NOT_APPLICABLE 流程永久不可达且无收据留痕）
  _waive_sec=0; _waive_perf=0
  if [ -n "$WAIVER_FILE" ] && [ -f "$WAIVER_FILE" ]; then
    grep -qE "^P3CD_SECURITY=NOT_APPLICABLE" "$WAIVER_FILE" && grep -qE "^SKIP_P3CD_SECURITY=" "${STATE_DIR}/${FEATURE}/skip-log.txt" 2>/dev/null && _waive_sec=1
    grep -qE "^P3CD_PERFORMANCE=NOT_APPLICABLE" "$WAIVER_FILE" && grep -qE "^SKIP_P3CD_PERFORMANCE=" "${STATE_DIR}/${FEATURE}/skip-log.txt" 2>/dev/null && _waive_perf=1
  fi
  # v3.30.6: 正本 fail-closed 校验 + GJ_BIND 配对行（收据写入处 printf）
  case "$CHECK_MODE" in
    security|full)
      if [ "$_waive_sec" = "1" ]; then echo "[OK] security 经 waiver+skip-log 显式豁免（SECURITY_WAIVED=1 留痕）"; else
        gj_enforce security || { echo "[P0] security JSON 正本未通过 Gate 强制"; exit 1; } ; fi ;;
  esac
  case "$CHECK_MODE" in
    performance|full)
      if [ "$_waive_perf" = "1" ]; then echo "[OK] performance 经 waiver+skip-log 显式豁免（PERFORMANCE_WAIVED=1 留痕）"; else
        gj_enforce performance || { echo "[P0] performance JSON 正本未通过 Gate 强制"; exit 1; } ; fi ;;
  esac
  enforce_phase_json() {
    local kind="$1" p="$2"
    if [ ! -f "$p" ]; then
      p0 "${kind}.json 缺失: ${p}——必须产出结构化审计正本（契约 schemas/${kind}.schema.json，管线 df_pipeline.py ${kind}，失败不渲染、不进 Gate）"
      return 1
    fi
    if ! devflow_py_ok; then
      p0 "${kind}.json 存在但 Python 3 不可用（python3/python/py 均未找到）——结构化校验无法执行（失败关闭）"
      return 1
    fi
    if ! (unset LC_ALL; "${DEVFLOW_PY[@]}" "${GATE_SCRIPT_DIR}/df_validate.py" --kind "$kind" --input "$p" --workspace . >/dev/null 2>&1); then
      (unset LC_ALL; "${DEVFLOW_PY[@]}" "${GATE_SCRIPT_DIR}/df_validate.py" --kind "$kind" --input "$p" --workspace . 2>&1 | head -4 | sed 's/^/    /')
      p0 "${kind}.json 校验失败——修复后重跑 df_pipeline.py ${kind} 再过 Gate"
      return 1
    fi
    # v3.25.2：report_path 三重约束——①工作区内相对路径；②真实落盘；③与 df_render
    # 从当前 JSON 的渲染产物逐字节一致（手工改动/双正本漂移即 P0；validate 不查，Gate 查）。
    local rp rp_err
    rp_err=$( (unset LC_ALL; "${DEVFLOW_PY[@]}" - "$p" <<'PYEOF'
import json, os, sys
rp = (json.load(open(sys.argv[1])).get("report_path") or "").strip()
if not rp:
    print("缺 report_path"); sys.exit(1)
if os.path.isabs(rp):
    print(f"必须是工作区内相对路径（得到绝对路径 {rp}）"); sys.exit(1)
base = os.path.realpath(".")
full = os.path.realpath(rp)
if full != base and not full.startswith(base + os.sep):
    print(f"越出工作区: {rp}"); sys.exit(1)
if not os.path.isfile(full):
    print(f"不存在: {rp}——必须由 df_pipeline.py 渲染落盘"); sys.exit(1)
PYEOF
) 2>&1) || true
    if [ -n "$rp_err" ]; then
      p0 "${kind}.json report_path 非法: $rp_err"
      return 1
    fi
    rp=$( (unset LC_ALL; "${DEVFLOW_PY[@]}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("report_path",""))' "$p" 2>/dev/null) || true)
    # 渲染一致性：report_path 必须与 df_render 从当前 JSON 的输出逐字节一致
    local expect
    expect=$(mktemp -t p3render.XXXXXX)
    if ! (unset LC_ALL; "${DEVFLOW_PY[@]}" "${GATE_SCRIPT_DIR}/df_render.py" "$kind" --input "$p" --out "$expect" >/dev/null 2>&1); then
      p0 "${kind} 报告渲染失败（渲染器/JSON 异常）"
      rm -f "$expect"
      return 1
    fi
    if ! cmp -s "$expect" "$rp"; then
      p0 "${kind} 报告与 JSON 渲染产物不一致: ${rp}——手工改动/双正本漂移，重跑 df_pipeline.py ${kind}"
      rm -f "$expect"
      return 1
    fi
    rm -f "$expect"
    ok "${kind}.json 校验通过（结构化正本 + 报告渲染一致）"
    return 0
  }
  case "$CHECK_MODE" in
    security)
      enforce_phase_json security "$SECURITY_JSON" || true
      check_security; check_sql_injection; check_sensitive_data; check_token_comparison ;;
    performance)
      enforce_phase_json performance "$PERFORMANCE_JSON" || true
      check_n_plus_one; check_response_time ;;
    full)
      enforce_phase_json security "$SECURITY_JSON" || true
      enforce_phase_json performance "$PERFORMANCE_JSON" || true
      check_security; check_n_plus_one; check_response_time; check_sql_injection; check_sensitive_data; check_token_comparison ;;
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
  # v3.27.5（FB-20260918-002）：full 是终态绑定——签发 P3cd 后删除被取代的 P3c/P3d
  # 子收据（含 docs 镜像）。子收据的证据树绑定分项渲染时的共享报告字节，full 重渲染
  # 后必然失配（死循环），audit-receipts 会误报"证据绑定 broken"。P3cd 覆盖安全+性能
  # 双域，子收据属过程性产物。
  if [ "$CHECK_MODE" = "full" ]; then
    for _sub in P3c P3d; do
      rm -f "$STATE_DIR/${FEATURE:?}/gates/$_sub/receipt.txt" \
            "docs/${FEATURE}/gates/$_sub/receipt.txt" 2>/dev/null || true
    done
  fi
  RECEIPT_DIR="$STATE_DIR/${FEATURE:?FEATURE is required for receipt (default fallback removed v3.14.0)}/gates/$RECEIPT_PHASE"
  mkdir -p "$RECEIPT_DIR" 2>/dev/null
  {
    # v3.26.1: EXIT_CODE 移到块尾计算——旧版在此处（块首）计算，其后 jq 缺失/证据树
    # 失败的 p0 会让 FAIL 增加，但收据里 EXIT_CODE 已冻结为 0（"命令失败、收据成功"
    # 矛盾状态，审计重验即漂移）。收据字段顺序不参与机器契约（键值对逐行解析）。
    echo "VERSION=p3-${CHECK_MODE}@$(bash "$(dirname "$0")/gate-version.sh")"
    echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
    echo "MODE=$CHECK_MODE"
    echo "PHASE=$RECEIPT_PHASE"
    echo "EVIDENCE_PATH=$REPORT_FILE"
    echo "EVIDENCE_SHA256=$(hash_file "$REPORT_FILE")"
    # v3.25.2(P1-b): 结构化正本绑定——篡改 security/performance.json 后审计重验即 FAIL
    case "$CHECK_MODE" in
      security|full)
        [ -f "$SECURITY_JSON" ] && echo "SECURITY_JSON_SHA256=$(hash_file "$SECURITY_JSON")" || echo "SECURITY_JSON=missing" ;;
    esac
    case "$CHECK_MODE" in
      performance|full)
        [ -f "$PERFORMANCE_JSON" ] && echo "PERFORMANCE_JSON_SHA256=$(hash_file "$PERFORMANCE_JSON")" || echo "PERFORMANCE_JSON=missing" ;;
    esac
    printf '%s' "$GJ_BIND"
    # v3.30.7: 豁免留痕行（audit 侧以 WAIVED+skip-log 授权替代绑定行核验）
    [ "$_waive_sec" = "1" ] && echo "SECURITY_WAIVED=1"
    [ "$_waive_perf" = "1" ] && echo "PERFORMANCE_WAIVED=1"
    # v3.25.2(P1)：证据树 fail-closed——缺 jq 不得静默降级为"只保护单一报告"
    # （否则审计无法重验 security/performance JSON，Gate 后替换即逃逸）。
    if ! command -v jq >/dev/null 2>&1; then
      p0 "jq 不可用——无法写入 EVIDENCE_PATHS_JSON/树哈希，security/performance JSON 将不受审计保护（失败关闭，请安装 jq）"
    else
      _P3CD_EV_ARGS=("$REPORT_FILE")
      # JSON 的 report_path（工作区内、渲染一致已由 enforce 保证）一并纳入证据树
      local _p3cd_sr _p3cd_pf
      case "$CHECK_MODE" in
        security|full)
          _p3cd_sr=$( (unset LC_ALL; "${DEVFLOW_PY[@]}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("report_path",""))' "$SECURITY_JSON" 2>/dev/null) || true)
          [ -n "$_p3cd_sr" ] && [ -f "$_p3cd_sr" ] && _P3CD_EV_ARGS+=("$_p3cd_sr") ;;
      esac
      case "$CHECK_MODE" in
        performance|full)
          _p3cd_pf=$( (unset LC_ALL; "${DEVFLOW_PY[@]}" -c 'import json,sys; print(json.load(open(sys.argv[1])).get("report_path",""))' "$PERFORMANCE_JSON" 2>/dev/null) || true)
          [ -n "$_p3cd_pf" ] && [ -f "$_p3cd_pf" ] && _P3CD_EV_ARGS+=("$_p3cd_pf") ;;
      esac
      [ -f "$SECURITY_JSON" ] && _P3CD_EV_ARGS+=("$SECURITY_JSON")
      [ -f "$PERFORMANCE_JSON" ] && _P3CD_EV_ARGS+=("$PERFORMANCE_JSON")
      _P3CD_TREE=$(receipt_evidence_tree "${_P3CD_EV_ARGS[@]}")
      if [ -n "$_P3CD_TREE" ]; then
        _P3CD_PATHS='['
        _p3cd_first=1
        for _p3cd_f in "${_P3CD_EV_ARGS[@]}"; do
          _p3cd_one=$(jq -cn --arg p "$_p3cd_f" '$p' 2>/dev/null) || _p3cd_one='""'
          [ "$_p3cd_first" -eq 1 ] || _P3CD_PATHS="${_P3CD_PATHS},"
          _P3CD_PATHS="${_P3CD_PATHS}${_p3cd_one}"
          _p3cd_first=0
        done
        _P3CD_PATHS="${_P3CD_PATHS}]"
        echo "EVIDENCE_PATHS_JSON=$_P3CD_PATHS"
        echo "EVIDENCE_TREE_SHA256=$_P3CD_TREE"
      else
        p0 "证据树哈希计算失败（receipt_evidence_tree 异常）——拒绝产出不受审计保护的收据"
      fi
    fi
    echo "EXIT_CODE=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)"
    echo "PASS=$PASS FAIL=$FAIL WARN=$WARN SKIP=$SKIP"
    echo "WAIVED_KEYS=${_P3CD_WAIVED_KEYS:-none}"
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
