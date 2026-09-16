#!/usr/bin/env bash
# ============================================================
# detect-n-plus-one.sh（skill-grade；版本随 SKILL.md 单一事实源）
# ------------------------------------------------------------
# 用途：扫描 Java MyBatis-Plus 映射文件 + Service 实现，
#       检测 N+1 查询（for/while 循环内调用 mapper 单对象查询）
#
# 启发式规则（减少误报）：
#   1. 只匹配 for( ... ) / while( ... ) 关键字循环（排除 stream().forEach()）
#   2. 循环体里调用 *.selectById / getById / selectOne / getOne
#   3. 标记为潜在 N+1（需人工 review）
#
# 输出：
#   - PASS：0 处
#   - WARN：1-5 处
#   - FAIL：>5 处 / 或 --strict
#
# 用法：
#   bash "$SKILL_ROOT/checks/detect-n-plus-one.sh"                            # 扫整个项目
#   bash "$SKILL_ROOT/checks/detect-n-plus-one.sh" backend/order-service     # 扫单个服务
#   bash "$SKILL_ROOT/checks/detect-n-plus-one.sh" --strict                  # 任意一处都 FAIL
# ============================================================

set -uo pipefail

SERVICE_DIR="backend"
STRICT=0
POSITIONAL=()
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *)        POSITIONAL+=("$arg") ;;
  esac
done
[ ${#POSITIONAL[@]} -gt 0 ] && SERVICE_DIR="${POSITIONAL[0]}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  N+1 查询检测"
echo "============================================="
echo "扫描目录: $SERVICE_DIR"
echo "严格模式: $STRICT"
echo

if [ ! -d "$SERVICE_DIR" ]; then
  err "目录不存在：$SERVICE_DIR"
  exit 1
fi

python3 - "$SERVICE_DIR" "$STRICT" <<'PYEOF'
import os, sys, re, glob, collections

base = sys.argv[1]
strict = int(sys.argv[2])

# 1) 找所有 Service 实现类
service_files = []
for f in glob.glob(f'{base}/*/src/main/java/**/service/impl/*ServiceImpl.java', recursive=True):
    service_files.append(f)

# 2) Mapper 单对象调用模式
mapper_pattern = re.compile(r'\.(getById|selectById|selectOne|getOne|selectByMap)\s*\(')

# 3) 只匹配 for(...){...} / while(...){...} 关键字循环（不含 stream / forEach）
#    通过 brace 匹配取循环体
loop_starts = []
findings = []

for f in service_files:
    try:
        content = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    lines = content.split('\n')
    # 找所有 for( / while( 起始行（必须有开括号，未闭合）
    for i, line in enumerate(lines):
        # for (...)   或   while (...)
        if re.search(r'\b(for|while)\s*\(', line) and not re.search(r'\bforEach\s*\(|\bstream\s*\(', line):
            # 计算本行括号深度
            # 简化：从 i 开始往后读直到闭合 ... 内的 ) 与 {
            j = i
            depth_paren = 0
            depth_brace = 0
            found_open = False
            body_lines = []
            while j < len(lines):
                l = lines[j]
                if j == i:
                    # 从 for 开始数
                    for ch in l:
                        if ch == '(':
                            depth_paren += 1
                            found_open = True
                        elif ch == ')':
                            depth_paren -= 1
                else:
                    # 在 for() 闭合之后进入 body
                    if depth_paren == 0 and depth_brace == 0 and '{' in l and found_open:
                        # 进入 body
                        for ch in l[l.index('{'):]:
                            if ch == '{': depth_brace += 1
                            elif ch == '}':
                                depth_brace -= 1
                                if depth_brace == 0: break
                        body_lines.append(l)
                        j += 1
                        continue
                    # 同一行若有 { 也要算
                    for ch in l:
                        if ch == '{': depth_brace += 1
                        elif ch == '}':
                            depth_brace -= 1
                            if depth_brace == 0: break
                j += 1
                if depth_paren <= 0 and depth_brace <= 0 and found_open:
                    break
            # 简单粗暴版：只取 for(...) 后 30 行内的 mapper 调用
            block = '\n'.join(lines[i:i+30])
            for m in mapper_pattern.finditer(block):
                col = block[:m.start()].count('\n')
                # 排除已经在 .selectList / .selectBatchIds 的批量调用
                # 检查前后 50 字符内是否有 .in( / selectList / selectBatchIds
                ctx = block[max(0,m.start()-100):m.start()+100]
                if '.selectList(' in ctx or 'selectBatchIds' in ctx or '.in(' in ctx:
                    continue
                findings.append((f, i + 1, lines[i].strip()[:80], m.group(0)))

# 4) 输出
if not findings:
    print(f'  [OK] 0 处 for/while 循环中的 N+1 风险')
    print()
    print(f'N+1 检测：PASS（0 处）')
    sys.exit(0)

by_file = collections.defaultdict(list)
for f, l, code, hint in findings:
    by_file[f].append((l, code, hint))

print(f'  发现 {len(findings)} 处潜在 N+1（{len(by_file)} 个文件）')
print()
for f, items in sorted(by_file.items()):
    print(f'  📄 {f}')
    for l, code, hint in items[:5]:
        print(f'    L{l}: {code}')
        print(f'      → 含 {hint}')
    if len(items) > 5:
        print(f'    ... 还有 {len(items)-5} 处')
    print()

# 5) 退出码
if strict and len(findings) > 0:
    print(f'N+1 检测：FAIL（{len(findings)} 处）— strict 模式')
    sys.exit(1)
elif len(findings) <= 5:
    print(f'N+1 检测：WARN（{len(findings)} 处）— 建议优化但非阻塞')
    sys.exit(0)
else:
    print(f'N+1 检测：FAIL（{len(findings)} 处）— 超阈值 5')
    sys.exit(1)
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
