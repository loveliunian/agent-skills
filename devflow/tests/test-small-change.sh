#!/usr/bin/env bash
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== devflow small-change tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
hash_file() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

expect_file "commands/small-change.md"
expect_file "commands/field-change.md"
expect_file "templates/小需求变更-模板.md"
expect_file "references/small-change-classification.md"
expect_file "scripts/small-change-gate.sh"
expect_file "scripts/field-change-gate.sh"
expect_contains "concepts/natural-language-triggers.md" '小需求|小改动|修复|改.*字段' "natural language routes small changes"
expect_contains "commands/ROUTING.md" '/small-change' "small-change command is routed"
expect_contains "README.md" 'small-change' "README exposes the small-change fast path"

W="$TMP/workspace"
mkdir -p "$W/.devflow/order-filter" "$W/docs/changes" "$W/frontend/src/views"
printf 'const filter = "status"\n' > "$W/frontend/src/views/order-list.vue"
printf 'subject=order-list-filter\nreferences=frontend/src/views/order-list.vue\nscan_command=rg order-list-filter\nSCAN_DB=MISS\nSCAN_DOMAIN=MISS\nSCAN_API=MISS\nSCAN_CLIENT=HIT\nSCAN_CONFIG=MISS\nSCAN_TEST=HIT\nSCAN_PERMISSION=MISS\nSCAN_WORKFLOW=MISS\nSCAN_CROSS_SERVICE=MISS\nSCAN_HISTORY_DATA=NA\n' > "$W/.devflow/order-filter/project-scan.txt"
printf '# small change\nsubject: order-list-filter\nacceptance: filter is applied\n' > "$W/docs/changes/order-filter-small-change.md"
cat > "$W/.devflow/order-filter/small-change.env" <<'EOF'
CHANGE_KIND=ui-behavior
CHANGE_SUBJECT=order-list-filter
LOGICAL_CHANGE_COUNT=1
TARGET=merge-ready
SURFACES=ui
PROJECT_SCAN_EVIDENCE=.devflow/order-filter/project-scan.txt
CHANGE_REPORT=docs/changes/order-filter-small-change.md
AFFECTED_PATHS=frontend/src/views/order-list.vue
BREAKING_API=0
TYPE_OR_NULLABILITY_BREAKING=0
PERMISSION_CHANGE=0
STATE_MACHINE_CHANGE=0
CROSS_SERVICE_CHANGE=0
NEW_TABLE_OR_SERVICE=0
LARGE_BACKFILL=0
MIGRATION_REQUIRED=0
DIALECTS=
VERIFY_CMD=awk 'BEGIN { print "focused small-change tests passed" }'
MIGRATION_VERIFY_CMD=
DEPLOY_RECEIPT_PATH=
MONITOR_RECEIPT_PATH=
DECISION=MICRO
DECISION_REASON=single existing page behavior adjustment
EOF

MICRO=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter 2>&1; echo "rc=$?")
if printf '%s' "$MICRO" | grep -q 'DECISION=MICRO' && printf '%s' "$MICRO" | grep -q 'rc=0$'; then ok "UI behavior is MICRO"; else bad "UI behavior is MICRO"; fi
VERIFY=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter 2>&1; echo "rc=$?")
if printf '%s' "$VERIFY" | grep -q 'STATUS=MERGE_READY' && printf '%s' "$VERIFY" | grep -q 'rc=0$'; then ok "MICRO verification writes MERGE_READY receipt"; else bad "MICRO verification writes MERGE_READY receipt"; fi
ALIAS=$(cd "$W" && bash "$ROOT/scripts/field-change-gate.sh" classify order-filter 2>&1; echo "rc=$?")
if printf '%s' "$ALIAS" | grep -q 'DECISION=MICRO' && printf '%s' "$ALIAS" | grep -q 'rc=0$'; then ok "field-change compatibility alias delegates"; else bad "field-change compatibility alias delegates"; fi

cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/config.env"
sed -i '' -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=config/' -e 's/SURFACES=ui/SURFACES=config/' -e 's/SCAN_CONFIG=MISS/SCAN_CONFIG=HIT/' -e 's/SCAN_CLIENT=HIT/SCAN_CLIENT=MISS/' "$W/.devflow/order-filter/config.env" 2>/dev/null || sed -i -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=config/' -e 's/SURFACES=ui/SURFACES=config/' -e 's/SCAN_CONFIG=MISS/SCAN_CONFIG=HIT/' -e 's/SCAN_CLIENT=HIT/SCAN_CLIENT=MISS/' "$W/.devflow/order-filter/config.env"
CONFIG=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter .devflow/order-filter/config.env 2>&1; echo "rc=$?")
if printf '%s' "$CONFIG" | grep -q 'DECISION=MICRO' && printf '%s' "$CONFIG" | grep -q 'rc=0$'; then ok "configuration tweak is MICRO"; else bad "configuration tweak is MICRO"; fi

cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/bugfix.env"
sed -i '' 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=bugfix/' "$W/.devflow/order-filter/bugfix.env" 2>/dev/null || sed -i 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=bugfix/' "$W/.devflow/order-filter/bugfix.env"
BUGFIX=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter .devflow/order-filter/bugfix.env 2>&1; echo "rc=$?")
if printf '%s' "$BUGFIX" | grep -q 'DECISION=MICRO' && printf '%s' "$BUGFIX" | grep -q 'rc=0$'; then ok "bounded existing bugfix is MICRO"; else bad "bounded existing bugfix is MICRO"; fi

printf 'record OrderFilter(String status) {}\n' > "$W/frontend/src/views/order-filter-api.txt"
cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/api.env"
cp "$W/.devflow/order-filter/project-scan.txt" "$W/.devflow/order-filter/api-scan.txt"
sed -i '' -e 's/SCAN_API=MISS/SCAN_API=HIT/' -e 's/SCAN_CLIENT=HIT/SCAN_CLIENT=MISS/' "$W/.devflow/order-filter/api-scan.txt" 2>/dev/null || sed -i -e 's/SCAN_API=MISS/SCAN_API=HIT/' -e 's/SCAN_CLIENT=HIT/SCAN_CLIENT=MISS/' "$W/.devflow/order-filter/api-scan.txt"
sed -i '' -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=additive-api/' -e 's/SURFACES=ui/SURFACES=api/' -e 's|PROJECT_SCAN_EVIDENCE=.*|PROJECT_SCAN_EVIDENCE=.devflow/order-filter/api-scan.txt|' -e 's|AFFECTED_PATHS=.*|AFFECTED_PATHS=frontend/src/views/order-filter-api.txt|' "$W/.devflow/order-filter/api.env" 2>/dev/null || sed -i -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=additive-api/' -e 's/SURFACES=ui/SURFACES=api/' -e 's|PROJECT_SCAN_EVIDENCE=.*|PROJECT_SCAN_EVIDENCE=.devflow/order-filter/api-scan.txt|' -e 's|AFFECTED_PATHS=.*|AFFECTED_PATHS=frontend/src/views/order-filter-api.txt|' "$W/.devflow/order-filter/api.env"
API=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter .devflow/order-filter/api.env 2>&1; echo "rc=$?")
if printf '%s' "$API" | grep -q 'DECISION=MICRO' && printf '%s' "$API" | grep -q 'rc=0$'; then ok "additive API change is MICRO"; else bad "additive API change is MICRO"; fi

cp "$W/.devflow/order-filter/project-scan.txt" "$W/.devflow/order-filter/permission-scan.txt"
sed -i '' 's/SCAN_PERMISSION=MISS/SCAN_PERMISSION=HIT/' "$W/.devflow/order-filter/permission-scan.txt" 2>/dev/null || sed -i 's/SCAN_PERMISSION=MISS/SCAN_PERMISSION=HIT/' "$W/.devflow/order-filter/permission-scan.txt"
cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/permission.env"
sed -i '' -e 's|PROJECT_SCAN_EVIDENCE=.*|PROJECT_SCAN_EVIDENCE=.devflow/order-filter/permission-scan.txt|' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/permission.env" 2>/dev/null || sed -i -e 's|PROJECT_SCAN_EVIDENCE=.*|PROJECT_SCAN_EVIDENCE=.devflow/order-filter/permission-scan.txt|' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/permission.env"
PERM=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter .devflow/order-filter/permission.env 2>&1; echo "rc=$?")
if printf '%s' "$PERM" | grep -q 'DECISION=FULL' && printf '%s' "$PERM" | grep -q 'rc=0$'; then ok "permission hit escalates FULL"; else bad "permission hit escalates FULL"; fi

cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/multi.env"
sed -i '' -e 's/LOGICAL_CHANGE_COUNT=1/LOGICAL_CHANGE_COUNT=2/' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/multi.env" 2>/dev/null || sed -i -e 's/LOGICAL_CHANGE_COUNT=1/LOGICAL_CHANGE_COUNT=2/' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/multi.env"
MULTI=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" classify order-filter .devflow/order-filter/multi.env 2>&1; echo "rc=$?")
if printf '%s' "$MULTI" | grep -q 'DECISION=FULL' && printf '%s' "$MULTI" | grep -q 'rc=0$'; then ok "multiple bounded changes escalate FULL"; else bad "multiple bounded changes escalate FULL"; fi

cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/breaking.env"
sed -i '' -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=breaking-api/' -e 's/BREAKING_API=0/BREAKING_API=1/' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/breaking.env" 2>/dev/null || sed -i -e 's/CHANGE_KIND=ui-behavior/CHANGE_KIND=breaking-api/' -e 's/BREAKING_API=0/BREAKING_API=1/' -e 's/DECISION=MICRO/DECISION=FULL/' "$W/.devflow/order-filter/breaking.env"
BREAKING=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter .devflow/order-filter/breaking.env 2>&1; echo "rc=$?")
if printf '%s' "$BREAKING" | grep -q 'ESCALATE_TO_FULL' && ! printf '%s' "$BREAKING" | grep -q 'rc=0$'; then ok "breaking requirement cannot verify as MICRO"; else bad "breaking requirement cannot verify as MICRO"; fi

for dialect in h2 postgresql oracle kingbase; do
  mkdir -p "$W/backend/svc/src/main/resources/db/migration/$dialect"
  printf 'ALTER TABLE demo ADD filter_hint VARCHAR(255);\n' > "$W/backend/svc/src/main/resources/db/migration/$dialect/V2__add_filter_hint.sql"
done
cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/persistence.env"
{
  sed '/^CHANGE_KIND=/d; /^SURFACES=/d; /^MIGRATION_REQUIRED=/d; /^DIALECTS=/d; /^AFFECTED_PATHS=/d; /^MIGRATION_VERIFY_CMD=/d' "$W/.devflow/order-filter/persistence.env"
  printf 'CHANGE_KIND=additive-persistence\nSURFACES=persistence\nMIGRATION_REQUIRED=1\nDIALECTS=h2,postgresql,oracle,kingbase\n'
  printf 'AFFECTED_PATHS=backend/svc/src/main/resources/db/migration/h2/V2__add_filter_hint.sql,backend/svc/src/main/resources/db/migration/postgresql/V2__add_filter_hint.sql,backend/svc/src/main/resources/db/migration/oracle/V2__add_filter_hint.sql,backend/svc/src/main/resources/db/migration/kingbase/V2__add_filter_hint.sql\n'
  printf 'MIGRATION_VERIFY_CMD=awk '\''BEGIN { print "four dialect migrations verified" }'\''\n'
} > "$W/.devflow/order-filter/persistence.tmp" && mv "$W/.devflow/order-filter/persistence.tmp" "$W/.devflow/order-filter/persistence.env"
PERSIST=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter .devflow/order-filter/persistence.env 2>&1; echo "rc=$?")
if printf '%s' "$PERSIST" | grep -q 'STATUS=MERGE_READY' && printf '%s' "$PERSIST" | grep -q 'rc=0$'; then ok "additive persistence change verifies four dialect files"; else bad "additive persistence change verifies four dialect files"; fi

mkdir -p "$W/.devflow/order-filter/deploy" "$W/.devflow/order-filter/monitor"
printf 'deployment evidence\n' > "$W/.devflow/order-filter/deploy/evidence.txt"
printf 'EXIT_CODE=0\nPHASE=P7\nEVIDENCE_PATH=.devflow/order-filter/deploy/evidence.txt\nEVIDENCE_SHA256=%s\n' "$(hash_file "$W/.devflow/order-filter/deploy/evidence.txt")" > "$W/.devflow/order-filter/deploy/receipt.txt"
printf 'monitor evidence\n' > "$W/.devflow/order-filter/monitor/evidence.txt"
printf 'EXIT_CODE=0\nPHASE=P8\nEVIDENCE_PATH=.devflow/order-filter/monitor/evidence.txt\nEVIDENCE_SHA256=%s\n' "$(hash_file "$W/.devflow/order-filter/monitor/evidence.txt")" > "$W/.devflow/order-filter/monitor/receipt.txt"
cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/released.env"
printf 'TARGET=released\nDEPLOY_RECEIPT_PATH=.devflow/order-filter/deploy/receipt.txt\nMONITOR_RECEIPT_PATH=.devflow/order-filter/monitor/receipt.txt\n' >> "$W/.devflow/order-filter/released.env"
sed -i '' '/^TARGET=merge-ready$/d; /^DEPLOY_RECEIPT_PATH=$/d; /^MONITOR_RECEIPT_PATH=$/d' "$W/.devflow/order-filter/released.env" 2>/dev/null || sed -i '/^TARGET=merge-ready$/d; /^DEPLOY_RECEIPT_PATH=$/d; /^MONITOR_RECEIPT_PATH=$/d' "$W/.devflow/order-filter/released.env"
RELEASED=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter .devflow/order-filter/released.env 2>&1; echo "rc=$?")
if printf '%s' "$RELEASED" | grep -q 'STATUS=RELEASED' && printf '%s' "$RELEASED" | grep -q 'rc=0$'; then ok "RELEASED binds P7 and P8 receipts"; else bad "RELEASED binds P7 and P8 receipts"; fi

cp "$W/.devflow/order-filter/small-change.env" "$W/.devflow/order-filter/mutate.env"
sed -i '' "s|^VERIFY_CMD=.*|VERIFY_CMD=awk 'BEGIN { print \"mutated\" }' > frontend/src/views/order-list.vue|" "$W/.devflow/order-filter/mutate.env" 2>/dev/null || sed -i "s|^VERIFY_CMD=.*|VERIFY_CMD=awk 'BEGIN { print \"mutated\" }' > frontend/src/views/order-list.vue|" "$W/.devflow/order-filter/mutate.env"
MUTATE=$(cd "$W" && bash "$ROOT/scripts/small-change-gate.sh" verify order-filter .devflow/order-filter/mutate.env 2>&1; echo "rc=$?")
if printf '%s' "$MUTATE" | grep -q 'affected implementation files' && ! printf '%s' "$MUTATE" | grep -q 'rc=0$'; then ok "verification cannot mutate implementation"; else bad "verification cannot mutate implementation"; fi

finish SMALL_CHANGE
