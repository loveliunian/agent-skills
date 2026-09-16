#!/usr/bin/env bash
# =============================================================================
# tech_constraints_lib.sh · 技术硬约束机器契约共享库
# =============================================================================
# 契约格式（技术约束文件内，唯一机读事实源；Gate 只信机器字段，不从自然语言推断）：
#
#   <!-- DEVFLOW:CONSTRAINTS
#   constraint_id=TC-TECH-001
#   type=MUST_USE
#   subject=workflow-engine
#   required_product=camunda
#   required_version=7.24.0
#   status=FROZEN
#   confirmed=true
#
#   constraint_id=TC-TECH-002
#   type=MUST_NOT_USE
#   subject=workflow-engine
#   required_product=FlowCore
#   status=FROZEN
#   confirmed=true
#   DEVFLOW:END -->
#
# 无硬约束时必须写：constraint_set=NONE + confirmed=true（不得省略块）。
#
# 选型报告绑定块（P1 产出）：
#   <!-- DEVFLOW:CONSTRAINT-BINDINGS
#   constraint_id=TC-TECH-001
#   selected_product=camunda
#   selected_version=7.24.0
#   compliance=PASS
#   evidence=backend/pom.xml
#   DEVFLOW:END -->
# =============================================================================
set -uo pipefail
LC_ALL=C
export LC_ALL

# 提取机器契约块正文。$1=文件 $2=块开始标记（DEVFLOW:CONSTRAINTS / DEVFLOW:CONSTRAINT-BINDINGS）
tc_extract_block() {
  local file="$1" marker="$2"
  [ -f "$file" ] || return 1
  awk -v m="$marker" '
    $0 ~ m {inblk=1; next}
    inblk && /DEVFLOW:END/ {inblk=0; exit}
    inblk {print}
  ' "$file"
}

# 解析块正文为记录（空行分隔），每条记录输出一行 TSV：k1=v1<TAB>k2=v2...
tc_parse_records() {
  # stdin: block body; stdout: one TSV line per record
  awk '
    /^[[:space:]]*$/ {if (rec != "") {print rec; rec=""; n=0} next}
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      if (n > 0) rec = rec "\t"
      rec = rec $0; n++
      next
    }
    END {if (rec != "") print rec}
  '
}

# 读取记录中的字段值。$1=记录行 $2=字段名
tc_field() {
  local rec="$1" key="$2" pair
  local oldifs="$IFS"; IFS=$'\t'
  for pair in $rec; do
    IFS="$oldifs"
    case "$pair" in
      "$key="*) printf '%s' "${pair#*=}"; return 0 ;;
    esac
  done
  IFS="$oldifs"
  return 1
}

# 校验技术约束文件并输出约束记录 TSV：
#   constraint_id \t type \t subject \t required_product \t required_version \t status \t confirmed
# 块缺失 → stderr 报错，exit 1。
tc_load_constraints() {
  local file="$1"
  local block
  block=$(tc_extract_block "$file" "DEVFLOW:CONSTRAINTS") || { echo "[TC-LIB] constraints block missing: $file" >&2; return 1; }
  [ -n "$block" ] || { echo "[TC-LIB] constraints block empty: $file" >&2; return 1; }
  printf '%s\n' "$block" | tc_parse_records
}

# 校验选型报告绑定块并输出绑定记录 TSV：
#   constraint_id \t selected_product \t selected_version \t compliance \t evidence
tc_load_bindings() {
  local file="$1"
  local block
  block=$(tc_extract_block "$file" "DEVFLOW:CONSTRAINT-BINDINGS") || { echo "[TC-LIB] constraint-bindings block missing: $file" >&2; return 1; }
  [ -n "$block" ] || { echo "[TC-LIB] constraint-bindings block empty: $file" >&2; return 1; }
  printf '%s\n' "$block" | tc_parse_records
}

# 结构校验：每条记录必须字段完备、status=FROZEN、confirmed=true。
# 输出违规原因行（供 gate 计数）；合法记录同时输出到 stdout 的 TSV（同 tc_load_constraints）。
# 用法：tc_validate_constraints <file>   —— 违规行写到 stderr 前缀 [TC-INVALID]，合法记录走 stdout。
tc_validate_constraints() {
  local file="$1" rec cid ctype csub cprod cver cstatus cconf bad=0
  local tmp; tmp=$(mktemp -t tc-validate.XXXXXX)
  if ! tc_load_constraints "$file" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  while IFS=$'\t' read -r rec; do
    [ -n "$rec" ] || continue
    cid=$(tc_field "$rec" constraint_id || true)
    ctype=$(tc_field "$rec" type || true)
    csub=$(tc_field "$rec" subject || true)
    cprod=$(tc_field "$rec" required_product || true)
    cver=$(tc_field "$rec" required_version || true)
    cstatus=$(tc_field "$rec" status || true)
    cconf=$(tc_field "$rec" confirmed || true)
    if [ "$ctype" = "NONE" ] || [ -n "$(tc_field "$rec" constraint_set || true)" ]; then
      [ "$cconf" = "true" ] || { echo "[TC-INVALID] constraint_set=NONE requires confirmed=true" >&2; bad=$((bad+1)); }
      continue
    fi
    [ -n "$cid" ] || { echo "[TC-INVALID] record missing constraint_id" >&2; bad=$((bad+1)); continue; }
    printf '%s' "$cid" | grep -qE '^TC-[A-Z0-9]+-[0-9]{3}$' || { echo "[TC-INVALID] ${cid:-?}: constraint_id must match TC-XXX-000" >&2; bad=$((bad+1)); }
    case "$ctype" in
      MUST_USE|MUST_NOT_USE) ;;
      *) echo "[TC-INVALID] $cid: type must be MUST_USE|MUST_NOT_USE (got '${ctype:-empty}')" >&2; bad=$((bad+1)); continue ;;
    esac
    [ -n "$cprod" ] || { echo "[TC-INVALID] $cid: required_product required" >&2; bad=$((bad+1)); }
    [ "$cstatus" = "FROZEN" ] || { echo "[TC-INVALID] $cid: status must be FROZEN to bind (got '${cstatus:-empty}'); DRAFT constraints block the pipeline" >&2; bad=$((bad+1)); }
    [ "$cconf" = "true" ] || { echo "[TC-INVALID] $cid: confirmed must be true (got '${cconf:-empty}')" >&2; bad=$((bad+1)); }
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$cid" "$ctype" "${csub:-}" "$cprod" "${cver:-}" "${cstatus:-}" "${cconf:-}"
  done < "$tmp"
  rm -f "$tmp"
  [ "$bad" -gt 0 ] && return 1
  return 0
}

# 选型↔约束合规对账。$1=约束文件 $2=绑定文件。
# 输出违规行（stdout）；exit 1 = 有违规或结构缺失。
tc_check_compliance() {
  local cfile="$1" bfile="$2"
  local cons bind rec cid ctype csub cprod cver bprod bver bcomp violations=0
  cons=$(mktemp -t tc-cons.XXXXXX); bind=$(mktemp -t tc-bind.XXXXXX)
  tc_validate_constraints "$cfile" > "$cons" 2>/dev/null || { echo "constraints structurally invalid: $cfile"; rm -f "$cons" "$bind"; return 1; }
  tc_load_bindings "$bfile" > "$bind" 2>/dev/null || { echo "constraint-bindings block missing in: $bfile"; rm -f "$cons" "$bind"; return 1; }
  while IFS=$'\t' read -r cid ctype csub cprod cver _cs _cc; do
    [ -n "$cid" ] || continue
    rec=$(BIND_CID="$cid" awk -F'\t' '{
      for (i = 1; i <= NF; i++) {
        if (index($i, "constraint_id=") == 1) {
          split($i, a, "=")
          if (a[2] == ENVIRON["BIND_CID"]) { print; exit }
        }
      }
    }' "$bind")
    if [ -z "$rec" ]; then
      echo "hard constraint ${cid} has no P1 binding"
      violations=$((violations+1))
      continue
    fi
    bprod=$(tc_field "$rec" selected_product || true)
    bver=$(tc_field "$rec" selected_version || true)
    bcomp=$(tc_field "$rec" compliance || true)
    printf '%s' "$bcomp" | grep -qiE '^(PASS|COMPLIANT)$' || { echo "hard constraint ${cid} binding compliance must be PASS (got '${bcomp:-empty}')"; violations=$((violations+1)); }
    if [ "$ctype" = "MUST_USE" ]; then
      printf '%s' "$bprod" | grep -qiF "$cprod" || { echo "MUST_USE ${cid} requires '${cprod}', selected '${bprod:-empty}'"; violations=$((violations+1)); }
      if [ -n "$cver" ] && [ -n "$bver" ]; then
        [ "$bver" = "$cver" ] || { echo "MUST_USE ${cid} requires version '${cver}', selected '${bver}'"; violations=$((violations+1)); }
      fi
    elif [ "$ctype" = "MUST_NOT_USE" ]; then
      if printf '%s' "$bprod" | grep -qiF "$cprod"; then
        echo "MUST_NOT_USE ${cid} forbids '${cprod}', selected '${bprod}'"
        violations=$((violations+1))
      fi
    fi
  done < "$cons"
  rm -f "$cons" "$bind"
  [ "$violations" -eq 0 ]
}

# 依赖对账：选型必须落到 Maven 依赖/配置。$1=约束文件 $2=搜索根（backend 或 backend/<service>）
# MUST_USE：required_product 必须出现在 pom.xml（依赖坐标）或 resources 配置中
# MUST_NOT_USE：required_product 禁止出现在任何 pom.xml / resources 配置中
tc_check_dependencies() {
  local cfile="$1" root="$2" violations=0
  [ -d "$root" ] || { echo "dependency check root missing: $root"; return 1; }
  local cons; cons=$(mktemp -t tc-deps.XXXXXX)
  tc_validate_constraints "$cfile" > "$cons" 2> /dev/null || { echo "constraints structurally invalid: $cfile"; rm -f "$cons"; return 1; }
  local cid ctype cprod _csub _cver _cs _cc found
  while IFS=$'\t' read -r cid ctype _csub cprod _cver _cs _cc; do
    [ -n "$cid" ] || continue
    case "$ctype" in
      MUST_USE)
        found=0
        if grep -rqiF "$cprod" "$root" --include='pom.xml' 2>/dev/null; then found=1; fi
        if [ "$found" -eq 0 ] && grep -rqiF "$cprod" "$root/src/main/resources" 2>/dev/null; then found=1; fi
        [ "$found" -eq 1 ] || { echo "MUST_USE ${cid}: '${cprod}' not found in pom.xml or config under $root"; violations=$((violations+1)); }
        ;;
      MUST_NOT_USE)
        if grep -rqiF "$cprod" "$root" --include='pom.xml' 2>/dev/null; then
          echo "MUST_NOT_USE ${cid}: forbidden '${cprod}' found in pom.xml under $root"
          violations=$((violations+1))
        fi
        if grep -rqiF "$cprod" "$root/src/main/resources" 2>/dev/null; then
          echo "MUST_NOT_USE ${cid}: forbidden '${cprod}' found in config under $root/src/main/resources"
          violations=$((violations+1))
        fi
        ;;
    esac
  done < "$cons"
  rm -f "$cons"
  [ "$violations" -eq 0 ]
}

# 文件 SHA256
tc_sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# 供 CLI 冒烟：bash tech_constraints_lib.sh <cmd> ...
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    extract)  shift; tc_extract_block "$@" ;;
    load)     shift; tc_load_constraints "$@" ;;
    validate) shift; tc_validate_constraints "$@" ;;
    bindings) shift; tc_load_bindings "$@" ;;
    compliance) shift; tc_check_compliance "$@" ;;
    deps)     shift; tc_check_dependencies "$@" ;;
    sha)      shift; tc_sha256 "$@" ;;
    *) echo "Usage: tech_constraints_lib.sh {extract|load|validate|bindings|compliance|deps|sha} <args>" >&2; exit 2 ;;
  esac
fi
