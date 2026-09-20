#!/usr/bin/env bash
# ============================================================
# generate-permission-matrix.sh (v3.0 - skill-grade)
# ------------------------------------------------------------
# 用途：从任意项目的代码（默认 Java Spring 的 @PreAuthorize）中
#       自动抽取权限码 → 生成/刷新 docs/<DOC_DIR>/_权限矩阵.md
#
# 数据源（可通过环境变量覆盖）：
#   CONTROLLER_GLOB  默认 backend/*/src/main/java/**/*.java
#   DOC_DIR          默认 docs/detailed-design
#   OUTPUT_FILE      默认 ${DOC_DIR}/_权限矩阵.md
#
# 占位符（javadoc 内允许残留）：xxx / xxx:yyy:zzz / 具体权限码
# ============================================================
set -uo pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
CONTROLLER_GLOB="${CONTROLLER_GLOB:-backend/*/src/main/java/**/*.java}"
# v3.22.0: 默认目录中文化；历史英文目录已存在且未显式指定 DOC_DIR 时沿用
if [ -n "${DOC_DIR:-}" ]; then :; elif [ -d "docs/detailed-design" ] && [ ! -d "docs/详细设计" ]; then DOC_DIR="docs/detailed-design"; else DOC_DIR="docs/详细设计"; fi
OUTPUT_FILE="${OUTPUT_FILE:-${DOC_DIR}/_权限矩阵.md}"
PLACEHOLDER_REGEX="xxx|xxx:yyy:zzz|具体权限码"

DRY_RUN=0; DIFF_MODE=0; SECTION_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --diff) DIFF_MODE=1 ;;
    --section-only) SECTION_ONLY=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "[ERR] unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "============================================="
echo "  生成 _权限矩阵.md §2 全清单"
echo "============================================="
echo "数据源   : ${CONTROLLER_GLOB}"
echo "输出文件 : ${OUTPUT_FILE}"
echo "时戳     : $(date +%Y%m%d_%H%M%S)"
echo

mkdir -p "$(dirname "$OUTPUT_FILE")"
export CONTROLLER_GLOB OUTPUT_FILE DOC_DIR PLACEHOLDER_REGEX DRY_RUN DIFF_MODE SECTION_ONLY

"${DEVFLOW_PY[@]}" << 'PYEOF'
import os, re, sys, glob, collections

controller_glob = os.environ.get('CONTROLLER_GLOB', 'backend/*/src/main/java/**/*.java')
# v3.22.0: 默认输出目录中文化（DOC_DIR 已由外层 shell 按中英存在性选定）
output_file     = os.environ.get('OUTPUT_FILE', os.environ.get('DOC_DIR', 'docs/详细设计') + '/_权限矩阵.md')
placeholder_rx  = os.environ.get('PLACEHOLDER_REGEX', 'xxx|xxx:yyy:zzz|具体权限码')
dry_run         = int(os.environ.get('DRY_RUN', '0'))
diff_mode       = int(os.environ.get('DIFF_MODE', '0'))
section_only    = int(os.environ.get('SECTION_ONLY', '0'))

placeholder_set = set(placeholder_rx.split('|'))

# ---------- 1) 扫描 ----------
ph_count = 0
real_perms = set()
ctrl_count = 0
ctrl_with_auth = 0
service_role_count = 0

files = glob.glob(controller_glob, recursive=True)
for f in files:
    try:
        c = open(f, encoding='utf-8', errors='ignore').read()
    except Exception:
        continue
    is_controller = f.endswith('Controller.java')
    if is_controller:
        ctrl_count += 1
        if '@PreAuthorize' in c:
            ctrl_with_auth += 1
    if "hasRole('SERVICE')" in c or 'hasRole("SERVICE")' in c:
        service_role_count += 1
    for m in re.finditer(r"hasAuthority\(['\"]([^'\"]+)['\"]\)", c):
        p = m.group(1)
        if p in placeholder_set:
            ph_count += 1
        else:
            real_perms.add(p)

perms = sorted(real_perms)
total = len(perms)
mods = collections.OrderedDict()
for p in perms:
    mod = p.split(':', 1)[0]
    mods.setdefault(mod, []).append(p)
mod_cnt = len(mods)

print(f"占位符残留：{ph_count}（仅允许在 javadoc 注释内）")
print(f"抽取到 {total} 个 unique 权限码")
print()

if dry_run:
    print("=== 各模块权限码分布 ===")
    for m, lst in mods.items():
        print(f"  {len(lst):3d}  {m}")
    print()
    print("[--dry-run] 模式：仅统计，未写入文件")
    sys.exit(0)

# ---------- 2) diff ----------
if diff_mode and os.path.exists(output_file):
    print(f"=== 与现有 {output_file} 对比 ===")
    doc_perms = set()
    rx_perm = re.compile(r"`([a-zA-Z][\w-]*:[a-zA-Z][\w-]*:[a-zA-Z][\w-]*)`")
    with open(output_file, encoding='utf-8') as f:
        for m in rx_perm.finditer(f.read()):
            p = m.group(1)
            if p not in placeholder_set:
                doc_perms.add(p)
    missing = sorted(doc_perms - set(perms))
    new = sorted(set(perms) - doc_perms)
    print(f"文档中但代码未实现：{len(missing)} 个")
    for p in missing[:10]:
        print(f"  - {p}")
    print(f"代码中但文档未列：{len(new)} 个")
    for p in new[:20]:
        print(f"  + {p}")
    sys.exit(0)

# ---------- 3) 生成 §2 内容 ----------
section = []
section.append("## 2. 权限码全清单（按模块）")
section.append("")
section.append("> **本节自动生成**（`scripts/generate-permission-matrix.sh`）")
section.append(f"> **共 {total} 个权限码**，按模块分组。")
section.append("")
seq = 0
for m, lst in mods.items():
    seq += 1
    section.append(f"### 2.{seq} `{m}` 模块（{len(lst)} 个）")
    section.append("")
    section.append("| 权限码 | 用途 |")
    section.append("|---|---|")
    for p in lst:
        section.append(f"| `{p}` | （待人工补充） |")
    section.append("")

section_text = "\n".join(section)

if section_only:
    sys.stdout.write(section_text)
    sys.exit(0)

# ---------- 4) 拼装完整 doc ----------
coverage_pct = (ctrl_with_auth * 100 // ctrl_count) if ctrl_count > 0 else 0
doc = []
doc.append("# 权限矩阵（Permission Matrix）")
doc.append("")
doc.append("> ")
doc.append("> **生成脚本**：`scripts/generate-permission-matrix.sh`")
doc.append(f"> **数据源**：`{controller_glob}` 的 `@PreAuthorize hasAuthority`")
doc.append("> **占位符**：`xxx` / `xxx:yyy:zzz` / `具体权限码`（javadoc 注释内残留，不计）")
doc.append("")
doc.append("---")
doc.append("")
doc.append("## 0. 速览")
doc.append("")
doc.append("| 维度 | 数量 |")
doc.append("|---|---:|")
doc.append(f"| 权限码总数（不含占位符） | {total} |")
doc.append(f"| 模块数 | {mod_cnt} |")
doc.append(f"| 含 `@PreAuthorize` 的 Controller | {ctrl_with_auth} / {ctrl_count} ({coverage_pct}%) |")
doc.append(f"| 占位符残留（javadoc 内允许） | {ph_count} |")
if service_role_count > 0:
    doc.append(f"| 服务间白名单（`hasRole('SERVICE')`） | {service_role_count} 个内部接口 |")
doc.append("")
doc.append("---")
doc.append("")
doc.append("## 1. 权限码命名规范")
doc.append("")
doc.append("### 1.1 三段格式（推荐）")
doc.append("")
doc.append("```")
doc.append("{module}:{resource}:{action}")
doc.append("```")
doc.append("")
doc.append("| 段位 | 取值约定 | 说明 |")
doc.append("|---|---|---|")
doc.append("| 模块 | 业务模块英文小写 | 与代码扫描结果一致 |")
doc.append("| 资源 | 资源对象英文小写 | 与业务对象对应 |")
doc.append("| 动作 | 标准动词（见 §1.2） | 操作类型 |")
doc.append("")
doc.append("### 1.2 标准动作清单")
doc.append("")
doc.append("```")
doc.append("view / list / add / create / edit / update / delete / remove")
doc.append("toggle / enable / disable / export / import / audit")
doc.append("reset / resetPwd / unlock / lock")
doc.append("assign / reassign / transfer / delegate / claim / unclaim")
doc.append("approve / reject / complete / start / stop / cancel / suspend / resume / terminate")
doc.append("deploy / undeploy / publish / jump / withdraw / route / run / execute / invoke")
doc.append("evaluate / decide / inspect / scan / calibrate / merge / decouple")
doc.append("```")
doc.append("")
doc.append("### 1.3 命名规则（推荐）")
doc.append("")
doc.append("| 模式 | 范例 | 用途 |")
doc.append("|---|---|---|")
doc.append("| `{module}:{resource}:{sub}:{action}` | `xx:res:sub:view` | 三层嵌套（子资源） |")
doc.append("| `{module}:{resource}:{action1}{Action2}` | `xx:res:saveDraft` | 双驼峰动作 |")
doc.append("| `{module}:{resource}:{action}` | `xx:res:view` | 二段标准 |")
doc.append("")
doc.append("> 命名规则由团队在 §1 顶部扩展；本脚本只负责扫描和生成 §2。")
doc.append("")
doc.append("---")
doc.append("")
doc.append(section_text)
doc.append("---")
doc.append("")
doc.append("## 3. 校验脚本")
doc.append("")
doc.append("| 校验 | 脚本 |")
doc.append("|---|---|")
doc.append("| 完整 Gate | `bash \"$SKILL_ROOT/scripts/p4_prd_vs_code.sh\" <feature> --prd ... --design ... --criteria ... --evidence ... --service ...` |")
doc.append("| 权限码一致性 | `bash \"$SKILL_ROOT/checks/check-permission-consistency.sh\"` |")
doc.append("| 占位符剔除 | `bash \"$SKILL_ROOT/scripts/s2_design_coverage_gate.sh\" <design> <criteria>` |")
doc.append("| CI 友好一致性 | `bash \"$SKILL_ROOT/checks/check-permission-consistency.sh\"` |")
doc.append("")
doc.append("```bash")
doc.append("# 重新生成")
doc.append("bash \"$SKILL_ROOT/scripts/generate-permission-matrix.sh\"")
doc.append("")
doc.append("# 仅统计")
doc.append("bash \"$SKILL_ROOT/scripts/generate-permission-matrix.sh\" --dry-run")
doc.append("")
doc.append("# 与现有 doc 对比")
doc.append("bash \"$SKILL_ROOT/scripts/generate-permission-matrix.sh\" --diff")
doc.append("```")
doc.append("")
doc.append("---")
doc.append("")
doc.append("## 4. 联动索引")
doc.append("")
doc.append("| 文档 | 路径 | 关系 |")
doc.append("|---|---|---|")
doc.append("| 工程公约 | `./_commons.md` | 错误码/公共字段/缓存/幂等 |")
doc.append("| 接口清单 | `./INDEX-接口.md` | 详设期望的接口 |")
doc.append("| 章节锚点 | `./INDEX-章节锚点.md` | 详设 ↔ P4b 脚本匹配 |")
doc.append("| 环境账号 | `./_环境与账号.md` | 服务端口/数据库账号 |")
doc.append("| 菜单 Seed | `./_菜单Seed索引.md` | 前端菜单 ↔ 后端 seed |")
doc.append("| ER 图索引 | `./_ER图索引.md` | 表结构 × 跨服务外键 |")
doc.append("| Schema 变更日志 | `./_Schema变更日志.md` | Flyway 版本时序 |")
doc.append("")
doc.append("---")
doc.append("")
doc.append("> **自动生成，勿手编 §2**（动作列可手编）。如需手编全文，请保留 §0～§4 章节结构。")
doc.append("")

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

_atomic_write(output_file, "\n".join(doc))

print(f"[OK] 已写入 {output_file}")
print(f"§2 全清单：{total} 个权限码 / {mod_cnt} 个模块")
print()
print("提示：人工补充 §2 各权限码的「用途」列描述")
print("  重新生成会覆盖 §2（可用 --diff 对比）")
PYEOF
# v3.15.19: 显式 rc 终验（与 er-index/schema-changelog 同口径）——隐式依赖
# "python 为末命令"传播 rc 在末尾追加命令时即静默破坏（fail-loud 显式化）。
# 非空检查仅默认写文件模式（--dry-run 仅统计/--diff 仅对比/--section-only 仅输出
# §2 到 stdout，三者均不写产物）
GEN_RC=$?
if [ "$GEN_RC" -ne 0 ]; then
  echo "[FAIL] Python 生成失败（rc=${GEN_RC}）: ${OUTPUT_FILE}" >&2
  exit 1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$DIFF_MODE" -eq 0 ] && [ "$SECTION_ONLY" -eq 0 ] && [ ! -s "$OUTPUT_FILE" ]; then
  echo "[FAIL] 产物未生成或为空: ${OUTPUT_FILE}" >&2
  exit 1
fi
