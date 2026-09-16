#!/usr/bin/env bash
# =============================================================================
# P4 首轮快照 Gate
# =============================================================================
# 功能：
#   1. 记录验收点清单快照
#   2. 记录详设版本
#   3. 检查 100% 原子验收点进入详设
#   4. 后续修复不回写首轮统计
# =============================================================================
set -uo pipefail


# ---------- 全局计数 ----------
FAIL=0; PASS=0; WARN=0

p0() { echo "[P0] $1"; FAIL=$((FAIL + 1)); }
p1() { echo "[P1] $1"; }
pass() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
warn() { echo "[WARN] $1"; WARN=$((WARN + 1)); }

# ---------- 参数解析 ----------
CMD="${1:-}"
FEATURE="${2:-}"
ARG3="${3:-}"
ARG4="${4:-}"
STATE_ROOT="${STATE_DIR:-.devflow}"

# v3.15.5: feature 白名单共享校验（devflow_feature.sh；为空时由后续 state/产物读取失败兜底）
if [ -n "$FEATURE" ]; then
  source "$(cd "$(dirname "$0")" && pwd)/devflow_feature.sh"
  devflow_feature_validate "$FEATURE" || exit 2
fi

usage() {
  cat <<EOF
Usage: $0 <command> [args...]

P4 首轮快照 Gate 命令

命令：
  freeze <feature> <criteria.md> <design.md>
    - 冻结验收点清单和详设版本

  check <feature>
    - 检查首轮快照是否有效

  verify <feature> [--force]

  record <feature> <test-report> <review-report>
    - 记录首轮测试和 Review 结果，计算准确率
    - 验证快照与当前详设一致（100% 覆盖）
    - <test-report> 为 per-ID TSV（列：acceptance_id<TAB>status）
      status ∈ {PASS,FAIL,SKIP}；每行一个验收点 ID

示例：
  $0 freeze m-03 docs/requirements/M-03-acceptance-criteria.md docs/detailed-design/M-03-design.md
  $0 check m-03
  $0 verify m-03
  $0 record m-03 docs/test/m-03-test-report.md docs/review/m-03-review-report.md
EOF
  # v3.15.8: 原 exit 0——无参/未知命令调用被上层当 gate PASS（fail-open）
  exit 2
}

[ -z "$CMD" ] && usage

# ---------- 哈希函数 ----------
hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

hash_stream() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    sha256sum | awk '{print $1}'
  fi
}

DIR="$STATE_ROOT/$FEATURE"

# =============================================================================
# COMMAND: freeze - 冻结首轮快照
# =============================================================================
freeze() {
  local criteria="$ARG3"
  local design="$ARG4"

  echo ""
  echo "=== §freeze 冻结首轮快照 ==="

  [ -n "$criteria" ] || { p0 "criteria.md not specified"; exit 1; }
  [ -n "$design" ] || { p0 "design.md not specified"; exit 1; }
  [ -f "$criteria" ] || { p0 "criteria missing: $criteria"; exit 1; }
  [ -f "$design" ] || { p0 "design missing: $design"; exit 1; }

  mkdir -p "$DIR"

  # 检查是否已冻结
  if [ -e "$DIR/first-pass-baseline.tsv" ]; then
    p0 "first-pass baseline already frozen at $DIR/first-pass-baseline.tsv"
    p1 "use 'verify' command to check current state"
    exit 1
  fi

  # 提取验收点 ID
  ids=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$criteria" 2>/dev/null | sort -u)
  id_count=$(printf '%s\n' "$ids" | grep -c . || true)

  [ "$id_count" -gt 0 ] || { p0 "no acceptance IDs found in $criteria"; exit 1; }

  # 创建基准文件
  {
    printf '%s\n' "acceptance_id	status"
    printf '%s\n' "$ids" | awk '{print $1 "	FROZEN"}'
  } > "$DIR/first-pass-baseline.tsv"

  # 创建元数据文件
  git_sha=$(git rev-parse HEAD 2>/dev/null || echo "UNCOMMITTED")

  {
    echo "feature=$FEATURE"
    echo "git_sha=$git_sha"
    echo "design_path=$design"
    echo "criteria_path=$criteria"
    echo "design_sha256=$(hash_file "$design")"
    echo "criteria_sha256=$(hash_file "$criteria")"
    echo "worktree_diff_sha256=$(git diff --binary 2>/dev/null | hash_stream)"
    echo "frozen_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "acceptance_count=$id_count"
    echo "frozen_acceptance_count=$id_count"
  } > "$DIR/first-pass-meta.env"

  pass "first-pass baseline frozen at $DIR"
  echo "  acceptance points: $id_count"
  echo "  design: $(basename "$design")"
  echo "  criteria: $(basename "$criteria")"
  echo "  git_sha: $git_sha"

  echo ""
  echo "P4 FREEZE: PASS"
}

# =============================================================================
# COMMAND: check - 检查快照有效性
# =============================================================================
check() {
  echo ""
  echo "=== §check 检查首轮快照 ==="

  [ -d "$DIR" ] || { p0 "snapshot directory missing: $DIR"; exit 1; }

  local base="$DIR/first-pass-baseline.tsv"
  local meta="$DIR/first-pass-meta.env"

  [ -f "$base" ] || { p0 "baseline missing: $base"; exit 1; }
  [ -f "$meta" ] || { p0 "meta missing: $meta"; exit 1; }

  # 读取元数据
  value() { sed -n "s/^$1=//p" "$meta" | tail -1; }

  local design_path design_sha criteria_path criteria_sha frozen_at acceptance_count
  design_path=$(value design_path)
  design_sha=$(value design_sha256)
  criteria_path=$(value criteria_path)
  criteria_sha=$(value criteria_sha256)
  frozen_at=$(value frozen_at)
  acceptance_count=$(value acceptance_count)

  echo "  Feature: $FEATURE"
  echo "  Frozen at: $frozen_at"
  echo "  Acceptance points: $acceptance_count"
  echo "  Design: $design_path"
  echo "  Criteria: $criteria_path"

  # 检查快照文件
  baseline_count=$(tail -n +2 "$base" | grep -c . || true)
  if [ "$baseline_count" -eq "$acceptance_count" ]; then
    pass "baseline count matches: $baseline_count"
  else
    p0 "baseline count mismatch: $baseline_count != $acceptance_count"
  fi

  pass "first-pass snapshot valid"

  echo ""
  echo "P4 CHECK: PASS"
}

# =============================================================================
# COMMAND: verify - 验证快照与当前详设一致
# =============================================================================
verify() {
  local force=false
  [ "$ARG3" = "--force" ] && force=true

  echo ""
  echo "=== §verify 验证快照与当前详设一致 ==="

  [ -d "$DIR" ] || { p0 "snapshot directory missing: $DIR"; exit 1; }

  local base="$DIR/first-pass-baseline.tsv"
  local meta="$DIR/first-pass-meta.env"
  local results="$DIR/first-pass-results.tsv"

  [ -f "$base" ] || { p0 "baseline missing: $base"; exit 1; }
  [ -f "$meta" ] || { p0 "meta missing: $meta"; exit 1; }

  # 读取元数据
  value() { sed -n "s/^$1=//p" "$meta" | tail -1; }

  local design_path design_sha criteria_path criteria_sha
  design_path=$(value design_path)
  design_sha=$(value design_sha256)
  criteria_path=$(value criteria_path)
  criteria_sha=$(value criteria_sha256)

  # 验证文件哈希（防止篡改）
  echo ""
  echo "=== §verify 文件完整性检查 ==="

  if [ -f "$design_path" ]; then
    local current_design_sha
    current_design_sha=$(hash_file "$design_path")
    if [ "$current_design_sha" = "$design_sha" ]; then
      pass "design file unchanged: $design_path"
    else
      if [ "$force" = "true" ]; then
        warn "design file changed (--force specified)"
        echo "  original sha: $design_sha"
        echo "  current sha:  $current_design_sha"
      else
        p0 "design file changed: $design_path"
        echo "  original sha: $design_sha"
        echo "  current sha:  $current_design_sha"
        p1 "use --force to override (not recommended)"
      fi
    fi
  else
    p0 "design file not found: $design_path"
  fi

  if [ -f "$criteria_path" ]; then
    local current_criteria_sha
    current_criteria_sha=$(hash_file "$criteria_path")
    if [ "$current_criteria_sha" = "$criteria_sha" ]; then
      pass "criteria file unchanged: $criteria_path"
    else
      if [ "$force" = "true" ]; then
        warn "criteria file changed (--force specified)"
      else
        p0 "criteria file changed: $criteria_path"
      fi
    fi
  else
    p0 "criteria file not found: $criteria_path"
  fi

  # 验证验收点覆盖
  echo ""
  echo "=== §verify 验收点覆盖检查 ==="

  if [ -f "$design_path" ]; then
    local baseline_ids current_ids missing_ids
    baseline_ids=$(tail -n +2 "$base" | cut -f1 | sort)
    current_ids=$(grep -oE 'M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}' "$design_path" 2>/dev/null | sort -u)

    baseline_count=$(printf '%s\n' "$baseline_ids" | grep -c . || true)
    current_count=$(printf '%s\n' "$current_ids" | grep -c . || true)

    echo "  Baseline IDs: $baseline_count"
    echo "  Current IDs in design: $current_count"

    # 检查所有基准 ID 是否在当前详设中
    missing_ids=""
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      if ! printf '%s\n' "$current_ids" | grep -qF "$id"; then
        missing_ids="$missing_ids $id"
      fi
    done <<< "$baseline_ids"

    if [ -z "$missing_ids" ]; then
      pass "100% acceptance points in design ($baseline_count/$baseline_count)"
    else
      # 统计缺失数量
      missing_count=$(printf '%s\n' "$missing_ids" | grep -c . || true)
      if [ "$missing_count" -gt 0 ]; then
        p0 "$missing_count acceptance points missing from design:$missing_ids"
      fi
    fi
  fi

  # 检查 results 文件是否已锁定
  echo ""
  echo "=== §verify 结果锁定检查 ==="

  if [ -f "$results" ]; then
    # results 文件应该已锁定（不可变）
    if [ -w "$results" ]; then
      p1 "WARNING: results file is writable (should be immutable)"
    else
      pass "results file is immutable"
    fi
  else
    pass "no results recorded yet (expected)"
  fi
}

# =============================================================================
# COMMAND DISPATCH

# =============================================================================
# COMMAND: record - 记录首轮测试和 Review 结果
# =============================================================================
record() {
  local test_report="$ARG3"
  local review_report="$ARG4"

  echo ""
  echo "=== §record 记录首轮测试和 Review 结果 ==="

  [ -n "$test_report" ] || { p0 "test_report not specified"; exit 1; }
  [ -n "$review_report" ] || { p0 "review_report not specified"; exit 1; }

  mkdir -p "$DIR"

  echo "Test report: $test_report"
  echo "Review report: $review_report"

  # 解析测试结果
  local test_pass=0 test_fail=0 test_skip=0
  if [ -f "$test_report" ]; then
    test_pass=$(grep -c "PASS" "$test_report" 2>/dev/null) || test_pass=0
    test_fail=$(grep -c "FAIL" "$test_report" 2>/dev/null) || test_fail=0
    test_skip=$(grep -c "SKIP" "$test_report" 2>/dev/null) || test_skip=0
    pass "parsed test results: pass=$test_pass fail=$test_fail skip=$test_skip"
  else
    warn "test report not found: $test_report"
  fi

  # 解析 Review 结果并落盘 per-ID 明细（v3.14.1：此前 Review 只统计不落盘，P6 断链）
  local review_pass=0 review_fail=0
  local review_tsv="$DIR/first-pass-review.tsv"
  if [ -f "$review_report" ]; then
    printf 'acceptance_id\tstatus\n' > "$review_tsv"
    # 从评审报告中抽取带 PASS/FAIL 结论的验收点行（格式：... M-xx-Fyy-Azz ... PASS|FAIL ...）
    # v3.15.8: 旧 grep+sed 管道在 BSD 工具链完全失效——①POSIX 括号表达式中反斜杠是字面字符，
    # [^\n] 实为"非反斜杠且非字母 n"（ID 与结论间含 n 的行全部漏匹配）；②BSD sed 不支持 \b
    # （s 命令不命中、原行原样通过）。实测 markdown 评审报告输入时 pass=0 fail=0 全丢、
    # accuracy 失真。改单 awk（match/RSTART 是 POSIX 标准，GNU/BSD 通用），
    # PASS/FAIL 独立词判定用 [^A-Za-z] 边界（不依赖 \b）。
    awk '
      match($0, /M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}/) {
        id = substr($0, RSTART, RLENGTH)
        if ($0 ~ /(^|[^A-Za-z])PASS([^A-Za-z]|$)/) print id "\tPASS"
        else if ($0 ~ /(^|[^A-Za-z])FAIL([^A-Za-z]|$)/) print id "\tFAIL"
      }' "$review_report" 2>/dev/null >> "$review_tsv" || true
    review_pass=$(awk -F'\t' 'NR>1 && $2=="PASS"{n++} END{print n+0}' "$review_tsv")
    review_fail=$(awk -F'\t' 'NR>1 && $2=="FAIL"{n++} END{print n+0}' "$review_tsv")
    pass "parsed & saved review results: pass=$review_pass fail=$review_fail → $(basename "$review_tsv")"
  else
    warn "review report not found: ${review_report}（P6 的 review 校验将缺证据）"
  fi

  # 计算准确率
  local total=$((test_pass + test_fail + review_pass + review_fail))
  local passed=$((test_pass + review_pass))
  local accuracy=0
  if [ "$total" -gt 0 ]; then
    accuracy=$((passed * 100 / total))
  fi

  # 保存结果
  # v3.9.6 修复：results.tsv 改为 per-ID 明细格式（与 baseline/s6_first_pass_accuracy.sh
  # 的读取约定对齐——此前 record 写统计汇总格式，s6 读 per-ID，P4→P6 格式断裂导致
  # "result IDs differ / invalid status / accuracy 0%" 永远 FAIL）。统计移入 stats.env。
  local results="$DIR/first-pass-results.tsv"
  if [ -f "$test_report" ]; then
    # v3.14.11-fix(jmmp2): 输入与输出为同一文件时 cat file > file 会先截断源文件导致结果被清空——
    # 用 -ef（同 inode）判断跳过自拷贝（jmmp2 项目实证：record 传 results 自身路径曾清空首轮结果）
    if ! [ "$test_report" -ef "$results" ]; then
      cat "$test_report" > "$results"
    fi
  else
    printf 'acceptance_id\tstatus\n' > "$results"
  fi
  {
    printf 'feature\t%s\n' "$FEATURE"
    printf 'test_pass\t%s\n' "$test_pass"
    printf 'test_fail\t%s\n' "$test_fail"
    printf 'test_skip\t%s\n' "$test_skip"
    printf 'review_pass\t%s\n' "$review_pass"
    printf 'review_fail\t%s\n' "$review_fail"
    printf 'total\t%s\n' "$total"
    printf 'passed\t%s\n' "$passed"
    printf 'accuracy\t%s%%\n' "${accuracy}"
    printf 'timestamp\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$DIR/first-pass-stats.env"

  pass "first-pass results recorded: $results"
  echo "  accuracy=$accuracy% (passed=$passed, total=$total)"

  # v3.9.6 修复：record 此前不写 results_sha256，导致 s6_first_pass_accuracy.sh
  # 的防篡改校验永远报 "results file has been modified"（P4→P6 交接数据断裂）
  local results_sha
  results_sha=$(hash_file "$results")
  grep -v '^results_sha256=' "$DIR/first-pass-meta.env" > "$DIR/first-pass-meta.env.tmp" 2>/dev/null && \
    mv "$DIR/first-pass-meta.env.tmp" "$DIR/first-pass-meta.env"
  echo "results_sha256=$results_sha" >> "$DIR/first-pass-meta.env"
  echo "results_recorded_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$DIR/first-pass-meta.env"
  pass "meta updated: results_sha256 written (P6 tamper-check input)"

  echo ""
  echo "P4 RECORD: PASS"
}
# =============================================================================
case "$CMD" in
  freeze) freeze ;;
  check) check ;;
  verify) verify ;;
  record) record ;;
  # v3.15.8: 原字面 echo "[P0]" 不走 p0()（FAIL 计数不增）且 usage 内 exit 0 → 未知命令 fail-open
  *) p0 "unknown command: $CMD"; exit 2 ;;
esac

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "P4 GATE: FAIL (blocking)"
  exit 1
fi
