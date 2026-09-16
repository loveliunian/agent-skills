#!/usr/bin/env bash
# generate-er-index.sh (v3.0 - skill-grade)
# 用途：扫描 backend/*/src/main/resources/db/migration 下的 Flyway 4 方言脚本
#       提取所有 CREATE TABLE 与 FOREIGN KEY 引用，按服务 × 模块分组输出 ER 索引。
# 输出：docs/详细设计/_ER图索引.md（兼容历史英文目录）
# 风格：与 generate-permission-matrix.sh / p4_prd_vs_code.sh 保持一致

set -uo pipefail

# ---------- v3.0 参数化 ----------
# v3.22.0: 默认目录中文化；历史英文目录已存在且未显式指定 DOC_DIR 时沿用
if [ -n "${DOC_DIR:-}" ]; then :; elif [ -d "docs/detailed-design" ] && [ ! -d "docs/详细设计" ]; then DOC_DIR="docs/detailed-design"; else DOC_DIR="docs/详细设计"; fi
OUTPUT_FILE="${OUTPUT_FILE:-${DOC_DIR}/_ER图索引.md}"

# v3.0: keep caller cwd (caller run in project root)

# 颜色
GREEN='\033[32m'
RED='\033[31m'
YELLOW='\033[33m'
NC='\033[0m'

ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; }

OUTPUT="$OUTPUT_FILE"
# v3.15.16: 输出目录自动创建（与 permission-matrix/postmortem 同惯例）——直接调用
# 且 docs/detailed-design 缺失时不再报 Python Traceback（fail-loud 但提示不清）
mkdir -p "$(dirname "$OUTPUT_FILE")"
TMP_JSON=$(mktemp -t er-index.XXXXXX.json)
trap 'rm -f "$TMP_JSON"' EXIT

# ----------------------------------------------------------------
# 1) Python 一次性扫描 4 方言 Flyway 脚本，输出 JSON
#    - 主源：h2（开发默认）
#    - 也扫 postgresql / oracle / kingbase 补充（防止 h2 缺而生产有）
# ----------------------------------------------------------------
ok "扫描 backend/*/src/main/resources/db/migration/*/*.sql ..."

python3 - "$TMP_JSON" <<'PYEOF'
import re, os, json, glob, collections, sys

out_file = sys.argv[1]

# 表/字段提取（多行匹配：FOREIGN KEY / REFERENCES 可能跨行）
CREATE_RE = re.compile(
    r"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?([A-Za-z_][A-Za-z0-9_]*)", re.IGNORECASE
)
# 在 join 后用单行扫描（FK 多行逐行 join）
# 多行版本：贪心找到 FOREIGN KEY (col1, col2) 后面 REFERENCES tbl
FK_RE = re.compile(
    r"FOREIGN\s+KEY\s*\(\s*([A-Za-z0-9_, ]+?)\s*\)\s*REFERENCES\s+([A-Za-z_][A-Za-z0-9_]*)",
    re.IGNORECASE,
)

# 服务路径检测：backend/<service>/src/main/resources/db/migration/<dialect>/...
DIALECTS = ("h2", "postgresql", "oracle", "kingbase")

# service -> { tables:set(h2-only), all_tables:set(4方言全集), from_fks:[], files:[], dialect_files:dict }
services = collections.defaultdict(lambda: {
    "tables": set(),
    "all_tables": set(),
    "from_fks": [],
    "files": [],
    "dialect_files": collections.defaultdict(int),
})

# 优先顺序：h2 > postgresql > oracle > kingbase（确保主表用 h2）
for dialect in DIALECTS:
    files = sorted(glob.glob(f"backend/*/src/main/resources/db/migration/{dialect}/**/*.sql", recursive=True))
    for f in files:
        # 解析 service 名
        parts = f.split("/")
        if len(parts) < 2:
            continue
        service = parts[1]
        try:
            content = open(f, encoding="utf-8").read()
        except Exception:
            continue
        services[service]["files"].append(f)
        services[service]["dialect_files"][dialect] += 1
        # 提取 CREATE TABLE（tables 只装 h2 作为主源；all_tables 装 4 方言全集）
        for m in CREATE_RE.finditer(content):
            tbl = m.group(1).lower()
            if dialect == "h2":
                services[service]["tables"].add(tbl)
            services[service]["all_tables"].add(tbl)
        # 提取外键：先把多行 FK 合并为单行
        # 简单策略：去掉换行再做正则
        flat = re.sub(r"\s+", " ", content)
        for m in FK_RE.finditer(flat):
            from_cols_raw = m.group(1)
            to_table = m.group(2).lower()
            from_cols = [c.strip().lower() for c in from_cols_raw.split(",")]
            services[service]["from_fks"].append((from_cols, to_table, dialect))

# 跨服务外键：扫描每个服务的 to_table 是否在其它服务也定义或同服务定义
# 注意：4 方言以 h2 为主源，但 postgresql/oracle/kingbase 可能补建 h2 缺的表
all_services = list(services.keys())
service_to_tables = {s: services[s]["tables"] for s in all_services}
table_to_service = {}
for s, tbls in service_to_tables.items():
    for t in tbls:
        if t not in table_to_service:
            table_to_service[t] = s
        else:
            # 表被多个服务定义（少见）
            table_to_service[t] = f"{table_to_service[t]}|{s}"

# 注意：all_tables 已在前面扫描时累加（4 方言全集），无需再次构建
# 但要确保排序后的 list 形式（result 序列化需要可序列化）
for s in all_services:
    services[s]["all_tables"] = sorted(services[s]["all_tables"])

# 跨服务：先看 h2，再看其它方言
cross_service_fks = collections.Counter()
dialect_diff_fks = collections.Counter()
# 计算 h2 缺哪些表（4 方言合集 - h2）
h2_tables = set()
for s in all_services:
    h2_tables |= services[s]["tables"]
other_dialect_tables = set()
for s in all_services:
    other_dialect_tables |= set(services[s]["all_tables"])
h2_only_dialect_diff = other_dialect_tables - h2_tables

for s in all_services:
    for from_cols, to_table, dialect in services[s]["from_fks"]:
        to_table_lower = to_table.lower()
        owner = None
        if to_table_lower in table_to_service:
            owner = table_to_service[to_table_lower].split("|")[0]
        if owner is None:
            for other_s in all_services:
                if to_table_lower in [t.lower() for t in services[other_s]["all_tables"]]:
                    owner = other_s
                    break
        if owner is None:
            dialect_diff_fks[(s, to_table, "+".join(from_cols))] += 1
        elif owner != s:
            key = (s, owner, to_table, "+".join(from_cols))
            cross_service_fks[key] += 1

# 还要把"h2 缺表"也加入 dialect_diff（不只是 FK 找不到）
for tbl in h2_only_dialect_diff:
    # 查找这个表在哪个服务/方言被定义
    found_in = []
    for s in all_services:
        for d in DIALECTS:
            if d == "h2":
                continue
            for f in glob.glob(f"backend/{s}/src/main/resources/db/migration/{d}/**/*.sql", recursive=True):
                try:
                    c = open(f, encoding="utf-8", errors="ignore").read()
                except Exception:
                    continue
                if re.search(rf"CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?{re.escape(tbl)}\b", c, re.IGNORECASE):
                    found_in.append((s, d))
                    break
    if found_in:
        # 用第一个匹配服务作为 from，标记为 "缺 h2"
        from_s = found_in[0][0]
        dialect_diff_fks[(from_s, tbl, "<h2-缺失>")] += 1

# 序列化
result = {
    "services": {
        s: {
            "tables": sorted(services[s]["tables"]),
            "dialect_files": dict(services[s]["dialect_files"]),
            "file_count": len(services[s]["files"]),
        }
        for s in all_services
    },
    "cross_service_fks": [
        {"from": s, "to": t, "table": tbl, "cols": cols, "occurrences": occ}
        for (s, t, tbl, cols), occ in cross_service_fks.most_common()
    ],
    "dialect_diff_fks": [
        {"from": s, "table": tbl, "cols": cols, "occurrences": occ}
        for (s, tbl, cols), occ in dialect_diff_fks.most_common()
    ],
    "dialect_summary": {
        s: {
            "h2": len([t for t in services[s]["all_tables"] if True]),  # placeholder
        }
        for s in all_services
    },
}
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

print(f"[Python] scanned {len(all_services)} services, {sum(len(services[s]['tables']) for s in all_services)} tables, {len(cross_service_fks)} cross-service FKs")
print(f"[Python] output -> {out_file}")
PYEOF

# v3.15.14: -f → -s（mktemp 预创建空文件使 [ ! -f ] 恒假死代码；python 失败时
# TMP_JSON 保持空，-s 才能真实拦截）
if [ ! -s "$TMP_JSON" ]; then
  err "Python 扫描失败，${TMP_JSON} 为空或未生成"
  exit 1
fi

# ----------------------------------------------------------------
# 2) 读取 JSON → 生成 markdown
# ----------------------------------------------------------------
ok "生成 $OUTPUT ..."

python3 - "$TMP_JSON" "$OUTPUT" <<'PYEOF'
import json, os, sys, datetime, collections
src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src, encoding="utf-8"))

services = data["services"]
cross_fks = data["cross_service_fks"]
dialect_diff = data.get("dialect_diff_fks", [])

# 排序服务
sorted_services = sorted(services.keys())

total_tables = sum(len(services[s]["tables"]) for s in sorted_services)
total_dialect_files = sum(sum(services[s]["dialect_files"].values()) for s in sorted_services)

# 按服务汇总表数
table_counts = collections.OrderedDict()
for s in sorted_services:
    table_counts[s] = len(services[s]["tables"])

# 跨服务外键按 (from, to) 分组
cross_grouped = collections.OrderedDict()
for fk in cross_fks:
    key = (fk["from"], fk["to"])
    cross_grouped.setdefault(key, []).append(fk)

ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# 渲染 markdown
md = []
md.append("# ER 图索引（Entity-Relationship Diagram Index）")
md.append("")
md.append(f"> **auto-generated · {ts}**")
md.append("> **目的**：把全平台业务表按服务 × 模块分组 + 跨服务外键关系汇总到单一事实源")
md.append("> **生成脚本**：`scripts/generate-er-index.sh`")
md.append("> **数据源**：`backend/*/src/main/resources/db/migration/{h2,postgresql,oracle,kingbase}/**/*.sql`")
md.append("> **解析方式**：正则 `CREATE TABLE` + `FOREIGN KEY ... REFERENCES`")
md.append("")
md.append("---")
md.append("")
md.append("## 0. 速览")
md.append("")
md.append("| 维度 | 数量 |")
md.append("|---|---:|")
md.append(f"| 服务（含 Flyway 脚本） | **{len(sorted_services)}** |")
md.append(f"| 业务表（合并 4 方言去重） | **{total_tables}** |")
md.append(f"| 跨服务外键关系（distinct (from,to,table,cols)） | **{len(cross_fks)}** |")
md.append(f"| 跨方言外键差异（h2 缺表，但 postgresql/oracle/kingbase 中存在） | **{len(dialect_diff)}** |")
md.append(f"| Flyway 脚本总数（4 方言合计） | **{total_dialect_files}** |")
md.append("")
md.append("### 0.1 服务 × 表数")
md.append("")
md.append("| 服务 | 表数 | 主要职责 |")
md.append("|---|---:|---|")
for s in sorted_services:
    cnt = table_counts[s]
    role = "由项目工程事实源定义"
    md.append(f"| {s} | **{cnt}** | {role} |")
md.append("")
md.append("---")
md.append("")

# 1. 各服务表清单
md.append("## 1. 各服务表清单")
md.append("")
for s in sorted_services:
    info = services[s]
    tables = info["tables"]
    md.append(f"### 1.{sorted_services.index(s) + 1} {s}（{len(tables)} 张）")
    md.append("")
    md.append(f"> Flyway 脚本：{info['file_count']} 个文件")
    df = info["dialect_files"]
    md.append(f"> 方言覆盖：h2={df.get('h2', 0)} postgresql={df.get('postgresql', 0)} oracle={df.get('oracle', 0)} kingbase={df.get('kingbase', 0)}")
    md.append("")
    if not tables:
        md.append("> （无表）")
    else:
        # 按表前缀分组
        by_prefix = collections.defaultdict(list)
        for t in tables:
            # 提取前缀：第一段下划线前
            prefix = t.split("_")[0] if "_" in t else t
            by_prefix[prefix].append(t)
        for prefix in sorted(by_prefix.keys()):
            md.append(f"**{prefix}_*** ({len(by_prefix[prefix])} 张)")
            md.append("")
            cols = 4
            tlist = sorted(by_prefix[prefix])
            for i in range(0, len(tlist), cols):
                row = tlist[i:i + cols]
                md.append("  - " + " · ".join(f"`{t}`" for t in row))
            md.append("")
    md.append("")

md.append("---")
md.append("")

# 2. 跨服务外键关系
md.append("## 2. 跨服务外键关系（Top 30）")
md.append("")
md.append("> 同一服务内的外键不计入；只展示 `from_service != to_service` 的引用")
md.append("")
if not cross_fks:
    md.append("> （无跨服务外键）")
else:
    md.append("| # | 从服务 | 引用表 | 字段 | 被引用服务 | 出现次数 |")
    md.append("|---:|---|---|---|---|---:|")
    for i, fk in enumerate(cross_fks[:30], 1):
        md.append(f"| {i} | {fk['from']} | `{fk['table']}` | {fk['cols']} | {fk['to']} | {fk['occurrences']} |")
md.append("")
md.append("---")
md.append("")

# 2.5 跨方言外键差异（h2 缺表，但 postgresql/oracle/kingbase 中存在）
md.append("## 2.5 跨方言外键差异")
md.append("")
md.append("> 这些是 **h2 方言下找不到对应建表脚本** 的 FK 引用，说明 h2 缺表 / 缺同步")
md.append("> **必须修复**：把缺的 CREATE TABLE 同步到 h2 方言（dev 环境的 h2 才会启动顺利）")
md.append("")
if not dialect_diff:
    md.append("> （无跨方言差异）")
else:
    md.append("| # | 从服务 | 引用表 | 字段 | 出现次数 | 修复方式 |")
    md.append("|---:|---|---|---|---:|---|")
    for i, fk in enumerate(dialect_diff[:30], 1):
        cols = fk["cols"]
        cols_display = "（整表缺失）" if cols == "<h2-缺失>" else cols
        md.append(f"| {i} | {fk['from']} | `{fk['table']}` | {cols_display} | {fk['occurrences']} | 从 postgresql/oracle 复制 CREATE TABLE 到 h2 |")
md.append("")
md.append("---")
md.append("")

# 3. 跨服务关系分组（按 from→to 聚合）
md.append("## 3. 跨服务关系按 (from,to) 聚合")
md.append("")
md.append("| # | from → to | 表数 | 表 |")
md.append("|---:|---|---:|---|")
for i, (key, items) in enumerate(cross_grouped.items(), 1):
    f, t = key
    tables_in_group = sorted(set(it["table"] for it in items))
    md.append(f"| {i} | {f} → {t} | {len(tables_in_group)} | {', '.join(f'`{tn}`' for tn in tables_in_group[:5])}{'...' if len(tables_in_group) > 5 else ''} |")
md.append("")
md.append("---")
md.append("")

# 4. 维护说明
md.append("## 4. 维护说明")
md.append("")
md.append("### 4.1 何时重新生成")
md.append("")
md.append("以下情况**必须重新生成** ER 索引：")
md.append("")
md.append("1. **新增表**：任何 `V*_*.sql` 文件中新增 `CREATE TABLE`")
md.append("2. **新增跨服务外键**：A 服务引用 B 服务表中某字段")
md.append("3. **新增 Flyway 方言**：例如将来引入 mysql 5th 方言")
md.append("4. **删表 / 退表**：迁移脚本中 `DROP TABLE`")
md.append("")
md.append("### 4.2 重新生成命令")
md.append("")
md.append("```bash")
md.append('bash "$SKILL_ROOT/scripts/generate-er-index.sh"')
md.append("```")
md.append("")
md.append("### 4.3 已知约束")
md.append("")
md.append("1. **主表用 h2**：4 方言以 h2 为主源，postgresql/oracle/kingbase 补充")
md.append("2. **同表多服务**：用 `|` 分隔所属服务（极少见）")
md.append("3. **未声明外键但逻辑引用**：本索引不捕获（如 sys_user_id 用 BIGINT 但无 FK）")
md.append("4. **Camunda 引擎表**：包含在 workflow-service 统计中，不在前缀分组")
md.append("")
md.append("---")
md.append("")
md.append("> 自动生成，勿手编。如需手编，请保留 §0～§4 章节结构，并在文末追加 `## 5. 人工备注`。")
md.append("")

# 写回
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

_atomic_write(dst, "\n".join(md))
print(f"[Python] _ER图索引.md 生成完成：{dst}")
PYEOF
# v3.15.13: 第二段 python 与第一段同口径防护——rc + 产物终验（防 python3 失败时假绿）
ER_RC=$?
if [ "$ER_RC" -ne 0 ] || [ ! -s "$OUTPUT" ]; then
  err "Python 渲染失败（rc=${ER_RC}）或输出未生成: ${OUTPUT}"
  exit 1
fi

ok "完成。输出：$OUTPUT"
