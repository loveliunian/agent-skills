#!/usr/bin/env bash
# v3.21.1: P4 executable ledger, P6 state metadata, and non-empty runner capture.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(dirname "$TEST_DIR")"
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "[PASS] $*"; }
bad() { FAIL=$((FAIL + 1)); echo "[FAIL] $*"; }
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }
SKILL_VER=$(sed -n 's/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh")
TMP=$(mktemp -d "${TMPDIR:-/tmp}/devflow-v3209.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

mk_p4_workspace() { # $1=status
  local w="$TMP/p4-$1"
  mkdir -p "$w/docs/test" "$w/docs/requirements" "$w/scripts"
  printf '| M-01-F01-A01 | x |\n| M-01-F01-A02 | x |\n' > "$w/docs/requirements/fx-acceptance-criteria.md"
  printf 'raw validation evidence\n' > "$w/docs/test/fx-raw.log"
  cat > "$w/scripts/run-p4.sh" <<EOF
#!/usr/bin/env bash
printf 'ID\\tSTATUS\\nM-01-F01-A01\\tPASS\\nM-01-F01-A02\\t$1\\n' > docs/test/fx-p4-results.tsv
printf 'executed P4 validation\\n'
EOF
  chmod +x "$w/scripts/run-p4.sh"
  cat > "$w/docs/test/fx-validation-report.md" <<'EOF'
P0_BLOCKERS=0
VALIDATION_EVIDENCE=docs/test/fx-raw.log
P4_CMD=./scripts/run-p4.sh
P4_RESULTS_PATH=docs/test/fx-p4-results.tsv
EOF
  printf '%s\n' "$w"
}

WP4_FAIL=$(mk_p4_workspace FAIL)
P4_FAIL_OUT=$(cd "$WP4_FAIL" && bash "$ROOT/scripts/p4_validation_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$P4_FAIL_OUT" | grep -q 'P4_ACCEPTANCE_FAIL' && ! printf '%s' "$P4_FAIL_OUT" | grep -q 'rc=0$'; then
  ok "P4 rejects a generated FAIL acceptance row"
else
  bad "P4 accepts a generated FAIL acceptance row"
fi

WP4_PASS=$(mk_p4_workspace PASS)
P4_PASS_OUT=$(cd "$WP4_PASS" && bash "$ROOT/scripts/p4_validation_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$P4_PASS_OUT" | grep -q 'rc=0$' \
   && grep -q '^EVIDENCE_PATHS_JSON=' "$WP4_PASS/.devflow/fx/gates/P4/receipt.txt" \
   && grep -q '^EVIDENCE_TREE_SHA256=' "$WP4_PASS/.devflow/fx/gates/P4/receipt.txt"; then
  ok "P4 binds report, raw evidence, results, and execution capture as a tree"
else
  bad "P4 lacks tree-bound executable evidence"
fi

mk_p6_receipts() { # $1=workspace
  local w="$1" evidence paths tree
  mkdir -p "$w/.devflow/fx/gates/P6" "$w/.devflow/fx/gates/P6-credential" "$w/.devflow/fx/gates/P6-final" "$w/docs/fx/gates/P6" "$w/docs/fx/gates/P6-credential" "$w/docs/fx/gates/P6-final"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\nM-01-F01-A02\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'results\n' > "$w/.devflow/fx/first-pass-results.tsv"
  printf 'ENVIRONMENT=staging\n' > "$w/.devflow/fx/test-evidence.env"
  evidence='.devflow/fx/first-pass-baseline.tsv'
  paths=$(jq -cn --arg p "$evidence" '[$p]')
  tree=$(cd "$w" && hash_file "$evidence" | awk -v p="$evidence" '{print $1 "  " p}' | { if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi; })
  printf 'EXIT_CODE=0\nVERSION=p6@%s\nPHASE=P6\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$w/.devflow/fx/gates/P6/receipt.txt"
  printf 'EXIT_CODE=0\nVERSION=p6-credential@%s\nPHASE=P6-credential\nSKILL_TREE=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" > "$w/.devflow/fx/gates/P6-credential/receipt.txt"
  printf 'EXIT_CODE=0\nVERSION=p6-final@%s\nPHASE=P6-final\nSKILL_TREE=%s\nEVIDENCE_PATHS_JSON=%s\nEVIDENCE_TREE_SHA256=%s\nPASS=1 FAIL=0 WARN=0\n' "$SKILL_VER" "$TREE" "$paths" "$tree" > "$w/.devflow/fx/gates/P6-final/receipt.txt"
  for p in P6 P6-credential P6-final; do cp "$w/.devflow/fx/gates/$p/receipt.txt" "$w/docs/fx/gates/$p/receipt.txt"; done
}

WSTATE="$TMP/state"; mkdir -p "$WSTATE/.devflow"
printf '{"feature":"fx","scope":{"skill_tree_sha256":"%s"},"current_phase":"P6","phases":{"P6":{"status":"completed"}},"acceptance_criteria":{"count":0,"frozen":0,"complete":0},"first_pass_snapshot":{"path":null,"accuracy":null}}\n' "$TREE" > "$WSTATE/.devflow/fx.state.json"
mk_p6_receipts "$WSTATE"
STATE_BAD=$(cd "$WSTATE" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs 2>&1; echo "rc=$?")
if printf '%s' "$STATE_BAD" | grep -q 'STATE_P6_ACCEPTANCE' && ! printf '%s' "$STATE_BAD" | grep -q 'rc=0$'; then
  ok "receipt audit rejects completed P6 with empty acceptance state"
else
  bad "receipt audit accepts completed P6 with empty acceptance state"
fi

jq '.acceptance_criteria={"count":2,"frozen":2,"complete":2} | .first_pass_snapshot={"path":".devflow/fx/first-pass-results.tsv","accuracy":100,"created_at":"2026-09-15T00:00:00Z"}' "$WSTATE/.devflow/fx.state.json" > "$WSTATE/state.tmp" && mv "$WSTATE/state.tmp" "$WSTATE/.devflow/fx.state.json"
STATE_OK=$(cd "$WSTATE" && bash "$ROOT/scripts/audit-receipts.sh" fx .devflow docs 2>&1; echo "rc=$?")
if printf '%s' "$STATE_OK" | grep -q 'rc=0$'; then ok "receipt audit accepts coherent completed P6 state"; else bad "receipt audit rejects coherent completed P6 state"; fi

mk_final_workspace() { # $1=workspace
  local w="$1" k
  mkdir -p "$w/.devflow/fx/reports"
  printf '{"feature":"fx","scope":{"frontend":"pc-web"},"current_phase":"P6"}\n' > "$w/.devflow/fx.state.json"
  printf 'acceptance_id\tstatus\nM-01-F01-A01\tFROZEN\n' > "$w/.devflow/fx/first-pass-baseline.tsv"
  printf 'feature=fx\nacceptance_count=1\n' > "$w/.devflow/fx/first-pass-meta.env"
  printf 'ID\tSTATUS\nM-01-F01-A01\tPASS\n' > "$w/.devflow/fx/final-verification.tsv"
  cat > "$w/Makefile" <<'EOF'
test-report:
	@k=`echo $(KIND) | tr "A-Z" "a-z"`; printf '# %s report\ncases: 1\npassed: 1\n' "$$k" > .devflow/fx/reports/$$k.txt
EOF
  {
    for k in UNIT INTEGRATION CLIENT LOAD STAGING; do
      low=$(printf '%s' "$k" | tr 'A-Z' 'a-z')
      printf '%s_CMD=make test-report KIND=%s > .devflow/fx/reports/%s.txt 2>&1\n%s_EXIT=0\n%s_REPORT_PATH=.devflow/fx/reports/%s.txt\n' "$k" "$k" "$low" "$k" "$k" "$low"
    done
    printf 'ENVIRONMENT=staging\n'
  } > "$w/.devflow/fx/test-evidence.env"
  python3 - "$w" <<'PYEOF'
import json, pathlib, sys
w=pathlib.Path(sys.argv[1]); env={}
for line in (w/'.devflow/fx/test-evidence.env').read_text().splitlines():
    if '=' in line: k,v=line.split('=',1); env[k]=v
doc={'feature':'fx','environment':'staging','acceptance_results':[{'id':'M-01-F01-A01','status':'PASS'}], 'evidence':{}, 'client_not_applicable':{'declared':False,'frontend_scope':'pc-web'}, 'zero_results':[]}
for k in ('unit','integration','client','load','staging'):
    K=k.upper(); doc['evidence'][k]={'cmd':env[K+'_CMD'],'exit_code':0,'report_path':env[K+'_REPORT_PATH']}
json.dump(doc, open(w/'.devflow/fx/verification.json','w'))
PYEOF
}

WEMPTY="$TMP/empty-capture"; mk_final_workspace "$WEMPTY"
EMPTY_OUT=$(cd "$WEMPTY" && bash "$ROOT/scripts/s6_final_verification_gate.sh" fx 2>&1; echo "rc=$?")
if printf '%s' "$EMPTY_OUT" | grep -q 'P6_EXECUTION_LOG_EMPTY' && ! printf '%s' "$EMPTY_OUT" | grep -q 'rc=0$'; then
  ok "P6 final rejects commands that empty the Gate capture"
else
  bad "P6 final accepts commands that empty the Gate capture"
fi

echo "=== v3.21.1 evidence gate result PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
