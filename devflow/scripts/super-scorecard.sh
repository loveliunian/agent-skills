#!/usr/bin/env bash
# ============================================================
# super-scorecard.sh (v3.2 - skill-grade)
# ------------------------------------------------------------
# 用途：S.U.P.E.R 5 维架构健康自动评分（spec_driven_develop 借鉴）
#
# 5 维：
#   S — Single Purpose（单一职责）
#   U — Unidirectional Flow（单向数据流）
#   P — Ports over Implementation（接口优先）
#   E — Environment-Agnostic（环境无关）
#   R — Replaceable Parts（可替换）
#
# 评分：每维 1-5 分，总分 ≥ 20/25 PASS
#
# 用法：
#   bash "$SKILL_ROOT/scripts/super-scorecard.sh"                           # 扫整个项目
#   bash "$SKILL_ROOT/scripts/super-scorecard.sh" backend/order-service     # 单个服务
#   bash "$SKILL_ROOT/scripts/super-scorecard.sh" backend/order-service docs/super.md  # 单服务 + 输出
#   bash "$SKILL_ROOT/scripts/super-scorecard.sh"                            # 扫整个项目（输出 stdout）
# ============================================================

set -o pipefail

# 参数解析：支持 1~2 个位置参数
# 第 1 个：服务目录（默认 backend）
# 第 2 个：输出 markdown 文件（可选，默认空=stdout）
SERVICE_DIR="${1:-backend}"
OUTPUT_FILE="${2:-}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  S.U.P.E.R 架构健康评分"
echo "============================================="
echo "扫描目录: $SERVICE_DIR"
echo

if [ ! -d "$SERVICE_DIR" ]; then
  err "目录不存在：$SERVICE_DIR"
  exit 1
fi

python3 - "$SERVICE_DIR" "$OUTPUT_FILE" <<'PYEOF'
import os, sys, re, glob
from collections import defaultdict

service_dir = sys.argv[1]
output = sys.argv[2]

# ============== 各维度评分 ==============

# S — Single Purpose
# 启发式：每个 Service / Controller / Mapper 文件 ≤ 200 行 = 5 分；201-400 = 4 分；401-500 = 3；501-800 = 2；>800 = 1
s_scores = []
s_files_too_big = []
for f in glob.glob(f'{service_dir}/src/main/java/**/service/impl/*ServiceImpl.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/service/impl/*ServiceImpl.java', recursive=True) + \
            glob.glob(f'{service_dir}/src/main/java/**/controller/*Controller.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/controller/*Controller.java', recursive=True):
    try:
        line_count = sum(1 for _ in open(f, encoding='utf-8', errors='ignore'))
    except Exception:
        continue
    if line_count > 800:
        s_scores.append(1)
        s_files_too_big.append((f, line_count, 'critical'))
    elif line_count > 500:
        s_scores.append(2)
        s_files_too_big.append((f, line_count, 'warning'))
    elif line_count > 400:
        s_scores.append(3)
    elif line_count > 200:
        s_scores.append(4)
    else:
        s_scores.append(5)
s_score = sum(s_scores) / len(s_scores) if s_scores else 5
s_score = round(s_score, 1)

# U — Unidirectional Flow
# 检查循环 import：用正则查 `import.*\.service\..*;` 出现在 `service/impl/` 内部
u_violations = 0
for f in glob.glob(f'{service_dir}/src/main/java/**/service/impl/*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/service/impl/*.java', recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    # Impl 内部 import 另一个 Impl = 循环依赖风险
    if re.search(r'import\s+.*\.service\.impl\.[A-Z]\w+', c):
        u_violations += 1
# Controller 调 Mapper（跳过 service）= 跳层
u_skip_layer = 0
for f in glob.glob(f'{service_dir}/src/main/java/**/controller/*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/controller/*.java', recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    if re.search(r'@Autowired.*[Mm]apper|@Resource.*[Mm]apper', c):
        u_skip_layer += 1
if u_violations == 0 and u_skip_layer == 0:
    u_score = 5
elif u_violations + u_skip_layer <= 2:
    u_score = 4
elif u_violations + u_skip_layer <= 5:
    u_score = 3
elif u_violations + u_skip_layer <= 10:
    u_score = 2
else:
    u_score = 1

# P — Ports over Implementation
# 检查跨服务 OpenFeign 客户端定义（@FeignClient）
feign_clients = 0
for f in glob.glob(f'{service_dir}/src/main/java/**/feign/*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/feign/*.java', recursive=True) + \
            glob.glob(f'{service_dir}/src/main/java/**/client/*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/client/*.java', recursive=True):
    feign_clients += 1
# 跨服务调用数 = feign client 文件数
feign_count = len(glob.glob(f'{service_dir}/src/main/java/**/feign/*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/feign/*.java', recursive=True))
p_score = 5 if feign_count >= 3 else 4 if feign_count >= 1 else 3

# E — Environment-Agnostic
# 检查 application.yml / application.properties 是否硬编码
e_hardcoded = 0
for f in glob.glob(f'{service_dir}/src/main/resources/application*.yml' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/resources/application*.yml', recursive=True) + \
            glob.glob(f'{service_dir}/src/main/resources/application*.properties' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/resources/application*.properties', recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    # 硬编码 IP / 端口 / 密码
    if re.search(r'localhost\s*:\s*3306|jdbc:mysql://\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}', c):
        e_hardcoded += 1
    if re.search(r'password:\s*[\w!@#$%^&*]+', c) and 'password' in c and '$' not in c.split('password:')[1].split('\n')[0]:
        e_hardcoded += 1
# 环境变量使用 ${VAR} 模式
env_var_usage = 0
for f in glob.glob(f'{service_dir}/src/main/resources/application*.yml' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/resources/application*.yml', recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    env_var_usage += len(re.findall(r'\$\{[\w.]+\}', c))
if e_hardcoded == 0 and env_var_usage >= 5:
    e_score = 5
elif e_hardcoded == 0 and env_var_usage >= 1:
    e_score = 4
elif e_hardcoded <= 2:
    e_score = 3
elif e_hardcoded <= 5:
    e_score = 2
else:
    e_score = 1

# R — Replaceable Parts
# 检查是否有 fallback（替代性）和适配器模式
r_fallbacks = 0
for f in glob.glob(f'{service_dir}/src/main/java/**/*Fallback*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/*Fallback*.java', recursive=True) + \
            glob.glob(f'{service_dir}/src/main/java/**/*FallbackFactory*.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/*FallbackFactory*.java', recursive=True):
    r_fallbacks += 1
# 接口类（@XxxClient / @XxxService 接口）数量
r_interfaces = len(glob.glob(f'{service_dir}/src/main/java/**/*Client.java' if os.path.exists(f'{service_dir}/src') else f'{service_dir}/*/src/main/java/**/*Client.java', recursive=True))
if r_fallbacks >= 3 and r_interfaces >= 3:
    r_score = 5
elif r_fallbacks >= 1 or r_interfaces >= 3:
    r_score = 4
elif r_fallbacks >= 1 or r_interfaces >= 1:
    r_score = 3
else:
    r_score = 2

# ============== 汇总 ==============
total = s_score + u_score + p_score + e_score + r_score

print(f'  S — Single Purpose       : {s_score} / 5')
print(f'  U — Unidirectional Flow  : {u_score} / 5')
print(f'  P — Ports over Impl      : {p_score} / 5')
print(f'  E — Environment-Agnostic : {e_score} / 5')
print(f'  R — Replaceable Parts    : {r_score} / 5')
print(f'  ─────────────────────────')
print(f'  TOTAL                    : {total} / 25')
print()

# 详细问题
if s_files_too_big:
    print(f'  📌 S 超标文件：')
    for f, n, lvl in sorted(s_files_too_big, key=lambda x: -x[1])[:5]:
        print(f'    [{lvl}] {f}: {n} 行')
    print()
if u_violations + u_skip_layer > 0:
    print(f'  📌 U 跳层 / 循环依赖：{u_violations + u_skip_layer} 处')
    print()
if e_hardcoded > 0:
    print(f'  📌 E 硬编码：{e_hardcoded} 处')
    print()

# 判定
if total >= 20:
    print(f'  ✅ S.U.P.E.R 评估：PASS（{total}/25）')
    rc = 0
elif total >= 15:
    print(f'  ⚠️ S.U.P.E.R 评估：WARN（{total}/25，建议修复后重跑）')
    rc = 0
else:
    print(f'  ❌ S.U.P.E.R 评估：FAIL（{total}/25，需重构）')
    rc = 1

# 输出 markdown
if output:
    md = []
    md.append('# S.U.P.E.R Scorecard Report')
    md.append('')
    md.append(f'> 扫描目录: `{service_dir}`')
    md.append(f'> 评分时间: 自动生成')
    md.append('')
    md.append('## 总分')
    md.append('')
    md.append(f'**{total} / 25**')
    md.append('')
    md.append('| 维度 | 得分 | 阈值 | 状态 |')
    md.append('|------|------|------|------|')
    for dim, sc in [('S', s_score), ('U', u_score), ('P', p_score), ('E', e_score), ('R', r_score)]:
        status = '✅' if sc >= 4 else ('⚠️' if sc >= 3 else '❌')
        md.append(f'| {dim} | {sc} / 5 | ≥ 4 | {status} |')
    md.append('')
    md.append('## 详解')
    md.append('')
    md.append('| 维度 | 含义 | 反模式 |')
    md.append('|------|------|--------|')
    md.append('| S | Single Purpose | 超大文件（> 500 行）|')
    md.append('| U | Unidirectional Flow | Impl 调 Impl / Controller 调 Mapper |')
    md.append('| P | Ports over Implementation | 缺少 OpenFeign Client |')
    md.append('| E | Environment-Agnostic | 硬编码 IP / 端口 / 密码 |')
    md.append('| R | Replaceable Parts | 缺少 Fallback / Client 接口 |')
    md.append('')
    md.append('## 修复建议')
    md.append('')
    if s_score < 5:
        md.append(f'- **S** 维度低：把 > 500 行的 Service 拆成 2-3 个，按职责切')
    if u_score < 5:
        md.append(f'- **U** 维度低：禁止 Controller 直接 @Autowired Mapper；禁止 Impl 互相 import')
    if p_score < 5:
        md.append(f'- **P** 维度低：跨服务调用必须用 OpenFeign Client 接口隔离')
    if e_score < 5:
        md.append(f'- **E** 维度低：所有连接信息走环境变量 `${{VAR_NAME}}`，禁止硬编码')
    if r_score < 5:
        md.append(f'- **R** 维度低：所有 OpenFeign 必须有 Fallback；Service 接口要可注入')
    md.append('')
    import os
    os.makedirs(os.path.dirname(output) or '.', exist_ok=True)
    with open(output, 'w', encoding='utf-8') as f:
        f.write('\n'.join(md))
    print(f'  [OK] 写入 {output}')

sys.exit(rc)
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
