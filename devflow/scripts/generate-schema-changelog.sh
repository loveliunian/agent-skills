#!/usr/bin/env bash
# generate-schema-changelog.sh (v3.0 - skill-grade)
# 用途：扫描 backend/*/src/main/resources/db/migration 下 4 方言脚本
#       按服务 × 版本生成 schema 变更日志（含描述、按方言的可用性）
# 输出：docs/详细设计/_Schema变更日志.md（兼容历史英文目录）
# 风格：与 generate-er-index.sh / generate-permission-matrix.sh 保持一致

set -uo pipefail

# ---------- v3.0 参数化 ----------
# v3.22.0: 默认目录中文化；历史英文目录已存在且未显式指定 DOC_DIR 时沿用
if [ -n "${DOC_DIR:-}" ]; then :; elif [ -d "docs/detailed-design" ] && [ ! -d "docs/详细设计" ]; then DOC_DIR="docs/detailed-design"; else DOC_DIR="docs/详细设计"; fi
OUTPUT_FILE="${OUTPUT_FILE:-${DOC_DIR}/_Schema变更日志.md}"

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
TMP_JSON=$(mktemp -t schema-changelog.XXXXXX.json)
trap 'rm -f "$TMP_JSON"' EXIT

# ----------------------------------------------------------------
# 1) Python 一次性扫描
# ----------------------------------------------------------------
ok "扫描 backend/*/src/main/resources/db/migration/*/*.sql ..."

python3 - "$TMP_JSON" <<'PYEOF'
import re, os, json, glob, collections, sys

out_file = sys.argv[1]

# V<version>__<description>.sql 解析
VERSION_RE = re.compile(r"^(V\d+(?:\.\d+){0,2})(?:__\.(sql))?__(.+)\.sql$", re.IGNORECASE)
# 兼容 V1.0.0__init.sql
VERSION_RE2 = re.compile(r"^(V\d+(?:\.\d+){0,2})__(.+)\.sql$", re.IGNORECASE)
DELIVERY_RE = re.compile(r"^V\d+(?:\.\d+){0,2}\.(sql)__(.+)$", re.IGNORECASE)

DIALECTS = ("h2", "postgresql", "oracle", "kingbase")

# service -> version -> { desc:str, dialects:dict, scripts:list }
schema_log = collections.defaultdict(lambda: collections.defaultdict(lambda: {
    "desc": "",
    "dialects": {d: 0 for d in DIALECTS},
    "scripts": [],
}))

# 角色：每个服务的版本集合
service_versions = collections.defaultdict(set)

# 全部脚本
total_scripts = 0
for d in DIALECTS:
    for f in sorted(glob.glob(f"backend/*/src/main/resources/db/migration/{d}/**/*.sql", recursive=True)):
        parts = f.split("/")
        if len(parts) < 2:
            continue
        service = parts[1]
        basename = os.path.basename(f)
        # 跳过非 V 开头的（数据 seed / 文件等）
        m = VERSION_RE2.match(basename)
        if not m:
            continue
        version = m.group(1)
        desc = m.group(2)
        schema_log[service][version]["desc"] = desc
        schema_log[service][version]["dialects"][d] += 1
        schema_log[service][version]["scripts"].append(f)
        service_versions[service].add(version)
        total_scripts += 1

# 序列化
result = {
    "schema_log": {
        s: {
            v: {
                "desc": schema_log[s][v]["desc"],
                "dialects": dict(schema_log[s][v]["dialects"]),
                "script_count": sum(schema_log[s][v]["dialects"].values()),
                "scripts": sorted(schema_log[s][v]["scripts"]),
            }
            for v in sorted(schema_log[s].keys())
        }
        for s in sorted(schema_log.keys())
    },
    "summary": {
        "services": list(sorted(schema_log.keys())),
        "total_scripts": total_scripts,
    },
}
with open(out_file, "w", encoding="utf-8") as f:
    json.dump(result, f, ensure_ascii=False, indent=2)

print(f"[Python] scanned {len(schema_log)} services, {total_scripts} versioned scripts")
print(f"[Python] output -> {out_file}")
PYEOF

# v3.15.14: -f → -s（mktemp 预创建空文件使 [ ! -f ] 恒假死代码；python 失败时
# TMP_JSON 保持空，-s 才能真实拦截）
if [ ! -s "$TMP_JSON" ]; then
  err "Python 扫描失败（${TMP_JSON} 为空或未生成）"
  exit 1
fi

# ----------------------------------------------------------------
# 2) 读取 JSON → 生成 markdown
# ----------------------------------------------------------------
ok "生成 $OUTPUT ..."

python3 - "$TMP_JSON" "$OUTPUT" <<'PYEOF'
import json, os, sys, datetime, collections, re

src, dst = sys.argv[1], sys.argv[2]
data = json.load(open(src, encoding="utf-8"))

schema_log = data["schema_log"]
total_scripts = data["summary"]["total_scripts"]

DIALECTS = ("h2", "postgresql", "oracle", "kingbase")
DIALECT_EMOJI = {
    "h2": "🟢",
    "postgresql": "🐘",
    "oracle": "🔶",
    "kingbase": "🏛️",
}

# 全版本集合
all_versions = set()
for s in schema_log:
    for v in schema_log[s]:
        all_versions.add(v)
sorted_versions = sorted(all_versions, key=lambda v: [int(p) if p.isdigit() else p for p in re.split(r"[._]", v)])

# 全版本分布：version -> service -> dialects
sorted_services = sorted(schema_log.keys())

# 统计每个版本的 active 方言
def version_dialect_count(v):
    cnt = {d: 0 for d in DIALECTS}
    for s in schema_log:
        if v in schema_log[s]:
            for d in DIALECTS:
                cnt[d] += schema_log[s][v]["dialects"].get(d, 0)
    return cnt

ts = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# 渲染 markdown
md = []
md.append("# Schema 变更日志（Schema Changelog）")
md.append("")
md.append(f"> **auto-generated · {ts}**")
md.append("> **目的**：把全平台 Flyway 迁移脚本按 **服务 × 版本 × 方言** 汇总到单一事实源")
md.append("> **生成脚本**：`scripts/generate-schema-changelog.sh`")
md.append("> **数据源**：`backend/*/src/main/resources/db/migration/{h2,postgresql,oracle,kingbase}/**/*.sql`")
md.append("> **解析规则**：`V<version>__<description>.sql`")
md.append("")
md.append("---")
md.append("")
md.append("## 0. 速览")
md.append("")
md.append("| 维度 | 数量 |")
md.append("|---|---:|")
md.append(f"| 服务 | **{len(sorted_services)}** |")
md.append(f"| Flyway 版本（distinct across all services） | **{len(sorted_versions)}** |")
md.append(f"| 脚本总数（4 方言合计） | **{total_scripts}** |")
md.append("")
md.append("### 0.1 服务 × 版本数 × 脚本数")
md.append("")
md.append("| 服务 | 版本数 | 脚本数 |")
md.append("|---|---:|---:|")
for s in sorted_services:
    ver_count = len(schema_log[s])
    script_count = sum(info["script_count"] for info in schema_log[s].values())
    md.append(f"| {s} | **{ver_count}** | **{script_count}** |")
md.append("")
md.append("---")
md.append("")

# 1. 全版本按时序排列
md.append("## 1. 版本时序（全域）")
md.append("")
md.append("> 同一 Flyway 版本可能被多个服务使用")
md.append("")
md.append("| 版本 | 活跃服务 | h2 | postgresql | oracle | kingbase | 说明 |")
md.append("|---|---|---|---|---|---|---|")
for v in sorted_versions:
    services_with_v = [s for s in sorted_services if v in schema_log[s]]
    dc = version_dialect_count(v)
    # 选第一个服务的描述（同一版本应一致）
    desc = ""
    for s in services_with_v:
        desc = schema_log[s][v]["desc"]
        break
    md.append(f"| **{v}** | {', '.join(services_with_v)} | {dc['h2']} | {dc['postgresql']} | {dc['oracle']} | {dc['kingbase']} | {desc} |")
md.append("")
md.append("---")
md.append("")

# 2. 按服务 × 版本
md.append("## 2. 按服务 × 版本")
md.append("")
for s in sorted_services:
    versions = schema_log[s]
    if not versions:
        continue
    md.append(f"### 2.{sorted_services.index(s) + 1} {s}（{len(versions)} 版本）")
    md.append("")
    md.append("| 版本 | 描述 | h2 | postgresql | oracle | kingbase | 脚本数 |")
    md.append("|---|---|---|---|---|---|---:|")
    for v in sorted_versions:
        if v not in versions:
            continue
        info = versions[v]
        d = info["dialects"]
        md.append(f"| **{v}** | {info['desc']} | {d.get('h2', 0)} | {d.get('postgresql', 0)} | {d.get('oracle', 0)} | {d.get('kingbase', 0)} | {info['script_count']} |")
    md.append("")
md.append("---")
md.append("")

# 3. 跨方言偏差（缺失方言）
md.append("## 3. 跨方言偏差（缺方言的版本）")
md.append("")
md.append("> 同一服务下，V 版本在 4 方言中不齐全时列出")
md.append("")
missing_dialect = []
for s in sorted_services:
    for v in sorted_versions:
        if v not in schema_log[s]:
            continue
        d = schema_log[s][v]["dialects"]
        missing = [dd for dd in DIALECTS if d.get(dd, 0) == 0]
        if missing:
            missing_dialect.append((s, v, d, missing))

if not missing_dialect:
    md.append("> （无跨方言偏差）")
else:
    md.append(f"> 共 **{len(missing_dialect)}** 个服务-版本存在方言偏差")
    md.append("")
    md.append("| # | 服务 | 版本 | 缺失方言 | 修复方式 |")
    md.append("|---:|---|---|---|---|")
    for i, (s, v, d, missing) in enumerate(missing_dialect[:50], 1):
        miss_str = "/".join(DIALECT_EMOJI[dd] + dd for dd in missing)
        md.append(f"| {i} | {s} | {v} | {miss_str} | 复制已有方言的 {v} 脚本到缺失方言并校验 DDL 差异 |")
    if len(missing_dialect) > 50:
        md.append(f"| ... | （更多 {len(missing_dialect) - 50} 条省略） | | | |")
md.append("")
md.append("---")
md.append("")

# 4. 维护说明
md.append("## 4. 维护说明")
md.append("")
md.append("### 4.1 何时重新生成")
md.append("")
md.append("以下情况**必须重新生成** Schema 变更日志：")
md.append("")
md.append("1. **新增 Flyway 脚本**：任何 `V*_*.sql` 新增")
md.append("2. **新增方言版本**：如 oracle 之前漏发的脚本补齐")
md.append("3. **版本号回滚**：理论上不允许；允许时再生成")
md.append("4. **删除历史脚本**：理论上不允许；允许时再生成")
md.append("")
md.append("### 4.2 重新生成命令")
md.append("")
md.append('```bash')
md.append('bash "$SKILL_ROOT/scripts/generate-schema-changelog.sh"')
md.append('```')
md.append("")
md.append("### 4.3 已知约束")
md.append("")
md.append("1. **业务 seed 脚本**：形如 `V*_*.sql` 非 V 开头的文件不计入（一般为 init data）")
md.append("2. **R/U 类型脚本**：目前未实现 Flyway 回滚/修复脚本检测")
md.append("3. **Camunda 引擎**：包含在 workflow-service 统计中，不单独列")
md.append("4. **跨服务同版本**：M-01/M-02 等模块常多服务同版本号，视为 1 个版本")
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
print(f"[Python] _Schema变更日志.md 生成完成：{dst}")
PYEOF

# v3.14.0: 产物存在性校验——python 失败时不再假成功（此前 SyntaxError 被静默吞掉）
# v3.15.14: rc + 非空双终验（与 generate-er-index 同口径）——纯 [ -f ] 遇陈旧产物
# 恒放行（PoC: python 失败 + 陈旧 $OUTPUT → exit 0 假绿）
SC_RC=$?
if [ "$SC_RC" -ne 0 ] || [ ! -s "${OUTPUT}" ]; then
  echo "[FAIL] Python 渲染失败（rc=${SC_RC}）或产物为空: ${OUTPUT}（检查上方 python 报错）"; exit 1; fi

ok "完成。输出：$OUTPUT"
