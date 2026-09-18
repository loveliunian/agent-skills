#!/usr/bin/env bash
# test-schema-guards.sh · v3.27.12 schema 契约守卫
# ① template.id 悬空守卫（schema const / sample 值 → templates/<id>.md 必须存在；白名单豁免）
# ② 样例模板身份守卫（sample.template.id == schema const；sample.template.version == SKILL 版本）
# ③ 死字段守卫（schema 属性在 scripts/ 零消费者 → 必须登记白名单，防"空转契约"复发）
# ④ 模板 frontmatter name == 文件名
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== schema 契约守卫（v3.27.12） ==="

py_out=$(python3 - "$ROOT" <<'PYEOF'
import json, glob, re, sys
from pathlib import Path
ROOT = Path(sys.argv[1])
tpl_dir = ROOT / "templates"
tpls = {p.stem for p in tpl_dir.glob("*.md")}
ALLOW_SAMPLE_TPL = {"执行契约"}   # execution-plan 样例 template.id 指产物名而非模板文件
ALLOW_DEAD = {
    "page_type": "§7.1 类型列正本；自由文本，仅 schema 必填",
    "preconditions": "业务操作前置条件；自由文本，仅 schema 必填",
    "related_objects": "业务操作关联对象处置；自由文本，仅 schema 必填",
    "repo_root": "基线调查仓库根；仅 schema 必填+文档注记",
    "side_effects": "业务操作副作用；自由文本，仅 schema 必填",
}
def emit(ok, msg):
    print(("ok|" if ok else "bad|") + msg)

schemas = {}
for f in sorted(glob.glob(str(ROOT / "schemas/*.schema.json"))):
    schemas[Path(f).stem.replace(".schema", "")] = json.load(open(f))
skill_ver = re.search(r'(?m)^version: "([0-9.]+)"', (ROOT / "SKILL.md").read_text(encoding="utf-8")).group(1)

# ① / ②
for kind, s in schemas.items():
    tprop = ((s.get("properties", {}).get("template") or {}).get("properties") or {})
    const = (tprop.get("id") or {}).get("const", "")
    emit(not const or const in tpls,
         f"{kind}: schema template.id const '{const}' 有模板文件" if const else f"{kind}: 无 template.id const（跳过）")
    sp = ROOT / f"examples/structured/{kind}.sample.json"
    if not sp.is_file():
        continue
    d = json.loads(sp.read_text(encoding="utf-8"))
    tid = (d.get("template") or {}).get("id", "")
    emit(not tid or tid in tpls or tid in ALLOW_SAMPLE_TPL,
         f"{kind}: sample template.id '{tid}' 存在（或白名单）" if tid else f"{kind}: sample 无 template.id（跳过）")
    if const and tid:
        emit(tid == const, f"{kind}: sample template.id == schema const（{const}）")
    tv = (d.get("template") or {}).get("version", "")
    if tv:
        emit(tv == skill_ver, f"{kind}: sample template.version == SKILL {skill_ver}")

# ③ 死字段
scripts = "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in (ROOT / "scripts").glob("*.py"))
scripts += "\n".join(p.read_text(encoding="utf-8", errors="replace") for p in (ROOT / "scripts").glob("*.sh"))
def props(d, out):
    if isinstance(d, dict):
        for k, v in (d.get("properties") or {}).items():
            out.add(k); props(v, out)
        it = d.get("items")
        if isinstance(it, dict):
            props(it, out)
        for v in d.values():
            props(v, out)
    elif isinstance(d, list):
        for v in d:
            props(v, out)
dead_total = 0
for kind, s in schemas.items():
    names = set(); props(s, names)
    for n in sorted(names):
        if not re.search(re.escape(n), scripts) and n not in ALLOW_DEAD:
            dead_total += 1
            emit(False, f"{kind}: 字段 '{n}' 在 scripts/ 无消费者且未登记白名单（空转契约）")
emit(dead_total == 0, "死字段扫描：除白名单外无零消费字段")

# ④ 模板 name
bad_name = 0
for p in sorted(tpl_dir.glob("*.md")):
    m = re.search(r'(?m)^name:\s*"?([^"\n]+)"?', p.read_text(encoding="utf-8"))
    nm = m.group(1).strip() if m else ""
    if nm != p.stem:
        bad_name += 1
        emit(False, f"templates/{p.name}: frontmatter name '{nm}' != 文件名")
emit(bad_name == 0, "模板 frontmatter name 与文件名一致")
PYEOF
)
while IFS= read -r line; do
  case "$line" in
    ok\|*) ok "${line#ok|}" ;;
    bad\|*) bad "${line#bad|}" ;;
  esac
done <<< "$py_out"

echo "=== SCHEMA_GUARDS RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
