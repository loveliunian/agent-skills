#!/usr/bin/env bash
# ============================================================
# check-frontend-standards.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：扫前端代码（Vue/React 通用）
# 检查项：
#   1. .vue 文件内必须 <template> + <script setup> + 三个块
#   2. 单文件 <script> 超过 200 行警告
#   3. 禁用 console.log / debugger /
#   4. 前端测试契约：package.json 必须声明 test script 且存在 test/spec 文件
#
# 用法：
#   bash "$SKILL_ROOT/checks/check-frontend-standards.sh"                       # 扫 frontend/
#   bash "$SKILL_ROOT/checks/check-frontend-standards.sh" frontend/src/views   # 指定子目录
# ============================================================

set -uo pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
SRC_DIR="${1:-frontend}"
STRICT=0
NOT_APPLICABLE=0
for arg in "${@:2}"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    --not-applicable) NOT_APPLICABLE=1 ;;
    *) echo "[FAIL] 未知参数: $arg"; exit 2 ;;
  esac
done

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  前端规范检查"
echo "============================================="
echo "扫描目录: $SRC_DIR"
echo "严格模式: $STRICT"
echo

if [ "$NOT_APPLICABLE" -eq 1 ]; then
  echo "[OK] 前端范围明确为 not-applicable，跳过前端测试契约"
  exit 0
fi

if [ ! -d "$SRC_DIR" ]; then
  warn "前端目录不存在：${SRC_DIR}（跳过）"
  exit 0
fi

"${DEVFLOW_PY[@]}" - "$SRC_DIR" "$STRICT" <<'PYEOF'
import json, os, sys, re, glob

base = sys.argv[1]
strict = int(sys.argv[2])

fail_count = 0
warn_count = 0

# 0) 前端测试契约。P3 只验证可执行测试的最小接线；P6 负责实际执行。
print('  0. 前端测试契约')
package_json = os.path.join(base, 'package.json')
if not os.path.isfile(package_json):
    print('     [FAIL] 缺少 package.json，无法声明测试命令')
    fail_count += 1
else:
    try:
        with open(package_json, encoding='utf-8') as f:
            package = json.load(f)
    except Exception as exc:
        print(f'     [FAIL] package.json 无法解析: {exc}')
        fail_count += 1
        package = {}

    test_script = (package.get('scripts') or {}).get('test')
    if not isinstance(test_script, str) or not test_script.strip():
        print('     [FAIL] package.json 缺少 scripts.test')
        fail_count += 1
    else:
        print(f'     [OK] scripts.test = {test_script}')

    test_files = []
    for pattern in ('**/*.test.ts', '**/*.test.tsx', '**/*.test.js', '**/*.test.jsx',
                    '**/*.spec.ts', '**/*.spec.tsx', '**/*.spec.js', '**/*.spec.jsx'):
        test_files.extend(glob.glob(os.path.join(base, pattern), recursive=True))
    test_files = [f for f in test_files if not any(part in f.split(os.sep) for part in ('node_modules', 'dist', 'build', 'coverage', '.next', '.turbo'))]
    if test_files:
        print(f'     [OK] 测试文件 {len(test_files)} 个')
    else:
        print('     [FAIL] 未找到 *.test.* 或 *.spec.* 测试文件')
        fail_count += 1
print()

# 1) .vue 文件结构
vue_files = glob.glob(f'{base}/**/*.vue', recursive=True)
print(f'  1. Vue 文件结构（{len(vue_files)} 个）')
ok_vue = 0
bad_vue = []
for f in vue_files:
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    has_t = '<template>' in c
    has_s = '<script' in c
    has_setup = 'setup' in c or 'setup lang' in c
    if has_t and has_s:
        ok_vue += 1
    else:
        bad_vue.append((f, has_t, has_s))
print(f'     pass {ok_vue} / fail {len(bad_vue)}')
for f, t, s in bad_vue[:3]:
    print(f'     [FAIL] {f}: template={t} script={s}')
print()

# 2) 单文件 <script> 长度
print('  2. <script> 块长度检查')
long_files = []
for f in vue_files:
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    m = re.search(r'<script[^>]*>(.*?)</script>', c, re.DOTALL)
    if m and m.group(1).count('\n') > 200:
        long_files.append((f, m.group(1).count('\n')))
if long_files:
    print(f'     [WARN] {len(long_files)} 个文件 <script> > 200 行')
    for f, n in long_files[:3]:
        print(f'       - {f}: {n} 行')
    warn_count += len(long_files)
else:
    print('     [OK] 0 个')
print()

# 3) console.log / debugger
print('  3. console.log / debugger 检查')
src_files = []
for ext in ('vue', 'ts', 'js', 'jsx', 'tsx'):
    src_files.extend(glob.glob(f'{base}/**/*.{ext}', recursive=True))
bad_logs = []
for f in src_files:
    if '/test/' in f or '/dist/' in f or '/build/' in f or '/node_modules/' in f:
        continue
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    if 'console.log' in c or 'debugger' in c:
        bad_logs.append(f)
if bad_logs:
    print(f'     [WARN] {len(bad_logs)} 个文件含 console.log/debugger')
    for f in bad_logs[:5]:
        print(f'       - {f}')
    warn_count += len(bad_logs)
else:
    print('     [OK] 0 个')
print()

# 总结
print('=' * 50)
if len(bad_vue) > 0:
    fail_count += len(bad_vue)
print(f'FAIL: {fail_count}   WARN: {warn_count}')
if strict and (fail_count + warn_count) > 0:
    print(f'\n[FAIL] 严格模式')
    sys.exit(1)
elif fail_count > 0:
    print(f'\n[FAIL]')
    sys.exit(1)
else:
    print(f'\n[OK]')
    sys.exit(0)
PYEOF
# v3.15.21: 显式 rc 终验（与生成器家族同口径）——隐式依赖"python 为末命令"
# 传播 rc 在末尾追加命令时即静默破坏（第 18 轮 PoC：追加一条 echo 后死
# python3 → rc=0 假绿，规范检查未运行却报成功）
# v3.15.22: 语义区分——rc=1 是 python sys.exit(1) 业务判定 FAIL（真实原因已由
# python 打印，静默透传阻断即可）；rc=127/126/2 等才是解释器/语法环境故障。
# 旧版把业务违规误报为"Python 检查失败"（第 19 轮 P3：排障者误查环境）
CHK_RC=$?
if [ "$CHK_RC" -eq 1 ]; then
  exit 1
fi
if [ "$CHK_RC" -ne 0 ]; then
  echo "[FAIL] Python 环境故障（rc=${CHK_RC}，非业务判定——检查 Python 3 可用性）" >&2
  exit 1
fi
