#!/usr/bin/env bash
# ============================================================
# check-entity-db-consistency.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：扫 Java Entity + MyBatis Mapper 与 Flyway DDL 一致性【咨询工具：仅输出报告，不改变退出码】
# 实际行为：
#   1. Entity 字段 ↔ DDL 字段一致性报告
#   2. 方言 SQL 覆盖统计
#   注：硬门禁由 p4_prd_vs_code（四方言表集合）与 p3 gates 承担；本脚本恒 exit 0
#
# 用法：
#   bash "$SKILL_ROOT/checks/check-entity-db-consistency.sh"
# ============================================================

set -uo pipefail

JAVA_GLOB="${JAVA_GLOB:-backend/*/src/main/java/**/entity/*.java}"
SQL_GLOB="${SQL_GLOB:-backend/*/src/main/resources/db/migration/h2/**/*.sql}"
DIALECTS="${DIALECTS:-h2 postgresql oracle kingbase}"

GREEN='\033[32m'; RED='\033[31m'; YELLOW='\033[33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[FAIL]${NC} $*"; }

echo "============================================="
echo "  Entity ↔ DDL 一致性检查"
echo "============================================="
echo "Java  glob: $JAVA_GLOB"
echo "SQL   glob: $SQL_GLOB"
echo "方言: $DIALECTS"
echo

python3 - "$JAVA_GLOB" "$SQL_GLOB" "$DIALECTS" <<'PYEOF'
import os, sys, re, glob

java_glob = sys.argv[1]
sql_glob = sys.argv[2]
dialects = sys.argv[3].split()

# 1) 抽取 Entity @TableName + 字段
entities = {}  # name -> {fields:set, table:str}
for f in glob.glob(java_glob, recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    # @TableName("xxx")（MyBatis-Plus）或 @Table(name="xxx") / @Table("xxx")（JPA）
    # v3.26.0: 补 JPA @Table 支持——phases/03 模板即 JPA 栈，旧版只认 @TableName，
    # JPA 实体全部跳过（Entity 数恒偏小，一致性报告失真）。
    m = re.search(r'@TableName\s*\(["\']([^"\']+)["\']', c)
    if not m:
        m = re.search(r'@Table\s*\(\s*(?:name\s*=\s*)?["\']([^"\']+)["\']', c)
    if not m:
        continue
    table = m.group(1).lower()
    # 字段：private Type name;
    fields = set()
    for fm in re.finditer(r'private\s+[\w<>,\s]+?\s+(\w+)\s*[=;]', c):
        fields.add(fm.group(1).lower())
    base = os.path.basename(f).replace('.java', '').lower()
    entities[table] = {'file': f, 'fields': fields, 'class': base}

# 2) 抽取 DDL CREATE TABLE
tables = {}  # table -> {fields:set, file:str}
# v3.26.0: 过滤约束关键字行——PRIMARY KEY / CONSTRAINT / FOREIGN KEY / INDEX 等
# 行首词曾被当作字段名（"primary"/"constraint" 混入 diff，纯噪音）。
_constraint_words = {'primary', 'key', 'constraint', 'unique', 'foreign',
                     'check', 'index', 'create', 'using', 'on', 'exclude', 'like'}
for f in glob.glob(sql_glob, recursive=True):
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    # 简化：CREATE TABLE name ( ... );
    # v3.26.0（回归修复）: fields 解析必须在 CREATE TABLE 匹配循环内——此前缩进
    # 漂移导致每个文件只记录最后一个匹配表（多表项目报告失真，test-dev-hardening 钉住）。
    for m in re.finditer(r'CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?(\w+)\s*\(([^;]*)\)', c, re.IGNORECASE | re.DOTALL):
        table = m.group(1).lower()
        body = m.group(2)
        fields = set()
        for fm in re.finditer(r'^\s*(\w+)\s+', body, re.MULTILINE):
            if fm.group(1).lower() in _constraint_words:
                continue
            fields.add(fm.group(1).lower())
        if table not in tables:
            tables[table] = {'fields': fields, 'file': f}

# 3) 交叉对比
print(f'  Entity 数: {len(entities)}')
print(f'  DDL 表数: {len(tables)}')
print()

missing_in_db = []
missing_in_entity = []
for t, info in entities.items():
    if t not in tables:
        missing_in_db.append(t)
        continue
    db_fields = tables[t]['fields']
    ef = {f for f in info['fields'] if f not in ('serialversionuid', 'log', 'this')}
    diff_db = ef - db_fields
    diff_entity = db_fields - ef
    if diff_db:
        missing_in_db.append((t, diff_db))
    if diff_entity:
        missing_in_entity.append((t, diff_entity))

if missing_in_db:
    print(f'  [WARN] Entity 字段不在 DDL：')
    for item in missing_in_db[:5]:
        if isinstance(item, tuple):
            print(f'    {item[0]}: {item[1]}')
        else:
            print(f'    Entity {item} 找不到 DDL 表')
    print()

if missing_in_entity:
    print(f'  [WARN] DDL 字段不在 Entity：')
    for t, fields in missing_in_entity[:5]:
        print(f'    {t}: {fields}')
    print()

# 4) 4 方言 DDL 覆盖
print(f'  方言覆盖检查（主源 h2）')
for d in dialects:
    n = len(glob.glob(f'backend/*/src/main/resources/db/migration/{d}/**/*.sql', recursive=True))
    print(f'    {d}: {n} 个 SQL')

# 5) 退出
if missing_in_db or missing_in_entity:
    print(f'\n[WARN] 存在差异，请检查 (entity={len(entities)}, db={len(tables)})')
    sys.exit(0)
else:
    print(f'\n[OK] 全部一致')
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
