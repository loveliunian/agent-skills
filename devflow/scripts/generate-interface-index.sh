#!/usr/bin/env bash
# ============================================================
# generate-interface-index.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：从 Controller 注解中提取所有 API 端点，
#       按服务和 HTTP 方法聚合，生成 INDEX-接口-auto.md
#
# 扫描目标：
#   @RequestMapping、@GetMapping、@PostMapping、@PutMapping、@DeleteMapping、@PatchMapping
#   含类级别 + 方法级别路径合并
#
# 用法：
#   bash "$SKILL_ROOT/scripts/generate-interface-index.sh"
#   bash "$SKILL_ROOT/scripts/generate-interface-index.sh" --diff
# ============================================================

set -uo pipefail

DOC_DIR="${DOC_DIR:-docs/detailed-design}"
OUTPUT_FILE="${OUTPUT_FILE:-$DOC_DIR/INDEX-接口-auto.md}"
DIFF=0
[ "${1:-}" = "--diff" ] && DIFF=1

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  生成 INDEX-接口-auto.md"
echo "============================================="
echo "DOC_DIR: $DOC_DIR"
echo "OUTPUT:  $OUTPUT_FILE"
echo

python3 - "$DOC_DIR" "$OUTPUT_FILE" "$DIFF" <<'PYEOF'
import os, sys, re, glob, json
from collections import defaultdict

doc_dir = sys.argv[1]
output = sys.argv[2]
diff_mode = int(sys.argv[3])

# 1) 扫所有 Controller
controllers = []
for f in glob.glob('backend/*/src/main/java/**/controller/*Controller.java', recursive=True):
    controllers.append(f)

endpoints = []  # (method, path, service, controller_file)

METHOD_ANNO = {
    'GetMapping':    'GET',
    'PostMapping':   'POST',
    'PutMapping':    'PUT',
    'DeleteMapping': 'DELETE',
    'PatchMapping':  'PATCH',
}

for f in controllers:
    try:
        content = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    # service
    svc_match = re.search(r'backend/([^/]+)/', f)
    service = svc_match.group(1) if svc_match else '?'
    # 类级别 @RequestMapping
    cls_match = re.search(r'@RequestMapping\s*\(\s*["\']([^"\']*)["\']', content)
    class_path = cls_match.group(1) if cls_match else ''
    # 方法级别
    for anno, method in METHOD_ANNO.items():
        for m in re.finditer(rf'@{anno}\s*\(([^)]*)\)', content):
            args = m.group(1)
            # 提取 path 字符串
            # v3.14.0: 优先 value=/path= 显式属性，再取首个不含 {} 的字面量；排除 produces/consumes 等非路径属性
            args_clean = re.sub(r'\b(produces|consumes|headers)\s*=\s*[^,)]+,?', '', args)
            pm = re.search(r'\b(?:value|path)\s*=\s*"([^"]+)"', args_clean)
            if not pm:
                pm = re.search(r'"([^"]*)"', args_clean)
            if pm and pm.group(1) is not None:
                sub = pm.group(1)
            else:
                sub = ''  # 默认为根
            full_path = (class_path + sub).replace('//', '/')
            endpoints.append((method, full_path, service, f.replace('backend/', '')))

# 2) 按方法统计
by_method = defaultdict(int)
by_service = defaultdict(int)
for m, p, s, _ in endpoints:
    by_method[m] += 1
    by_service[s] += 1

# 3) 生成 markdown
out = []
out.append('# 全平台接口清单（自动生成 · skill-grade v3.0）')
out.append('')
out.append(f'> **生成时间**: 由 `scripts/generate-interface-index.sh` 自动产出')
out.append(f'> **本文件是机器可读索引**（auto），与人工维护的 `INDEX-接口.md` 并存')
out.append('')
out.append('---')
out.append('')
out.append('## 1. 总览')
out.append('')
out.append(f'- 端点数：**{len(endpoints)}**')
out.append(f'- Controller 数：**{len(controllers)}**')
out.append(f'- 服务数：**{len(by_service)}**')
out.append('')
out.append('### 1.1 按 HTTP 方法')
out.append('')
out.append('| Method | Count |')
out.append('|---|---|')
for m in ('GET','POST','PUT','DELETE','PATCH'):
    if by_method[m]:
        out.append(f'| {m} | {by_method[m]} |')
out.append('')
out.append('### 1.2 按服务')
out.append('')
out.append('| 服务 | 端点数 |')
out.append('|---|---|')
for s in sorted(by_service.keys()):
    out.append(f'| {s} | {by_service[s]} |')
out.append('')
out.append('## 2. 全量端点清单')
out.append('')
out.append('| Method | Path | 服务 | Controller |')
out.append('|---|---|---|---|')
for m, p, s, c in sorted(endpoints, key=lambda x: (x[2], x[1])):
    out.append(f'| {m} | `{p}` | {s} | {c} |')
out.append('')

content = '\n'.join(out)

# 4) diff 模式
if diff_mode:
    manual = os.path.join(doc_dir, 'INDEX-接口.md')
    if os.path.exists(manual):
        existing = open(manual, encoding='utf-8').read()
        existing_paths = set(m.group(1) for m in re.finditer(r'`(/api/[^`]+)`', existing))
        generated_paths = set(p for _, p, _, _ in endpoints)
        only_doc = existing_paths - generated_paths
        only_db = generated_paths - existing_paths
        print(f'  人工 INDEX-接口.md 有但代码无：{len(only_doc)} 个')
        for t in sorted(only_doc)[:10]:
            print(f'    - {t}')
        print(f'  代码有但 人工 INDEX-接口.md 无：{len(only_db)} 个')
        for t in sorted(only_db)[:10]:
            print(f'    - {t}')
        print()

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
print(f'[OK] 写入 {output}：{len(endpoints)} 个端点')
PYEOF
# v3.15.19: 显式 rc + 非空双终验（与 er-index/schema-changelog 同口径）——
# 隐式依赖"python 为末命令"传播 rc 在末尾追加命令时即静默破坏（fail-loud 显式化）
GEN_RC=$?
if [ "$GEN_RC" -ne 0 ] || [ ! -s "$OUTPUT_FILE" ]; then
  echo "[FAIL] Python 生成失败（rc=${GEN_RC}）或产物为空: ${OUTPUT_FILE}" >&2
  exit 1
fi
