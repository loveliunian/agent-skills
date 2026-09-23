#!/usr/bin/env bash
# bump-version.sh · 版本升级唯一入口（v3.30.5 审查报告 P0-1 配套）
# 用法: bash scripts/bump-version.sh <new-version>
# 覆盖: SKILL.md + commands/phases/subagents/references/concepts/templates 前matter+标题
#       + scripts banner + structured samples template.version + agents/devflow.md
set -euo pipefail
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
NEW_VER="${1:?用法: bump-version.sh <new-version>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
OLD_VER=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
[ -n "$OLD_VER" ] || { echo "[FAIL] 无法解析当前版本"; exit 1; }
if [ "$OLD_VER" = "$NEW_VER" ]; then
  echo "[SKIP] 版本未变化（${OLD_VER}）——无操作"
  exit 0
fi
echo "bump: $OLD_VER → $NEW_VER"

"${DEVFLOW_PY[@]}" - "$ROOT" "$OLD_VER" "$NEW_VER" <<'PYEOF'
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
        new_text = json.dumps(d, ensure_ascii=False, indent=2)
        if open(path, encoding="utf-8").read() != new_text:
            open(path, "w", encoding="utf-8").write(new_text)
            count += 1
print(f"  bumped {count} files")
PYEOF

# scripts/checks/maintenance banner（前 3 行身份版本；v3.27.11：由固定 4 文件改为全量扫描，
# 与 check-skill-version.sh 的 banner 扫描口径对齐——此前漏更即触发版本门禁漂移）
while IFS= read -r f; do
  sed -i '' "2,3s/v${OLD_VER}/v${NEW_VER}/g" "$f" 2>/dev/null || sed -i "2,3s/v${OLD_VER}/v${NEW_VER}/g" "$f"
done < <(find "$ROOT/scripts" "$ROOT/checks" "$ROOT/maintenance" -maxdepth 1 -name '*.sh' 2>/dev/null)
echo "done"
