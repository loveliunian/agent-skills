#!/usr/bin/env bash
# ============================================================
# generate-table-index.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：从 Flyway DDL 中提取所有 CREATE TABLE，
#       按服务和方言聚合，生成 INDEX-表-auto.md
#       （不覆盖人工维护的 INDEX-表.md）
#
# 用法：
#   bash "$SKILL_ROOT/scripts/generate-table-index.sh"                    # 生成 auto 版
#   bash "$SKILL_ROOT/scripts/generate-table-index.sh" --diff             # 与人工版对比差异
#   OUTPUT_FILE=INDEX-表.md bash "$SKILL_ROOT/scripts/generate-table-index.sh"  # 显式覆盖
# ============================================================

set -uo pipefail

# v3.22.0: 默认目录中文化；历史英文目录已存在且未显式指定 DOC_DIR 时沿用
if [ -n "${DOC_DIR:-}" ]; then :; elif [ -d "docs/detailed-design" ] && [ ! -d "docs/详细设计" ]; then DOC_DIR="docs/detailed-design"; else DOC_DIR="docs/详细设计"; fi
OUTPUT_FILE="${OUTPUT_FILE:-$DOC_DIR/INDEX-表-auto.md}"  # 默认 auto 版
DIALECTS="${DIALECTS:-h2 postgresql oracle kingbase}"
DIFF=0
[ "${1:-}" = "--diff" ] && DIFF=1

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  生成 INDEX-表-auto.md"
echo "============================================="
echo "DOC_DIR: $DOC_DIR"
echo "OUTPUT:  $OUTPUT_FILE"
echo "方言:    $DIALECTS"
echo

python3 - "$DOC_DIR" "$OUTPUT_FILE" "$DIALECTS" "$DIFF" <<'PYEOF'
import os, sys, re, glob
from collections import defaultdict

doc_dir = sys.argv[1]
output = sys.argv[2]
dialects = sys.argv[3].split()
diff_mode = int(sys.argv[4])

# 1) 收集 CREATE TABLE
tables = defaultdict(lambda: {'dialects': set(), 'files': []})
for d in dialects:
    for f in glob.glob(f'backend/*/src/main/resources/db/migration/{d}/**/*.sql', recursive=True):
        try:
            c = open(f, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        for m in re.finditer(r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)', c, re.IGNORECASE):
            name = m.group(1).lower()
            tables[name]['dialects'].add(d)
            tables[name]['files'].append(f.replace('backend/', ''))

# 2) 按前缀分组
by_prefix = defaultdict(list)
for name in sorted(tables.keys()):
    by_prefix[name.split('_')[0]].append(name)

# 3) 生成 markdown
out = []
out.append('# 全平台数据库表清单（自动生成 · skill-grade v3.0）')
out.append('')
out.append(f'> **生成时间**: 由 `scripts/generate-table-index.sh` 自动产出')
out.append(f'> **覆盖方言**: {", ".join(dialects)}')
out.append(f'> **本文件是机器可读索引**（auto），与人工维护的 `INDEX-表.md` 并存')
out.append('')
out.append('---')
out.append('')
out.append(f'## 1. 总览')
out.append('')
out.append(f'- 总表数：**{len(tables)}**')
out.append(f'- 前缀数：**{len(by_prefix)}**（{", ".join(sorted(by_prefix.keys()))}）')
out.append('')
out.append('## 2. 全量表清单（按前缀分组）')
out.append('')
for prefix in sorted(by_prefix.keys()):
    out.append(f'### `{prefix}_*` （{len(by_prefix[prefix])} 张）')
    out.append('')
    out.append('| 表名 | 方言覆盖 | 文件 |')
    out.append('|---|---|---|')
    for name in sorted(by_prefix[prefix]):
        d_str = ','.join(sorted(tables[name]['dialects']))
        f_str = '; '.join(sorted(set(tables[name]['files'])))[:100]
        out.append(f'| `{name}` | {d_str} | {f_str} |')
    out.append('')

content = '\n'.join(out)

# 4) --diff 模式：与人工 INDEX-表.md 对比
if diff_mode:
    manual = os.path.join(doc_dir, 'INDEX-表.md')
    if os.path.exists(manual):
        existing = open(manual, encoding='utf-8').read()
        existing_tables = set(m.group(1).lower() for m in re.finditer(r'`(\w+_\w+)`', existing))
        generated_tables = set(tables.keys())
        only_db = generated_tables - existing_tables
        only_doc = existing_tables - generated_tables
        print(f'  人工 INDEX-表.md 有但 DB 无：{len(only_doc)} 个')
        for t in sorted(only_doc)[:10]:
            print(f'    - {t}')
        print(f'  DB 有但 人工 INDEX-表.md 无：{len(only_db)} 个')
        for t in sorted(only_db)[:10]:
            print(f'    - {t}')
        print()

# 5) 写出
os.makedirs(os.path.dirname(output) or '.', exist_ok=True)

# v3.21.0(L-P2-001): 硬链接防护 + 原子写——硬链接别名共享 inode，in-place 覆写会经同一
# inode 双向破坏（事故：聚合投影覆写分文档详设）。nlink>1 拒绝写入（fail-closed）；
# 正常路径写 <path>.tmp 后 os.replace 原子落盘（替换目录项，天然斩断别名）。
def _atomic_write(path, content):
    if os.path.exists(path):
        _nlink = os.stat(path).st_nlink
        if _nlink > 1:
            print(f'[P0] 目标为硬链接（nlink={_nlink}），拒绝覆写: {path} —— 跨模板视图必须独立文件（L-P2-001），请先 unlink 或拆除别名', file=sys.stderr)
            sys.exit(1)
    tmp = path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        f.write(content)
    os.replace(tmp, path)

_atomic_write(output, content)
print(f'[OK] 写入 {output}：{len(tables)} 张表')
PYEOF
# v3.15.19: 显式 rc + 非空双终验（与 er-index/schema-changelog 同口径）——
# 隐式依赖"python 为末命令"传播 rc 在末尾追加命令时即静默破坏（fail-loud 显式化）
GEN_RC=$?
if [ "$GEN_RC" -ne 0 ] || [ ! -s "$OUTPUT_FILE" ]; then
  echo "[FAIL] Python 生成失败（rc=${GEN_RC}）或产物为空: ${OUTPUT_FILE}" >&2
  exit 1
fi
