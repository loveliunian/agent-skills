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

SERVICE_DIR="${1:-backend}"
STRICT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    backend)  SERVICE_DIR="$1" ;;
    *)        SERVICE_DIR="$1" ;;
  esac
  shift
done

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

python3 - "$SERVICE_DIR" "$STRICT" <<'PYEOF'
import os, sys, re, glob

base = sys.argv[1]
strict = int(sys.argv[2])

FAIL_THRESHOLD = 200    # Service/Controller 行数阈值
WARN_THRESHOLD = 500    # Impl 超此数警告
LONG_METHOD = 100       # 单方法超此数警告

fail_count = 0
warn_count = 0
ok_count = 0

# 1) 行数检查
total_services = 0
over_threshold = []
for f in glob.glob(f'{base}/*/src/main/java/**/controller/*Controller.java', recursive=True) + \
            glob.glob(f'{base}/*/src/main/java/**/service/impl/*ServiceImpl.java', recursive=True):
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
for f in glob.glob(f'{base}/*/src/main/java/**/*.java', recursive=True):
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
  echo "[FAIL] Python 环境故障（rc=${CHK_RC}，非业务判定——检查 python3 可用性）" >&2
  exit 1
fi
