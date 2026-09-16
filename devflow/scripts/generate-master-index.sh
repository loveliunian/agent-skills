#!/usr/bin/env bash
# ============================================================
# generate-master-index.sh (v3.1 - skill-grade)
# ------------------------------------------------------------
# 用途：扫描项目 docs/ + phases/ + INDEX-* 文件，自动生成 MASTER.md
#       作为"项目进度单一索引"，借鉴 spec_driven_develop 的 MASTER.md 思路
#
# 输出段落：
#   1. 项目速览（模块数 / 阶段数 / 事实源数 / 自动化覆盖率）
#   2. 当前阶段（VERIFICATION.md 通过情况）
#   3. 全量文档索引（按 docs/* 子目录聚合）
#   4. 全量脚本索引
#   5. 跨文档引用图
#
# 用法：
#   bash "$SKILL_ROOT/scripts/generate-master-index.sh"                        # 默认写 MASTER.md
#   OUTPUT_FILE=docs/MASTER.md bash "$SKILL_ROOT/scripts/generate-master-index.sh"
# ============================================================

set -o pipefail

OUTPUT_FILE="${OUTPUT_FILE:-MASTER.md}"
DOC_DIR="${DOC_DIR:-docs/detailed-design}"

GREEN='\033[32m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

echo "============================================="
echo "  生成 MASTER.md"
echo "============================================="
echo "OUTPUT:  $OUTPUT_FILE"
echo "DOC_DIR: $DOC_DIR"
echo

python3 - "$OUTPUT_FILE" "$DOC_DIR" <<'PYEOF'
import os, sys, re, glob
from collections import defaultdict

output = sys.argv[1]
doc_dir = sys.argv[2]

# 1) 扫全量文档
docs_by_dir = defaultdict(list)
for root, dirs, files in os.walk('.'):
    # 跳过 .git / node_modules / target / .cursor/skills
    skip = any(s in root for s in ('.git/', 'node_modules/', 'target/', '.cursor/skills/', '.bak/', '/dist/'))
    if skip:
        continue
    if not files:
        continue
    for f in files:
        if not f.endswith('.md'):
            continue
        p = os.path.relpath(os.path.join(root, f), '.')
        d = os.path.dirname(p) or '.'
        docs_by_dir[d].append(p)

# 2) 扫 phases
phases = []
for root, dirs, files in os.walk('.'):
    skip = any(s in root for s in ('.git/', 'node_modules/'))
    if skip:
        continue
    for f in files:
        if not f.endswith('.md'):
            continue
        if re.match(r'^\d{2}', f):  # 00- / 01- / 02- ... 命名
            p = os.path.relpath(os.path.join(root, f), '.')
            phases.append(p)

# 3) 扫 scripts
scripts = []
for root, dirs, files in os.walk('.'):
    skip = any(s in root for s in ('.git/', 'node_modules/', 'target/'))
    if skip:
        continue
    for f in files:
        if not (f.endswith('.sh') or f.endswith('.py')):
            continue
        p = os.path.relpath(os.path.join(root, f), '.')
        if '/test/' in p or '/target/' in p:
            continue
        scripts.append(p)

# 4) 扫 verification 标记
verifications = []
for root, dirs, files in os.walk('.'):
    skip = any(s in root for s in ('.git/', 'node_modules/', 'target/'))
    if skip:
        continue
    for f in files:
        if 'VERIFICATION' not in f.upper():
            continue
        p = os.path.relpath(os.path.join(root, f), '.')
        try:
            content = open(os.path.join(root, f), encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        passed = bool(re.search(r'passed:\s*true', content, re.IGNORECASE))
        verifications.append((p, passed))

# 5) 生成 markdown
out = []
out.append('# MASTER.md — 项目单一索引')
out.append('')
out.append('> **自动生成**（`scripts/generate-master-index.sh`）')
out.append('> **作用**：新人 5 秒看到项目全貌')
out.append('> **再生成**：每次 phase 切换、文档新增、脚本新增后跑一次')
out.append('')
out.append('---')
out.append('')
out.append('## 1. 项目速览')
out.append('')
out.append(f'| 维度 | 数量 |')
out.append(f'|------|------|')
out.append(f'| Markdown 文档 | {sum(len(v) for v in docs_by_dir.values())} 个')
out.append(f'| 文档目录 | {len(docs_by_dir)} 个')
out.append(f'| Phase 文档 | {len(phases)} 个')
out.append(f'| 自动化脚本 | {len(scripts)} 个')
out.append(f'| VERIFICATION 文件 | {len(verifications)} 个（其中 passed={sum(1 for _,p in verifications if p)}）')
out.append('')

# 6) 当前阶段（基于 VERIFICATION.md）
out.append('## 2. 当前阶段（基于 VERIFICATION.md）')
out.append('')
if verifications:
    out.append('| 文件 | 状态 |')
    out.append('|------|------|')
    for p, passed in sorted(verifications):
        status = '✅ PASS' if passed else '❌ FAIL'
        out.append(f'| `{p}` | {status} |')
    out.append('')
else:
    out.append('> ⚠️ 未发现 VERIFICATION.md — 建议在 `phases/` 各阶段补齐')
    out.append('')

# 7) 文档索引
out.append('## 3. 文档索引')
out.append('')
for d in sorted(docs_by_dir.keys()):
    files = sorted(docs_by_dir[d])
    if len(files) <= 1:
        continue
    out.append(f'### `{d}/` ({len(files)} 个)')
    out.append('')
    for f in files[:30]:
        out.append(f'- `{f}`')
    if len(files) > 30:
        out.append(f'- ... 还有 {len(files)-30} 个')
    out.append('')

# 8) Phase 索引
out.append('## 4. Phase 文档索引')
out.append('')
if phases:
    out.append('| 阶段 | 文件 |')
    out.append('|------|------|')
    for p in sorted(phases):
        m = re.match(r'^(\d{2})', os.path.basename(p))
        if m:
            phase_id = m.group(1)
        else:
            phase_id = '?'
        out.append(f'| P{phase_id} | `{p}` |')
    out.append('')
else:
    out.append('> 无 phase 命名文档')
    out.append('')

# 9) 脚本索引
out.append('## 5. 自动化脚本索引')
out.append('')
out.append('| 文件 | 大小 |')
out.append('|------|------|')
for s in sorted(scripts):
    try:
        size = os.path.getsize(s)
        out.append(f'| `{s}` | {size} bytes |')
    except Exception:
        out.append(f'| `{s}` | - |')
out.append('')

# 10) 引用图（简版）
out.append('## 6. 跨文档引用关系')
out.append('')
ref_count = 0
for d, files in docs_by_dir.items():
    for f in files[:3]:  # 只查前 3 个防爆量
        try:
            content = open(f, encoding='utf-8', errors='ignore').read()
        except Exception:
            continue
        refs = re.findall(r'\]\(([^)]+\.md)\)', content)
        if refs:
            ref_count += len(refs)
out.append(f'> 总 markdown 内部引用数：{ref_count} 个（采样前 30 个文档）')
out.append('')
out.append('---')
out.append('')
out.append('## 7. 再生成命令')
out.append('')
out.append('```bash')
out.append('bash "$SKILL_ROOT/scripts/generate-master-index.sh"')
out.append('OUTPUT_FILE=docs/MASTER.md bash "$SKILL_ROOT/scripts/generate-master-index.sh"')
out.append('```')

content = '\n'.join(out)

# v3.21.0(L-P2-001): 硬链接防护 + 原子写——硬链接别名共享 inode，in-place 覆写会经同一
# inode 双向破坏（事故：聚合投影覆写分文档详设）。目标存在且 nlink>1 时拒绝写入
# （fail-closed，操作方决定 unlink 还是拆独立文件）；正常路径写 <path>.tmp 后
# os.replace 原子落盘（替换目录项，天然斩断别名；生成 md 产物权限位丢失可接受）。
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
print(f'   文档: {sum(len(v) for v in docs_by_dir.values())} | Phases: {len(phases)} | Scripts: {len(scripts)} | VERIFICATION: {len(verifications)}')
PYEOF
# v3.15.19: 显式 rc + 非空双终验（与 er-index/schema-changelog 同口径）——
# 隐式依赖"python 为末命令"传播 rc 在末尾追加命令时即静默破坏（fail-loud 显式化）
GEN_RC=$?
if [ "$GEN_RC" -ne 0 ] || [ ! -s "$OUTPUT_FILE" ]; then
  echo "[FAIL] Python 生成失败（rc=${GEN_RC}）或产物为空: ${OUTPUT_FILE}" >&2
  exit 1
fi
