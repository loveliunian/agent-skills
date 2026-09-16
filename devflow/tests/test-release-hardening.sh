#!/usr/bin/env bash
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
source "$TEST_DIR/testlib.sh"

echo "=== v3.16.24 regression tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

hash_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# P3b must accept the shipped template after the template is populated with
# the required identity fields and acceptance mapping. Narrative headings are
# not findings; only structured FINDING rows are findings.
W_P3B="$TMP/p3b"
mkdir -p "$W_P3B/docs/review" "$W_P3B/docs/detailed-design" "$W_P3B/docs/requirements" "$W_P3B/backend/svc/src/main/java"
cp "$ROOT/templates/代码审查报告-模板.md" "$W_P3B/docs/review/fx-code-review-report.md"
sed -i '' -e 's/DEVELOPER_ID=<developer-id>/DEVELOPER_ID=alice/' -e 's/REVIEWER_ID=<reviewer-id>/REVIEWER_ID=bob/' -e 's/REVIEW_SESSION_ID=<independent-session-id>/REVIEW_SESSION_ID=s1/' "$W_P3B/docs/review/fx-code-review-report.md" 2>/dev/null ||
  sed -i -e 's/DEVELOPER_ID=<developer-id>/DEVELOPER_ID=alice/' -e 's/REVIEWER_ID=<reviewer-id>/REVIEWER_ID=bob/' -e 's/REVIEW_SESSION_ID=<independent-session-id>/REVIEW_SESSION_ID=s1/' "$W_P3B/docs/review/fx-code-review-report.md"
printf '\nFINDING|P0|P0-1|STATUS=CLOSED|legacy issue fixed\nM-01-F01-A01 mapped\n' >> "$W_P3B/docs/review/fx-code-review-report.md"
printf '# design\nM-01-F01-A01\n' > "$W_P3B/docs/detailed-design/fx-design.md"
printf '# criteria\nM-01-F01-A01\n' > "$W_P3B/docs/requirements/fx-acceptance-criteria.md"
printf 'class Svc {}\n' > "$W_P3B/backend/svc/src/main/java/Svc.java"
P3B_OUT=$(cd "$W_P3B" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$P3B_OUT" | grep -q 'rc=0$'; then
  ok "P3b accepts populated official template and ignores narrative P0 headings"
else
  bad "P3b rejects populated official template or counts narrative P0 headings"
fi

cp "$W_P3B/docs/review/fx-code-review-report.md" "$W_P3B/docs/review/fx-code-review-report-bad.md"
sed -i '' 's/FINDING|P0|P0-1|STATUS=CLOSED|legacy issue fixed/FINDING|P0|bad|STATUS=CLOSED|bad format/' "$W_P3B/docs/review/fx-code-review-report-bad.md" 2>/dev/null ||
  sed -i 's/FINDING|P0|P0-1|STATUS=CLOSED|legacy issue fixed/FINDING|P0|bad|STATUS=CLOSED|bad format/' "$W_P3B/docs/review/fx-code-review-report-bad.md"
cp "$W_P3B/docs/review/fx-code-review-report-bad.md" "$W_P3B/docs/review/fx-code-review-report.md"
P3B_BAD=$(cd "$W_P3B" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$P3B_BAD" | grep -q 'structured finding format invalid' && ! printf '%s' "$P3B_BAD" | grep -q 'rc=0$'; then
  ok "P3b rejects malformed P0 finding IDs"
else
  bad "P3b accepts malformed P0 finding IDs"
fi
sed -i '' 's/FINDING|P0|bad|STATUS=CLOSED|bad format/FINDING|P0|P0-1|STATUS=CLOSED|legacy issue fixed/' "$W_P3B/docs/review/fx-code-review-report.md" 2>/dev/null ||
  sed -i 's/FINDING|P0|bad|STATUS=CLOSED|bad format/FINDING|P0|P0-1|STATUS=CLOSED|legacy issue fixed/' "$W_P3B/docs/review/fx-code-review-report.md"
printf 'FINDING|P0|P0-1|STATUS=CLOSED|duplicate\n' >> "$W_P3B/docs/review/fx-code-review-report.md"
P3B_DUP=$(cd "$W_P3B" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$P3B_DUP" | grep -q 'duplicate P0 finding IDs' && ! printf '%s' "$P3B_DUP" | grep -q 'rc=0$'; then
  ok "P3b rejects duplicate P0 finding IDs"
else
  bad "P3b accepts duplicate P0 finding IDs"
fi
sed -i '' '$d' "$W_P3B/docs/review/fx-code-review-report.md" 2>/dev/null || sed -i '$d' "$W_P3B/docs/review/fx-code-review-report.md"
printf 'FINDING|P0| P0-1 |STATUS=CLOSED|whitespace duplicate\n' >> "$W_P3B/docs/review/fx-code-review-report.md"
P3B_WS=$(cd "$W_P3B" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$P3B_WS" | grep -q 'duplicate P0 finding IDs' && ! printf '%s' "$P3B_WS" | grep -q 'rc=0$'; then
  ok "P3b rejects whitespace-variant duplicate P0 IDs"
else
  bad "P3b accepts whitespace-variant duplicate P0 IDs"
fi
sed -i '' '$d' "$W_P3B/docs/review/fx-code-review-report.md" 2>/dev/null || sed -i '$d' "$W_P3B/docs/review/fx-code-review-report.md"
printf 'finding|p0|P0-1|STATUS=CLOSED|case variant\n' >> "$W_P3B/docs/review/fx-code-review-report.md"
P3B_CASE=$(cd "$W_P3B" && bash "$ROOT/scripts/p3b_code_review_gate.sh" fx svc 2>&1; echo "rc=$?")
if printf '%s' "$P3B_CASE" | grep -q 'structured finding format invalid' && ! printf '%s' "$P3B_CASE" | grep -q 'rc=0$'; then
  ok "P3b rejects case-variant structured finding rows"
else
  bad "P3b accepts case-variant structured finding rows"
fi

# P6 must reject a report that existed before the gate and is only read by a
# grep command; this is the stale/prebuilt evidence false-green regression.
W_P6="$TMP/p6"
mkdir -p "$W_P6/.devflow/fx/reports"
printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\n' > "$W_P6/.devflow/fx/first-pass-baseline.tsv"
printf 'feature=fx\n' > "$W_P6/.devflow/fx/first-pass-meta.env"
printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > "$W_P6/.devflow/fx/final-verification.tsv"
for kind in unit integration client load staging; do
  printf '# %s test report\nsuite=%s\npassed=1\nfailed=0\n' "$kind" "$kind" > "$W_P6/.devflow/fx/reports/${kind}-report.txt"
done
{
  for kind in UNIT INTEGRATION CLIENT LOAD STAGING; do
    lower=$(printf '%s' "$kind" | tr '[:upper:]' '[:lower:]')
    report=".devflow/fx/reports/${lower}-report.txt"
    printf '%s_CMD=grep -q "^# %s test report$" %s\n' "$kind" "$lower" "$report"
    printf '%s_EXIT=0\n%s_REPORT_PATH=%s\n%s_REPORT_SHA256=%s\n' "$kind" "$kind" "$report" "$kind" "$(hash_file "$W_P6/$report")"
  done
  printf 'ENVIRONMENT=staging\n'
} > "$W_P6/.devflow/fx/test-evidence.env"
P6_OUT=$(cd "$W_P6" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if ! printf '%s' "$P6_OUT" | grep -q 'rc=0$'; then
  ok "P6 rejects pre-existing reports checked by read-only commands"
else
  bad "P6 accepts pre-existing reports checked by read-only commands"
fi

W_P6_MUT="$TMP/p6-mutated"
cp -R "$W_P6" "$W_P6_MUT"
sed -i '' "s|^UNIT_CMD=.*|UNIT_CMD=python3 -c \"open('.devflow/fx/test-evidence.env','a').write('# touched by unit');open('.devflow/fx/reports/unit-report.txt','a').write('live')\"|" "$W_P6_MUT/.devflow/fx/test-evidence.env" 2>/dev/null ||
  sed -i "s|^UNIT_CMD=.*|UNIT_CMD=python3 -c \"open('.devflow/fx/test-evidence.env','a').write('# touched by unit');open('.devflow/fx/reports/unit-report.txt','a').write('live')\"|" "$W_P6_MUT/.devflow/fx/test-evidence.env"
P6_MUT_OUT=$(cd "$W_P6_MUT" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$P6_MUT_OUT" | grep -q '篡改 test-evidence.env' && ! printf '%s' "$P6_MUT_OUT" | grep -q 'rc=0$'; then
  ok "P6 detects a test command mutating later test declarations"
else
  bad "P6 allows a test command to mutate later test declarations"
fi

# Declared tool capabilities must cover the operations each command/subagent
# explicitly requires.
if grep -qF 'allowed-tools: [read, write, exec, glob, grep, task]' "$ROOT/SKILL.md"; then
  ok "main skill declares execution capability"
else
  bad "main skill declares execution capability"
fi
if grep -qE '^  - write$' "$ROOT/commands/review.md" &&
   grep -qE '^  - exec$' "$ROOT/commands/review.md" &&
   grep -qE '^  - task$' "$ROOT/commands/review.md" &&
   grep -qE '^  - write$' "$ROOT/subagents/code-reviewer.md" &&
   grep -qE '^  - task$' "$ROOT/subagents/code-reviewer.md"; then
  ok "review command and coordinator declare required capabilities"
else
  bad "review command and coordinator declare required capabilities"
fi

# Release Audit must validate allowed-tools as a list, not merely accept YAML
# that silently turns it into null or folds list items into another scalar.
W_AUDIT="$TMP/audit"
cp -R "$ROOT" "$W_AUDIT"
printf '%s\n' '---' 'name: malformed-tools-fixture' 'version: "3.16.24"' 'allowed-tools:' 'paths: []' 'disable-model-invocation: false' '  - read' '---' > "$W_AUDIT/subagents/malformed-tools-fixture.md"
printf '%s\n' '---' 'name: unknown-tools-fixture' 'version: "3.16.24"' 'allowed-tools: [read, exce]' 'paths: []' '---' > "$W_AUDIT/subagents/unknown-tools-fixture.md"
AUDIT_OUT=$(DEVFLOW_AUDIT_ROOT="$W_AUDIT" bash "$ROOT/scripts/release-audit.sh" 2>&1; echo "rc=$?")
if printf '%s' "$AUDIT_OUT" | grep -q 'allowed-tools' && ! printf '%s' "$AUDIT_OUT" | grep -q 'rc=0$'; then
  ok "release audit rejects malformed allowed-tools semantics"
else
  bad "release audit accepts malformed allowed-tools semantics"
fi

# Every command/subagent must declare a non-empty allow-list using only the
# tool names understood by this skill; release-audit performs this in its
# Python or POSIX fallback, so this test remains runnable without PyYAML.
CURRENT_AUDIT=$(bash "$ROOT/scripts/release-audit.sh" 2>&1; echo "rc=$?")
if printf '%s' "$CURRENT_AUDIT" | grep -q 'RELEASE AUDIT: PASS' && printf '%s' "$CURRENT_AUDIT" | grep -q 'allowed-tools semantics ok'; then
  ok "all command and subagent allowed-tools are explicit and known"
else
  bad "command or subagent allowed-tools missing, duplicated, or unknown"
fi

if grep -q 'FROZEN_TEST_EV' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'TEST_EV_INITIAL_SHA' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 freezes test-evidence input before running commands"
else
  bad "P6 rereads mutable test-evidence input during command execution"
fi

if grep -q 'P0_FORMAT_BAD' "$ROOT/scripts/p3b_code_review_gate.sh" &&
   grep -q 'P0_DUP_IDS' "$ROOT/scripts/p3b_code_review_gate.sh"; then
  ok "P3b validates P0 finding format and duplicate IDs"
else
  bad "P3b accepts malformed or duplicate structured P0 findings"
fi

if grep -q 'tolower(\$1)' "$ROOT/scripts/p3b_code_review_gate.sh" &&
   grep -q 'shasum.*sha256sum' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P3b rejects case-variant finding rows and P6 requires a hash tool"
else
  bad "P3b case handling or P6 hash-tool fail-closed guard is missing"
fi

if grep -q 'FINAL_TSV_INITIAL_SHA' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'BASELINE_TSV_INITIAL_SHA' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 freezes final verification and baseline inputs"
else
  bad "P6 allows test commands to mutate final verification or baseline inputs"
fi
if grep -q 'trap cleanup_p6_temp EXIT' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 cleans frozen input on every exit path"
else
  bad "P6 may leak frozen input on early failure"
fi
if grep -q '报告路径与内部终验证据冲突' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 rejects report paths colliding with internal evidence"
else
  bad "P6 allows a report path to alias its own execution evidence"
fi
if grep -q '_REPORTS_RESOLVED' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'uniq -d' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 checks canonical report-path uniqueness"
else
  bad "P6 compares report paths textually instead of canonically"
fi
if grep -q 'EXECUTABLE_PATH' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'EXECUTABLE_SHA256_BEFORE' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'EXECUTABLE_SHA256_AFTER' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'P6_EXECUTABLE_REQUIRED' "$ROOT/scripts/s6_final_verification_gate.sh"; then
  ok "P6 records executed binary provenance"
else
  bad "P6 execution records omit binary provenance"
fi
if grep -q 'TEST_EVIDENCE_SHA256_AFTER=.*EXEC_TMP_RECORD' "$ROOT/scripts/s6_final_verification_gate.sh" &&
   grep -q 'gsub(/\[\[:space:\]\]/, "", id)' "$ROOT/scripts/p3b_code_review_gate.sh"; then
  ok "P6 preserves per-test input hashes and P3b normalizes finding IDs"
else
  bad "per-test input hashes or normalized finding IDs are not preserved"
fi

if grep -qE '^  - task$' "$ROOT/subagents/test-engineer.md" &&
   grep -qE '^  - write$' "$ROOT/subagents/completeness-auditor.md"; then
  ok "delegating and report-producing subagents declare required capabilities"
else
  bad "delegating or report-producing subagent capabilities are incomplete"
fi

finish V31615_FIXES
