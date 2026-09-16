#!/usr/bin/env bash
# ============================================================
# 流程测试流水线 v2 —— 契约模式（参数化）+ 兼容港口 legacy 模式
# v2.3（2026-09-07 第十二轮·通道自持）：双端执行改用内置 api 采集器（api-capture.py），
#   不再依赖外部 FlowTrace CLI（FLOWTEST_RUNNER=api 默认 / cli 仅显式 FLOWTEST_CLI
#   兼容保留）；runner 透传 --systems-dir（$RUNTIME_DIR/systems/api）；
# v2.4（2026-09-09 第X轮·skill 自持分离）：运行态（systems/reports/executions）迁出项目
#   .flowtrace/，落 $SKILL/runtime/<项目键>/（FLOWTEST_RUNTIME_DIR 可整体覆盖）——
#   与旧 FlowTrace 流水线目录彻底分离；env 前缀 FLOWTRACE_*→FLOWTEST_*（旧名回退兼容）；
#   legacy 兼容模式（--parse/run-all-plants.js）仍用 .flowtrace/（那本来就是 FlowTrace 的资产）
#   路径解析支持 skill 布局（FLOWTEST_PROJECT_ROOT / FLOWTEST_TEMPLATES_DIR 可覆盖，
#   缺省自动探测项目布局或从 cwd git 根推导）——同一脚本在项目内与 skill 内均可运行
# v2.2（2026-09-07 第十一轮审计）：
#   - run-id 不可复用：exec/report 目录已存在即拒绝（重跑必须新 run-id）
#   - finish_block 账本门控：run-manifest 写入失败 → 不产出 summary（无完整账本不得有结论件）
#   - 落账一律 --allow-unrecorded-versions（账本诚实记录 unrecorded；
#     正式 PASS 由 conclude 拒绝未绑定版本的结论）
#   - 契约声明 gate 的证据改由 gate-evidence-check.py 结构化校验
#     （type=file 须 sha256 现算一致 / type=url 须现场 200 / generated_at 时限 /
#      target_env 绑定——自由文本证据不再放行）
# v2.1（2026-09-06 第四轮审计）：用法错误/参数缺值 exit 2（不与 FAIL(1) 结论码混淆）；
#   同源复算对 compare-rules 升级为逐字节比对；复算解释器 -B 运行（dry-run 零字节码副作用）
# v2.5（2026-09-09 第三十四轮审计）：
#   - 依赖统一（P1）：PYRUN 解析——系统 python3 带 PyYAML 即用之，否则回退
#     `uv run --with pyyaml,jsonschema`（与文档命令一致），两者皆无 → 明确阻断 exit 2
#     （不再"前置警告后执行必失败"）；jsonschema 由 validate-contract 自身 fail-closed 兜底
#   - 路由矛盾收紧（P2-3）：--drill 才向 validate-contract 传 --allow-route-drift
#     （探索性路由仅限演练）；正式执行默认拒绝用例路由与 nodes.next 矛盾
#   - 产物路径口径（P2-1）：执行产物=docs/<流程名>/自动化测试/对比测试/<run-id>/，
#     runtime 仅存通道配置与 gate 证据库（私有配置目录）
#
# 契约模式（推荐;凭据自动从 $RUNTIME_DIR/env 加载——v1.3.3 去 .env 化）:
#   bash $SKILL/scripts/pipeline.sh \
#     --contract docs/李雅庄铁路流程/自动化测试/test-contract.yaml \
#     --scenario-dir docs/李雅庄铁路流程/自动化测试/生成件/flowtrace-scenarios \
#     --rules        docs/李雅庄铁路流程/自动化测试/生成件/compare-rules.json
#
#   步骤: preflight(契约校验) → gates(健康门禁) → runner(场景执行, 后端不可用=诚实 BLOCKED)
#         → fieldcmp(语义对拍) → manifest(落账) → conclude(三态 Gate)
#
# legacy 模式（不传 --contract，兼容港口煤发运旧流程）:
#   bash $SKILL/scripts/pipeline.sh [--skip-parse] [--plants a,b]   # 旧流水线资产仍在 .flowtrace/
#
# 通用:
#   --dry-run  零副作用（不建目录/不 curl/不写文件，仅校验与打印计划）
#   --run-id   指定 run-id（默认 run-<ts>）
#   --gate-evidence <path> gate 证据文件（结构+sha 预校验后于 run 目录创建时拷入
#              run 目录根 gate-evidence.json——第二十轮：替代监视器竞态注入）
#   --runs-dir <dir>  run 证据库（豁免取证链核验；缺省智能解析，1.3.1）
#   --help|-h  打印用法
#
# 第三十五轮（P3）：--help/-h 简短帮助——此前未知参数只报"未知参数"，无自助入口
usage() {
  cat <<'EOF'
flow-test-contract pipeline —— 契约模式（推荐;凭据自动从 $RUNTIME_DIR/env 加载）:
  bash pipeline.sh \
    --contract docs/<流程>/自动化测试/test-contract.yaml \
    --scenario-dir docs/<流程>/自动化测试/生成件/flowtrace-scenarios \
    --rules        docs/<流程>/自动化测试/生成件/compare-rules.json
  步骤: preflight(契约校验) → gates(健康门禁) → runner(场景执行, 后端不可用=诚实 BLOCKED)
        → fieldcmp(语义对拍) → manifest(落账) → conclude(三态 Gate)

  可选: --dry-run   零副作用（不建目录/不 curl/不写文件，仅校验与打印计划）
        --drill     演练（全账本但 conclusion=DRILL，不出正式三态结论；允许探索性路由）
        --cases C-01,C-02  场景子集过滤（正式结论必须全量）
        --run-id <id>      指定 run-id（默认 run-<ts>；同 id 已存在即拒绝）
        --gate-evidence <file>  gate 证据（结构+sha 预校验后原子拷入 run 目录）
        --runs-dir <dir>   run 证据库（豁免取证链核验；缺省智能解析：契约同目录/对比测试
                           → 上一级/对比测试，覆盖 生成件/ 布局——1.3.1）

legacy 模式（不传 --contract，兼容 .flowtrace 旧流水线）:
  bash pipeline.sh [--skip-parse] [--plants a,b]

执行产物: docs/<流程名>/自动化测试/对比测试/<run-id>/（截图/账本/结论/最终 md 报告同放）
退出码:   0=PASS  1=FAIL  2=BLOCKED/用法错误
EOF
}
#
# ⚠️ 第十一轮：run-id 不可复用——同 run-id 目录已存在即拒绝；账本/结论不可覆盖；
# runner/CLI 不可用 → BLOCKED（不伪造）。历史 run 目录保留不清空；结论仅绑定 run-id。
# ============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 第三十四轮（P1·依赖统一）：PYRUN 单点解析 ----------
# 系统 python3 已带 PyYAML 即用之；缺则回退 `uv run --with pyyaml,jsonschema`
# （与 SKILL.md 文档命令同一策略）；两者皆无 → 明确阻断 exit 2（不再"警告后必失败"）。
# jsonschema 仅 test_ready 契约校验需要——缺失时 validate-contract.py 自身 fail-closed 报错。
if python3 -c "import yaml" >/dev/null 2>&1; then
  PYRUN="python3"
elif command -v uv >/dev/null 2>&1; then
  PYRUN="uv run --with pyyaml,jsonschema python3"
else
  echo "⛔ 缺 python3(PyYAML) 且无 uv：pip install pyyaml jsonschema，或安装 uv（将走 uv run --with pyyaml,jsonschema）" >&2
  exit 2
fi

# ---------- 双布局路径解析（第十二轮·通道自持）：同一脚本在"项目部署布局"与"skill 自持布局"均可运行 ----------
# 优先级：env 覆盖 → 项目布局（<root>/.flow-test-contract/scripts + <root>/docs/自动化测试模板）
#        → skill 布局（<skill>/scripts + <skill>/templates；项目根从 cwd git 根推导）
resolve_project_root() {
  if [ -n "${FLOWTEST_PROJECT_ROOT:-}" ]; then echo "$FLOWTEST_PROJECT_ROOT"; return; fi
  if [ -f "$SCRIPT_DIR/../../docs/自动化测试模板/validate-contract.py" ] && [ -d "$SCRIPT_DIR/../../.flow-test-contract" ]; then
    (cd "$SCRIPT_DIR/../.." && pwd); return   # 项目部署布局
  fi
  if _gr="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$_gr" ]; then
    echo "$_gr"; return                        # skill 布局 + 在项目内运行
  fi
  echo ""; return
}
# ---------- 运行态根（skill 自持）：通道配置与 gate 证据库存 $SKILL/runtime/<项目键>/（私有配置目录）；
# 执行产物落 <项目>/docs/<流程名>/自动化测试/对比测试/<run-id>/（ftc_output_root）；
# 与旧 FlowTrace 流水线的 <root>/.flowtrace/ 彻底分离；解析规则唯一实现见 scripts/ftc-runtime.sh
# shellcheck source=ftc-runtime.sh
source "$SCRIPT_DIR/ftc-runtime.sh"
resolve_runtime_dir() { ftc_runtime_dir "$1" "$SCRIPT_DIR"; }

# ---------- v1.3.3（去 .env 化）：运行态凭据自动加载 ----------
# 凭据不再依赖项目根 .env；统一落 $RUNTIME_DIR/env（私有运行态，绝不入库/同步）。
# 语义与 scripts/ftc_env.py 镜像：KEY=VALUE（容忍 export/引号/#注释），setdefault
# 加载——进程已有值（显式导出）优先；密码需显式 FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 统一默认密码
# （缺失键由 api/browser 采集器经 ftc_env.resolve_credentials 兜底，仍缺=诚实 BLOCKED）。
ftc_load_runtime_env() {  # $1=env 文件路径
  local _f="$1" _line _k _v
  [ -f "$_f" ] || return 0
  [ -L "$_f" ] && { echo "⛔ runtime env 禁止符号链接: $_f" >&2; return 2; }
  local _mode _uid_owner
  _mode="$(stat -c '%a' "$_f" 2>/dev/null || stat -f '%Lp' "$_f" 2>/dev/null || true)"
  [ "$_mode" = "600" ] || { echo "⛔ runtime env 权限过宽: $_f（要求 0600，当前 ${_mode:-unknown}）" >&2; return 2; }
  # 镜像 ftc_env._check_env_file：必须当前用户所有（防共享机器上他人放入的凭据文件）
  _uid_owner="$(stat -c '%u' "$_f" 2>/dev/null || stat -f '%u' "$_f" 2>/dev/null || true)"
  if [ -n "$_uid_owner" ] && command -v id >/dev/null 2>&1; then
    [ "$_uid_owner" = "$(id -u)" ] || { echo "⛔ runtime env 非当前用户所有: $_f（owner uid=$_uid_owner，当前 uid=$(id -u)）" >&2; return 2; }
  fi
  while IFS= read -r _line || [ -n "$_line" ]; do
    _line="${_line%$'\r'}"
    _line="${_line#"${_line%%[![:space:]]*}"}"
    _line="${_line%"${_line##*[![:space:]]}"}"
    case "$_line" in ''|\#*) continue ;; esac
    _line="${_line#export }"
    case "$_line" in *=*) ;; *) continue ;; esac
    _k="${_line%%=*}"; _v="${_line#*=}"
    _k="${_k#"${_k%%[![:space:]]*}"}"; _k="${_k%"${_k##*[![:space:]]}"}"
    _v="${_v#"${_v%%[![:space:]]*}"}"; _v="${_v%"${_v##*[![:space:]]}"}"
    case "$_k" in ''|*[!A-Za-z0-9_]*) continue ;; esac
    case "$_v" in
      \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
      \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
    esac
    if ! env | grep -q "^${_k}="; then
      export "$_k=$_v"
    fi
  done < "$_f"
}

resolve_templates_dir() {   # $1=PROJECT_ROOT
  if [ -n "${FLOWTEST_TEMPLATES_DIR:-}" ]; then echo "$FLOWTEST_TEMPLATES_DIR"; return; fi
  # skill 布局优先用自身 sibling templates（隔离：不串到 cwd 所在项目的模板）
  [ -f "$SCRIPT_DIR/../templates/validate-contract.py" ] && { echo "$SCRIPT_DIR/../templates"; return; }
  [ -f "$1/docs/自动化测试模板/validate-contract.py" ] && { echo "$1/docs/自动化测试模板"; return; }
  echo ""
}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC}   $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

CONTRACT=""; SCENARIO_DIR=""; RULES=""; RUN_ID=""; DRY_RUN=false
GATE_EVIDENCE_SRC=""; RUNS_DIR=""
CASES=""; DRILL=false
LEGACY_SKIP_PARSE=false; LEGACY_PLANTS=""
RUNS_DIR_FLAG=""

while [[ $# -gt 0 ]]; do
  # 第四轮审计：带值参数缺值（set -u 下 unbound variable）与未知参数此前 exit 1——
  # 与 FAIL 结论码冲突（crash/用法错误伪装 FAIL），一律 exit 2
  case $1 in
    --contract|--scenario-dir|--rules|--run-id|--plants|--gate-evidence|--cases|--runs-dir)
      if [[ $# -lt 2 || "$2" == --* ]]; then
        echo "⛔ 参数 $1 缺少值" >&2; exit 2
      fi
      case $1 in
        --contract) CONTRACT="$2" ;;
        --scenario-dir) SCENARIO_DIR="$2" ;;
        --rules) RULES="$2" ;;
        --run-id) RUN_ID="$2" ;;
        --plants) LEGACY_PLANTS="$2" ;;
        --gate-evidence) GATE_EVIDENCE_SRC="$2" ;;
        --cases) CASES="$2" ;;
        --runs-dir) RUNS_DIR="$2" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --drill) DRILL=true; shift ;;
    --skip-parse) LEGACY_SKIP_PARSE=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数: $1（--help 查看用法）" >&2; exit 2 ;;
  esac
done

# 1.0.1 P0 修复：DRILL 初始化为非空 "false"，${DRILL:+…} 的非空判断恒为真——不带 --drill 的
# 正式运行曾误传 --allow-route-drift，把"用例路由 ∉ nodes.next"降级 WARN 绕过 fail-closed
# （shell 实测复现）。改显式布尔派生，布尔值不再由 :+ 非空陷阱承担：
DRILL_ROUTE_FLAG=""; DRILL_NOTE=""
if [ "$DRILL" = true ]; then
  DRILL_ROUTE_FLAG="--allow-route-drift"; DRILL_NOTE="；drill=只记录不阻断"
fi
# 1.3.1（P1）：--runs-dir 显式指定 run 证据库时才转发（argv 传参不经 shell 内插，无注入面）；
# 缺省由 validate-contract 智能解析（契约同目录/对比测试 → 上一级/对比测试）
if [ -n "$RUNS_DIR" ]; then
  RUNS_DIR_FLAG="--runs-dir $RUNS_DIR"
fi

# 1.1.0 可复现性：正式执行（非 dry-run、非 drill）向下游采集器注入 FLOWTEST_FORMAL_RUN=1——
# browser 通道据此禁用 npx latest 回退（未锁版本=联网下载+版本漂移，正式 PASS 不可复现）；
# 演练/探针不受限。导出时机在参数解析后、任何 runner 调用前。
if [ "$DRILL" != true ] && [ "$DRY_RUN" != true ]; then
  export FLOWTEST_FORMAL_RUN=1
fi

# 第二十一轮（实测反哺）：--cases "C-01,C-02" 场景子集过滤（同源复算/runner/账本同步过滤）；
# --drill 演练模式：全账本语义但不出正式三态结论（summary.conclusion=DRILL），
#   用于生产保护（如老系统办结会触发后置流程自动发起时的截断演练）与试点验证。
#   正式结论必须全量场景 + gates + conclude（不带 --cases、不带 --drill）。
if [ -n "$CASES" ]; then export FLOWTRACE_CASES="$CASES"; fi

# 第二十轮（实测反哺）：gate-evidence 结构/sha 预校验（只读零副作用）。
# 背景：此前证据文件只能靠"文件监视器抢在健康检查窗口内拷入 exec 目录"注入——竞态 hack。
# 正式用法：--gate-evidence <path> 由 pipeline 在 run 目录创建时原子拷入；
#           dry-run 同步预校验（结构 + sha256_16 现算一致），坏证据不进 run。
validate_gate_evidence() {  # $1=path ；合法=0
  $PYRUN -B - "$1" <<'PY'
import hashlib, json, sys
from pathlib import Path
try:
    raw = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    assert isinstance(raw, list) and raw, "gate-evidence 必须是非空 JSON 列表"
    for e in raw:
        if not isinstance(e, dict) or not e.get("id"):
            raise SystemExit(f"条目缺 id: {e!r}")
        if e.get("type") not in ("file", "url"):
            raise SystemExit(f"{e.get('id')}: type 非法（file|url）")
        if not str(e.get("target_env") or "").strip():
            raise SystemExit(f"{e.get('id')}: 缺 target_env")
        if not str(e.get("generated_at") or "").strip():
            raise SystemExit(f"{e.get('id')}: 缺 generated_at")
        if e.get("type") == "file":
            p = Path(str(e.get("path") or ""))
            if not p.is_file():
                raise SystemExit(f"{e.get('id')}: 证据文件不存在 {p}")
            h = hashlib.sha256(p.read_bytes()).hexdigest()[:16]
            if h != e.get("sha256_16"):
                raise SystemExit(f"{e.get('id')}: sha256_16 不符（现算 {h} ≠ 声明 {e.get('sha256_16')}）——报告已变更请重打 sha")
        else:
            if not str(e.get("url") or "").startswith(("http://", "https://")):
                raise SystemExit(f"{e.get('id')}: url 非法")
except SystemExit as ex:
    print(f"gate-evidence 预校验失败: {ex}", file=sys.stderr)
    sys.exit(1)
except Exception as ex:
    print(f"gate-evidence 预校验失败: {type(ex).__name__}: {ex}", file=sys.stderr)
    sys.exit(1)
PY
}

MODE="legacy"; [ -n "$CONTRACT" ] && MODE="contract"

# 路径解析在参数解析后执行（dry-run 兜底见下）
PROJECT_ROOT="$(resolve_project_root)"
if [ -z "$PROJECT_ROOT" ]; then
  if [ "$DRY_RUN" = true ]; then
    PROJECT_ROOT="$PWD"   # dry-run 零副作用：RID 计划校验用 cwd 兜底即可
  else
    echo "⛔ 无法定位项目根：skill 自持布局请在项目目录内运行，或设 FLOWTEST_PROJECT_ROOT" >&2; exit 2
  fi
fi
TEMPLATES_DIR="$(resolve_templates_dir "$PROJECT_ROOT")"
if [ -z "$TEMPLATES_DIR" ]; then
  echo "⛔ 无法定位立契模板目录（validate-contract.py）：设 FLOWTEST_TEMPLATES_DIR" >&2; exit 2
fi
RUNTIME_DIR="$(resolve_runtime_dir "$PROJECT_ROOT")"
ftc_load_runtime_env "$RUNTIME_DIR/env" || exit 2  # v1.3.3：凭据自 $RUNTIME_DIR/env 自动加载（进程环境优先）
# 执行产物根（第三十轮）：截图/文档/记录/账本落 docs/<流程名>/自动化测试/对比测试/<run-id>/，
# 多轮对比同放一处；FLOWTEST_OUTPUT_DIR 整体覆盖；无契约（legacy 模式）回退 runtime/reports
RUN_OUTPUT_BASE="$(ftc_output_root "$PROJECT_ROOT" "$CONTRACT")"
[ -n "$RUN_OUTPUT_BASE" ] || RUN_OUTPUT_BASE="$RUNTIME_DIR/reports"

# run-id 消毒（防路径穿越写出 reports/executions 之外；write-manifest 会再拦一道）
# 第三轮审计：与 write-manifest 的 RUN_ID_RE 完全对齐（[A-Za-z0-9._-]、首字符字母数字、禁 ..）——
# 此前只拦 "/" 与 ".."，单引号/空格 run-id 可穿透到后续 python -c 的字符串内插（代码注入面）
if [ -n "$RUN_ID" ]; then
  if [[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && [[ "$RUN_ID" != *..* ]]; then
    :
  else
    echo "⛔ 非法 run-id: '$RUN_ID'（只允许 [A-Za-z0-9][A-Za-z0-9._-]* 且不含 ..）" >&2; exit 2
  fi
fi

# 契约同源复算：--rules/--scenario-dir 必须与"由契约确定性重生成"的字节完全一致。
# 第三轮审计：此前 pipeline 只查 rules 可解析、场景可解析——生成后手改 rules（塞 abs:inf/
# 追加豁免）或改场景内容，执行照单全收 → 篡改规则可推假 PASS。契约是唯一事实源，执行件必须可复算。
verify_provenance() {  # $1=contract $2=rules $3=scenario-dir ；一致=0
  # -B：不写 __pycache__（import gen_from_contract 会在模板目录落 .pyc——违反 dry-run 零副作用承诺）
  $PYRUN -B - "$1" "$2" "$3" "$TEMPLATES_DIR" <<'PY'
import json, sys
from pathlib import Path

contract, rules_path, scen_dir, gen_pkg_dir = sys.argv[1:5]
sys.path.insert(0, gen_pkg_dir)
try:
    import os as _os
    import yaml
    import gen_from_contract as g
    c = yaml.safe_load(Path(contract).read_text(encoding="utf-8")) or {}
    exp_rules = g.gen_compare_rules(c, formal=True)
    _sel = {x.strip().upper() for x in (_os.environ.get("FLOWTRACE_CASES") or "").split(",") if x.strip()}
    exp_scen = {f"{c['meta']['flow_code']}-{case['id'].lower()}.yaml": g.gen_scenario(case, c, "")
                for case in c.get("cases", []) if isinstance(case, dict) and case.get("id")
                and (not _sel or str(case["id"]).upper() in _sel)}
except Exception as e:
    print(f"同源复算失败（契约/依赖不可读）: {type(e).__name__}: {e}", file=sys.stderr); sys.exit(1)
problems = []
try:
    # 第四轮审计：此前对 rules 只做语义相等（json.loads == 期望）——重排/重缩进的规则可过；
    # 承诺是"逐字节一致"，改为与 gen 同参数序列化后字节比对（场景侧本就是字节比对）
    exp_rules_bytes = json.dumps(exp_rules, ensure_ascii=False, indent=2).encode("utf-8")
    if Path(rules_path).read_bytes() != exp_rules_bytes:
        problems.append("compare-rules 与契约重生成不逐字节一致（篡改/过期/重排/草稿——重新 gen_from_contract）")
except Exception as e:
    problems.append(f"compare-rules 不可读: {e}")
sd = Path(scen_dir)
act_names = {p.name for p in sd.glob("*.yaml")} if sd.exists() else set()
if _sel:  # --cases 子集：未选中场景留在目录里是预期，不参与同源比对
    act_names = {n for n in act_names if n in exp_scen}
for missing in sorted(set(exp_scen) - act_names):
    problems.append(f"场景缺失: {missing}")
for extra in sorted(act_names - set(exp_scen)):
    problems.append(f"场景多余（契约未登记）: {extra}")
for name in sorted(set(exp_scen) & act_names):
    try:
        if (sd / name).read_text(encoding="utf-8") != exp_scen[name]:
            problems.append(f"场景内容与契约复算不一致: {name}")
    except Exception as e:
        problems.append(f"场景不可读: {name}: {e}")
if problems:
    print("; ".join(problems), file=sys.stderr); sys.exit(1)
PY
}

# ---------- 通用零副作用 dry-run（只校验与打印，不碰工作区/网络） ----------
if [ "$DRY_RUN" = true ]; then
  echo "[DRY-RUN] mode=$MODE"
  FAIL=0
  if [ "$MODE" = "contract" ]; then
    for f in "$CONTRACT" "$RULES"; do
      [ -n "$f" ] && [ -f "$f" ] && echo "  ✓ $f" || { echo "  ✗ 缺失: $f"; FAIL=1; }
    done
    [ -d "$SCENARIO_DIR" ] && echo "  ✓ 场景目录 ($(ls "$SCENARIO_DIR"/*.yaml 2>/dev/null | wc -l | tr -d ' ') 个)" || { echo "  ✗ 场景目录缺失"; FAIL=1; }
    $PYRUN "$TEMPLATES_DIR/validate-contract.py" --contract "$CONTRACT" --level test_ready ${DRILL_ROUTE_FLAG} \
      ${RUNS_DIR_FLAG} \
      && echo "  ✓ 契约 test_ready 校验" || FAIL=1
    # rules 必须是可解析的 JSON（防串文件/半损坏规则进执行）
    if [ -f "$RULES" ] && ! $PYRUN -c "import json,sys; json.load(open(sys.argv[1]))" "$RULES" 2>/dev/null; then
      echo "  ✗ compare-rules.json 不是合法 JSON"; FAIL=1
    fi
    # 场景文件必须可解析为 YAML（防半损坏场景进 runner）——单解释器批量解析（P2-4：
    # 此前逐文件起 python 子进程，场景多时启动开销线性放大）
    if ! SCEN_DIR="$SCENARIO_DIR" $PYRUN -B - <<'PY' 2>/dev/null; then
import os, sys, pathlib
try:
    import yaml
except Exception:
    sys.exit(1)
bad = [p for p in sorted(pathlib.Path(os.environ["SCEN_DIR"]).glob("*.yaml"))
       if yaml.safe_load(p.read_text(encoding="utf-8")) is None]
sys.exit(1 if bad else 0)
PY
      echo "  ✗ 场景损坏（YAML 不可解析/空）: $SCENARIO_DIR"; FAIL=1
    fi
    # 同源复算（零副作用，只读比对）：执行件必须是契约的确定性重生成物
    if ! verify_provenance "$CONTRACT" "$RULES" "$SCENARIO_DIR"; then
      echo "  ✗ 执行件与契约不同源（rules/场景被篡改或过期——重新生成后再跑）"; FAIL=1
    fi
    # 第二十轮：--gate-evidence 预校验（结构 + sha256_16 现算一致）——坏证据不进 run
    if [ -n "$GATE_EVIDENCE_SRC" ]; then
      if [ ! -f "$GATE_EVIDENCE_SRC" ]; then
        echo "  ✗ gate-evidence 文件不存在: $GATE_EVIDENCE_SRC"; FAIL=1
      elif validate_gate_evidence "$GATE_EVIDENCE_SRC"; then
        echo "  ✓ gate-evidence 预校验通过 ($GATE_EVIDENCE_SRC)"
      else
        echo "  ✗ gate-evidence 结构/sha 校验失败: $GATE_EVIDENCE_SRC"; FAIL=1
      fi
    fi
  else
    echo "  legacy 模式：parse=$([ "$LEGACY_SKIP_PARSE" = false ] && echo on || echo skip) plants=${LEGACY_PLANTS:-all}"
  fi
  [ "$MODE" = "contract" ] && echo "  ✓ 执行产物目录: $RUN_OUTPUT_BASE/<run-id>（截图/账本/结论/最终 md 报告同放）"
  # 第十一轮：run-id 计划可行性——复用已存在 run-id 的计划=无效计划（正式执行同名强制拒绝）
  RID_CHECK="${RUN_ID:-run-$(date +%Y%m%d%H%M%S)}"
  if [ -e "$RUN_OUTPUT_BASE/executions/$RID_CHECK" ] || [ -e "$RUN_OUTPUT_BASE/reports/$RID_CHECK" ] \
     || [ -e "$RUN_OUTPUT_BASE/$RID_CHECK" ]; then
    echo "  ✗ run-id 已存在（不可复用——重跑必须换新 run-id）: $RID_CHECK"; FAIL=1
  fi
  # 执行后端探测（只探测不调用；第十二轮：默认 api 自持通道，cli 仅显式兼容）
  RUNNER_MODE="${FLOWTEST_RUNNER:-${FLOWTRACE_RUNNER:-api}}"
  if [ "$RUNNER_MODE" = "api" ]; then
    _SYS_DIR="${FLOWTEST_SYSTEMS_API_DIR:-${FLOWTRACE_SYSTEMS_API_DIR:-$(resolve_runtime_dir "$PROJECT_ROOT")}/systems/api}"
    if [ -f "$_SYS_DIR/legacy.yaml" ] && [ -f "$_SYS_DIR/current.yaml" ]; then
      # 第十六轮审计（P1）：dry-run 必须同步执行 legacy-config-check（占位/结构检查）——
      # 仅"文件存在"会掩盖 __F12_RECORD__ 残留仍显示"计划可行"；配置检查零副作用（只读）
      if $PYRUN "$SCRIPT_DIR/legacy-config-check.py" --systems-dir "$_SYS_DIR" >/dev/null 2>&1; then
        echo "  ✓ 执行后端=api（systems api 配置就绪且占位/结构检查通过: ${_SYS_DIR}）"
      else
        echo "  ✗ 执行后端=api 配置未就绪（legacy-config-check 失败——F12 端点占位残留或结构缺口）: $_SYS_DIR"
        echo "    检查：$PYRUN $SCRIPT_DIR/legacy-config-check.py --systems-dir $_SYS_DIR"
        echo "    录端点手册：$HOME/.agents/skills/flow-test-contract/references/f12-record.md"; FAIL=1
      fi
    else
      echo "  ⚠ 执行后端=api 但 systems api 配置缺失（$_SYS_DIR/legacy.yaml|current.yaml）——契约模式执行将 BLOCKED"
    fi
  elif [ "$RUNNER_MODE" = "browser" ]; then
    _BDIR="${FLOWTEST_SYSTEMS_BROWSER_DIR:-${FLOWTRACE_SYSTEMS_BROWSER_DIR:-$(resolve_runtime_dir "$PROJECT_ROOT")}/systems/browser}"
    if command -v node >/dev/null 2>&1 || [ -f "$HOME/.codex/skills/playwright/scripts/playwright_cli.sh" ]; then
      if [ -f "$_BDIR/legacy.yaml" ] && [ -f "$_BDIR/current.yaml" ]; then
        # 占位/凭据检查（零副作用只读；__UI_RECORD__ 残留或 env 缺失即不就绪）
        _bok=1
        for _bside in legacy current; do
          $PYRUN "$SCRIPT_DIR/browser-capture.py" --check-config --systems "$_BDIR/$_bside.yaml" >/dev/null 2>&1 || _bok=0
        done
        if [ $_bok -eq 1 ]; then
          echo "  ✓ 执行后端=browser（playwright-cli 浏览器采集；配置就绪: ${_BDIR}）"
        else
          echo "  ✗ 执行后端=browser 配置未就绪（__UI_RECORD__ 占位残留或凭据 env 缺失）: $_BDIR"
          echo "    检查：$PYRUN $SCRIPT_DIR/browser-capture.py --check-config --systems $_BDIR/legacy.yaml"
          echo "    UI 录制手册：$HOME/.agents/skills/flow-test-contract/references/browser-channel.md"
          FAIL=1
        fi
      else
        echo "  ⚠ 执行后端=browser 但配置缺失（$_BDIR/legacy.yaml|current.yaml）——从 skill assets/systems-browser/ 拷贝后做 UI 录制"
        FAIL=1
      fi
    else
      echo "  ✗ 执行后端=browser 需要 node（playwright-cli）——环境缺 node"; FAIL=1
    fi
  elif [ "$RUNNER_MODE" = "cli" ] && [ -n "${FLOWTRACE_CLI:-}" ]; then
    echo "  ✓ 执行后端=cli（兼容，FLOWTRACE_CLI=${FLOWTRACE_CLI}）"
  else
    echo "  ⚠ 执行后端不可用（FLOWTRACE_RUNNER=$RUNNER_MODE 且无 FLOWTRACE_CLI）——契约模式执行将 BLOCKED"
  fi
  [ $FAIL -eq 0 ] && echo "[DRY-RUN] 计划可行（未发生任何写入/网络调用）" || { echo "[DRY-RUN] 计划不可行"; exit 2; }
  exit 0
fi

# ---------- 正式执行 ----------
export FLOWTEST_RUN_TS="${FLOWTEST_RUN_TS:-$(date +%Y%m%d%H%M%S)}"
RUN_ID="${RUN_ID:-run-${FLOWTEST_RUN_TS}}"
RUN_EXEC_DIR="$RUN_OUTPUT_BASE/$RUN_ID"
RUN_REPORT_DIR="$RUN_OUTPUT_BASE/$RUN_ID"   # 与 exec 同目录：单 run 单目录（截图/采集/账本/结论/报告同放）
# 第十一轮：run-id 不可复用——目录已存在（预置/遗留/碰撞）即拒绝；
# 账本与结论不可覆盖，重跑只能用新 run-id（顺带封死"预置采集/gate-evidence 被本次冒领"面）
if [ -e "$RUN_EXEC_DIR" ] || [ -e "$RUN_REPORT_DIR" ]; then
  echo "⛔ run-id 已存在: ${RUN_ID}（exec/report 目录非空不可复用——账本不可篡改，重跑必须换新 run-id）" >&2
  exit 2
fi

mkdir -p "$RUN_EXEC_DIR" "$RUN_REPORT_DIR"
echo "run-id: ${RUN_ID}（exec: ${RUN_EXEC_DIR}；report: ${RUN_REPORT_DIR}）"
# v1.5.0 任务完成门④：测试数据账本建账（best-effort，不阻断主链路）
$PYRUN "$SCRIPT_DIR/test-data-ledger.py" init --run-dir "$RUN_EXEC_DIR" ${CONTRACT:+--contract "$CONTRACT"} \
  || log_warn "数据账本建账失败（辅助产物，不阻断）"
# v1.7.2 P0-2：已声明排他数据时，租约冲突在正式 run 一律 finish_block（两个 run 并发
# 占用同一 fixture/resource 会互相污染并可能各自产出 PASS——数据安全优先于可用性）；
# --drill 降级告警（演练允许并行观察）

finish_block() {  # $1=原因
  log_err "$1 → BLOCKED"
  # 三件占位证据逐个补齐（已存在的不覆盖）：保证 conclude 有完整可判 BLOCKED 的证据面
  [ -f "$RUN_REPORT_DIR/gates.json" ] || \
    echo '[{"id":"GATE-PIPELINE","severity":"P99","passed":false,"synthetic":true,"note":"流水线前置失败，finish_block 占位——不计入 P0 计数"}]' > "$RUN_REPORT_DIR/gates.json"
  [ -f "$RUN_REPORT_DIR/case-results.json" ] || \
    echo "[]" > "$RUN_REPORT_DIR/case-results.json"
  [ -f "$RUN_REPORT_DIR/field-compare.json" ] || \
    echo '{"status":"BLOCKED","coverage":["流水线前置失败，未执行"]}' > "$RUN_REPORT_DIR/field-compare.json"
  # 第十一轮：先落账，账本写入成功才允许产出结论件（无完整账本不得有 summary——
  # 此前 manifest 写失败被忽略仍出 summary = 不完整的 EXECUTED 账本面）。
  # --allow-unrecorded-versions：BLOCKED 账本诚实记录 unrecorded 即可；
  # 正式 PASS 的版本绑定由 conclude 强制（versions unrecorded → BLOCKED）
  $PYRUN "$SCRIPT_DIR/test-data-ledger.py" close --run-dir "$RUN_EXEC_DIR" \
    || log_warn "数据账本收账失败（辅助产物，不阻断）"
  FB_LEDGER=()
  [ -f "$RUN_EXEC_DIR/test-data-ledger.json" ] && \
    FB_LEDGER=(--extra-file "data_ledger=$RUN_EXEC_DIR/test-data-ledger.json")
  if $PYRUN "$SCRIPT_DIR/write-manifest.py" --run-id "$RUN_ID" --reports-dir "$RUN_OUTPUT_BASE" \
      --project-root "$PROJECT_ROOT" --evidence-dir "$RUN_EXEC_DIR" --allow-unrecorded-versions \
      "${FB_LEDGER[@]}" \
      && [ -f "$RUN_REPORT_DIR/run-manifest.json" ]; then
    $PYRUN "$SCRIPT_DIR/conclude.py" --report-dir "$RUN_REPORT_DIR" || true
  else
    log_err "run-manifest 落账失败——不产出 summary.json（无完整账本不得出结论件；修复后新 run-id 重跑）"
  fi
  exit 2
}

if $PYRUN "$SCRIPT_DIR/test-data-ledger.py" claim --run-dir "$RUN_EXEC_DIR"; then
  log_ok "数据租约 claim 成功（fixtures/resources 独占）"
elif [ "$DRILL" = true ]; then
  log_warn "drill：数据租约 claim 冲突（仅告警不阻断演练）"
else
  finish_block "数据租约 claim 冲突——另一 run 正占用本契约声明的排他测试数据；"\
    "等待对方 release/到期，或调整 fixtures 声明后重试（详见 runtime/leases.json）"
fi
# 第二十轮：--gate-evidence 原子拷入 run 目录（替代文件监视器竞态注入——
# 证据在 gate 校验前就位，且 dry-run 已预校验结构+sha）
if [ -n "$GATE_EVIDENCE_SRC" ]; then
  if [ -f "$GATE_EVIDENCE_SRC" ]; then
    cp "$GATE_EVIDENCE_SRC" "$RUN_EXEC_DIR/gate-evidence.json"
    log_ok "gate-evidence 已注入: $GATE_EVIDENCE_SRC → $RUN_EXEC_DIR/gate-evidence.json"
  else
    log_warn "--gate-evidence 文件不存在，跳过注入: ${GATE_EVIDENCE_SRC}（gate 校验将按无证据 fail-closed）"
  fi
fi
if [ "$MODE" = "contract" ]; then
  # ===== 契约模式 =====
  log_step "1/5 契约校验（fail-closed）..."
  [ -f "$CONTRACT" ] || finish_block "契约文件不存在: $CONTRACT"
  # 1.3.1（P1）：--runs-dir 可选显式指定 run 证据库；缺省由 validate-contract 智能解析
  # （契约同目录/对比测试 → 上一级/对比测试，覆盖 生成件/ 布局）——此前固定传
  # "$(dirname "$CONTRACT")/对比测试"，全分支契约（生成件/）会解析到不存在的
  # 生成件/对比测试，合法历史豁免被误 BLOCKED 且无覆盖入口。
  if ! $PYRUN "$TEMPLATES_DIR/validate-contract.py" --contract "$CONTRACT" --level test_ready ${DRILL_ROUTE_FLAG} \
      ${RUNS_DIR_FLAG}; then
    finish_block "契约未过 test_ready 校验（DRAFT 契约禁止正式执行）"
  fi
  # 取证源指纹复算（1.2.3 P1）：契约里登记的 sha256 只能证明"生成时曾声明某哈希"，
  # 不能证明执行时源文件仍与生成时一致（分支源被改动 → 契约与取证源脱节而无人察觉）。
  # 这里对 meta.branch_coverage.source_fingerprints 逐条现算比对；不一致=BLOCKED。
  # drill 只告警不阻断（演练允许源在迭代中）。
  if ! _FP_OUT="$($PYRUN -B - "$CONTRACT" <<'PY'
import hashlib, sys
from pathlib import Path
try:
    import yaml
except Exception:
    sys.exit(0)   # 依赖缺失由前置检查负责，此处不重复阻断
c = yaml.safe_load(Path(sys.argv[1]).read_text(encoding="utf-8")) or {}
bc = ((c.get("meta") or {}).get("branch_coverage") or {})
fps = bc.get("source_fingerprints") or []
if not isinstance(fps, list) or not fps:
    sys.exit(0)   # 非多分支契约（无指纹段）——不适用
bad = []
for e in fps:
    if not isinstance(e, dict) or e.get("supplied") is False:
        continue
    p, want = e.get("path"), e.get("sha256")
    if not p or not want:
        continue
    f = Path(str(p))
    if not f.is_file():
        bad.append(f"{e.get('role')}: 取证源已不存在 {p}"); continue
    got = hashlib.sha256(f.read_bytes()).hexdigest()
    if got != want:
        bad.append(f"{e.get('role')}: {p} sha 不符（契约登记 {str(want)[:16]}… 现算 {got[:16]}…）")
if bad:
    print("；".join(bad)); sys.exit(1)
print(f"取证源指纹复算一致（{len([e for e in fps if isinstance(e, dict) and e.get('supplied') is not False])} 源）")
PY
  )"; then
    if [ "$DRILL" = true ]; then
      log_warn "取证源指纹复算不一致（drill 不阻断）: $_FP_OUT"
    else
      finish_block "取证源指纹复算不一致——契约与生成时的取证源已脱节，正式执行拒绝: $_FP_OUT"
    fi
  elif [ -n "$_FP_OUT" ]; then
    log_ok "$_FP_OUT"
  fi
  [ -d "$SCENARIO_DIR" ] || finish_block "场景目录不存在（先跑 gen_from_contract.py）"
  [ -f "$RULES" ] || finish_block "compare-rules 不存在（先跑 gen_from_contract.py）"
  # 同源复算：执行件与契约必须逐字节一致（篡改 rules/场景在此拦截，不得进入执行）
  verify_provenance "$CONTRACT" "$RULES" "$SCENARIO_DIR" || finish_block "执行件与契约不同源（rules/场景被篡改或过期——重新 gen_from_contract 后新 run-id 重跑）"

  log_step "2/5 前置门禁（健康检查——按契约 environments.health_checks，不再硬编码端点）${DRILL_NOTE}..."
  # 第十三轮（P1）：健康检查由契约声明驱动（health-check.py），环境可移植；
  # 契约未声明 health_checks → health-check.py exit 2（fail-closed）
  if [ "$DRILL" = true ]; then
    $PYRUN "$SCRIPT_DIR/health-check.py" --contract "$CONTRACT" --out "$RUN_EXEC_DIR/health-results.json" \
      || log_warn "drill：健康检查失败（仅记录，不阻断演练）"
  else
    $PYRUN "$SCRIPT_DIR/health-check.py" --contract "$CONTRACT" --out "$RUN_EXEC_DIR/health-results.json" \
      || finish_block "健康检查失败（契约 environments.health_checks 缺失/不可解析）"
  fi
  # 第十三轮：gate 证据须能证明该 gate——契约 gates[].evidence_schema（validate-contract 强制）：
  #   kind=http    url 命中 allowed_urls 白名单且现场 200
  #   kind=report  报告文件按 file_format 解析 + required_fields 断言 + flow_field 绑定流程
  # 通用 file|url / 自由文本证据不再放行（fail-closed）
  # drill 也执行（gates.json 进账本/演练 summary），但不阻断
  $PYRUN "$SCRIPT_DIR/gate-evidence-check.py" "$RUN_REPORT_DIR/gates.json" "$RUN_EXEC_DIR/health-results.json" \
    "$CONTRACT" "$RUN_EXEC_DIR/gate-evidence.json" "$PROJECT_ROOT" \
    || finish_block "gate 证据校验器异常（gate-evidence-check.py 非零退出）"
  if [ "$DRILL" != true ]; then
    # 路径经 argv 传递（此前内插进 python -c 字符串——含引号的路径会破坏语法甚至注入代码）
    GATE_FAILED=$($PYRUN -c 'import json,sys;print(int(any(g.get("passed") is False for g in json.load(open(sys.argv[1])))))' "$RUN_REPORT_DIR/gates.json")
    [ "$GATE_FAILED" = "0" ] || finish_block "门禁未过（健康或契约 gate 证据缺失/无效——可在 $RUN_EXEC_DIR/gate-evidence.json 按契约 evidence_schema 提供证据（kind=report 报告文件或 kind=http 白名单 URL，均含 generated_at/target_env）后新 run-id 重跑）"
  fi

  log_step "3/5 场景执行（runner 后端=${FLOWTRACE_RUNNER:-api}；采集不可信=诚实 BLOCKED）..."
  $PYRUN "$SCRIPT_DIR/run-contract-scenarios.py" --scenario-dir "$SCENARIO_DIR" --exec-dir "$RUN_EXEC_DIR" --run-id "$RUN_ID" \
    --systems-dir "$RUNTIME_DIR/systems/api" \
    || log_warn "runner 存在 BLOCKED/ERROR 用例（交由结论 Gate 判定）"
  # P0-6：runner 产物落 run 目录（第三十轮起 exec/report 合并为单 run 单目录；下方兼容旧分离布局）
  if [ "$RUN_EXEC_DIR" != "$RUN_REPORT_DIR" ] && [ -f "$RUN_EXEC_DIR/case-results.json" ]; then
    cp "$RUN_EXEC_DIR/case-results.json" "$RUN_REPORT_DIR/case-results.json"
  elif [ ! -f "$RUN_REPORT_DIR/case-results.json" ]; then
    echo '[{"id":"RUNNER","required":true,"status":"BLOCKED","reason":"runner 未产出 case-results.json"}]' > "$RUN_REPORT_DIR/case-results.json"
  fi

  # v1.5.0：双端实例号入账（从 field-captures 实读，零编造）
  $PYRUN "$SCRIPT_DIR/test-data-ledger.py" record --run-dir "$RUN_EXEC_DIR" \
    || log_warn "数据账本实例登记失败（辅助产物，不阻断）"
  log_step "3.5/5 语义对拍..."
  $PYRUN "$SCRIPT_DIR/field-level-compare.py" --captures-dir "$RUN_EXEC_DIR/field-captures" --rules "$RULES" --outdir "$RUN_REPORT_DIR" \
    || log_warn "语义对拍非 OK（交由结论 Gate 判定）"
  # v1.6.0：数据账本 close 前置到落账前——账本 sha 经 write-manifest --extra-file 入证据链
  # （防清理痕迹游离于证据链外；close 只读验证资源状态，绝不自动破坏性清理）
  $PYRUN "$SCRIPT_DIR/test-data-ledger.py" close --run-dir "$RUN_EXEC_DIR" \
    || log_warn "数据账本收账失败（辅助产物，不阻断）"
  LEDGER_EXTRA=()
  [ -f "$RUN_EXEC_DIR/test-data-ledger.json" ] && \
    LEDGER_EXTRA=(--extra-file "data_ledger=$RUN_EXEC_DIR/test-data-ledger.json")
  # v1.7.2 P0-1：覆盖账本随 run 快照入账（结论期 conclude_core 复核哈希——运行后篡改现形）
  if [ -n "$CONTRACT" ] && [ -f "$CONTRACT" ]; then
    CM_PATH="$($PYRUN -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1],encoding="utf-8")) or {}; cm=(c.get("meta") or {}).get("coverage_manifest") or {}; p=(cm.get("path") if isinstance(cm,dict) else cm) or ""; print(p)' "$CONTRACT" 2>/dev/null || true)"
    if [ -n "$CM_PATH" ]; then
      case "$CM_PATH" in /*) CM_ABS="$CM_PATH" ;; *) CM_ABS="$(dirname "$CONTRACT")/$CM_PATH" ;; esac
      if [ -f "$CM_ABS" ]; then
        LEDGER_EXTRA+=(--extra-file "coverage_manifest=$CM_ABS")
        log_ok "覆盖账本已随 run 快照: $CM_ABS"
      fi
    fi
  fi
  log_step "4/5 落账..."
  # 第十三轮·审计修复：manifest 落账失败必须 finish_block（补占位证据 + 走 exit 2），
  # 仅 log_err 会让 operator 误以为继续——最终 conclude 会拒写 summary 但原因不可见
  # 第二十一轮：drill 同样落账（账本完整=演练可审计），但不出正式结论（见下）
  $PYRUN "$SCRIPT_DIR/write-manifest.py" --run-id "$RUN_ID" --reports-dir "$RUN_OUTPUT_BASE" \
    --project-root "$PROJECT_ROOT" --evidence-dir "$RUN_EXEC_DIR" --allow-unrecorded-versions \
    "${LEDGER_EXTRA[@]}" \
    --contract "$CONTRACT" --rules "$RULES" --scenarios "$SCENARIO_DIR" \
    --case-results "$RUN_REPORT_DIR/case-results.json" --gates-file "$RUN_REPORT_DIR/gates.json" \
    --field-compare "$RUN_REPORT_DIR/field-compare.json" \
    --source-version "${SOURCE_VERSION:-}" --target-version "${TARGET_VERSION:-}" --flow-version "${FLOW_VERSION:-}" \
    || finish_block "manifest 落账失败（版本/登记文件/重写冲突等）——修复后新 run-id 重跑"
  if [ "$DRILL" = true ]; then
    # 第二十一轮：演练模式——不出正式三态结论（conclude 不执行），写 DRILL summary。
    # 结论语义：DRILL ≠ PASS/FAIL/BLOCKED，仅陈述已执行的采集与对拍事实。
    log_step "5/5 演练结论（DRILL——不作为正式 PASS/FAIL 结论来源）..."
    $PYRUN -B - "$RUN_REPORT_DIR" "$RUN_ID" <<'PY'
import json, sys
from pathlib import Path
rd, run_id = Path(sys.argv[1]), sys.argv[2]
def _load(p, default):
    f = rd / p
    try:
        return json.loads(f.read_text(encoding="utf-8"))
    except Exception:
        return default
cr = _load("case-results.json", [])
fc = _load("field-compare.json", {})
gates = _load("gates.json", {})
summary = {
    "run_id": run_id,
    "conclusion": "DRILL",
    "note": "演练模式（--drill）：不出正式三态结论；正式 PASS/FAIL/BLOCKED 须全量场景+gates+conclude（不带 --drill）。",
    "mode": "drill",
    "cases": [{"id": c.get("id"), "status": c.get("status"), "reason": c.get("reason", "")} for c in cr if isinstance(c, dict)],
    "field_compare_summary": {k: fc.get(k) for k in ("status", "diffs_count", "exempted_count") if k in fc},
    "gates": gates if isinstance(gates, list) else [],
}
(rd / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
(md := rd / "summary.md").write_text(
    f"# 演练 run {run_id}（DRILL）\n\n> 演练产出，不作为正式 PASS/FAIL 结论来源。\n\n"
    f"- cases: " + ", ".join(f"{c.get('id')}={c.get('status')}" for c in summary["cases"]) + "\n"
    f"- field_compare: {summary['field_compare_summary']}\n", encoding="utf-8")
PY
    log_ok "演练完成：summary=DRILL（$RUN_REPORT_DIR/summary.json）"
    exit 0
  fi
  log_step "5/5 结论 Gate..."
else
  # ===== legacy 模式（港口煤发运旧链路，行为保持；浏览器脚本为仓库内 run-all-plants.js，
  # 第十二轮：移除对外部 ~/项目/FlowTrace 的默认指向——如需外部 CLI 仅显式 FLOWTRACE_CLI） =====
  if [ "$LEGACY_SKIP_PARSE" = false ]; then
    log_step "1/3 Excel → FlowDef..."
    (cd "$PROJECT_ROOT" && python3 .flowtrace/scripts/generate-flowdef-from-excel.py) || finish_block "FlowDef 解析失败"
  fi
  log_step "2/3 运行测试（run-id 隔离，保留历史）..."
  TEST_EXIT=0
  if [ -n "$LEGACY_PLANTS" ]; then
    (cd "$PROJECT_ROOT" && node .flowtrace/scripts/run-all-plants.js --plants "$LEGACY_PLANTS") || TEST_EXIT=$?
  else
    (cd "$PROJECT_ROOT" && node .flowtrace/scripts/run-all-plants.js) || TEST_EXIT=$?
  fi
  [ $TEST_EXIT -eq 0 ] && log_ok "测试执行完成" || log_warn "测试退出码=${TEST_EXIT}（不中断，交由 Gate）"
  log_step "3/3 落账+结论..."
  echo "[{\"id\":\"LEGACY-TEST\",\"severity\":\"P1\",\"passed\":$([ $TEST_EXIT -eq 0 ] && echo true || echo false)}]" > "$RUN_REPORT_DIR/gates.json"
  echo '[{"id":"LEGACY","required":true,"status":"'$([ $TEST_EXIT -eq 0 ] && echo PASS || echo ERROR)'"}]' > "$RUN_REPORT_DIR/case-results.json"
  echo '{"status":"BLOCKED","coverage":["legacy 模式无字段采集——语义对拍不适用，结论仅反映 runner 退出码"]}' > "$RUN_REPORT_DIR/field-compare.json"
  $PYRUN "$SCRIPT_DIR/write-manifest.py" --run-id "$RUN_ID" --reports-dir "$RUN_OUTPUT_BASE" --project-root "$PROJECT_ROOT" --evidence-dir "$RUN_EXEC_DIR" --allow-unrecorded-versions || true
fi



log_step "结论 Gate..."
CONCLUDE_ARGS=(--report-dir "$RUN_REPORT_DIR")
[ "$MODE" = "contract" ] && CONCLUDE_ARGS+=(--contract "$CONTRACT")  # 交叉核对：结果用例必须与契约 cases 一一对应
if $PYRUN "$SCRIPT_DIR/conclude.py" "${CONCLUDE_ARGS[@]}"; then
  CONCLUSION=PASS; CONCLUSION_EXIT=0
else
  CONCLUSION_EXIT=$?
  [ $CONCLUSION_EXIT -eq 1 ] && CONCLUSION=FAIL || CONCLUSION=BLOCKED
fi
# 第十一轮：结论件必须与完整账本同在（conclude 已保证"无账本不写 summary"）；
# 此处兜底防御：summary 缺失 = 账本断裂，绝不冒充任何结论退出
if [ ! -f "$RUN_REPORT_DIR/summary.json" ]; then
  log_err "未产出 summary.json（无完整可信账本——见上方 write-manifest/conclude 输出；修复后新 run-id 重跑）"
  exit 2
fi
# 最终交付物：单一 md 报告（1.3.4：生成前证据链核验——缺正式证据/结论复算不一致即拒绝；
# 新 run-id 全新目录，报告不可能已存在。核验失败不改变三态退出码，但打印显式告警）
if ! $PYRUN "$SCRIPT_DIR/gen-final-report.py" --run-dir "$RUN_REPORT_DIR" \
  ${CONTRACT:+--title "$(basename "${CONTRACT%.yaml}") 对比执行报告"}; then
  log_warn "最终报告未生成（证据链核验失败——见上方；summary.json 结论不受影响）"
fi

echo ""
case $CONCLUSION in
  PASS) echo -e "${GREEN}✅ PASS（P0/P1=0，必测全 PASS，无未豁免语义差异）${NC}" ;;
  FAIL) echo -e "${RED}❌ FAIL（存在未豁免语义差异）${NC}" ;;
  *)    echo -e "${YELLOW}⛔ BLOCKED（环境/数据/证据不足——fail-closed）${NC}" ;;
esac
echo "报告: $RUN_REPORT_DIR/summary.md（结论仅绑定 run-id=${RUN_ID}）"
exit $CONCLUSION_EXIT
