#!/bin/bash
# ============================================================
# check-permission-consistency.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：CI 友好的权限码一致性检查
# 比较：
#   - 代码：@PreAuthorize hasAuthority('...') 列表
#   - 文档：docs/detailed-design/_权限矩阵.md 表格列出的权限码
#
# 退出码：
#   0 = 完全一致（或容忍内）
#   1 = 超出容忍
#   2 = 文档缺失（需先生成）
#
# 容忍度：
#   - doc-code 缺（文档多代码少）：0 个（**必须修**）
#   - code-doc 缺（代码多文档少）：≤40 个（auto 生成会随代码扩展）
#
# 用法：
#   bash "$SKILL_ROOT/checks/check-permission-consistency.sh"          # 检查
#   bash "$SKILL_ROOT/checks/check-permission-consistency.sh" --fix    # 检查后自动 run generate
#   bash "$SKILL_ROOT/checks/check-permission-consistency.sh" --strict # 严格模式（任何差异都 fail）
# ============================================================
set -uo pipefail
# v3.0: keep caller cwd (caller run in project root)
DOC_DIR="${DOC_DIR:-docs/detailed-design}"
OUTPUT_FILE="${OUTPUT_FILE:-${DOC_DIR}/_权限矩阵.md}"
CONTROLLER_GLOB="${CONTROLLER_GLOB:-backend/*/src/main/java/**/*.java}"

DOC_FILE="$OUTPUT_FILE"
GEN_SCRIPT="scripts/generate-permission-matrix.sh"
SKILL_ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
case "${1:-}" in
  --fix)
    # v3.14.0: --fix 从承诺变为实现——先重生成矩阵再检查
    bash "$SKILL_ROOT/$GEN_SCRIPT" || { echo "[FATAL] 重生成失败"; exit 2; }
    ;;
  --strict) STRICT=1 ;;
esac
export DOC_FILE CONTROLLER_GLOB
export STRICT

echo "============================================="
echo "  权限码一致性检查"
echo "============================================="
echo "时戳：$(date +%Y%m%d_%H%M%S)"
echo "文档：$DOC_FILE"
echo

# 检查文档存在
if [ ! -f "$DOC_FILE" ]; then
  echo "[FATAL] 文档 $DOC_FILE 不存在"
  echo "  首次使用请运行：bash $GEN_SCRIPT"
  exit 2
fi

# 用 Python 一站式提取并对比（避免 shell 路径的 `0\n0` 等坑）
GEN_SCRIPT="$GEN_SCRIPT" python3 << 'PYEOF'
import re, os, glob, sys

DOC_FILE = os.environ.get("DOC_FILE", "docs/detailed-design/_权限矩阵.md")
GEN_SCRIPT = os.environ.get("GEN_SCRIPT", "scripts/generate-permission-matrix.sh")
PLACEHOLDER = {"xxx", "xxx:yyy:zzz", "具体权限码"}
def is_placeholder(p):
    return p in PLACEHOLDER or p.startswith("xx:") or p.startswith("{") or "{" in p
STRICT = os.environ.get("STRICT", "0") == "1"

# 1. 从代码抽取
code_perms = set()
for f in glob.glob(os.environ.get("CONTROLLER_GLOB", "backend/*/src/main/java/**/*.java"), recursive=True):
    if not f.endswith("Controller.java"): continue
    try:
        c = open(f, encoding="utf-8").read()
    except Exception:
        continue
    for m in re.finditer(r"hasAuthority\(['\"]([^'\"]+)['\"]\)", c):
        p = m.group(1)
        if not is_placeholder(p) and ":" in p and len(p) > 5:
            code_perms.add(p)

# 2. 从文档抽取
doc_perms = set()
try:
    c = open(DOC_FILE, encoding="utf-8").read()
    for m in re.finditer(r"`([A-Za-z]+:[A-Za-z_-]+:[A-Za-z_-]+)`", c):
        p = m.group(1)
        if not is_placeholder(p):
            doc_perms.add(p)
except Exception as e:
    print(f"[FATAL] 文档读取失败: {e}")
    sys.exit(2)

# 3. 计算差异
missing = doc_perms - code_perms  # 文档有，代码无
new = code_perms - doc_perms       # 代码有，文档无

print(f"代码权限码: {len(code_perms)} 个")
print(f"文档权限码: {len(doc_perms)} 个")
print()
print(f"[doc-code 缺] 文档多代码少: {len(missing)} 个")
if missing:
    print("  警告：详设期望但代码未实现")
    for p in sorted(missing)[:10]:
        print(f"  - {p}")
    if len(missing) > 10:
        print(f"  ... +{len(missing)-10} more")
print()
print(f"[code-doc 缺] 代码多文档少: {len(new)} 个")
if new:
    print("  提示：可能是新增未生成文档")
    for p in sorted(new)[:20]:
        print(f"  + {p}")
    if len(new) > 20:
        print(f"  ... +{len(new)-20} more")
print()

# 4. 判定
TOLERANCE_MISSING = 0   # 文档多代码少：必须 0
TOLERANCE_NEW = 40      # 代码多文档少：≤40 容忍

if STRICT:
    ok = (len(missing) == 0 and len(new) == 0)
elif len(missing) == 0 and len(new) <= TOLERANCE_NEW:
    ok = True
else:
    ok = False

print("=" * 50)
if ok:
    print(f"[GATE PASS] 一致性通过（missing={len(missing)} new={len(new)}）")
    sys.exit(0)
else:
    print(f"[GATE FAIL] 不一致（missing={len(missing)} new={len(new)}；容忍 missing≤0 new≤{TOLERANCE_NEW}）")
    if len(missing) > 0:
        print("  建议：删除文档中代码未实现的权限码")
    if len(new) > TOLERANCE_NEW:
        print(f"  建议：运行 'bash {GEN_SCRIPT}' 自动刷新文档")
    sys.exit(1)
PYEOF
# v3.15.21: 显式 rc 终验（与生成器家族同口径）——隐式依赖"python 为末命令"
# 传播 rc 在末尾追加命令时即静默破坏（第 18 轮 PoC：追加一条 echo 后死
# python3 → rc=0 假绿，规范检查未运行却报成功）
# v3.15.22: 语义区分——rc=1 是 python sys.exit(1) 业务判定 FAIL（真实原因已由
# python 打印，静默透传阻断即可）；rc=127/126 等才是解释器/语法环境故障。
# 旧版把业务违规误报为"Python 检查失败"（第 19 轮 P3：排障者误查环境）
# v3.15.23: 本脚本 python 另有 sys.exit(2) 业务语义（文档读取 FATAL，L89-90）——
# rc=2 同样透传，不误报环境故障（第 20 轮 P3-2：无效 UTF-8 文档的 FATAL 曾被
# 紧随的"环境故障"矛盾措辞误导）
CHK_RC=$?
if [ "$CHK_RC" -eq 1 ] || [ "$CHK_RC" -eq 2 ]; then
  exit "$CHK_RC"
fi
if [ "$CHK_RC" -ne 0 ]; then
  echo "[FAIL] Python 环境故障（rc=${CHK_RC}，非业务判定——检查 python3 可用性）" >&2
  exit 1
fi
