#!/usr/bin/env bash
# =============================================================================
# s6_final_verification_gate.sh · 版本随 SKILL.md
# P6 终验 Gate（final verification）——部署前最后一道验收点/测试证据闸门
# =============================================================================
# 背景（用户复审 P0-1）：s6_first_pass_accuracy.sh 只计算首轮准确率（首轮允许失败，
# FAILED>0 仅作指标），4 PASS + 1 FAIL + 零测试证据仍 P6 GATE PASS。两件事必须拆开：
#   - first-pass accuracy >= 80%：首轮质量指标（s6_first_pass_accuracy.sh，保持不动）
#   - final verification：部署前必须 FAIL=0 + 五类测试执行证据（本脚本）
#
# 契约（.devflow/<feature>/final-verification.tsv）：
#   ID\tSTATUS —— 验收点最终状态，全部必须 PASS（任一 FAIL/SKIP 即阻断）
# 契约（.devflow/<feature>/test-evidence.env）：
#   UNIT_CMD/UNIT_EXIT/UNIT_REPORT_PATH[/UNIT_REPORT_SHA256]
#   INTEGRATION_CMD/... CLIENT_CMD/... LOAD_CMD/... STAGING_CMD/...
#   ENVIRONMENT=dev|staging|production
# 校验：每类命令非空、退出码=0、报告由本轮命令创建或内容发生变化、报告文件存在且
#（若声明）SHA-256 一致、环境边界合法。报告不得使用执行前已存在且未变化的陈旧文件。
# v3.21.0: STAGING 类新增真实容器签名校验（java -jar / spring-boot:run|bootRun /
#   curl http(s) 探测三选一；P6_STAGING_NOT_CONTAINER）——MockMvc/单元级命令冒充
#   STAGING 曾可过终验（治理服务复盘：schema 漂移仅在真实容器暴露）。
#   豁免：STAGING_EXEMPT=1 且冻结前端范围=not-applicable（与 CLIENT_EXEMPT 同型对账）。
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
source "$(cd "$(dirname "$0")" && pwd)/devflow_receipt.sh"
# v3.22.0: 文档层中文化（中文优先、英文回退）
source "$(cd "$(dirname "$0")" && pwd)/devflow_paths.sh"
source "$(cd "$(dirname "$0")" && pwd)/perf-track.sh"
perf_start "P6-final"

FAIL=0; PASS=0; WARN=0
P6F_STARTED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

FEATURE="${1:-}"
[ -n "$FEATURE" ] || { echo "Usage: $0 <feature>"; exit 2; }
devflow_feature_validate "$FEATURE" || exit 2
EFF_FEATURE="$(devflow_feature "$FEATURE")" || { echo "[FATAL] feature 推导失败"; exit 2; }
STATE_ROOT="${STATE_DIR:-.devflow}"
DIR="$STATE_ROOT/$FEATURE"
FINAL_TSV="$DIR/final-verification.tsv"
TEST_EV="$DIR/test-evidence.env"
# v3.16.11（P0-1）: 冻结验收点基准（P4 freeze 产出）——终验 ID 集合的对账源
BASELINE_TSV="$DIR/first-pass-baseline.tsv"
BASELINE_META="$DIR/first-pass-meta.env"
# v3.16.12（P0-2）: Gate 自己执行五类命令并固化实际退出码、stdout/stderr。
# 不再只信 test-evidence.env 里可手写的 *_EXIT=0；执行记录和日志随 P6-final
# 收据一并入证据树，后续 complete/audit 会重新验证。
EXEC_DIR="$DIR/test-executions"
EXEC_RECORD="$DIR/test-execution-results.env"
EXEC_TMP_DIR=""
EXEC_TMP_RECORD=""
EXEC_LOGS=()

_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; else sha256sum "$1" 2>/dev/null | awk '{print $1}'; fi; }
_ev() { sed -n "s/^$1=//p" "$FROZEN_TEST_EV" 2>/dev/null | head -1; }
_kind_file() {
  case "$1" in
    UNIT) echo unit ;;
    INTEGRATION) echo integration ;;
    CLIENT) echo client ;;
    LOAD) echo load ;;
    STAGING) echo staging ;;
    *) echo unknown ;;
  esac
}

_is_shell_wrapper() {
  local first
  # 先扫整条命令，覆盖 X='a b' bash -c、export X=1; bash -c、绝对路径
  # 及 env/command 转包；仅按空格取首 token 会被引号/分号绕过。
  if printf '%s' "$1" | grep -qE '(^|[[:space:];|&()])([^[:space:];|&()]*/)?(bash|sh|zsh|env|command|exec)([[:space:];|&()]|$)'; then
    return 0
  fi
  # 跳过前导 VAR=value 赋值后再检查首个实际命令；否则 X=1 bash -c ...
  # 可绕过只看第一个 token 的黑名单。
  first=$(printf '%s' "$1" | awk '{for (i=1; i<=NF; i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=.*/) {print $i; exit}}')
  [ -n "$first" ] || return 0
  case "$first" in
    bash|*/bash|sh|*/sh|zsh|*/zsh|env|*/env|command|exec) return 0 ;;
    *) return 1 ;;
  esac
}

_prepare_execution_evidence() {
  [ -n "$EXEC_TMP_RECORD" ] || { p0 "无法创建隔离测试执行记录"; return 1; }
  {
    echo "# P6 final live execution record"
    echo "STARTED_AT=$P6F_STARTED_AT"
  } > "$EXEC_TMP_RECORD" || { p0 "无法创建测试实际执行记录: $EXEC_TMP_RECORD"; return 1; }
  return 0
}

# v3.20.2(P0-3): 测试命令来源绑定——可执行+退出码 0+报告非空 ≠ 真实执行过测试。
# 受信运行器白名单 + 工程清单存在性 + 报表生成器拒绝（awk 直接打印报告的夹具曾通过 P6）。
_validate_test_provenance() { # <kind> <command>
  local kind="$1" command="$2" first _prov_manifest="" _mf _found=""
  first=$(printf '%s' "$command" | awk '{for (i=1; i<=NF; i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=.*/) {print $i; exit}}')
  case "$first" in
    echo|printf|cat|tee|awk|sed|head|tail|touch|cp|mv|true|yes|seq|openssl|shasum|sha256sum)
      p0 "${kind} 测试命令首词为报表/文件生成器（${first}）——不是测试运行器，无法证明执行过测试（P6_CMD_NOT_RUNNER）" ;;
  esac
  # v3.28.4(P1-9)：解释器内联与自建脚本不得作为测试证据命令——
  # 首词受信但命令体自写 = "被执行的东西"由被门禁者定义（review P0-3）
  case " $command " in
    *" -c "*|*" -c\""*|*" -c'"*|*" --eval "*|*" -e "*)
      p0 "${kind} 测试命令含解释器内联（-c/-e/--eval）——内联代码无法与任何测试计划绑定（P6_CMD_INLINE_EVAL）" ;;
  esac
  case "$command" in
    *"./scripts/"*)
      p0 "${kind} 测试命令引用自建脚本（./scripts/*）——被门禁会话可自写脚本自我证明（P6_CMD_SELF_SCRIPT）" ;;
  esac
  case "$first" in
    mvn|mvnw|./mvnw)              _prov_manifest="pom.xml" ;;
    gradle|./gradlew)             _prov_manifest="build.gradle" ;;
    npm|pnpm|yarn)                _prov_manifest="package.json" ;;
    pytest|python|python3)        _prov_manifest="pytest.ini pyproject.toml setup.cfg" ;;
    go)                           _prov_manifest="go.mod" ;;
    cargo)                        _prov_manifest="Cargo.toml" ;;
    make)                         _prov_manifest="Makefile" ;;
    dotnet)                       _prov_manifest="*.csproj" ;;
    flutter)                      _prov_manifest="pubspec.yaml" ;;
    java|curl)
      # v3.21.0: 真实容器执行器仅对 STAGING 类开放（java -jar / curl 探测）；
      # 其余类别仍走黑名单拒绝。工程清单绑定要求不变。
      if [ "$kind" = "STAGING" ]; then
        _prov_manifest="pom.xml build.gradle package.json Makefile"
      else
        p0 "${kind} 测试命令首词 ${first} 不在受信测试运行器清单（mvn/gradle/npm/pnpm/yarn/pytest/go/cargo/make/dotnet/flutter）——无法证明真实执行（P6_CMD_PROVENANCE）"
      fi ;;
    bash|sh)
      p0 "${kind} 测试命令以 bash/sh 包装——来源不可证明，请直接调用受信测试运行器（P6_CMD_PROVENANCE）" ;;
    *)
      p0 "${kind} 测试命令首词 ${first} 不在受信测试运行器清单（mvn/gradle/npm/pnpm/yarn/pytest/go/cargo/make/dotnet/flutter）——无法证明真实执行（P6_CMD_PROVENANCE）" ;;
  esac
  for _mf in $_prov_manifest; do
    case "$_mf" in
      *.csproj) [ -n "$(ls ./*.csproj 2>/dev/null)" ] && _found="$_mf" && break ;;
      *) [ -f "$_mf" ] && _found="$_mf" && break ;;
    esac
  done
  [ -n "$_found" ] || p0 "${kind} 测试运行器 ${first} 未找到工程清单（${_prov_manifest}）——命令未绑定任何测试计划/工程（P6_CMD_PROVENANCE）"
}

# v3.21.0: STAGING 类证据必须是真实容器执行——MockMvc/单元级命令（mvn test）冒充
# STAGING 曾可过终验（治理服务复盘：schema 漂移 / fail-open 探活 / 静态资源 500
# 全部只在真实 java -jar 容器暴露）。真实容器签名（三选一）：java … -jar 自托管
# 进程 / spring-boot:run|bootRun 运行目标 / curl 对 http(s) 端点的探测。
# 不满足即 P0；栈扩展（docker compose / next start 等）只需追加一个 || 分支。
_validate_staging_container() { # <command>
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qE '(^|[[:space:];&])java([[:space:]]+[^[:space:];|&]+)*[[:space:]]-jar([[:space:];|&]|$)' \
     || printf '%s' "$cmd" | grep -qE 'spring-boot:run|bootRun' \
     || printf '%s' "$cmd" | grep -qE '(^|[[:space:];&])curl[[:space:]][^|;&]*https?://'; then
    return 0
  fi
  p0 "STAGING 证据非真实容器执行: ${cmd} —— STAGING 须为 java -jar 启动容器、spring-boot:run/bootRun、或对 http(s) 端点的 curl 探测；MockMvc/单元级证据不构成 STAGING（P6_STAGING_NOT_CONTAINER）"
  return 1
}

_validate_client_browser() { # <command>
  # v3.28.1（L-M01-011 续）：CLIENT 证据必须是真实浏览器 E2E——playwright/cypress/puppeteer/
  # selenium 之一（或 npm script 引用它们）；vitest/jest 等组件单元测试不构成 CLIENT 证据。
  local cmd="$1"
  if printf '%s' "$cmd" | grep -qiE 'playwright|cypress|puppeteer|selenium|webdriver|browser.*(test|e2e)|e2e.*run|test.*e2e'; then
    return 0
  fi
  # 兼容：npm run <script> 且 package.json 中该 script 引用了 E2E 框架——Gate 无法读 package.json，
  # 但接受常见的 script 命名（test:e2e / e2e / e2e:test / browser-test）
  if printf '%s' "$cmd" | grep -qiE 'npm[[:space:]]+run[[:space:]].*(e2e|e2e:|browser)'; then
    return 0
  fi
  p0 "CLIENT 证据非真实浏览器 E2E: ${cmd} —— CLIENT 须为 playwright/cypress/puppeteer/selenium 级的浏览器自动化测试（含 npm run test:e2e）；vitest/jest 等组件单元测试不构成 CLIENT 证据（P6_CLIENT_NOT_BROWSER）"
  return 1
}

_run_test_command() { # <kind> <command> <declared-exit>
  local kind="$1" command="$2" declared_exit="$3" log tmp_log actual started finished file_key first executable executable_before_sha executable_after_sha log_bytes
  file_key=$(_kind_file "$kind")
  log="$EXEC_DIR/${file_key}.log"
  tmp_log="$EXEC_TMP_DIR/${file_key}.log"
  first=$(printf '%s' "$command" | awk '{for (i=1; i<=NF; i++) if ($i !~ /^[A-Za-z_][A-Za-z0-9_]*=.*/) {print $i; exit}}')
  executable=$(command -v "$first" 2>/dev/null || true)
  executable_before_sha=$(_sha "$executable")
  [ -n "$executable" ] && [ -n "$executable_before_sha" ] || p0 "${kind} 无法解析可执行文件或其 SHA（P6_EXECUTABLE_REQUIRED）"
  started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  # 受控项目的冻结测试命令在 workspace 根运行；stdout/stderr 均保存为后续可重验的证据。
  bash -c "$command" > "$tmp_log" 2>&1
  actual=$?
  log_bytes=$(wc -c < "$tmp_log" 2>/dev/null | tr -d ' ')
  finished=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  {
    echo "${kind}_CMD=$command"
    echo "${kind}_DECLARED_EXIT=$declared_exit"
    echo "${kind}_ACTUAL_EXIT=$actual"
    echo "${kind}_EXECUTABLE_PATH=$executable"
    executable_after_sha=$(_sha "$executable")
    echo "${kind}_EXECUTABLE_SHA256_BEFORE=$executable_before_sha"
    echo "${kind}_EXECUTABLE_SHA256_AFTER=$executable_after_sha"
    echo "${kind}_LOG_PATH=$log"
    echo "${kind}_LOG_SHA256=$(_sha "$tmp_log")"
    echo "${kind}_LOG_BYTES=${log_bytes:-0}"
    echo "${kind}_STARTED_AT=$started"
    echo "${kind}_FINISHED_AT=$finished"
  } >> "$EXEC_TMP_RECORD"
  [ "$executable_before_sha" = "$executable_after_sha" ] || p0 "${kind} 执行文件在运行期间发生变化"
  EXEC_LOGS+=("$log")
  if [ "$actual" -ne 0 ]; then
    p0 "${kind} 实际执行失败: exit=${actual}（cmd: ${command}；日志: ${log}）"
  else
    pass "${kind} 命令已实际执行且 exit=0（日志: ${log}）"
  fi
  if [ "$actual" -eq 0 ] && [ "${log_bytes:-0}" -eq 0 ]; then
    p0 "${kind} Gate 执行捕获为空（P6_EXECUTION_LOG_EMPTY）——不得用命令重定向隐藏 stdout/stderr；测试报告可另存，但运行器必须留下非空输出"
  fi
  if [ "$declared_exit" != "$actual" ]; then
    p0 "${kind} 声明 EXIT=${declared_exit} 与实际执行 exit=${actual} 不一致——不得信任手写退出码"
  fi
  _env_after=$(_sha "$TEST_EV")
  echo "${kind}_TEST_EVIDENCE_SHA256_AFTER=$_env_after" >> "$EXEC_TMP_RECORD"
  [ "$_env_after" = "$TEST_EV_INITIAL_SHA" ] || p0 "${kind} 执行期间篡改 test-evidence.env 输入清单"
}

echo "=== §0 终验文件存在性 ==="
[ -f "$FINAL_TSV" ] && pass "final-verification.tsv exists" || p0 "final-verification.tsv missing（验收点最终状态未记录）"
[ -f "$TEST_EV" ] && pass "test-evidence.env exists" || p0 "test-evidence.env missing（五类测试执行证据未记录）"
[ "$FAIL" -gt 0 ] && { echo "P6-FINAL GATE: FAIL (missing inputs)"; exit 1; }
# v3.16.21: 哈希工具是证据绑定的硬依赖；双缺失时空字符串不能参与相等比较而假绿。
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
  echo "[P0] P6_HASH_TOOL_REQUIRED: shasum/sha256sum 均不可用，拒绝无哈希终验" >&2
  exit 2
fi

echo ""
echo "=== §0.5 冻结验收点基准对账 ==="
# v3.16.11（P0-1）: 终验 ID 集合必须与 P4 冻结 baseline 完全相等——此前只查
# "现有行是否全 PASS"，无 baseline 时 100 个冻结点只提交 1 个 PASS 也过
#（PoC：ONLY-ONE PASS 无 baseline 仍 GATE PASS/EXIT=0）
if [ ! -f "$BASELINE_TSV" ]; then
  p0 "first-pass-baseline.tsv 缺失: ${BASELINE_TSV}——终验无法与冻结验收点对账（P4 freeze 是前置）"
elif [ ! -f "$BASELINE_META" ]; then
  p0 "first-pass-meta.env 缺失: ${BASELINE_META}——冻结元数据（criteria/design 哈希）不可追溯"
else
  pass "baseline 存在: $BASELINE_TSV"
  _BASE_IDS=$(tail -n +2 "$BASELINE_TSV" 2>/dev/null | cut -f1 | LC_ALL=C sort -u)
  _BASE_N=$(printf '%s\n' "$_BASE_IDS" | grep -c . || true)
  echo "  frozen acceptance points: $_BASE_N"
  # ID 格式校验（与 s4 freeze 提取口径一致：M-XX-FXX-AXX）
  _FMT_BAD=$(awk -F'\t' 'NR>1 && $1 !~ /^M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}$/ {print $1}' "$FINAL_TSV" | head -3)
  [ -n "$_FMT_BAD" ] && p0 "final TSV 含非法格式 ID（须 M-XX-FXX-AXX）: $(printf '%s ' $_FMT_BAD)"
  # 重复 ID
  _DUP=$(awk -F'\t' 'NR>1 {n[$1]++} END {for (id in n) if (n[id]>1) print id}' "$FINAL_TSV" | LC_ALL=C sort | head -5)
  [ -n "$_DUP" ] && p0 "final TSV 含重复 ID（每冻结验收点恰好一行终态）: $(printf '%s ' $_DUP)"
  # 集合差集：缺失（冻结了但终验未提交）/ 额外（未冻结却出现在终验）
  _FINAL_IDS=$(tail -n +2 "$FINAL_TSV" 2>/dev/null | cut -f1 | LC_ALL=C sort -u)
  _MISSING=$(comm -23 <(printf '%s\n' "$_BASE_IDS") <(printf '%s\n' "$_FINAL_IDS") | grep -c . || true)
  _EXTRA=$(comm -13 <(printf '%s\n' "$_BASE_IDS") <(printf '%s\n' "$_FINAL_IDS") | head -5)
  _EXTRA_N=$(printf '%s\n' "$_EXTRA" | grep -c . || true)
  [ "$_MISSING" -eq 0 ] || p0 "终验缺失冻结验收点: $_MISSING 个（冻结集合 ≠ 终验集合——缺失点未终验）"
  [ "$_EXTRA_N" -eq 0 ] || p0 "终验含未冻结的额外 ID: $(printf '%s ' $_EXTRA)（终验集合不得超出冻结集合）"
  [ "$_MISSING" -eq 0 ] && [ "$_EXTRA_N" -eq 0 ] && [ -z "$_FMT_BAD" ] && [ -z "$_DUP" ] \
    && pass "终验 ID 集合与冻结 baseline 完全相等（$_BASE_N 点）"
  # v3.16.11（P0-1 附）: criteria/design 完整性——meta 记录的 SHA 与现存文件对账
  #（终验时点产物通常仍在 docs/；已归档移动 → 文件缺失不阻断，由 baseline 入树兜底）
  _CRIT_P=$(sed -n 's/^criteria_path=//p' "$BASELINE_META" | head -1)
  _CRIT_S=$(sed -n 's/^criteria_sha256=//p' "$BASELINE_META" | head -1)
  if [ -n "$_CRIT_P" ] && [ -f "$_CRIT_P" ] && [ -n "$_CRIT_S" ]; then
    if [ "$(_sha "$_CRIT_P")" = "$_CRIT_S" ]; then
      pass "冻结 criteria 哈希一致: $_CRIT_P"
    else
      p0 "冻结 criteria 与冻结时哈希不一致（冻结后被篡改？）: $_CRIT_P"
    fi
  fi
fi

echo ""
echo "=== §1 验收点终态 FAIL=0 ==="
# v3.16.6（N27-P1-2）: 首行必须是 ID<TAB>STATUS 表头——此前 tail -n +2 / NR>1 无条件
# 跳过首行，无表头文件的数据行可藏入"表头位"绕过 FAIL=0（PoC：首行 A01<TAB>FAIL + 其余
# PASS → total=1 pass=1 fail=0 → gate exit 0）
_HEADER=$(head -1 "$FINAL_TSV" 2>/dev/null || true)
[ "$_HEADER" = "$(printf 'ID	STATUS')" ]   || p0 "final-verification.tsv 首行非 ID<TAB>STATUS 表头（实测首行: ${_HEADER:-空}）——无表头文件首行数据被跳过，FAIL 行可藏入表头位"
F_TOTAL=$(tail -n +2 "$FINAL_TSV" | grep -c . || true)
F_PASS=$(awk -F'\t' 'NR>1 && $2=="PASS" {n++} END {print n+0}' "$FINAL_TSV")
F_FAIL=$(awk -F'\t' 'NR>1 && $2=="FAIL" {n++} END {print n+0}' "$FINAL_TSV")
F_SKIP=$(awk -F'\t' 'NR>1 && $2=="SKIP" {n++} END {print n+0}' "$FINAL_TSV")
F_INVALID=$(awk -F'\t' 'NR>1 && $2!="PASS" && $2!="FAIL" && $2!="SKIP" {print}' "$FINAL_TSV" | head -3)
echo "  total=$F_TOTAL pass=$F_PASS fail=$F_FAIL skip=$F_SKIP"
[ -n "$F_INVALID" ] && p0 "invalid status rows: $F_INVALID"
[ "$F_TOTAL" -gt 0 ] || p0 "final-verification.tsv 无数据行"
[ "$F_FAIL" -eq 0 ] || p0 "终验存在 FAIL 验收点: $F_FAIL 个——部署前必须全部通过（首轮准确率仅是指标，终验 FAIL=0 才能部署）"
[ "$F_SKIP" -eq 0 ] || p0 "终验存在 SKIP 验收点: $F_SKIP 个——SKIP 不得进入部署"
[ "$F_PASS" -eq "$F_TOTAL" ] || p0 "终验 PASS 数不等于总数"

echo ""
echo "=== §2 五类测试执行证据（命令/退出码/报告哈希/反自报）==="
# v3.16.11（P0-2）: 三层反自报——此前五类全部 CMD=true/EXIT=0/同一份"ok"文件即可过
#（PoC 实证；删报告后 audit 仍 PASS——报告不在收据绑定内）
_REPORTS=()   # 五类报告路径收集（互异校验 + 入收据证据树）
_REPORTS_RESOLVED=()
TEST_EV_INITIAL_SHA=$(_sha "$TEST_EV")
[ -n "$TEST_EV_INITIAL_SHA" ] || { echo "[P0] test-evidence.env 初始哈希为空，拒绝继续" >&2; exit 2; }
FINAL_TSV_INITIAL_SHA=$(_sha "$FINAL_TSV")
BASELINE_TSV_INITIAL_SHA="MISSING"; BASELINE_META_INITIAL_SHA="MISSING"
[ -f "$BASELINE_TSV" ] && BASELINE_TSV_INITIAL_SHA=$(_sha "$BASELINE_TSV")
[ -f "$BASELINE_META" ] && BASELINE_META_INITIAL_SHA=$(_sha "$BASELINE_META")
[ -n "$FINAL_TSV_INITIAL_SHA" ] || { echo "[P0] final-verification.tsv 初始哈希为空，拒绝继续" >&2; exit 2; }
[ "$BASELINE_TSV_INITIAL_SHA" = MISSING ] || [ -n "$BASELINE_TSV_INITIAL_SHA" ] || { echo "[P0] first-pass-baseline.tsv 哈希为空，拒绝继续" >&2; exit 2; }
[ "$BASELINE_META_INITIAL_SHA" = MISSING ] || [ -n "$BASELINE_META_INITIAL_SHA" ] || { echo "[P0] first-pass-meta.env 哈希为空，拒绝继续" >&2; exit 2; }
FROZEN_TEST_EV=$(mktemp "${TMPDIR:-/tmp}/devflow-p6-test-evidence.XXXXXX" 2>/dev/null || true)
[ -n "$FROZEN_TEST_EV" ] && cp "$TEST_EV" "$FROZEN_TEST_EV" 2>/dev/null || p0 "无法冻结 test-evidence.env 输入清单"
cleanup_frozen() { rm -f "${FROZEN_TEST_EV:-}" 2>/dev/null || true; }
cleanup_p6_temp() {
  cleanup_frozen
  rm -rf "${EXEC_TMP_DIR:-}" 2>/dev/null || true
}
EXEC_TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/devflow-p6-exec.XXXXXX" 2>/dev/null || true)
EXEC_TMP_RECORD="${EXEC_TMP_DIR:+$EXEC_TMP_DIR/test-execution-results.env}"
[ -n "$EXEC_TMP_RECORD" ] || { echo "[P0] 无法创建隔离执行目录" >&2; exit 2; }
trap cleanup_p6_temp EXIT
_prepare_execution_evidence || true
_WS_BASE=$(_receipt_ws_base)
mkdir -p "$EXEC_DIR" || p0 "无法创建执行证据目录: $EXEC_DIR"
# v3.19.0(P0-1): 免客户端标记必须对账 P0 冻结的前端范围（state 的 .scope.frontend）——
# test-evidence.env 与 verification.json 都是可手写输入，互相印证不构成对"冻结值"的印证；
# 实测 pc-web + CLIENT_EXEMPT=1 + JSON 声明 not-applicable 曾直接 PASS（绕过浏览器旅程证据）。
STATE_FILE="$STATE_ROOT/${EFF_FEATURE}.state.json"
FROZEN_FRONTEND=$(jq -r '.scope.frontend // empty' "$STATE_FILE" 2>/dev/null || true)
CLIENT_EXEMPT=$(_ev CLIENT_EXEMPT)
case "$CLIENT_EXEMPT" in 1|true|yes|TRUE|YES) CLIENT_EXEMPT=1 ;; *) CLIENT_EXEMPT=0 ;; esac
if [ "$CLIENT_EXEMPT" = "1" ] && [ "$FROZEN_FRONTEND" != "not-applicable" ]; then
  p0 "CLIENT_EXEMPT=1 但冻结前端范围=${FROZEN_FRONTEND:-<state 缺失或未冻结>}——只有 not-applicable 可免客户端证据（冻结值以 ${STATE_FILE} 为准，声明不可覆盖冻结）"
fi

# v3.21.0: STAGING 免容器证据豁免——与 CLIENT_EXEMPT 同型对账：声明须与冻结前端
# 范围一致（not-applicable 才可免）。无服务端的项目（纯前端）据此跳过容器签名。
STAGING_EXEMPT=$(_ev STAGING_EXEMPT)
case "$STAGING_EXEMPT" in 1|true|yes|TRUE|YES) STAGING_EXEMPT=1 ;; *) STAGING_EXEMPT=0 ;; esac
if [ "$STAGING_EXEMPT" = "1" ] && [ "$FROZEN_FRONTEND" != "not-applicable" ]; then
  p0 "STAGING_EXEMPT=1 但冻结前端范围=${FROZEN_FRONTEND:-<state 缺失或未冻结>}——只有 not-applicable 可免 STAGING 容器证据（冻结值以 ${STATE_FILE} 为准）"
  STAGING_EXEMPT=0
fi

# v3.20.2(P0-1): 平台精确匹配——verification.json 显式声明的 frontend_scope 必须
# 与冻结值全等（此前只禁"非豁免偷换"，mini-program 冻结 + 声明 pc-web 曾直接 PASS）
_VERIFY_JSON_PATH="${DIR:-.devflow/${FEATURE}}/verification.json"
if [ -f "$_VERIFY_JSON_PATH" ]; then
  command -v jq >/dev/null 2>&1 || p0 "jq 不可用——无法校验 verification.json 平台声明（P6_SCOPE_JQ_REQUIRED）"
  _DECL_SCOPE=$(jq -r '.client_not_applicable.frontend_scope // .client.frontend_scope // .frontend_scope // empty' "$_VERIFY_JSON_PATH" 2>/dev/null || true)
  if [ -z "$_DECL_SCOPE" ]; then
    p0 "verification.json 未声明 frontend_scope——平台必须显式声明并与冻结值精确匹配（P6_SCOPE_UNDECLARED）"
  fi
  if [ -f "$STATE_FILE" ] && [ "$_DECL_SCOPE" != "$FROZEN_FRONTEND" ]; then
    p0 "verification.json 声明 frontend_scope=${_DECL_SCOPE} ≠ 冻结值 ${FROZEN_FRONTEND:-<缺失>}——平台不可偷换（P6_SCOPE_MISMATCH，冻结值以 ${STATE_FILE} 为准）"
  fi
fi
for kind in UNIT INTEGRATION CLIENT LOAD STAGING; do
  if [ "$kind" = "CLIENT" ] && [ "$CLIENT_EXEMPT" = "1" ] && [ "$FROZEN_FRONTEND" = "not-applicable" ]; then
    pass "CLIENT 免证据（冻结前端范围=not-applicable + CLIENT_EXEMPT=1）"
    continue
  fi
  if [ "$kind" = "STAGING" ] && [ "$STAGING_EXEMPT" = "1" ] && [ "$FROZEN_FRONTEND" = "not-applicable" ]; then
    pass "STAGING 免容器证据（冻结前端范围=not-applicable + STAGING_EXEMPT=1）"
    continue
  fi
  cmd=$(_ev "${kind}_CMD"); ext=$(_ev "${kind}_EXIT"); rp=$(_ev "${kind}_REPORT_PATH"); rs=$(_ev "${kind}_REPORT_SHA256")
  _REPORT_BEFORE_SHA=""
  _resolved_rp=""
  if [ -z "$cmd" ] || [ -z "$ext" ] || [ -z "$rp" ]; then
    p0 "${kind} 证据不完整（须 ${kind}_CMD/_EXIT/_REPORT_PATH；REPORT_SHA256 为可选断言）"
    continue
  fi
  if [ -n "$_WS_BASE" ]; then
    _resolved_rp=$(_receipt_norm_file "$rp" 2>/dev/null || true)
  fi
  # 反自报第一层：占位命令黑名单（true/:/echo/printf/exit/pwd/ls/touch——不是测试执行）
  case "$cmd" in
    true|true\ *|:|false|pwd|ls|echo|echo\ *|printf\ *|exit|exit\ *|touch\ *|cat|cat\ *|tee\ *)
      p0 "${kind}_CMD 为占位命令（非测试执行）: ${cmd}——终验不接受手写 EXIT=0 的间接证据"
      ;;
    *)
      if _is_shell_wrapper "$cmd"; then
        p0 "${kind}_CMD 为 shell 包装命令（禁止 bash/sh/env/command/exec 转包自造报告）: ${cmd}"
      elif [ -z "$_WS_BASE" ]; then
        p0 "workspace 无法物理归一，拒绝验证 ${kind} 报告路径"
      else
        _resolved_rp=$(_receipt_norm_file "$rp" 2>/dev/null || true)
        case "$_resolved_rp" in
          "$_WS_BASE"|"$_WS_BASE"/*) : ;;
          *) p0 "${kind} 报告路径越界（必须在 workspace 内）: ${rp}"; continue ;;
        esac
        _internal_log="$EXEC_DIR/$(_kind_file "$kind").log"
        # v3.20.2(P0-2): 五类报告路径不得与终验报告本体碰撞（UNIT_REPORT_PATH=终验报告路径
        # 曾 PASS，报告随后被渲染器覆盖——收据里"单元报告"变成终验报告）
        for _internal in "$TEST_EV" "$FINAL_TSV" "$BASELINE_TSV" "$BASELINE_META" "$EXEC_RECORD" "$_internal_log" \
            "docs/test/${EFF_FEATURE:-__unset__}-final-verification-report.md" \
            "docs/测试/${EFF_FEATURE:-__unset__}-终验报告.md"; do
          _internal_resolved=$(_receipt_norm_file "$_internal" 2>/dev/null || true)
          [ -n "$_internal_resolved" ] && [ "$_resolved_rp" = "$_internal_resolved" ] && \
            p0 "${kind} 报告路径与内部终验证据冲突（禁止绑定 manifest/快照/执行记录/日志）: ${rp}"
        done
      fi
      if [ -f "$rp" ]; then
        _REPORT_BEFORE_SHA=$(_sha "$rp" 2>/dev/null || true)
      fi
      if [ -f "$EXEC_TMP_RECORD" ] && ! _is_shell_wrapper "$cmd" && [ -n "$_WS_BASE" ]; then
        _validate_test_provenance "$kind" "$cmd"
        # v3.21.0: STAGING 额外要求真实容器签名（MockMvc 级命令在此被拒）
        if [ "$kind" = "STAGING" ]; then _validate_staging_container "$cmd" || true; fi
        if [ "$kind" = "CLIENT" ] && [ "$CLIENT_EXEMPT" != "1" ]; then _validate_client_browser "$cmd" || true; fi
        _run_test_command "$kind" "$cmd" "$ext"
      elif [ ! -f "$EXEC_RECORD" ]; then
        p0 "${kind} 无法记录实际执行结果（执行记录未初始化）"
      fi
      ;;
  esac
  [ "$ext" = "0" ] || p0 "${kind} 退出码非零: ${kind}_EXIT=${ext}（cmd: ${cmd}）"
  _REPORTS+=("$rp")
  [ -n "${_resolved_rp:-}" ] && _REPORTS_RESOLVED+=("$_resolved_rp")
  if [ ! -f "$rp" ]; then
    p0 "${kind} 报告缺失: $rp"
    continue
  fi
  actual=$(_sha "$rp")
  if [ -n "$rs" ]; then
    [ -n "$actual" ] && [ "$actual" = "$rs" ] || p0 "${kind} 报告哈希不匹配: $rp"
  fi
  if [ -n "${_REPORT_BEFORE_SHA:-}" ] && [ "$actual" = "$_REPORT_BEFORE_SHA" ]; then
    p0 "${kind} 报告在本轮命令前已存在且内容未变化（拒绝陈旧/预制证据）: $rp"
  fi
  # 反自报第二层：报告互异（五类共用同一份"ok"文件不构成五类证据）
  # 反自报第三层：报告实质内容（非空、≥32 字节、首行非纯占位词——"ok"/"pass" 单词文件）
  _R_BYTES=$(wc -c < "$rp" | tr -d ' ')
  [ "${_R_BYTES:-0}" -ge 32 ] || p0 "${kind} 报告疑似占位（${_R_BYTES:-0} 字节 < 32）: ${rp}——真实测试报告须含实质内容"
  _R_LINE1=$(head -1 "$rp" 2>/dev/null | tr -d '[:space:]')
  case "$_R_LINE1" in
    ok|pass|success|done|OK|PASS|SUCCESS|DONE|"")
      p0 "${kind} 报告首行为占位词（${_R_LINE1:-空}）: ${rp}——须为真实测试报告内容"
      ;;
    *)
      [ -n "$actual" ] && [ "$actual" = "$rs" ] && pass "${kind} 证据一致（exit=0, report sha verified, 实质内容）"
      ;;
  esac
done
TEST_EV_FINAL_SHA=$(_sha "$TEST_EV")
[ "$TEST_EV_FINAL_SHA" = "$TEST_EV_INITIAL_SHA" ] || p0 "测试执行后 test-evidence.env 输入清单发生变化"
FINAL_TSV_FINAL_SHA=$(_sha "$FINAL_TSV")
BASELINE_TSV_FINAL_SHA=$(_sha "$BASELINE_TSV")
BASELINE_META_FINAL_SHA=$(_sha "$BASELINE_META")
[ "$FINAL_TSV_FINAL_SHA" = "$FINAL_TSV_INITIAL_SHA" ] || p0 "测试执行后 final-verification.tsv 发生变化"
[ "$BASELINE_TSV_INITIAL_SHA" = MISSING ] || [ "$BASELINE_TSV_FINAL_SHA" = "$BASELINE_TSV_INITIAL_SHA" ] || p0 "测试执行后 first-pass-baseline.tsv 发生变化"
[ "$BASELINE_META_INITIAL_SHA" = MISSING ] || [ "$BASELINE_META_FINAL_SHA" = "$BASELINE_META_INITIAL_SHA" ] || p0 "测试执行后 first-pass-meta.env 发生变化"
mkdir -p "$EXEC_DIR" || p0 "无法创建最终执行证据目录: $EXEC_DIR"
cp "$EXEC_TMP_RECORD" "$EXEC_RECORD" 2>/dev/null || p0 "无法固化测试执行记录: $EXEC_RECORD"
for _kind_file in unit integration client load staging; do
  # v3.17.2(M4): 免客户端时无 client.log，跳过拷贝（记录树随之少一份日志属预期）
  [ "$_kind_file" = "client" ] && [ "$CLIENT_EXEMPT" = "1" ] && continue
  # v3.21.0: 免 STAGING 时无 staging.log，同上
  [ "$_kind_file" = "staging" ] && [ "${STAGING_EXEMPT:-0}" = "1" ] && continue
  cp "$EXEC_TMP_DIR/${_kind_file}.log" "$EXEC_DIR/${_kind_file}.log" 2>/dev/null || p0 "缺失 ${_kind_file} 执行日志"
done
printf 'CLIENT_EXEMPT=%s\n' "$CLIENT_EXEMPT" >> "$EXEC_RECORD"
printf 'STAGING_EXEMPT=%s\n' "${STAGING_EXEMPT:-0}" >> "$EXEC_RECORD"
_ACTUAL_RECORDS=$(grep -c '_ACTUAL_EXIT=' "$EXEC_RECORD" 2>/dev/null || true)
if [ "$CLIENT_EXEMPT" = "1" ] && [ "${STAGING_EXEMPT:-0}" = "1" ]; then
  [ "$_ACTUAL_RECORDS" -eq 3 ] || p0 "执行记录不完整：CLIENT_EXEMPT=1 + STAGING_EXEMPT=1 期望 3 条实际退出记录，得到 $_ACTUAL_RECORDS"
elif [ "$CLIENT_EXEMPT" = "1" ]; then
  [ "$_ACTUAL_RECORDS" -eq 4 ] || p0 "执行记录不完整：CLIENT_EXEMPT=1 期望 4 条实际退出记录，得到 $_ACTUAL_RECORDS"
elif [ "${STAGING_EXEMPT:-0}" = "1" ]; then
  [ "$_ACTUAL_RECORDS" -eq 4 ] || p0 "执行记录不完整：STAGING_EXEMPT=1 期望 4 条实际退出记录，得到 $_ACTUAL_RECORDS"
else
  [ "$_ACTUAL_RECORDS" -eq 5 ] || p0 "执行记录不完整：期望 5 条实际退出记录，得到 $_ACTUAL_RECORDS"
fi
# 互异校验（循环外做全量两两比对——同一文件充多类报告）
_DUPRP=$(printf '%s\n' "${_REPORTS_RESOLVED[@]:-}" | grep -v '^$' | LC_ALL=C sort | uniq -d | head -3)
[ -z "$_DUPRP" ] || p0 "多类测试共用同一报告文件（五类证据须各自独立）: $(printf '%s ' $_DUPRP)"

echo ""
echo "=== §3 环境边界 ==="
ENVIRONMENT=$(_ev ENVIRONMENT)
case "$ENVIRONMENT" in
  dev|staging|production) pass "ENVIRONMENT=$ENVIRONMENT" ;;
  *) p0 "ENVIRONMENT 非法或缺失: ${ENVIRONMENT:-<empty>}（须 dev|staging|production）" ;;
esac

# ---------- §3.5 结构化产物层 verification.json 对账 (v3.17.0; v3.19.0 升级为必填) ----------
# 失败关闭：终验的结构化产物不可缺席——它是终验报告的唯一数据源（Gate 执行通过后自动
# 渲染报告并绑定收据），缺失则报告只能手写、无跨字段保证。
echo ""
echo "=== §3.5 结构化产物层 (verification.json) 对账 ==="
VERIFY_JSON="$DIR/verification.json"
if [ ! -f "$VERIFY_JSON" ]; then
  p0 "verification.json 缺失: ${VERIFY_JSON}——P6-final 必填（契约 schemas/verification.schema.json；Gate 通过后自动渲染终验报告并绑定收据）"
elif ! command -v python3 >/dev/null 2>&1; then
  p0 "verification.json 存在但 python3 不可用——结构化产物对账无法执行（失败关闭）: $VERIFY_JSON"
else
  V_ARGS=(--kind verification --input "$VERIFY_JSON" --workspace .)
  [ -f "$BASELINE_TSV" ] && V_ARGS+=(--baseline "$BASELINE_TSV")
  [ -f "$EXEC_RECORD" ] && V_ARGS+=(--exec-record "$EXEC_RECORD")
  [ -n "$FROZEN_FRONTEND" ] && V_ARGS+=(--frontend-scope "$FROZEN_FRONTEND")
  if python3 "$(cd "$(dirname "$0")" && pwd)/df_validate.py" "${V_ARGS[@]}"; then
    pass "verification.json 与冻结 baseline / 本轮实际执行记录 / 冻结前端范围对账一致"
  else
    p0 "verification.json 校验或对账失败——修复后重跑 Gate（终验报告必须由已校验 JSON 渲染）"
  fi
fi

# ---------- §3.6 渲染终验报告 (v3.19.0 NEW) ----------
# 因果序：Gate 执行并校验通过 → 从已校验 JSON 渲染报告 → 报告与 JSON 进入收据证据树。
# 渲染失败 = 失败关闭（拒绝产出绑定不完整的收据）。
# v3.22.0: 终验报告改中文产物名；历史英文路径若存在（在途项目）继续沿用同一文件，避免双报告
P6_REPORT="$(df_resolve_doc "$EFF_FEATURE" final_verification .md test)"
[ -n "$P6_REPORT" ] || P6_REPORT="$(df_default_doc "$EFF_FEATURE" final_verification .md test)"
if [ "$FAIL" -eq 0 ]; then
  mkdir -p "$(dirname "$P6_REPORT")" || p0 "无法创建报告目录 $(dirname "$P6_REPORT")"
  if python3 "$(cd "$(dirname "$0")" && pwd)/df_render.py" verification \
      --input "$VERIFY_JSON" --out "$P6_REPORT" \
      --exec-record "$EXEC_RECORD" --workspace . && [ -f "$P6_REPORT" ]; then
    pass "终验报告已渲染并绑定: $P6_REPORT"
  else
    p0 "终验报告渲染失败——失败关闭，不产出收据"
  fi
fi

# ---------- 收据（统一契约）----------
# v3.16.11（P0-1/P0-2）: 绑定扩展——TSV/env 之外补 baseline（冻结集合对账源）、
# meta（criteria/design 哈希）与五类报告（PoC：五报告不入树 → 删报告后
# audit/complete 重验只查 TSV+env 仍 PASS——绑定与被验对象必须同生共死）
# 失败轮处理：报告缺失时树哈希失败 → exit 2 拒绝产出绑定不完整的收据
#（证据链断裂的失败轮没有可追溯收据，迭代重跑后产出）；其余失败轮
#（哈希不匹配/占位命令等）报告在、树可算 → 产出 EXIT_CODE=1 收据（审计 WARN 语义）
EV_ARGS=()
# v3.19.0(P0-3): 结构化产物与终验报告必须进入收据证据树——verification.json 是报告的
# 唯一数据源，报告是 Gate 渲染产物，二者与 TSV/env 同生共死（审计重验时缺一即阻断）。
for _f in "$FINAL_TSV" "$TEST_EV" "$BASELINE_TSV" "$BASELINE_META" "$EXEC_RECORD" "$VERIFY_JSON" "$P6_REPORT" "${_REPORTS[@]:-}" "${EXEC_LOGS[@]:-}"; do
  [ -n "$_f" ] && [ -f "$_f" ] && EV_ARGS+=("$_f")
done
EV_TREE=$(receipt_evidence_tree "${EV_ARGS[@]:-}")
P6F_EXIT=$([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
RECEIPT_DIR="$STATE_ROOT/${EFF_FEATURE}/gates/P6-final"
mkdir -p "$RECEIPT_DIR"
GATE_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$(cd "$(dirname "$0")/.." && pwd)/SKILL.md" 2>/dev/null | head -1)
# v3.16.2: fail-closed 对齐 p3b——版本源读取失败/树哈希计算失败/jq 缺失均拒绝产出
# 无绑定收据（旧口径：VER 空仍写 VERSION=p6-final@、EV_TREE 空写 calc-failed 占位、
# jq 缺失 EVIDENCE_PATHS_JSON 为空 → 收据降级 legacy 无绑定，审计 WARN 放行）
[ -n "$GATE_VER" ] || { echo "[FATAL] 版本源读取失败，拒绝产出收据" >&2; exit 2; }
[ -n "$EV_TREE" ] || { echo "[FATAL] 证据树哈希计算失败（绑定文件缺失——baseline/报告不在？），拒绝产出无绑定收据" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "[FATAL] jq 不可用——收据契约无法生成，拒绝产出无绑定收据" >&2; exit 2; }
# v3.16.11: JSON 数组按参数序构造（jq 逐个 append——bash 3.2 无 mapfile/关联序保证）
EVIDENCE_PATHS_JSON='['
_first=1
for _f in "${EV_ARGS[@]:-}"; do
  [ -n "$_f" ] || continue
  [ "$_first" -eq 1 ] || EVIDENCE_PATHS_JSON="${EVIDENCE_PATHS_JSON},"
  # v3.16.11: 每项 jq 输出必须非空——假 jq/损坏时拼接产出空数组 "[]" 逃过
  # 非空守卫（T21 假 jq 钉实证 rc=1 而非 2）
  _one=$(jq -cn --arg p "$_f" '$p' 2>/dev/null) || _one=""
  [ -n "$_one" ] || { echo "[FATAL] EVIDENCE_PATHS_JSON 生成失败（jq 损坏）" >&2; exit 2; }
  EVIDENCE_PATHS_JSON="${EVIDENCE_PATHS_JSON}${_one}"
  _first=0
done
EVIDENCE_PATHS_JSON="${EVIDENCE_PATHS_JSON}]"
if [ "${#EV_ARGS[@]:-0}" -gt 0 ] && [ "$EVIDENCE_PATHS_JSON" = "[]" ]; then
  echo "[FATAL] EVIDENCE_PATHS_JSON 生成失败（空数组）" >&2; exit 2
fi
# v3.16.2: 结果守卫——jq 损坏（存在但执行失败）时 JSON 为空，同样拒绝产出无绑定收据
[ -n "$EVIDENCE_PATHS_JSON" ] || { echo "[FATAL] EVIDENCE_PATHS_JSON 生成失败（jq 缺失或损坏）" >&2; exit 2; }
{
  echo "COMMAND=s6_final_verification_gate.sh $FEATURE"
  echo "EXIT_CODE=$P6F_EXIT"
  echo "EVIDENCE_PATHS_JSON=$EVIDENCE_PATHS_JSON"
  echo "EVIDENCE_TREE_SHA256=$EV_TREE"
  echo "PRODUCER_ROLE=final-verifier"
  echo "SESSION_ID=${SESSION_ID:-unknown}"
  echo "STARTED_AT=${P6F_STARTED_AT:-unknown}"
  echo "FINISHED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "ENVIRONMENT=${ENVIRONMENT:-unknown}"
  echo "STAGING_EXEMPT=${STAGING_EXEMPT:-0}"
  echo "VERSION=p6-final@$GATE_VER"
  echo "SKILL_TREE=$(bash "$(dirname "$0")/gate-skill-tree.sh" 2>/dev/null || echo unknown)"
  echo "PHASE=P6-final"
  echo "PASS=$PASS FAIL=$FAIL WARN=$WARN"
  echo "final_total=$F_TOTAL final_pass=$F_PASS final_fail=$F_FAIL"
} > "$RECEIPT_DIR/receipt.txt"
[ -s "$RECEIPT_DIR/receipt.txt" ] || { echo "[RECEIPT] WRITE FAILED" >&2; exit 1; }
DOCS_MIRROR="docs/${EFF_FEATURE}/gates/P6-final"
[ "${EFF_FEATURE}" != "default" ] && mkdir -p "$DOCS_MIRROR" 2>/dev/null && cp "$RECEIPT_DIR/receipt.txt" "$DOCS_MIRROR/" 2>/dev/null

echo ""
echo "========================================"
echo "P6-FINAL RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
[ "$FAIL" -gt 0 ] && { echo "P6-FINAL GATE: FAIL (blocking——部署前必须 FAIL=0 + 五类测试证据齐备)"; exit 1; }
if [ "$CLIENT_EXEMPT" = "1" ] && [ "${STAGING_EXEMPT:-0}" = "1" ]; then
  echo "P6-FINAL GATE: PASS（验收点 FAIL=0 + unit/integration/load 证据齐备 + CLIENT_EXEMPT=1 免客户端 + STAGING_EXEMPT=1 免容器）"
elif [ "$CLIENT_EXEMPT" = "1" ]; then
  echo "P6-FINAL GATE: PASS（验收点 FAIL=0 + unit/integration/load/staging 证据齐备 + CLIENT_EXEMPT=1 免客户端）"
else
  echo "P6-FINAL GATE: PASS（验收点 FAIL=0 + unit/integration/client/load/staging 证据齐备）"
fi
perf_end "P6-final"
exit 0
