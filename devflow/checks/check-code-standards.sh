#!/usr/bin/env bash
# ============================================================
# check-code-standards.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：CI 友好的代码规范检查
# 规范基准：concepts/Java开发手册_黄山版.md（Java 代码生成与评审的强制依据）
# 口径说明：本脚本只覆盖可自动化子集（行数/调试输出等）；手册全量【强制】合规由 P3b 评审逐条核对
# 检查项（v3.14.1 与实现对齐）：
#   1. Service/Controller 行数 > 200 → FAIL
#   2. 文件行数 > 500 → WARN
#   3. 业务代码中禁用 System.out.println
#   （方法级行数/嵌套 SQL 拼接仅部分覆盖：巨型 Service 见本项 1-2，N+1 循环查询见 detect-n-plus-one）
#
# 用法：
#   bash "$SKILL_ROOT/checks/check-code-standards.sh"                          # 扫全项目
#   bash "$SKILL_ROOT/checks/check-code-standards.sh" backend/order-service    # 单服务
#   bash "$SKILL_ROOT/checks/check-code-standards.sh" --strict                 # 任何 warn 都 fail
# ============================================================

set -uo pipefail

# v3.26.1: 参数解析修复——旧版 SERVICE_DIR="${1:-backend}" 会把 --strict 吃成目录
# （文档用法 `--strict` 单独使用即报"目录不存在：--strict"）；flag 与位置参数分离。
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
SERVICE_DIR=""
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    *)        SERVICE_DIR="$1" ;;
  esac
  shift
done
SERVICE_DIR="${SERVICE_DIR:-backend}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  代码规范检查"
echo "============================================="
echo "扫描目录: $SERVICE_DIR"
echo "严格模式: $STRICT"
echo

if [ ! -d "$SERVICE_DIR" ]; then
  err "目录不存在：$SERVICE_DIR"
  exit 1
fi

"${DEVFLOW_PY[@]}" - "$SERVICE_DIR" "$STRICT" <<'PYEOF'
import os, sys, re, glob

base = sys.argv[1]
strict = int(sys.argv[2])

FAIL_THRESHOLD = 200    # Service/Controller 行数阈值
WARN_THRESHOLD = 500    # Impl 超此数警告
LONG_METHOD = 100       # 单方法超此数警告

fail_count = 0
warn_count = 0
ok_count = 0

# v3.26.1: 服务根解析修复——旧 glob `{base}/*/src/main/java/...` 假定 base 是多模块根，
# 传单服务目录（文档用法）时匹配 0 个文件却报"全部 PASS"（假绿）。
# 现在：base 本身是服务目录（含 src/main/java）→ 单服务口径；否则按多模块展开；
# 两者皆无 → fail-closed 报错退出，不再静默 PASS。
def service_roots(base):
    roots = []
    if os.path.isdir(os.path.join(base, 'src', 'main', 'java')):
        roots.append(base)
    for d in sorted(glob.glob(f'{base}/*/src/main/java')):
        roots.append(os.path.dirname(os.path.dirname(os.path.dirname(d))))
    return roots

roots = service_roots(base)
if not roots:
    print(f'[FAIL] 未发现服务目录（{base} 下既无 src/main/java 也无 */src/main/java）——拒绝零文件假绿')
    sys.exit(1)
print(f'  服务根: {len(roots)} 个')

# 1) 行数检查
total_services = 0
over_threshold = []
scan_globs = []
for r in roots:
    scan_globs += glob.glob(f'{r}/src/main/java/**/controller/*Controller.java', recursive=True)
    scan_globs += glob.glob(f'{r}/src/main/java/**/service/impl/*ServiceImpl.java', recursive=True)
for f in scan_globs:
    try:
        line_count = sum(1 for _ in open(f, encoding='utf-8', errors='ignore'))
    except Exception:
        continue
    total_services += 1
    if line_count > WARN_THRESHOLD:
        over_threshold.append((f, line_count, 'WARN'))
        warn_count += 1
    if line_count > FAIL_THRESHOLD:
        over_threshold.append((f, line_count, 'FAIL'))
        fail_count += 1
    if line_count <= FAIL_THRESHOLD and line_count <= WARN_THRESHOLD:
        ok_count += 1

print(f'  1. 行数检查（阈值 {FAIL_THRESHOLD}）')
print(f'     扫描 {total_services} 个文件，pass {ok_count} / warn {warn_count} / fail {fail_count}')
if over_threshold:
    print()
    for f, c, lvl in sorted(over_threshold, key=lambda x: -x[1])[:5]:
        print(f'     [{lvl}] {f}: {c} 行')
    if len(over_threshold) > 5:
        print(f'     ... 还有 {len(over_threshold)-5} 个')
print()

# 2) System.out.println 检查
print('  2. System.out.println 检查（业务代码禁用）')
sop_files = []
sop_globs = []
for r in roots:
    sop_globs += glob.glob(f'{r}/src/main/java/**/*.java', recursive=True)
for f in sop_globs:
    if '/test/' in f or '/Test/' in f:
        continue
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    if 'System.out.println' in c:
        sop_files.append(f)
if not sop_files:
    print('     [OK] 0 处')
else:
    print(f'     [WARN] {len(sop_files)} 个文件')
    for f in sop_files[:5]:
        print(f'       - {f}')
    if len(sop_files) > 5:
        print(f'       ... 还有 {len(sop_files)-5} 个')
    warn_count += len(sop_files)
print()

# 3) 总结
print('=' * 50)
total = fail_count + warn_count
print(f'FAIL: {fail_count}   WARN: {warn_count}')
if strict and total > 0:
    print(f'\n[FAIL] 严格模式：存在 {total} 处违规')
    sys.exit(1)
elif fail_count > 0:
    print(f'\n[FAIL] FAIL 数超阈值')
    sys.exit(1)
elif warn_count > 0:
    print(f'\n[WARN] 只有 warning，未阻塞')
    sys.exit(0)
else:
    print(f'\n[OK] 全部 PASS')
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
