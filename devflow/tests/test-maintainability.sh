#!/usr/bin/env bash
set -u
set -o pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PASS=0
FAIL=0

ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }

echo "=== devflow maintainability tests ==="

CURRENT_VER=$(sed -n 's/^  version: "\(.*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
[ -n "$CURRENT_VER" ] && ok "release version matches SKILL.md ($CURRENT_VER)" || bad "release version missing"

README_LINES=$(wc -l < "$ROOT/README.md" | tr -d ' ')
ORCHESTRATOR_LINES=$(wc -l < "$ROOT/commands/devflow.md" | tr -d ' ')
# v3.23.1: 增加「30 秒上手」（含安装指引）后上限由 80 放宽到 100，仍保持索引页定位。
[ "$README_LINES" -le 100 ] && ok "README is a concise index" || bad "README is a concise index (lines=$README_LINES)"
[ "$ORCHESTRATOR_LINES" -le 350 ] && ok "orchestrator is progressively disclosed" || bad "orchestrator is progressively disclosed (lines=$ORCHESTRATOR_LINES)"
grep -q "devflow v${CURRENT_VER}" "$ROOT/README.md" && ok "README uses current version" || bad "README uses current version"

FLOW=$(awk '/^## 整体流程图$/{capture=1; next} capture && /^## /{exit} capture{print}' "$ROOT/README.md")
printf '%s\n' "$FLOW" | grep -q '^```mermaid$' && ok "README keeps a Mermaid overview flowchart" || bad "README keeps a Mermaid overview flowchart"
if printf '%s\n' "$FLOW" | grep -q 'P0' && printf '%s\n' "$FLOW" | grep -q 'P10'; then
  ok "overview covers the P0-P10 delivery chain"
else
  bad "overview covers the P0-P10 delivery chain"
fi
if printf '%s\n' "$FLOW" | grep -q 'PC Web' && printf '%s\n' "$FLOW" | grep -q '微信小程序' && printf '%s\n' "$FLOW" | grep -q 'APP' && printf '%s\n' "$FLOW" | grep -q 'not-applicable'; then
  ok "overview covers all frontend scopes"
else
  bad "overview covers all frontend scopes"
fi
if printf '%s\n' "$FLOW" | grep -q 'Gate FAIL' && printf '%s\n' "$FLOW" | grep -q 'checkpoint' && printf '%s\n' "$FLOW" | grep -q '重跑当前 Gate'; then
  ok "overview shows the failure and recovery loop"
else
  bad "overview shows the failure and recovery loop"
fi
printf '%s\n' "$FLOW" | grep -q -- '--design-only' && ok "overview shows the design-only exit" || bad "overview shows the design-only exit"

grep -q 'artifact_gate\.sh P0b' "$ROOT/commands/ROUTING.md" && ok "P0b artifact gate is routed" || bad "P0b artifact gate is routed"
grep -q 'artifact_gate\.sh P7' "$ROOT/commands/ROUTING.md" && ok "P7 artifact gate is routed" || bad "P7 artifact gate is routed"
grep -q 'artifact_gate\.sh P8' "$ROOT/commands/ROUTING.md" && ok "P8 artifact gate is routed" || bad "P8 artifact gate is routed"
grep -q 'artifact_gate\.sh P9' "$ROOT/commands/ROUTING.md" && ok "P9 artifact gate is routed" || bad "P9 artifact gate is routed"
grep -q 'p10_feedback_gate\.sh' "$ROOT/commands/ROUTING.md" && ok "P10 feedback gate is routed" || bad "P10 feedback gate is routed"
grep -q '5 角色' "$ROOT/commands/ROUTING.md" && ok "P2a five-role review is documented" || bad "P2a five-role review is documented"

for file in test-contracts.sh test-state.sh test-client-platforms.sh test-phase-gates.sh test-release.sh; do
  [ -f "$ROOT/tests/$file" ] && ok "split test exists: $file" || bad "split test exists: $file"
done

if grep -RIE 'backend/(governance-service|org-service)' "$ROOT/commands" "$ROOT/concepts" "$ROOT/scripts" "$ROOT/templates" --include='*.md' --include='*.sh' >/dev/null 2>&1; then
  bad "active guidance has no project-specific backend path"
else
  ok "active guidance has no project-specific backend path"
fi

if grep -RIE 'find .*(^|[[:space:]])-path([[:space:]]|$)' "$ROOT/scripts" "$ROOT/hooks" --include='*.sh' >/dev/null 2>&1; then
  bad "shell scripts avoid find -path"
else
  ok "shell scripts avoid find -path"
fi

# v3.16.22: 符号链接安装钉——macOS BSD find 不跟随起始符号链接，ROOT 必须解析物理路径。
# 回归场景：经 symlink 目录调用 gate-skill-tree.sh 必须产出 64 位十六进制树哈希（v3.16.21 曾空树 FATAL）。
LINKTMP=$(mktemp -d)
trap 'rm -rf "$TMP" "$LINKTMP"' EXIT
ln -s "$ROOT" "$LINKTMP/devflow"
_LINK_HASH=$(bash "$LINKTMP/devflow/scripts/gate-skill-tree.sh" 2>/dev/null; echo "rc=$?")
if printf '%s' "$_LINK_HASH" | grep -qE '^[0-9a-f]{64}$' && printf '%s' "$_LINK_HASH" | grep -q 'rc=0$'; then
  ok "gate-skill-tree enumerates through symlinked install (pwd -P)"
else
  bad "gate-skill-tree enumerates through symlinked install (got: $_LINK_HASH)"
fi

# v3.16.22: 残缺引用块钉——历史编辑事故曾留下 `> （清单 #N）。` / `> 。` / `> ⚠️ ：` 孤行。
if grep -rnE '^> （清单 #[0-9]+。）|^> 。$|^> ⚠️ ：$|^> ：' "$ROOT/commands" "$ROOT/concepts" "$ROOT/references" --include='*.md' >/dev/null 2>&1; then
  bad "no orphan blockquote fragments in active docs"
else
  ok "no orphan blockquote fragments in active docs"
fi

grep -q '^| 项 | 内容 |$' "$ROOT/templates/验收点-模板.md" && ok "acceptance template table is valid" || bad "acceptance template table is valid"
grep -qF 'templates/验收点-模板.md' "$ROOT/references/RESOURCE-REGISTRY.md" && ok "acceptance template is explicitly registered" || bad "acceptance template is explicitly registered"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp -R "$ROOT" "$TMP/skill"; rm -rf "$TMP/skill/tests/logs" "$TMP/skill/.git" "$TMP/skill/.backups" "$TMP/skill/_archive" "$TMP/skill/scripts/__pycache__"
printf '\n[broken fixture](missing-local-file.md)\n' >> "$TMP/skill/README.md"
printf '{broken json\n' > "$TMP/skill/templates/bad.json"
printf '\n|| malformed | table |\n' >> "$TMP/skill/templates/验收点-模板.md"
printf '\n```bash\n' >> "$TMP/skill/commands/performance.md"
cat > "$TMP/skill/subagents/unregistered-fixture.md" <<EOF
---
name: unregistered-fixture
version: "${CURRENT_VER}"
description: fixture
---
EOF
# v3.15.1: 损坏的 frontmatter（缩进冲突——allowed-tools/paths 冲突）必须被审计拦截
cat > "$TMP/skill/subagents/broken-frontmatter-fixture.md" <<EOF
---
name: broken-frontmatter-fixture
version: "${CURRENT_VER}"
description: fixture with broken yaml
allowed-tools:
paths: []
  - read
  - exec
---
EOF

if DEVFLOW_AUDIT_ROOT="$TMP/skill" bash "$ROOT/scripts/release-audit.sh" > "$TMP/audit.out" 2>&1; then
  bad "release audit rejects malformed release fixtures"
else
  grep -q 'invalid JSON: templates/bad.json' "$TMP/audit.out" && ok "release audit checks every JSON file" || bad "release audit checks every JSON file"
  grep -q 'broken local link: README.md -> missing-local-file.md' "$TMP/audit.out" && ok "release audit checks local Markdown links" || bad "release audit checks local Markdown links"
  grep -q 'malformed Markdown table: templates/验收点-模板.md' "$TMP/audit.out" && ok "release audit checks malformed tables" || bad "release audit checks malformed tables"
  grep -q 'unbalanced Markdown fences: commands/performance.md' "$TMP/audit.out" && ok "release audit checks unbalanced fences" || bad "release audit checks unbalanced fences"
  grep -q 'unregistered resource: subagents/unregistered-fixture.md' "$TMP/audit.out" && ok "release audit checks resource registration" || bad "release audit checks resource registration"
  grep -q 'invalid frontmatter YAML structure: subagents/broken-frontmatter-fixture.md' "$TMP/audit.out" && ok "release audit validates frontmatter YAML structure" || bad "release audit validates frontmatter YAML structure"
fi

# ---------- 产物路径单一来源（review P0-2e：以 devflow_paths.sh 为正本的 contract 测试） ----------
# 复盘正本：docs/复盘/<f>-复盘报告.md（p10_feedback_gate.sh:18 同源）
grep -q 'docs/复盘/<feature>-复盘报告.md' "$ROOT/commands/retro.md" \
  && ! grep -q '<feature>-复盘\.md' "$ROOT/commands/audit-completeness.md" \
  && ok "复盘产物路径单一（复盘报告.md）" || bad "复盘产物路径漂移（复盘.md vs 复盘报告.md）"
# 事故复盘正本：生成规则与 Gate 检查同带日期前缀
PM_DATED=$(grep -c 'YYYY-MM-DD>-<\(slug\|incident\)>-事故复盘' "$ROOT/commands/postmortem.md" 2>/dev/null || grep -c '\[YYYY-MM-DD\]-\[slug\]-事故复盘' "$ROOT/commands/postmortem.md")
[ "${PM_DATED:-0}" -ge 2 ] && ok "postmortem 生成/检查文件名一致（带日期）" || bad "postmortem 文件名规则不一致（生成 vs Gate）"
# 测试报告正本：docs/测试报告/（p6_credential_gate.sh 同源）
grep -q 'docs/测试报告/<feature>-测试报告.md' "$ROOT/commands/audit-completeness.md" \
  && ok "测试报告路径单一（docs/测试报告）" || bad "测试报告路径漂移"
# 性能正本：审计报告 docs/评审/、压测报告 docs/测试/（由 performance.json 渲染）
grep -q 'docs/评审/<feature>-性能审计报告.md' "$ROOT/commands/performance.md" \
  && grep -q 'docs/评审/<feature>-性能审计报告.md' "$ROOT/commands/audit-completeness.md" \
  && ok "性能审计报告路径单一（docs/评审）" || bad "性能审计报告路径漂移"
grep -q 'docs/测试/<feature>-压测报告.md' "$ROOT/commands/performance.md" \
  && ok "压测报告路径单一（docs/测试）" || bad "压测报告路径漂移"
# 幽灵环境变量不再出现（review P0-2d：EXPECT_* 从未被 s2 gate 读取）
! grep -q 'EXPECT_DATA\|EXPECT_API' "$ROOT/commands/spec.md" \
  && ok "spec.md 无 EXPECT_* 幽灵变量" || bad "spec.md 仍教用户设 EXPECT_* 幽灵变量"
# TC 用例编号机检支持中文模块（review P0-5：TC-组织架构-001 必须可被 gate 计数）
printf '| TC-组织架构-001 | x |\n' > "$TMP/tc-zh.md"
grep -qE '^\|[[:space:]]*TC-[^[:space:]|]+' "$TMP/tc-zh.md" \
  && ok "p5 TC 正则支持中文模块名" || bad "p5 TC 正则不认中文模块名"

# ---------- 文档-机器一致性 meta-gate（review P1-7：gate 注册/产物路径/DF 配额三扫描） ----------
if "${DEVFLOW_PY[@]}" "$ROOT/scripts/check-contract-consistency.py" > "$TMP/cc.out" 2>&1; then
  ok "meta-gate: gate 注册/产物路径/DF 配额三扫描全绿"
else
  bad "meta-gate 拦截: $(grep '✗' "$TMP/cc.out" | head -3 | tr '\n' ' ')"
fi

echo "=== MAINTAINABILITY RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
