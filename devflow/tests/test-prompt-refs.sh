#!/usr/bin/env bash
# test-prompt-refs.sh · v3.24.0 提示词引用完整性回归（体检报告 A16）
# 校验 commands/phases/subagents/references/concepts/templates/SKILL.md 中
# 反引号与 Markdown 链接引用的 skill 内部路径真实存在——
# 「仅检查 Markdown 链接不足以覆盖反引号里的重要文件路径」。
# CHANGELOG 是历史版本迁移记录（记录的是各版本当时存在的文件），不在活提示词
# 扫描范围；占位符路径（含 < > { } * $）与项目相对路径（docs/ backend/ 任务/ 等）跳过。
set -u
set -o pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0
FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }

echo "=== prompt reference integrity (A16) ==="

# 收集全部被引用路径：反引号 span 与 Markdown 链接目标
REFS_FILE=$(mktemp -t promptrefs.XXXXXX)
trap 'rm -f "$REFS_FILE"' EXIT
python3 - "$ROOT" > "$REFS_FILE" <<'PYEOF'
import re, sys
from pathlib import Path

root = Path(sys.argv[1])
scan_dirs = ["commands", "phases", "subagents", "references", "concepts", "templates", "agents", "checks", "hooks"]
files = [root / "SKILL.md", root / "README.md"]
for d in scan_dirs:
    base = root / d
    if base.is_dir():
        files.extend(p for p in base.rglob("*.md"))
        files.extend(p for p in base.rglob("*.sh"))
# CHANGELOG 为历史迁移记录（记录的是各版本当时存在的文件），豁免活提示词扫描
files = [f for f in files if f.name != "CHANGELOG.md"]

refs = set()
bt = re.compile(r"`([^`\n]+)`")
link = re.compile(r"\]\(([^)\s]+)\)")
skip_prefixes = ("docs/", "backend/", "frontend/", "tasks/", ".devflow/", "http://", "https://")
for f in files:
    if not f.is_file():
        continue
    try:
        text = f.read_text(encoding="utf-8", errors="replace")
    except OSError:
        continue
    rel = f.relative_to(root)
    hits = [(m.group(1), m.start()) for m in bt.finditer(text)]
    hits += [(m.group(1), m.start()) for m in link.finditer(text)]
    for s, pos in hits:
        s = s.split("#", 1)[0].strip()
        if not s or s.startswith(("$", "~")):
            continue
        if any(ch in s for ch in "<>*{}"):
            continue                             # 占位符/通配路径
        if " " in s:
            continue
        if not re.search(r"\.(md|sh|json|yaml|yml|py|tsv|sql|pem|txt)$", s):
            continue
        if s.startswith(skip_prefixes) or s.startswith("agent-skills/"):
            continue
        refs.add((str(rel), s))
for rel, s in sorted(refs):
    print(f"{rel}\t{s}")
PYEOF

# 仅校验「含 / 且首段为 skill 内部目录」的引用——裸文件名是行文提法，
# 任务//docs/ 等是项目侧产物路径，不属于本检查范畴。
SKILL_DIRS="scripts|templates|commands|phases|subagents|references|concepts|agents|checks|hooks|schemas|examples|tests|maintenance"
BROKEN=0
while IFS=$'\t' read -r src ref; do
  [ -n "$ref" ] || continue
  case "$ref" in
    ./*|../*) continue ;;
  esac
  printf '%s' "$ref" | grep -qE "^($SKILL_DIRS)/" || continue
  if [ ! -e "$ROOT/$ref" ]; then
    bad "dangling reference: [$src] -> $ref"
    BROKEN=$((BROKEN + 1))
  fi
done < "$REFS_FILE"

if [ "$BROKEN" -eq 0 ]; then
  ok "all backtick/linked skill-internal paths resolve（$(grep -c . "$REFS_FILE") 处引用）"
else
  bad "$BROKEN dangling references found — 修复文档或补齐文件"
fi

# A16 已知反例钉：曾经悬空的引用不得回归
for gone in "concepts/design-review-process.md" "concepts/SKILL.md"; do
  if grep -rq "$gone" "$ROOT/commands" "$ROOT/phases" "$ROOT/subagents" 2>/dev/null; then
    bad "known-dangling reference reappeared: $gone"
  else
    ok "no regression: $gone remains unreferenced"
  fi
done

echo "=== prompt refs RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
