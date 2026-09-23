#!/usr/bin/env bash
# devflow_receipt.sh · 版本随 SKILL.md
# 统一收据契约共享库——complete / reconcile / audit-receipts 三条路径共用同一校验函数。
# 背景（用户复审 P0-3）：收据只记录报告路径、不绑定原始证据时，
# Gate 通过后删除证据文件，收据审计仍 PASS（PoC 实证 REPORT_EXISTS=no 仍 AUDIT PASS）。
#
# 统一收据契约（v3.16.0 起，gate 逐批迁移）：
#   COMMAND=               生成收据的命令
#   EXIT_CODE=             退出码
#   EVIDENCE_PATHS_JSON=   证据文件列表（JSON 数组字符串）
#   EVIDENCE_TREE_SHA256=  证据树哈希（列表内全部文件逐文件 sha256 后再整体 sha256）
#   PRODUCER_ROLE=         产出角色（如 completeness-auditor）
#   SESSION_ID=            会话 ID（角色隔离）
#   STARTED_AT= / FINISHED_AT=
#   ENVIRONMENT=           环境边界（dev/staging/production）
# 兼容旧单文件契约：EVIDENCE_PATH= + EVIDENCE_SHA256=（devflow-state verify_evidence 原口径）。
#
# 路径口径（v3.16.6 钉死）：
#   证据路径 = 生成时 gate 的记录形式（相对 workspace 根或绝对路径均可），
#   树哈希行使用收据记录的原始路径形式（重算必须同形式——路径名掺入哈希）；
#   校验侧以 ${WORKSPACE:-$PWD} 为基归一解析文件位置（不再依赖调用方 cwd）。
#
# 用法: source 本文件后调用下方函数。本文件不得改写调用方 shell 选项。

# ===== v3.16.9（N30-P3-3）: stage→证据契约映射（单一事实源）=====
# 消费者：devflow-state-complete.sh（verify_stage_evidence_contract——契约校验）
# 与 audit-receipts.sh（剥离检测）——此前两处内联复制，一处漏改即重演
# N29-P2-1/2（三处白名单漂移的根治未归零）。
# 契约类型 + 版本阈值（该版本起生成器对成功收据必然产出绑定行）：
#   new:  P3b/P6-final/ARCH-PITFALLS  ≥3.16.0；P4 ≥3.21.1（EVIDENCE_PATHS_JSON/TREE）
#   old:  P0b/P3cd/P5/P7-P10          ≥3.13.4（EVIDENCE_PATH/SHA256）
#   old4b: P4b                        ≥3.15.5（p4_prd_vs_code 绑定起点）
# 低于阈值的收据为合法 legacy（渐进放行）；阈值以上缺绑定 = 被剥离。
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
receipt_stage_contract() {
  case "$1" in
    P3b|P6-final|ARCH-PITFALLS) echo "new 3.16.0" ;;
    P4) echo "new 3.21.1" ;;
    P0b|P3cd|P5|P7|P8|P9|P10) echo "old 3.13.4" ;;
    P4b) echo "old4b 3.15.5" ;;
    *) echo "none" ;;
  esac
}

_stage_ver_ge() { # $1=版本号 $2=基准 → stdout 0/1（$1 ≥ $2；空版本 → 0）
  [ -n "$1" ] || { echo 0; return 0; }
  printf '%s\n%s\n' "$1" "$2" | awk 'NR==1{a=$0} NR==2{b=$0}
    END{n=split(a,av,"."); m=split(b,bv,"."); k=(n>m?n:m)
      for(i=1;i<=k;i++){x=av[i]+0; y=bv[i]+0
        if(x>y){print 1; exit} else if(x<y){print 0; exit}}
      print 1}'
}

_receipt_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}

# v3.16.6（N27-P3-2）: 路径归一助手——bash 3.2 无 readlink -f（BSD），
# 用 cd -P 物理归一（符号链接展开，防越界洗白）
_receipt_norm_dir() { # $1=目录 → 物理绝对路径；不可达 → rc1
  ( cd -P "$1" 2>/dev/null && pwd -P ) || return 1
}
_receipt_ws_base() { # → workspace 物理绝对路径；不可达 → 空输出
  _receipt_norm_dir "${WORKSPACE:-$PWD}" 2>/dev/null || echo ""
}
# v3.16.11（P1-3）: 完整 realpath——cd -P 只解析父目录，最终文件层的 symlink
# 不被展开（PoC：workspace/evidence-link -> /tmp/外部/external.txt 词法落界内、
# 物理在外 → 边界比较被逃逸）。python3 os.path.realpath 完整解析所有层
#（macOS bash 3.2 无 readlink -f）；无 python3 时 fail-closed 拒绝 symlink
# 文件（非 symlink 文件 cd -P 父目录归一已足够）。
_receipt_realpath() { # $1=绝对/相对路径 → 完整物理路径；失败 rc1
  if devflow_py_ok; then
    # v3.20.2: 剥离 LC_ALL——C locale 下含非 ASCII site 配置的解释器（venv 中文
    # .pth）在 site 初始化即崩，导致所有 gate 的路径解析级联"unresolvable"
    (unset LC_ALL; exec "${DEVFLOW_PY[@]}" -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1") 2>/dev/null || return 1
  elif command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; then
    readlink -f "$1" 2>/dev/null || return 1
  else
    return 2  # 无可用 realpath 工具（调用方按 symlink fail-closed 处理）
  fi
}

_receipt_norm_file() { # $1=任意路径 → 物理绝对路径（相对路径以 workspace 为基）；父目录不可达 → rc1
  local p="$1" d b _rp
  case "$p" in
    /*) ;;
    *) p="${WORKSPACE:-$PWD}/$p" ;;
  esac
  d=$(dirname "$p"); b=$(basename "$p")
  _rp=$( cd -P "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || return 1
  # v3.16.11: 最终层/中间层 symlink 完整解析（realpath 工具缺失时 symlink 文件 fail-closed）
  if devflow_py_ok \
     || { command -v readlink >/dev/null 2>&1 && readlink -f / >/dev/null 2>&1; }; then
    _receipt_realpath "$_rp" && return 0
    return 1
  fi
  # 无 realpath 工具：文件本身是 symlink → 拒绝（无法验证落点，fail-closed）
  if [ -L "$_rp" ]; then
    return 1
  fi
  printf '%s\n' "$_rp"
}

# 证据树哈希：参数 = 若干证据文件路径（相对调用方 cwd）
# 任一文件缺失/不可读 → 空输出 + rc=1（调用方按校验失败处理）
receipt_evidence_tree() {
  local combined="" f h
  for f in "$@"; do
    [ -n "$f" ] || continue
    h=$(_receipt_sha256_file "$f")
    [ -n "$h" ] || { echo ""; return 1; }
    combined="${combined}${h}  ${f}"$'\n'
  done
  printf '%s' "$combined" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }
}

# v3.16.6: 校验侧树哈希——哈希行用收据记录的原始路径名（与生成端
# receipt_evidence_tree 同口径），文件内容按 workspace 归一路径读取
_receipt_tree_verify() {
  local combined="" f h resolved
  for f in "$@"; do
    [ -n "$f" ] || continue
    resolved=$(_receipt_norm_file "$f")
    [ -n "$resolved" ] || { echo ""; return 1; }
    h=$(_receipt_sha256_file "$resolved")
    [ -n "$h" ] || { echo ""; return 1; }
    combined="${combined}${h}  ${f}"$'\n'
  done
  printf '%s' "$combined" | { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; }
}

# 校验收据的证据绑定（对账重验，不依赖生成时状态）：
#   0 = 通过（重算一致）
#   1 = 绑定存在但不一致/证据缺失/越界（必须 FAIL——防"删证据后审计仍通过"与
#       "证据调包到 workspace 外部稳定文件"，N27-P1-1）
#   3 = 收据无证据绑定（legacy 渐进迁移，调用方按 WARN 处理）
# 输出诊断行到 stdout。
# v3.16.6（N27-P1-1）: workspace 边界——证据（新旧契约同口径）必须落在
# ${WORKSPACE:-$PWD} 内（物理归一，防 ../ 词法逃逸与符号链接逃逸）；
# v3.16.6（N27-P3-2）: 相对路径以 workspace 为基归一解析（此前依赖调用方 cwd，
# 非 workspace 根 cwd 下对真实收据一律误拒）。
# v3.30.1: 通用 *_JSON / *_JSON_SHA256 绑定对重验——Gate JSON 强制（gate_json_lib）写入的
# 收据绑定行此前无任何重验逻辑（声明"audit 重验即拦截"不成立，本批修复）。规则：
# 每个形如 ^[A-Z0-9_]+_JSON=<path> 的行，若存在同名 _JSON_SHA256=<64hex> 配对行，
# 则验：路径物理归一 + workspace 边界 + 文件存在 + 哈希一致。EVIDENCE_PATHS_JSON
# 是数组形式（无同名 _SHA256 配对），自然跳过，仍由专有逻辑处理。
_verify_json_pairs() { # <receipt>
  local receipt="$1" line tag path want actual resolved _ws_base
  _ws_base=$(_receipt_ws_base)
  [ -n "$_ws_base" ] || { echo "[EVIDENCE] workspace 不可解析（${WORKSPACE:-$PWD}）: $receipt"; return 1; }
  while IFS= read -r line; do
    tag="${line%%=*}"; path="${line#*=}"
    [ "$tag" = "EVIDENCE_PATHS_JSON" ] && continue
    want=$(sed -n "s/^${tag}_SHA256=//p" "$receipt" | head -1)
    [ -n "$want" ] || continue
    printf '%s' "$want" | grep -qE '^[0-9a-f]{64}$' || {
      echo "[EVIDENCE] ${tag}_SHA256 非法（非 64hex）: $receipt"; return 1; }
    resolved=$(_receipt_norm_file "$path" 2>/dev/null)
    if [ -z "$resolved" ]; then
      echo "[EVIDENCE] ${tag} 路径不可解析: ${path}（收据 ${receipt}）"; return 1
    fi
    case "$resolved" in
      "$_ws_base"|"$_ws_base"/*) ;;
      *) echo "[EVIDENCE] ${tag} 证据越出 workspace: ${path}（收据 ${receipt}）"; return 1 ;;
    esac
    [ -f "$resolved" ] || {
      echo "[EVIDENCE] ${tag} 绑定文件缺失: ${path}（收据 ${receipt}）——JSON 正本删除后审计必须阻断"; return 1; }
    actual=$(_receipt_sha256_file "$resolved")
    [ "$actual" = "$want" ] || {
      echo "[EVIDENCE] ${tag} 哈希不匹配: ${path}（收据 ${receipt}）——JSON 正本篡改后审计必须阻断"; return 1; }
  done < <(grep -E '^[A-Z0-9_]+_JSON=' "$receipt" 2>/dev/null)
  return 0
}

# v3.30.4: 阶段必备 JSON 绑定行检测（剥离即 FAIL——镜像 v3.16.8 对 EVIDENCE 行的
# 同类收口）：v3.30.0 起 13 处 Gate + P0 的收据必然携带 *_JSON=path 绑定行（gj 库
# fail-closed 产出）；阈值以上缺行 = 被剥离（剥两行即可让正本篡改对 audit 隐形——
# 实证 PoC：P5 终态收据剥 TEST_CASES_JSON* + 篡改 json → audit rc=0 放行）。
# 豁免：EXIT_CODE≠0（失败轮）、SKIPPED=1（合法跳过）、版本 < 3.30.0（legacy WARN 语义）。
verify_stage_json_binding() { # <receipt> <stage>
  local receipt="$1" stage="$2" ver vernum _rc _skip _tag
  [ -f "$receipt" ] || return 0
  _rc=$(grep '^EXIT_CODE=' "$receipt" | head -1 | cut -d= -f2)
  [ "${_rc:-1}" = "0" ] || return 0
  # v3.30.7: state-init 豁免收紧——仅 gates/P0 目录 + PHASE=P0 三重条件（第 2 轮 PoC：
  # 任意收据改 VERSION=state-init@ 前缀即可关掉绑定检测；基线只存在于 gates/P0）
  if sed -n 's/^VERSION=//p' "$receipt" | head -1 | grep -q '^state-init@'; then
    case "$receipt" in
      */gates/P0/receipt.txt)
        [ "$(sed -n 's/^PHASE=//p' "$receipt" | head -1)" = "P0" ] && return 0 ;;
    esac
    echo "[EVIDENCE] state-init@ 前缀仅合法于 gates/P0 基线——当前收据伪造前缀拒绝: $receipt"
    return 1
  fi
  # v3.30.7: 不可跳阶段拒绝名单（SKILL.md 停止条件：P3、P4b、P6、P7-P10 不可跳过
  # ——此前只验"授权真伪"不验"该阶段可否跳"，伪造四字段+skip-log 即可跳过 P6/P7）
  case "$stage" in
    P3|P4b|P6|P7|P8|P9|P10)
      if grep -q '^SKIPPED=1' "$receipt"; then
        echo "[EVIDENCE] ${stage} 属不可跳过阶段（停止条件硬规则），SKIPPED 收据拒绝: $receipt"
        return 1
      fi ;;
  esac
  # v3.30.5: SKIPPED 豁免须双重授权核验（伪 SKIPPED=1 绕过绑定检测的 PoC 收口）——
  # 收据四字段（reason/by/at/approval）+ skip-log 对应阶段授权行（authorized-by 一致）
  if grep -q '^SKIPPED=1' "$receipt"; then
    local _sr _sb _sa _se _feat _slog _sline
    _sr=$(sed -n 's/^SKIP_REASON=//p' "$receipt" | head -1)
    _sb=$(sed -n 's/^AUTHORIZED_BY=//p' "$receipt" | head -1)
    _sa=$(sed -n 's/^AUTHORIZED_AT=//p' "$receipt" | head -1)
    _se=$(sed -n 's/^APPROVAL_EVIDENCE=//p' "$receipt" | head -1)
    if [ -z "$_sr" ] || [ -z "$_sb" ] || [ -z "$_sa" ] || [ -z "$_se" ]; then
      echo "[EVIDENCE] ${stage} 收据声明 SKIPPED 但缺四字段授权（SKIP_REASON/AUTHORIZED_BY/AUTHORIZED_AT/APPROVAL_EVIDENCE）——伪跳过拒绝: $receipt"
      return 1
    fi
    # v3.30.5b: 三层 dirname——receipt=<ws>/.devflow/<feature>/gates/<stage>/receipt.txt
    # （两层只到 gates，_feat 误取 "gates" → skip-log 永远找不到——Linux 全量抓到）
    _feat=$(basename "$(dirname "$(dirname "$(dirname "$receipt")")")")
    _slog="${WORKSPACE:-$PWD}/.devflow/$_feat/skip-log.txt"
    _sline=""
    [ -f "$_slog" ] && _sline=$(grep "^SKIP_${stage}=" "$_slog" | head -1)
    if [ -z "$_sline" ] || ! printf '%s' "$_sline" | grep -qF "authorized-by=$_sb"; then
      echo "[EVIDENCE] ${stage} SKIPPED 收据在 skip-log 无对应授权行（需 SKIP_${stage}=…authorized-by=${_sb}）: $receipt"
      return 1
    fi
    return 0
  fi
  ver=$(sed -n 's/^VERSION=//p' "$receipt" | head -1)
  vernum="${ver##*@}"
  printf '%s' "$vernum" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+' || return 0
  [ "$(printf '%s\n3.30.0\n' "$vernum" | awk 'NR==1{a=$0} NR==2{b=$0} END{n=split(a,av,"."); m=split(b,bv,"."); k=(n>m?n:m); for(i=1;i<=k;i++){x=av[i]+0; y=bv[i]+0; if(x>y){print 1;exit} else if(x<y){print 0;exit}} print 1}')" = "1" ] || return 0
  # v3.30.7: P3c/P3d 分项收据按 PHASE 行取有效映射（security 模式真产出 gates/P3c
  # + PHASE=P3c——audit 归一 P3cd 后要求双行会误杀分项流程）
  _pline=$(sed -n 's/^PHASE=//p' "$receipt" | head -1)
  case "$_pline" in P3c|P3d) stage="$_pline" ;; esac
  case "$stage" in
    P0)          set -- ACCEPTANCE_JSON ;;
    P0b)         set -- PRD_REVIEW_JSON ;;
    P1)          set -- TECH_SELECTION_JSON CLARIFICATION_JSON CONSTRAINTS_JSON ;;
    P2)          set -- DESIGN_JSON ;;
    P2a)         set -- DESIGN_REVIEW_JSON ;;
    P2b)         set -- DEMO_SIGNOFF_JSON ;;
    P3)          set -- SELF_CHECK_JSON ;;
    P3c)         set -- SECURITY_JSON ;;
    P3d)         set -- PERFORMANCE_JSON ;;
    P3cd)        set -- SECURITY_JSON PERFORMANCE_JSON ;;
    P3b)         set -- CODE_REVIEW_JSON ;;
    P4)          set -- PRD_VALIDATION_JSON ;;
    P5)          set -- TEST_CASES_JSON ;;
    P7)          set -- DEPLOYMENT_JSON ;;
    P8)          set -- MONITORING_JSON ;;
    P9)          set -- DOCS_INDEX_JSON ;;
    P10)         set -- RETROSPECTIVE_JSON SHARING_JSON ;;
    SMALL-CHANGE) set -- SMALL_CHANGE_JSON ;;
    *)           return 0 ;;
  esac
  local _feat2 _slog2
  _feat2=$(basename "$(dirname "$(dirname "$(dirname "$receipt")")")")
  _slog2="${WORKSPACE:-$PWD}/.devflow/$_feat2/skip-log.txt"
  for _tag do
    if ! grep -q "^${_tag}=" "$receipt"; then
      # v3.30.7: P3cd 豁免留痕——WAIVED=1 + skip-log 对应授权行可替代绑定行
      case "$_tag" in
        SECURITY_JSON)    _wkey="SKIP_P3CD_SECURITY" ;;
        PERFORMANCE_JSON) _wkey="SKIP_P3CD_PERFORMANCE" ;;
        *) _wkey="" ;;
      esac
      # v3.30.8: 对齐 SKIPPED 双重口径（第3轮审计 F3——原两行可伪造）：WAIVED 行 +
      # skip-log 授权行须含非空 authorized-by
      if [ -n "$_wkey" ] && grep -q "^${_tag%%_JSON}_WAIVED=1$" "$receipt" \
         && [ -f "$_slog2" ] && grep -qE "^${_wkey}=[^|]+\|authorized-by=[^|]+" "$_slog2"; then
        continue
      fi
      echo "[EVIDENCE] ${stage} 终态收据缺 ${_tag} 绑定行（版本 $vernum ≥ 3.30.0 必然产出——缺行即被剥离，正本篡改将脱离审计）: $receipt"
      return 1
    fi
  done
  return 0
}

verify_receipt_evidence() {
  local receipt_file="$1"
  local paths_json tree_stored tree_calc f resolved ev_path ev_sha actual _ws_base
  [ -f "$receipt_file" ] || { echo "[EVIDENCE] receipt missing: $receipt_file"; return 1; }

  # v3.30.1: Gate JSON 绑定对重验（*_JSON + *_JSON_SHA256——篡改/删除/越界即拒）
  _verify_json_pairs "$receipt_file" || return 1

  tree_stored=$(sed -n 's/^EVIDENCE_TREE_SHA256=//p' "$receipt_file" | head -1)
  paths_json=$(sed -n 's/^EVIDENCE_PATHS_JSON=//p' "$receipt_file" | head -1)

  if [ -n "$tree_stored" ] && [ -n "$paths_json" ]; then
    # 新契约：JSON 数组 → 路径列表 → 重算树哈希
    if ! command -v jq >/dev/null 2>&1; then
      echo "[EVIDENCE] jq 不可用——无法重验 EVIDENCE_PATHS_JSON: ${receipt_file}"
      return 1
    fi
    local -a ev_files=()
    while IFS= read -r f; do
      [ -n "$f" ] && ev_files+=("$f")
    done < <(jq -r '.[]' <<<"$paths_json" 2>/dev/null || true)
    if [ "${#ev_files[@]}" -eq 0 ]; then
      echo "[EVIDENCE] EVIDENCE_PATHS_JSON 解析为空: $receipt_file"
      return 1
    fi
    _ws_base=$(_receipt_ws_base)
    [ -n "$_ws_base" ] || { echo "[EVIDENCE] workspace 不可解析（${WORKSPACE:-$PWD}）: $receipt_file"; return 1; }
    for f in "${ev_files[@]}"; do
      resolved=$(_receipt_norm_file "$f")
      if [ -z "$resolved" ] || [ ! -f "$resolved" ]; then
        echo "[EVIDENCE] 证据文件缺失/不可解析: ${f}（收据 ${receipt_file}）——删除证据后审计必须阻断"
        return 1
      fi
      case "$resolved" in
        "$_ws_base"|"$_ws_base"/*) ;;
        *) echo "[EVIDENCE] 证据路径越界（必须在 workspace 内）: ${f}（收据 ${receipt_file}）"; return 1 ;;
      esac
    done
    tree_calc=$(_receipt_tree_verify "${ev_files[@]}")
    if [ -z "$tree_calc" ]; then
      echo "[EVIDENCE] 证据树哈希计算失败: $receipt_file"
      return 1
    fi
    if [ "$tree_calc" = "$tree_stored" ]; then
      echo "[EVIDENCE] OK 树哈希一致（${#ev_files[@]} 文件）: $receipt_file"
      return 0
    fi
    echo "[EVIDENCE] 证据树哈希不匹配（证据被篡改或替换）: $receipt_file"
    echo "  stored: $tree_stored"
    echo "  actual: $tree_calc"
    return 1
  fi

  # 旧单文件契约（devflow-state verify_evidence 原口径）
  ev_path=$(sed -n 's/^EVIDENCE_PATH=//p' "$receipt_file" | head -1)
  ev_sha=$(sed -n 's/^EVIDENCE_SHA256=//p' "$receipt_file" | head -1)
  if [ -n "$ev_path" ] && [ -n "$ev_sha" ]; then
    # v3.16.6（N27-P1-1）: 旧契约同补 workspace 边界（对齐 verify_evidence_receipt 语义）
    local resolved_l _ws_base_l
    _ws_base_l=$(_receipt_ws_base)
    resolved_l=$(_receipt_norm_file "$ev_path")
    if [ -z "$resolved_l" ] || [ ! -f "$resolved_l" ]; then
      echo "[EVIDENCE] 证据文件缺失: ${ev_path}（收据 ${receipt_file}）"
      return 1
    fi
    case "$resolved_l" in
      "$_ws_base_l"|"$_ws_base_l"/*) ;;
      *) echo "[EVIDENCE] 证据路径越界（必须在 workspace 内）: ${ev_path}（收据 ${receipt_file}）"; return 1 ;;
    esac
    actual=$(_receipt_sha256_file "$resolved_l")
    if [ "$actual" = "$ev_sha" ]; then
      echo "[EVIDENCE] OK 单文件哈希一致: $ev_path"
      return 0
    fi
    echo "[EVIDENCE] 证据哈希不匹配: ${ev_path}（收据 ${receipt_file}）"
    return 1
  fi

  echo "[EVIDENCE] 收据无证据绑定（legacy 契约，仅路径/计数）: $receipt_file"
  return 3
}
