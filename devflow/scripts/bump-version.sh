#!/usr/bin/env bash
# bump-version.sh · 版本升级唯一入口（v3.27.4 审查报告 P0-1 配套）
# 用法: bash scripts/bump-version.sh <new-version>
# 覆盖: SKILL.md + commands/phases/subagents/references/concepts/templates 前matter+标题
#       + scripts banner + structured samples template.version + agents/devflow.md
set -euo pipefail
NEW_VER="${1:?用法: bump-version.sh <new-version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OLD_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
[ -n "$OLD_VER" ] || { echo "[FAIL] 无法解析当前版本"; exit 1; }
echo "bump: $OLD_VER → $NEW_VER"

python3 - "$ROOT" "$OLD_VER" "$NEW_VER" <<'PYEOF'
import glob, json, sys, re
root, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
count = 0
for path in sorted(glob.glob(f"{root}/**/*.md", recursive=True) + glob.glob(f"{root}/*.md")):
    if "/tests/" in path or "/.git/" in path:
        continue
    text = open(path, encoding="utf-8").read()
    orig = text
    text = text.replace(f'version: "{old}"', f'version: "{new}"')
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if line.startswith("# ") and f"v{old}" in line:
            lines[i] = line.replace(f"v{old}", f"v{new}")
            break
    text = "\n".join(lines)
    if text != orig:
        open(path, "w", encoding="utf-8").write(text)
        count += 1
for path in sorted(glob.glob(f"{root}/examples/structured/*.sample.json")):
    d = json.load(open(path))
    tpl = d.get("template", {})
    if tpl.get("version") == old:
        tpl["version"] = new
        json.dump(d, open(path, "w"), ensure_ascii=False, indent=2)
        count += 1
print(f"  bumped {count} files")
PYEOF

# scripts banner（前 3 行）
for f in "$ROOT"/scripts/check-copies.sh "$ROOT"/scripts/install.sh "$ROOT"/scripts/release.sh "$ROOT"/scripts/secret-scan.sh; do
  [ -f "$f" ] || continue
  sed -i '' "s/v${OLD_VER}/v${NEW_VER}/g" "$f" 2>/dev/null || sed -i "s/v${OLD_VER}/v${NEW_VER}/g" "$f"
done
echo "done"
