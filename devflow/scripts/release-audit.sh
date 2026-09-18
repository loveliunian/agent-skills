#!/usr/bin/env bash
# Release integrity gate for the active devflow tree.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
DEFAULT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ROOT="${DEVFLOW_AUDIT_ROOT:-$DEFAULT_ROOT}"
FAIL=0

fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }
pass() { echo "[PASS] $*"; }

active_files() {
  # v3.20.3: references/manifest/（发布台账自身）与 tests/logs/（测试运行日志）
  # 与 gate-skill-tree/gen-skill-manifest 排除口径对齐，不入发布审计面。
  # 用目录名 prune（-path 是 GNU 扩展，BSD find 语义不同）——目录名唯一，等价。
  find "$ROOT" -type d \( -name '.backups' -o -name '_archive' -o -name 'manifest' -o -name 'logs' \) -prune -o \
    -type f ! -name '*.bak-*' -print
}

active_markdown() {
  active_files | grep -E '\.md$'
}

TARGET_VERSION=$(sed -n 's/^  version: "\(.*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
[ -n "$TARGET_VERSION" ] || { echo "[FAIL] SKILL.md metadata.version missing"; exit 1; }

# Every active Markdown file with frontmatter must carry the release version.
while IFS= read -r file; do
  [ "$file" = "$ROOT/SKILL.md" ] && continue
  head -1 "$file" | grep -qx -- '---' || continue
  version=$(sed -n '1,/^---$/s/^version: "\(.*\)"/\1/p' "$file" | head -1)
  [ -n "$version" ] || version=$(sed -n '1,/^---$/s/^  version: "\(.*\)"/\1/p' "$file" | head -1)
  rel=${file#"$ROOT"/}
  if [ -z "$version" ]; then
    fail "frontmatter version missing: $rel"
  elif [ "$version" != "$TARGET_VERSION" ]; then
    fail "version $version != $TARGET_VERSION: $rel"
  fi
done < <(active_markdown)

# v3.15.1: frontmatter YAML 结构校验（真实解析器优先，结构校验兜底——fail-closed）。
# 背景：completeness-auditor.md 的 allowed-tools/paths 缩进冲突曾使 YAML 解析 exit 1，
# 而旧审计只查 frontmatter 版本号，未发现结构损坏。
validate_frontmatter_yaml() {
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    python3 -c '
import sys, yaml
try:
    yaml.safe_load(sys.stdin)
    sys.exit(0)
except Exception:
    sys.exit(1)
'
    return $?
  fi
  # 结构校验（受控 YAML 子集）：key 行 / 列表项 / 折叠块的缩进归属必须合法
  awk '
    BEGIN { last_indent = -1; expects = 0; errs = 0 }
    /^[ \t]*$/ { next }
    {
      line = $0
      match(line, /^[ \t]*/)
      ind = RLENGTH
      rest = substr(line, RLENGTH + 1)
      if (rest ~ /^- /) {
        if (!expects || ind <= last_indent) { errs++ }
        next
      }
      if (rest ~ /^[A-Za-z0-9_.-]+:/) {
        if (ind > last_indent && !expects) { errs++ }
        colon = index(rest, ":")
        tail = substr(rest, colon + 1)
        gsub(/^[ \t]+/, "", tail); gsub(/[ \t]+$/, "", tail)
        expects = (tail == "" || tail == ">" || tail == ">-" || tail == "|" || tail == "|-")
        last_indent = ind
        next
      }
      if (ind > 0) {
        if (!expects || ind <= last_indent) { errs++ }
        next
      }
      errs++
    }
    END { exit (errs > 0) }
  '
}

# v3.16.21: YAML 语法有效不代表 allowed-tools 字段语义有效。
# 空值或错误缩进会被解析为 null，导致实际需要的 write/exec/task 权限静默丢失。
# v3.23.0: Agent Skills 规范形式为空格分隔字符串；Claude Code 惯用 YAML 列表。
#          两种形式都接受，但工具名白名单/去重/非空校验保持 fail-closed。
#          同时校验顶层 compatibility 为字符串、metadata 为 string→string。
validate_allowed_tools_semantics() {
  local file="$1"
  if command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    python3 - "$file" <<'PY'
import sys, yaml
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
parts = text.split("---", 2)
if len(parts) < 3:
    raise SystemExit(0)
data = yaml.safe_load(parts[1]) or {}
known = {"read", "write", "exec", "glob", "grep", "task"}

def parse_tools(value):
    if isinstance(value, str):
        items = value.replace(",", " ").split()
    elif isinstance(value, list):
        items = value
    else:
        return None
    if not items or any(not isinstance(x, str) or not x.strip() or x not in known for x in items):
        return None
    if len(items) != len(set(items)):
        return None
    return items

required = path.split("/")[-2] in {"commands", "subagents"} and path.split("/")[-1] != "ROUTING.md"
if required and "allowed-tools" not in data:
    raise SystemExit(1)
if "allowed-tools" in data and parse_tools(data["allowed-tools"]) is None:
    raise SystemExit(1)
if "compatibility" in data and not isinstance(data["compatibility"], str):
    raise SystemExit(1)
metadata = data.get("metadata")
if metadata is not None and (not isinstance(metadata, dict) or
        any(not isinstance(k, str) or not isinstance(v, str) for k, v in metadata.items())):
    raise SystemExit(1)
PY
    return $?
  fi
  # 受控回退：inline/缩进列表均须为已知工具，且不允许重复。
  line=$(awk '/^allowed-tools:/{print; exit}' "$file")
  [ -n "$line" ] || {
    case "$file" in */commands/ROUTING.md) return 0 ;; *) return 1 ;; esac
  }
  tools=$(printf '%s\n' "$line" | sed 's/^allowed-tools:[[:space:]]*//; s/[\[\],]/ /g')
  if [ -z "$(printf '%s' "$tools" | tr -d '[:space:]')" ]; then
    tools=$(awk '/^allowed-tools:/{f=1; next} f && /^  - /{sub(/^  - /, ""); print; next} f{exit}' "$file")
  fi
  [ -n "$(printf '%s' "$tools" | tr -d '[:space:]')" ] || return 1
  for tool in $tools; do
    case "$tool" in read|write|exec|glob|grep|task) ;; *) return 1 ;; esac
  done
  dup=$(printf '%s\n' $tools | LC_ALL=C sort | uniq -d)
  [ -z "$dup" ]
}

frontmatter_fail=0
while IFS= read -r file; do
  rel=${file#"$ROOT"/}
  head -1 "$file" | grep -qx -- '---' || continue
  fm=$(awk 'NR==1 && $0=="---" {infm=1; next} infm && $0=="---" {exit} infm {print}' "$file")
  if [ -z "$fm" ]; then
    fail "empty frontmatter: $rel"
    frontmatter_fail=1
    continue
  fi
  if printf '%s\n' "$fm" | validate_frontmatter_yaml; then
    pass "frontmatter YAML structure ok: $rel"
  else
    fail "invalid frontmatter YAML structure: $rel"
    frontmatter_fail=1
  fi
  if validate_allowed_tools_semantics "$file"; then
    pass "allowed-tools semantics ok: $rel"
  else
    fail "allowed-tools semantic structure invalid: $rel"
  fi
  case "$rel" in
    commands/ROUTING.md) : ;;
    commands/*.md|subagents/*.md)
      grep -q '^allowed-tools:' "$file" || fail "allowed-tools missing: $rel"
      ;;
  esac
done < <(active_markdown)
[ "$frontmatter_fail" -eq 0 ] && pass "all frontmatter YAML structures are valid"

if grep -q "# devflow v${TARGET_VERSION}$" "$ROOT/README.md" 2>/dev/null; then
  pass "README title matches release version"
else
  fail "README title does not match release version $TARGET_VERSION"
fi

# Retired skill names must not return to active files.
legacy_ref=0
while IFS= read -r file; do
  if grep -qiE 'full[-_]dev[-_]workflow|full[-_]development[-_]workflow|\.cursor/skills/full[-_]dev[-_]workflow' "$file"; then
    echo "[FAIL] retired legacy name/path: ${file#"$ROOT"/}"
    legacy_ref=1
  fi
done < <(active_files | grep -E '\.(md|sh)$')
if [ "$legacy_ref" -eq 0 ]; then
  pass "no retired legacy name/path in active files"
else
  FAIL=$((FAIL + 1))
fi

# Validate every active JSON resource, not only the client manifest example.

while IFS= read -r json_file; do
  rel=${json_file#"$ROOT"/}
  if command -v jq >/dev/null 2>&1; then
    # v3.16.2: 显式 if 替代尾随 $? 判定（v3.15.19 同型脆弱写法——其间插入命令即静默丢失）
    if jq empty "$json_file" >/dev/null 2>&1; then
      pass "valid JSON: $rel"
    else
      fail "invalid JSON: $rel"
    fi
    continue
  elif command -v python3 >/dev/null 2>&1; then
    # v3.15.23: 区分 python3 运行故障与 JSON 无效——旧版把解释器损坏误报 invalid
    # JSON（第 20 轮 P3-7：fail 方向正确但归因误导）
    if python3 -m json.tool "$json_file" >/dev/null 2>&1; then
      pass "valid JSON: $rel"
    else
      fail "invalid JSON (or python3 validator failure): $rel"
    fi
    continue
  else
    fail "JSON validator unavailable: $rel"
    continue
  fi
done < <(active_files | grep -E '\.json$')

# Reject the common malformed-table typo that silently breaks rendered templates.
table_fail=0
while IFS= read -r file; do
  if grep -qE '^\|\|' "$file"; then
    fail "malformed Markdown table: ${file#"$ROOT"/}"
    table_fail=1
  fi
done < <(active_markdown)
[ "$table_fail" -eq 0 ] && pass "Markdown tables have no double-pipe header typo"

# Every Markdown file must have paired fenced-code delimiters.
fence_fail=0
while IFS= read -r file; do
  fence_count=$(grep -c '^```' "$file" 2>/dev/null || true)
  if [ $((fence_count % 2)) -ne 0 ]; then
    fail "unbalanced Markdown fences: ${file#"$ROOT"/}"
    fence_fail=1
  fi
done < <(active_markdown)
[ "$fence_fail" -eq 0 ] && pass "Markdown fences are balanced"

# Validate concrete relative Markdown links. Web, anchor, mail and templated links are skipped.
link_fail=0
while IFS= read -r file; do
  rel=${file#"$ROOT"/}
  link_file=$(mktemp)
  grep -oE '\]\([^)]+\)' "$file" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//' > "$link_file" || true
  while IFS= read -r target; do
    case "$target" in
      ''|http://*|https://*|mailto:*|\#*|*'<'*|*'>'*|*'|'*|*'\'*) continue ;;
    esac
    clean=$(printf '%s' "$target" | sed -E 's/[?#].*$//; s/^<//; s/>$//')
    [ -z "$clean" ] && continue
    case "$clean" in
      /*) resolved="$clean" ;;
      *) resolved="$(dirname "$file")/$clean" ;;
    esac
    if [ ! -e "$resolved" ]; then
      fail "broken local link: $rel -> $target"
      link_fail=1
    fi
  done < "$link_file"
  rm -f "$link_file"
done < <(active_markdown)
[ "$link_fail" -eq 0 ] && pass "local Markdown links resolve"

# Phase, subagent and template resources must be registered in one explicit,
# machine-readable source; prose mentions in tests/changelogs do not count.
REGISTRY="$ROOT/references/RESOURCE-REGISTRY.md"
if [ ! -f "$REGISTRY" ]; then
  fail "resource registry missing: references/RESOURCE-REGISTRY.md"
  registry_fail=1
else
  registry_fail=0
fi
while IFS= read -r resource; do
  rel=${resource#"$ROOT"/}
  if ! sed -n '/devflow-resource-registry:start/,/devflow-resource-registry:end/p' "$REGISTRY" 2>/dev/null | grep -qxF "$rel"; then
    fail "unregistered resource: $rel"
    registry_fail=1
  fi
done < <(find "$ROOT/phases" "$ROOT/subagents" "$ROOT/templates" -type f -name '*.md' 2>/dev/null)
if [ -f "$REGISTRY" ]; then
  while IFS= read -r rel; do
    case "$rel" in ''|\<\!--*) continue ;; esac
    [ -f "$ROOT/$rel" ] || { fail "stale registry resource: $rel"; registry_fail=1; }
  done < <(sed -n '/devflow-resource-registry:start/,/devflow-resource-registry:end/p' "$REGISTRY" | grep -v 'devflow-resource-registry:')
fi
[ "$registry_fail" -eq 0 ] && pass "phase/subagent/template resources are routed or registered"

syntax_fail=0
while IFS= read -r shell_file; do
  bash -n "$shell_file" || syntax_fail=$((syntax_fail + 1))
done < <(find "$ROOT/scripts" "$ROOT/hooks" "$ROOT/tests" -type f -name '*.sh' ! -name '*.bak-*' 2>/dev/null)
[ "$syntax_fail" -eq 0 ] && pass "bash syntax clean" || fail "bash syntax failures=$syntax_fail"

if bash "$ROOT/hooks/pre-commit-devflow.sh" --self-test >/dev/null 2>&1; then
  pass "pre-commit hook self-test"

# v3.27.2: Contract Registry 一致性 linter（审查报告 P0-1——sample/probe/spawn/core 漂移自动拦截）
if command -v python3 >/dev/null 2>&1; then
  if python3 "$ROOT/scripts/check-contract-consistency.py" >/dev/null 2>&1; then
    pass "contract consistency linter"
  else
    fail "contract consistency linter failed (run: python3 scripts/check-contract-consistency.py)"
  fi
fi
else
  fail "pre-commit hook self-test failed"
fi

# v3.14.3: 版本戳一致性——脚本中 @x.y.z 戳必须等于 SKILL.md 版本（防漏改造成收据审计断裂）
CURRENT_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
STALE_STAMPS=$(grep -rhoE '@[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/scripts" "$ROOT/hooks" 2>/dev/null | grep -v "@${CURRENT_VER}$" | sort -u || true)
if [ -n "$STALE_STAMPS" ]; then
  fail "stale version stamps (expected @${CURRENT_VER}): $(echo $STALE_STAMPS | tr '\n' ' ')"
fi

if command -v shellcheck >/dev/null 2>&1; then
  shell_files=$(find "$ROOT/scripts" "$ROOT/hooks" "$ROOT/tests" -type f -name '*.sh' ! -name '*.bak-*' 2>/dev/null)
  # Note: shellcheck gets a word list of paths; skill paths contain no whitespace.
  shellcheck -S warning $shell_files || fail "shellcheck warnings"
else
  echo "[WARN] shellcheck unavailable; bash -n was used"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "RELEASE AUDIT: PASS version=$TARGET_VERSION"
  exit 0
fi

echo "RELEASE AUDIT: FAIL count=$FAIL"
exit 1
