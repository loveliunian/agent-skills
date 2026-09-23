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
