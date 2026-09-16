#!/usr/bin/env bash
# =============================================================================
# 代码图谱健康 Gate
# =============================================================================
# 功能：
#   1. 检查图谱服务可用性
#   2. 检查索引状态 = ready
#   3. 检查本批关键文件已同步
#   4. 图谱不可用时要求源码回退
#   5. 支持 GIT_RANGE 环境变量 / --git-range 参数自定义 Git 变更范围
# =============================================================================
set -uo pipefail


# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# v3.20.3: fallback 清单逐文件重算所需
sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# ---------- 参数解析 ----------
# v3.15.18: FEATURE 不再从 $1 预赋值——旧写法在 flag 解析循环之前执行，
# options-only 调用（--force-fallback / --report x / --git-range 3 foo）的
# 首个 flag 被误存为 feature，白名单校验即 exit 2（usage 自带的三种示例用法
# 全部不可用，PoC 实证）。feature 统一由循环 *) 分支收集首个位置参数。
FEATURE=""
# v3.15.11: 实现 usage 宣称的默认值——旧 `${GRAPH_URL:-}` 为空时 curl 请求无 scheme 的
# "/health" 恒失败，图谱服务在跑也恒判 unreachable（fail-closed 但默认值形同虚设）
GRAPH_URL="${GRAPH_URL:-http://localhost:8086}"
# 仅当命令行提供了 --report 才覆盖 env
REPORT="${REPORT:-}"
FORCE_FALLBACK=false

usage() {
  cat <<EOF
Usage: $0 [feature] [--report path] [--force-fallback] [--git-range <n>]

检查代码图谱健康 Gate

参数：
  feature           功能模块名（可选）
  --report path    图谱检查报告路径
  --force-fallback 强制使用 fallback 模式
  --git-range <n>   Git 变更范围（默认 5，即最近 n 个提交；关键文件真实来源）

环境变量：
  GRAPH_URL         图谱服务 URL（默认：http://localhost:8086）
  GIT_RANGE         Git 变更范围（默认 5）
  GRAPH_EXPECTED_ID 显式声明的索引身份（服务使用不透明 ID 时绑定用；
                    未设时按 repo realpath/仓名/HEAD 自动对账，对不上即阻断）

示例：
  $0 m-03
  $0 --report .devflow/m-03/graph-health-report.env
  $0 --git-range 10
  GIT_RANGE=10 $0 m-03
EOF
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    # v3.15.9: 带值 flag 缺值前置检查（p3 v3.15.8 同型收口）
    --report) [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --report requires a non-flag value" >&2; exit 2; }; REPORT="$2"; shift 2 ;;
    --force-fallback) FORCE_FALLBACK=true; shift ;;
    --git-range)
      [ "$#" -ge 2 ] && [ "${2#-}" = "$2" ] || { echo "[ERR] --git-range requires a non-flag value" >&2; exit 2; }; GIT_RANGE="$2"; shift 2 ;;
    --help|-h) usage ;;
    --*) echo "[P0] unknown argument: $1"; exit 2 ;;
    *) [ -z "$FEATURE" ] && FEATURE="$1"; shift ;;
  esac
done

# v3.15.5: feature 白名单共享校验（devflow_feature.sh；为空时由后续 state/产物读取失败兜底）
if [ -n "$FEATURE" ]; then
  source "$(cd "$(dirname "$0")" && pwd)/../scripts/devflow_feature.sh"
  devflow_feature_validate "$FEATURE" || exit 2
fi

# ---------- 状态变量 ----------
GRAPH_STATUS="unknown"
INDEX_FRESH="unknown"
CHECKED_AT=""
ERROR_MSG=""

# =============================================================================
# SECTION 0: 初始化报告文件
# =============================================================================
echo ""
echo "=== §0 图谱健康检查 ==="

REPORT_DIR="${REPORT_DIR:-.devflow}"
[ -n "$FEATURE" ] && REPORT_DIR="$REPORT_DIR/$FEATURE"
mkdir -p "$REPORT_DIR"

REPORT_FILE="${REPORT:-${REPORT_DIR}/graph-health-report.env}"

# v3.15.18: 幂等修复——运行前快照既有证据指针，SECTION 5 报告重写时回写保留。
# 旧版报告覆盖重写丢弃 source_fallback_evidence 行 → 同一报告第二次运行失去
# 证据指针而 FAIL（首跑 WARN 放行、重跑 blocking 的非幂等，PoC 实证）。
PREV_FALLBACK_EVIDENCE=""
if [ -f "$REPORT_FILE" ]; then
  PREV_FALLBACK_EVIDENCE=$(grep "^source_fallback_evidence=" "$REPORT_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)
fi

# =============================================================================
# SECTION 1: 图谱服务可用性检查
# =============================================================================
echo ""
echo "=== §1 图谱服务可用性检查 ==="

check_graph_health() {
  local url="$1"
  local timeout="${2:-5}"
  local response http_code body

  # 使用 curl 检查服务健康状态
  if command -v curl >/dev/null 2>&1; then
    # 尝试多个可能的健康检查端点
    for endpoint in "/health" "/api/health" "/status" ""; do
      response=$(curl -s -m "$timeout" -w "\n%{http_code}" "${url}${endpoint}" 2>/dev/null || true)
      http_code=$(echo "$response" | tail -1)
      body=$(echo "$response" | sed '$d')  # macOS 兼容: 替代 head -n -1

      if [ "$http_code" = "200" ] || [ "$http_code" = "204" ]; then
        # v3.15.1: 响应 schema 校验——body 必须是含健康语义字段（status/service/index_status）的 JSON；
        # 任意静态 HTTP 200（含任意 HTML/文本）不再判为图谱服务可达。
        if command -v jq >/dev/null 2>&1 \
          && printf '%s' "$body" | jq -e 'type == "object" and (has("status") or has("service") or has("index_status"))' >/dev/null 2>&1; then
          echo "$body"
          return 0
        else
          echo "$body" >&2
          return 2
        fi
      fi
    done
  fi

  return 1
}

# 尝试连接图谱服务
if [ "$FORCE_FALLBACK" = "false" ]; then
  check_graph_health "$GRAPH_URL" 5
  _gh_rc=$?
  if [ "$_gh_rc" -eq 0 ]; then
    GRAPH_STATUS="reachable"
    pass "graph service reachable with health JSON schema: $GRAPH_URL"
  elif [ "$_gh_rc" -eq 2 ]; then
    GRAPH_STATUS="invalid-schema"
    p0 "GRAPH_URL 返回 200 但响应非图谱健康 schema（JSON status/service 字段缺失）: $GRAPH_URL"
  else
    GRAPH_STATUS="unreachable"
    warn "graph service unreachable: $GRAPH_URL"
  fi
else
  GRAPH_STATUS="fallback"
  warn "force fallback mode enabled"
fi

# =============================================================================
# SECTION 2: 索引状态检查
# =============================================================================
echo ""
echo "=== §2 索引状态检查 ==="

# v3.20.3: repo 绑定三元组——索引身份必须能对上本仓（realpath/仓名/HEAD 或显式 GRAPH_EXPECTED_ID），
# 否则即"wrong-project 假绿"（Gate 记录的是别的仓库的索引状态）。
REPO_REALPATH=$(pwd -P)
REPO_NAME=$(basename "$REPO_REALPATH")
GIT_HEAD=""
if command -v git >/dev/null 2>&1; then
  GIT_HEAD=$(git rev-parse HEAD 2>/dev/null || true)
fi

index_identity_match="unknown"
if [ "$GRAPH_STATUS" = "reachable" ]; then
  # 检查索引是否 ready（v3.15.1: 记录索引/项目身份，状态未知不再放行）
  status_response=$(curl -s -m 5 "${GRAPH_URL}/api/index/status" 2>/dev/null || true)
  index_status=$(printf '%s' "$status_response" | jq -r '[.status, .index_status] | map(select(type == "string" and length > 0)) | first // empty' 2>/dev/null || true)
  index_identity=$(printf '%s' "$status_response" | jq -r '[.index_id, .project, .project_id, .repo, .repo_path, .workspace, .root, .path] | map(select(type == "string" and length > 0)) | first // empty' 2>/dev/null || true)
  # 响应内嵌路径字段（如 project_path/root）优先与 repo realpath 对账
  index_path=$(printf '%s' "$status_response" | jq -r '[.project_path, .root_path, .root, .path, .workspace_path] | map(select(type == "string" and length > 0)) | first // empty' 2>/dev/null || true)

  if [ "$index_status" = "ready" ]; then
    INDEX_FRESH="true"
    pass "graph index status: ready${index_identity:+ (index=${index_identity})}"
  elif [ -n "$index_status" ]; then
    INDEX_FRESH="false"
    # v3.20.3: stale 从 WARN 升级为阻断——放行 stale 索引等于让后续环节基于过期图谱
    p0 "graph index status: $index_status (not ready) — stale 索引必须同步后重跑，不再 WARN 放行"
  else
    INDEX_FRESH="unknown"
    # v3.15.1: 索引状态未知不得进入 PASS（fail-closed）—— /api/index/status 无合法 status 字段即阻断
    p0 "could not determine index status（响应无 status 字段）——索引状态未知不得放行"
  fi

  # v3.20.3: 身份绑定（仅 reachable 时强制；unreachable 走 fallback 证据链）
  # v3.20.6 重构（第 2 轮对抗复查收口）：
  #   ① 净化——身份/路径字段提取后立即剥离 CR/LF（防报告行注入伪造
  #     source_fallback_evidence / index_identity_match 行）；
  #   ② 归一化——每个含路径语义的候选串逐个 normpath，任何一步失败即
  #     fail-closed（不再回退原始拼接串，python3 损坏/缺失同责）；
  #   ③ 拼接——identity 与 path 不再拼接对账（拼接可重组伪造 realpath），
  #     改为两字段各自逐一对账，全部不中才判 mismatch。
  strip_crlf() { printf '%s' "$1" | tr -d '\r\n'; }
  index_identity=$(strip_crlf "${index_identity:-}")
  index_path=$(strip_crlf "${index_path:-}")
  # v3.20.7: index_status 同样净化——第 3 轮实证 status 字段换行可注入伪造证据指针
  # （第 2 轮只封了 identity/path 两面）；再加枚举白名单，非 known 状态一律按 unknown 处理。
  index_status=$(strip_crlf "${index_status:-}")
  case "$index_status" in
    ready|indexing|stale|building|error|"") ;;
    *) index_status="unknown:$index_status" ;;
  esac

  if [ -n "${GRAPH_EXPECTED_ID:-}" ]; then
    if [ "$index_identity" = "$GRAPH_EXPECTED_ID" ]; then
      index_identity_match="true"
      pass "index identity == GRAPH_EXPECTED_ID: $index_identity"
    else
      index_identity_match="false"
      p0 "index identity mismatch: reported='${index_identity:-empty}' != GRAPH_EXPECTED_ID=${GRAPH_EXPECTED_ID}（图谱指向别的项目）"
    fi
  elif [ -n "$index_identity" ] || [ -n "$index_path" ]; then
    # v3.20.4: 仓名匹配要求段边界——"repo-backup"/"repo_x" 不命中仓名 "repo"。
    # realpath/HEAD 维持子串匹配（本仓物理路径与 40hex 不可能作为子串出现在无关串中）。
    matched=0
    HEAD_SHORT=""
    [ -n "$GIT_HEAD" ] && HEAD_SHORT="${GIT_HEAD:0:12}"
    # 归一化器：优先 python3 os.path.normpath；不可用/失败时退化 sed 归一化，
    # 但含未归一化 ".." 段且无法归一化即整体 fail-closed（v3.20.5 曾 fail-open）。
    normalize_str() {
      # normalize_str <raw> -> stdout 归一化结果；失败 rc=1
      local raw="$1"
      [ -n "$raw" ] || { printf '%s' "$raw"; return 0; }
      if command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1; then
        python3 -c 'import os,sys; print(os.path.normpath(sys.argv[1]))' "$raw" 2>/dev/null && return 0
      fi
      case "$raw" in
        *".."*) return 1 ;;   # 无法归一化的父段引用——fail-closed
        *) printf '%s' "$raw" | sed 's|/\./|/|g; s|//\+|/|g' && return 0 ;;
      esac
      return 1
    }
    # 候选对账池：identity 与 path 各自归一化后逐段对账（不拼接）。
    # v3.20.7: 任何候选归一化失败 = 整体对账失败（norm_failed 短路）——
    # 不再"失败候选跳过、其余候选照常匹配"造成报告 match=true 与 p0 并存的语义矛盾。
    hay_pool=()
    norm_failed=0
    for raw in "$index_identity" "$index_path"; do
      [ -n "$raw" ] || continue
      if ! normed=$(normalize_str "$raw"); then
        p0 "index identity contains un-normalizable '..' segment（无法归一化，fail-closed）: ${raw}"
        norm_failed=1
        break
      fi
      hay_pool+=("$normed")
    done
    if [ "$norm_failed" -eq 1 ]; then
      matched=0
      hay_pool=()
    fi
    if [ "$matched" -eq 0 ] && [ "$norm_failed" -eq 0 ] && [ "${#hay_pool[@]}" -gt 0 ]; then
      for cand in "$REPO_REALPATH" "$REPO_NAME" "$GIT_HEAD" "$HEAD_SHORT"; do
        [ -n "$cand" ] || continue
        for haystack in ${hay_pool[@]+"${hay_pool[@]}"}; do
          if [ "$cand" = "$REPO_NAME" ]; then
            case "$haystack" in
              "$cand"|*/"$cand"|"$cand"/*|*/"$cand"/*) matched=1; break 2 ;;
              "$cand".*|*/"$cand".*) matched=1; break 2 ;;
            esac
          else
            case "$haystack" in
              *"$cand"*) matched=1; break 2 ;;
            esac
          fi
        done
      done
    fi
    if [ "$matched" -eq 1 ]; then
      index_identity_match="true"
      pass "index identity bound to this repo (${REPO_NAME}@${GIT_HEAD:0:12})"
    else
      index_identity_match="false"
      p0 "index identity mismatch: reported='${index_identity:-}${index_path:+ path=${index_path}}' 与本仓 ${REPO_REALPATH}@${GIT_HEAD:0:12} 无法对上——wrong-project 必须阻断（部署若使用不透明 ID，设 GRAPH_EXPECTED_ID 显式绑定）"
    fi
  else
    index_identity_match="unknown"
    p0 "index identity unavailable（响应无身份字段）——无法绑定图谱与本仓，fail-closed"
  fi
else
  INDEX_FRESH="n/a"
  warn "skip index check: graph service ${GRAPH_STATUS}"
fi

# =============================================================================
# SECTION 3: 本批关键文件同步检查
# =============================================================================
echo ""
echo "=== §3 本批关键文件同步检查 ==="

SYNCED_FILES=0
MISSING_FILES=0

# v3.20.3: 关键文件来源实义化——--git-range/GIT_RANGE 旧实现只解析从未使用（恒为
# 四个固定文档）。现在优先从真实 git 变更范围发现本批文件；git 不可用/空范围才
# 降级 legacy 四文档并 WARN。key_files_source 记入报告可审计。
GIT_RANGE="${GIT_RANGE:-5}"
KEY_FILES_SOURCE="legacy"
KEY_FILES=()
if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # 最近 N 个提交中新增/修改/重命名的文件（排除删除；去重；截断 50 防爆量）
  range_files=$(git log --diff-filter=ACMR --name-only --pretty=format: -"$GIT_RANGE" 2>/dev/null \
    | sed '/^$/d' | LC_ALL=C sort -u | head -50)
  if [ -n "$range_files" ]; then
    KEY_FILES_SOURCE="git-range"
    # v3.20.4: 过滤"范围内先增后删"的路径（ACMR 会经其 add 提交列出已删除文件）
    while IFS= read -r f; do
      [ -f "$f" ] && KEY_FILES+=("$f")
    done <<EOF
$range_files
EOF
  fi
fi
if [ "$KEY_FILES_SOURCE" = "legacy" ]; then
  warn "key files degraded to legacy fixed list（git 不可用或最近 ${GIT_RANGE} 个提交无变更）"
  KEY_FILES=(
    "docs/detailed-design/_commons.md"
    "docs/detailed-design/_权限矩阵.md"
    "docs/detailed-design/INDEX-表.md"
    "docs/detailed-design/INDEX-接口.md"
  )
fi

for f in ${KEY_FILES[@]+"${KEY_FILES[@]}"}; do
  if [ -f "$f" ]; then
    SYNCED_FILES=$((SYNCED_FILES + 1))
  else
    MISSING_FILES=$((MISSING_FILES + 1))
  fi
done

if [ "${#KEY_FILES[@]}" -eq 0 ]; then
  warn "no key files to check（空变更范围）"
elif [ "$MISSING_FILES" -eq 0 ]; then
  pass "all key files synced: $SYNCED_FILES/$SYNCED_FILES (source=$KEY_FILES_SOURCE)"
else
  p1 "missing key files: $MISSING_FILES/$((SYNCED_FILES + MISSING_FILES)) (source=$KEY_FILES_SOURCE)"
fi

# =============================================================================
# SECTION 4: Fallback 模式检查
# =============================================================================
echo ""
echo "=== §4 Fallback 模式检查 ==="

if [ "$GRAPH_STATUS" = "unreachable" ] || [ "$FORCE_FALLBACK" = "true" ]; then
  echo "Graph service unavailable, requiring source code fallback..."

  # 检查是否有源码回退证据
  FALLBACK_EVIDENCE=""

  # 检查是否有图谱同步失败的记录
  if [ -f "$REPORT_FILE" ]; then
    FALLBACK_EVIDENCE=$(grep "^source_fallback_evidence=" "$REPORT_FILE" 2>/dev/null | cut -d= -f2- | tr -d '\r' || true)
  fi

  if [ -n "$FALLBACK_EVIDENCE" ] && [ -e "$FALLBACK_EVIDENCE" ]; then
    # v3.15.1: fallback 证据实质化——必须记录 命令/范围/文件清单/发现/hash。
    # v3.20.3: hash 从"格式检查"升级为"重算对账"——FALLBACK_FILE_LIST 逐行
    # `<sha256>  <相对路径>`（shasum 格式），逐文件重算比对；FALLBACK_SHA256 必须
    # 等于清单文件自身的 SHA（清单被改即失配）。FINDINGS 允许 0（完成审查零发现
    # 合法），完整性由文件清单绑定保证而非"发现数>=1"的数字门槛。
    fb_ok=1
    for fb_key in FALLBACK_COMMAND FALLBACK_SCOPE FALLBACK_FILES FALLBACK_FINDINGS FALLBACK_SHA256 FALLBACK_FILE_LIST; do
      if ! grep -qE "^${fb_key}=.+" "$FALLBACK_EVIDENCE" 2>/dev/null; then
        p0 "fallback evidence missing ${fb_key}=<非空>（须记录命令/范围/文件清单/发现/hash/清单文件）: $FALLBACK_EVIDENCE"
        fb_ok=0
      fi
    done
    # 数值校验：FINDINGS 为整数（>=0 合法——零发现允许，见 v3.20.3）
    fb_findings=$(sed -n 's/^FALLBACK_FINDINGS=//p' "$FALLBACK_EVIDENCE" | head -1)
    if ! printf '%s' "${fb_findings:-}" | grep -qE '^[0-9]+$'; then
      p0 "fallback evidence FINDINGS must be a non-negative integer: ${fb_findings:-未声明}"
      fb_ok=0
    fi
    # 清单文件绑定：逐行 <sha> <path>，逐文件重算 SHA 对账；清单自身 SHA 与
    # FALLBACK_SHA256 对账（两处任意篡改均可检出）
    fb_list=$(sed -n 's/^FALLBACK_FILE_LIST=//p' "$FALLBACK_EVIDENCE" | head -1)
    fb_sha=$(sed -n 's/^FALLBACK_SHA256=//p' "$FALLBACK_EVIDENCE" | head -1)
    fb_files_count=$(sed -n 's/^FALLBACK_FILES=//p' "$FALLBACK_EVIDENCE" | head -1)
    if [ -n "$fb_list" ] && [ -f "$fb_list" ]; then
      # v3.20.8: grep -c 计数 0 时 exit 1，`|| echo 0` 会产出 "0\n0" 双值——
      # 先捕获再判空（第 4 轮复查 P3：integer expression expected stderr 噪声）
      list_lines=$(grep -cE '^[0-9a-f]{64}[[:space:]]+[^[:space:]].*$' "$fb_list" 2>/dev/null)
      [ -n "$list_lines" ] || list_lines=0
      junk_lines=$(grep -cvE '^[0-9a-f]{64}[[:space:]]+[^[:space:]].*$|^[[:space:]]*$' "$fb_list" 2>/dev/null)
      [ -n "$junk_lines" ] || junk_lines=0
      if [ "$junk_lines" -gt 0 ]; then
        p0 "fallback file list has $junk_lines malformed line(s)（每行须 <sha256>  <相对路径>）: $fb_list"
        fb_ok=0
      fi
      if printf '%s' "${fb_files_count:-}" | grep -qE '^[0-9]+$' && [ "$list_lines" -ne "$fb_files_count" ]; then
        p0 "fallback FALLBACK_FILES=$fb_files_count != 清单行数 $list_lines: $fb_list"
        fb_ok=0
      fi
      [ "$list_lines" -ge 1 ] || { p0 "fallback file list is empty: $fb_list"; fb_ok=0; }
      if [ "$list_lines" -ge 1 ]; then
        sha_mismatch=0; sha_missing=0
        while IFS= read -r line; do
          [ -n "$line" ] || continue
          want=$(printf '%s' "$line" | awk '{print $1}')
          rel=$(printf '%s' "$line" | awk '{print $2}')
          # v3.20.4: 清单路径必须是仓内相对路径——绝对路径与 .. 逃逸段拒绝
          case "$rel" in
            /*|*/../*|*/..|../*|..) echo "[P0] fallback listed path must be repo-relative (no absolute/..-segment): $rel" >&2; sha_missing=$((sha_missing + 1)); continue ;;
          esac
          if [ ! -f "$rel" ]; then
            echo "[P0] fallback listed file missing: $rel" >&2
            sha_missing=$((sha_missing + 1))
            continue
          fi
          if [ "$(sha256 "$rel")" != "$want" ]; then
            echo "[P0] fallback listed file sha mismatch: $rel" >&2
            sha_mismatch=$((sha_mismatch + 1))
          fi
        done < "$fb_list"
        [ "$sha_missing" -eq 0 ] || { p0 "fallback file list: $sha_missing file(s) missing on disk"; fb_ok=0; }
        [ "$sha_mismatch" -eq 0 ] || { p0 "fallback file list: $sha_mismatch file(s) SHA mismatch（清单与磁盘内容不一致）"; fb_ok=0; }
      fi
      actual_list_sha=$(sha256 "$fb_list")
      [ "$actual_list_sha" = "$fb_sha" ] || { p0 "fallback evidence SHA256 mismatch: 声明=${fb_sha} 清单重算=${actual_list_sha}（清单在登记后被改写）"; fb_ok=0; }
      if [ "$fb_ok" -eq 1 ]; then
        pass "fallback evidence substantive & verified (${list_lines} files sha-recomputed, findings=${fb_findings:-0}): $FALLBACK_EVIDENCE"
      fi
    elif [ -n "$fb_list" ]; then
      p0 "fallback evidence FALLBACK_FILE_LIST 不存在: $fb_list"
      fb_ok=0
    fi
  else
    p0 "no fallback evidence found"
    p0 "Graph unavailable without fallback proof - blocking"
  fi

  # 检查是否有本地缓存
  CACHE_DIR="${CACHE_DIR:-.devflow/cache}"
  if [ -d "$CACHE_DIR" ]; then
    CACHE_COUNT=$(find "$CACHE_DIR" -type f -mtime -7 2>/dev/null | wc -l)
    if [ "$CACHE_COUNT" -gt 0 ]; then
      pass "local cache available: $CACHE_COUNT files"
    else
      warn "local cache empty or stale"
    fi
  fi
fi

# =============================================================================
# SECTION 5: 生成报告
# =============================================================================
echo ""
echo "=== §5 生成报告 ==="

CHECKED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 写入报告文件
{
  echo "status=$GRAPH_STATUS"
  echo "checked_at=$CHECKED_AT"
  echo "scope=${FEATURE:-all}"
  echo "index_fresh=$INDEX_FRESH"
  echo "index_status=${index_status:-n/a}"
  if [ -n "${index_identity:-}" ]; then
    echo "index_identity=$index_identity"
  fi
  # v3.20.3: repo 绑定与关键文件来源入报告（可审计——报告记录的是谁的索引、查的哪些文件）
  echo "repo_realpath=$REPO_REALPATH"
  echo "git_head=${GIT_HEAD:-none}"
  echo "index_identity_match=${index_identity_match:-n/a}"
  echo "key_files_source=${KEY_FILES_SOURCE:-legacy}"
  echo "git_range=${GIT_RANGE:-5}"
  echo "graph_url=$GRAPH_URL"
  echo "synced_files=$SYNCED_FILES"
  echo "missing_files=$MISSING_FILES"
  if [ -n "$ERROR_MSG" ]; then
    echo "error=$ERROR_MSG"
  fi
  # v3.15.18: 回写证据指针（幂等）——报告重写不得丢失 source_fallback_evidence
  if [ -n "${PREV_FALLBACK_EVIDENCE:-}" ]; then
    echo "source_fallback_evidence=$PREV_FALLBACK_EVIDENCE"
  fi
} > "$REPORT_FILE"

pass "report written to: $REPORT_FILE"

# =============================================================================
# SECTION 6: 决策逻辑
# =============================================================================
echo ""
echo "=== §6 决策逻辑 ==="

DECISION="PASS"

case "$GRAPH_STATUS" in
  reachable)
    if [ "$INDEX_FRESH" = "true" ] && [ "$index_identity_match" = "true" ]; then
      DECISION="PASS"
      pass "graph health: PASS (service ready, index fresh, identity bound)"
    elif [ "$INDEX_FRESH" = "false" ]; then
      # v3.20.3: stale 阻断（原 WARN 假绿——放行过期索引）
      DECISION="FAIL"
      p0 "graph health: FAIL (service ready but index stale) — 同步索引后重跑"
    elif [ "$index_identity_match" != "true" ]; then
      # v3.20.3: 身份未绑定/不匹配阻断（§2 已 p0 记因，这里同步决策展示）
      DECISION="FAIL"
      p0 "graph health: FAIL (index identity not bound to this repo: match=${index_identity_match})"
    else
      DECISION="FAIL"
      p0 "graph health: FAIL (index status unknown) — 索引状态未知不得放行"
    fi
    ;;
  unreachable)
    if [ -n "$FALLBACK_EVIDENCE" ] && [ -e "$FALLBACK_EVIDENCE" ]; then
      DECISION="WARN"
      warn "graph health: WARN (service unreachable but fallback evidence provided)"
    elif [ "$MISSING_FILES" -eq 0 ]; then
      DECISION="WARN"
      warn "graph health: WARN (service unreachable but key files synced)"
      warn "recommend: sync graph when service is available"
    else
      DECISION="FAIL"
      p0 "graph health: FAIL (service unreachable, key files missing)"
      p1 "recommend: restore graph service before proceeding"
    fi
    ;;
  fallback)
    DECISION="WARN"
    warn "graph health: WARN (fallback mode)"
    ;;
esac

# =============================================================================
# FINAL: 输出汇总
# =============================================================================
echo ""
echo "========================================"
echo "GRAPH HEALTH RESULT: PASS=$PASS FAIL=$FAIL WARN=$WARN"
echo "========================================"
echo ""
echo "  Graph Status: $GRAPH_STATUS"
echo "  Index Fresh: $INDEX_FRESH"
echo "  Synced Files: $SYNCED_FILES"
echo "  Missing Files: $MISSING_FILES"
echo "  Checked At: $CHECKED_AT"
echo "  Decision: $DECISION"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "GRAPH HEALTH GATE: FAIL (blocking)"
  echo ""
  echo "阻塞原因:"
  echo "  - 图谱服务不可用且关键文件缺失"
  echo "  - 无法进行图谱健康检查"
  exit 1
fi

if [ "$DECISION" = "WARN" ]; then
  echo ""
  echo "GRAPH HEALTH GATE: WARN (non-blocking)"
  echo ""
  echo "警告:"
  echo "  - 图谱服务不可用或索引不新鲜"
  echo "  - 请尽快同步图谱"
  exit 0
fi

echo ""
echo "GRAPH HEALTH GATE: PASS"
exit 0
