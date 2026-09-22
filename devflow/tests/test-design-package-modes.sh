#!/usr/bin/env bash
# test-design-package-modes.sh · v3.24.0 设计包/三模式/适用性回归
# 覆盖体检报告：A05 设计包清单（子集并集=冻结分母、缺文档即失败、范围过滤对账）、
# A07 三模式「模板→最小合法填充→管线→Gate」完整正向（monolith 正向在
# test-design-contract-hardening.sh，本文件补 sub/total）、A06 适用性正向夹具
# （纯 UI / 消息消费者 / 小程序 / APP）。
set -u
set -o pipefail

# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/py_runtime.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
PASS=0
FAIL=0
ok() { echo "[PASS] $1"; PASS=$((PASS + 1)); }
bad() { echo "[FAIL] $1"; FAIL=$((FAIL + 1)); }
check_rc() { local expect="$1" desc="$2"; shift 2
  "$@" >/dev/null 2>&1; local rc=$?
  [ "$rc" = "$expect" ] && ok "$desc (exit=$rc)" || bad "$desc (expect=$expect got=$rc)"
}
assert_out() { local pat="$1" desc="$2"; shift 2
  local out; out=$("$@" 2>&1 || true)
  printf '%s' "$out" | grep -q "$pat" && ok "$desc" || bad "${desc}（输出未含: ${pat}）"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-pkgmodes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK" || exit 1
V="$ROOT/scripts/df_validate.py"
PKG="$ROOT/scripts/df_design_package.py"
S2="$ROOT/scripts/s2_design_coverage_gate.sh"
PI="$ROOT/scripts/df_pipeline.py"

echo "=== design package / three modes / applicability (v3.24.0) ==="

# ---------- A05：df_design_package 清单校验（单元级） ----------
mkdir -p pkg
printf '| M-01-F01-A01 | x |\n| M-01-F01-A02 | x |\n' > pkg/criteria.md
printf '# docA\n' > pkg/doc-a.md
printf '# docB\n' > pkg/doc-b.md
cat > pkg/pkg-ok.json <<'EOF'
{"feature":"f","docs":[
  {"path":"pkg/doc-a.md","mode":"sub","acceptance_ids":["M-01-F01-A01"]},
  {"path":"pkg/doc-b.md","mode":"total","acceptance_ids":["M-01-F01-A02"]}]}
EOF
cat > pkg/pkg-gap.json <<'EOF'
{"feature":"f","docs":[
  {"path":"pkg/doc-a.md","mode":"sub","acceptance_ids":["M-01-F01-A01"]}]}
EOF
cat > pkg/pkg-missing-doc.json <<'EOF'
{"feature":"f","docs":[
  {"path":"pkg/doc-a.md","mode":"sub","acceptance_ids":["M-01-F01-A01"]},
  {"path":"pkg/doc-gone.md","mode":"sub","acceptance_ids":["M-01-F01-A02"]}]}
EOF
cat > pkg/pkg-fake-id.json <<'EOF'
{"feature":"f","docs":[
  {"path":"pkg/doc-a.md","mode":"sub","acceptance_ids":["M-01-F01-A01"]},
  {"path":"pkg/doc-b.md","mode":"total","acceptance_ids":["M-09-F09-A09"]}]}
EOF
check_rc 0 "package manifest union == frozen set accepted (A05)" \
  "${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-ok.json --criteria pkg/criteria.md --doc pkg/doc-a.md
PKG_OUT=$("${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-ok.json --criteria pkg/criteria.md --doc pkg/doc-a.md)
printf '%s' "$PKG_OUT" | grep -q "SCOPE=M-01-F01-A01" && ok "current doc scope exported (A05)" || bad "scope export failed: $PKG_OUT"
check_rc 1 "package manifest current doc registered check" \
  "${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-ok.json --criteria pkg/criteria.md --doc pkg/doc-x.md
assert_out "并集" "union gap against frozen denominator rejected (A05)" \
  "${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-gap.json --criteria pkg/criteria.md --doc pkg/doc-a.md
assert_out "文档不存在" "missing registered doc rejected (A05)" \
  "${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-missing-doc.json --criteria pkg/criteria.md --doc pkg/doc-a.md
assert_out "冻结分母之外" "fabricated acceptance ID in subset rejected (A05)" \
  "${DEVFLOW_PY[@]}" "$PKG" --package pkg/pkg-fake-id.json --criteria pkg/criteria.md --doc pkg/doc-a.md

# ---------- A05：df_validate 范围过滤对账（--scope-ids） ----------
cp "$ROOT/examples/structured/design.sample.json" design.json
cp "$ROOT/examples/structured/design.skeleton.md" doc.md
cat > criteria.md <<'EOF'
| M01-F01-A01 | x |
| M01-F01-A02 | x |
| M01-F02-A01 | x |
EOF
mkdir -p docs/requirements && cp criteria.md docs/requirements/demo-pay-acceptance-criteria.md
# doc-sub.md：只保留 A01/A02 引用的对象（删掉 A03 的 §2.2.2 与 §7.1.2 小节）
"${DEVFLOW_PY[@]}" - <<'PYEOF'
import re
from pathlib import Path
t = Path("doc.md").read_text(encoding="utf-8")
t = re.sub(r"(### 2\.2\.2 退款单表（pay_refund）\n)(.*?)(## §3)", r"\1\3", t, flags=re.S)
t = re.sub(r"(### 7\.1\.2 退款页\n)(.*?)(### 7\.2\.1)", r"\1\3", t, flags=re.S)
Path("doc-sub.md").write_text(t, encoding="utf-8")
PYEOF
check_rc 1 "full reconciliation fails when doc lacks module-B sections" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-sub.md
check_rc 0 "scope-filtered reconciliation passes for the doc's own subset (A05)" \
  "${DEVFLOW_PY[@]}" "$V" --kind design --input design.json --criteria criteria.md --doc doc-sub.md \
    --scope-ids "M01-F01-A01,M01-F01-A02"

# ---------- A07/A05：sub 模式完整正向（模板拷贝→最小合法填充→管线→Gate） ----------
build_sub_fixture() { # <dir>
  local d="$1" tplv
  mkdir -p "$d/docs/需求" "$d/docs/详细设计" "$d/.devflow/subf"
  tplv=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-总分分文档-模板.md" | head -1)
  "${DEVFLOW_PY[@]}" - "$ROOT/templates/详细设计-总分分文档-模板.md" "$d/docs/详细设计/subf-详细设计.md" "$tplv" <<'PYEOF'
import re, sys
from pathlib import Path
src, dst, ver = sys.argv[1], sys.argv[2], sys.argv[3]
t = Path(src).read_text(encoding="utf-8")
lines = t.split("\n")
start = next(i for i, ln in enumerate(lines) if ln.strip() == "<!--")
end = next(i for i, ln in enumerate(lines[start + 1:], start + 1) if ln.strip() == "-->")
t = "\n".join(lines[:start] + lines[end + 1:])          # 移除铁律注释块
t = re.sub(r"> 模板版本：.*", f"> 模板版本：`{ver}`", t)                       # 模板身份
t = re.sub(r"\{[^{}\n]{1,24}\}", "示例", t)                      # 其余占位统一最小合法填充
t = t.replace("#### 5.3.1 分页查询\n", "#### 5.3.1 分页查询\n\n> 说明：GET /api/demo/page ｜权限：demo:view\n", 1)
t = t.replace("#### 5.3.2 新增\n", "#### 5.3.2 新增\n\n> 说明：POST /api/demo ｜权限：demo:add\n", 1)
# 概览裁到与详细定义一一对应（模板示例只展开 5.3.1/5.3.2 两个接口）
t = t.replace("""| GET | /api/示例/{id} | 详情查询 | 示例:view |
| POST | /api/示例 | 新增 | 示例:add |
| PUT | /api/示例/{id} | 更新 | 示例:edit |
| DELETE | /api/示例/{id} | 删除 | 示例:delete |
| GET | /api/示例/export | 导出 | 示例:export |
""", "")
# v3.27.12：§7.1 页面清单表行改为与 design.json pages[] 同源（清单表对账）
_lines = t.split("\n")
for _i, _l in enumerate(_lines):
    if _l.startswith("| # | 子域/分组 | 页面 | 路径 | 组件"):
        _j = _i + 2
        _k = _j
        while _k < len(_lines) and _lines[_k].startswith("|"):
            _k += 1
        _lines[_j:_k] = ["| 1 | 示例 | 列表页 | /demo/list | views/demo/ListPage.vue | 列表+详情抽屉 | demo:view |"]
        break
t = "\n".join(_lines)
Path(dst).write_text(t, encoding="utf-8")
PYEOF
  printf '| M-01-F01-A01 | FROZEN |\n' > "$d/docs/需求/subf-验收点.md"
  printf '# subf PRD\n' > "$d/docs/需求/subf-prd.md"
  cat > "$d/docs/需求/subf-技术约束.md" <<'EOF'
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
  "${DEVFLOW_PY[@]}" - "$d" <<'PYEOF'
import json, sys
d = sys.argv[1]
tbl_cfg = {
    "anchor": "§2.3.1", "name": "示例_config", "fields": [
        {"name": "id", "type": "bigint", "constraint": "PK, AUTO_INCREMENT", "default": "—", "note": "主键", "ddr": ["DDR-1"]},
        {"name": "config_key", "type": "varchar(64)", "constraint": "NOT NULL, UNIQUE", "default": "—", "note": "配置键", "ddr": ["DDR-1"]},
        {"name": "config_value", "type": "text", "constraint": "NULL", "default": "NULL", "note": "配置值", "ddr": ["DDR-1"]},
        {"name": "config_type", "type": "varchar(32)", "constraint": "NOT NULL", "default": "—", "note": "配置类型", "ddr": ["DDR-1"]},
        {"name": "description", "type": "varchar(256)", "constraint": "NULL", "default": "NULL", "note": "描述", "ddr": ["DDR-1"]},
        {"name": "sort_order", "type": "int", "constraint": "NOT NULL", "default": "0", "note": "排序", "ddr": ["DDR-1"]},
        {"name": "config_status", "type": "tinyint", "constraint": "NOT NULL", "default": "1", "note": "1=启用，0=停用", "ddr": ["DDR-1"]},
        {"name": "version", "type": "int", "constraint": "NOT NULL", "default": "0", "note": "乐观锁版本", "ddr": ["DDR-1"]},
        {"name": "deleted", "type": "tinyint", "constraint": "NOT NULL", "default": "0", "note": "逻辑删除标志", "ddr": ["DDR-1"]},
        {"name": "create_time", "type": "datetime", "constraint": "NOT NULL", "default": "CURRENT_TIMESTAMP", "note": "创建时间", "ddr": ["DDR-1"]},
        {"name": "create_by", "type": "bigint", "constraint": "NULL", "default": "NULL", "note": "创建人", "ddr": ["DDR-1"]},
        {"name": "update_time", "type": "datetime", "constraint": "NULL", "default": "NULL", "note": "更新时间", "ddr": ["DDR-1"]},
        {"name": "update_by", "type": "bigint", "constraint": "NULL", "default": "NULL", "note": "更新人", "ddr": ["DDR-1"]},
    ]}
tbl_rec = {
    "anchor": "§2.3.2", "name": "示例_record", "fields": [
        {"name": "id", "type": "bigint", "constraint": "PK, AUTO_INCREMENT", "default": "—", "note": "主键", "ddr": ["DDR-1"]},
        {"name": "record_no", "type": "varchar(32)", "constraint": "NOT NULL, UNIQUE", "default": "—", "note": "业务编号", "ddr": ["DDR-1"]},
        {"name": "record_name", "type": "varchar(128)", "constraint": "NOT NULL", "default": "—", "note": "名称", "ddr": ["DDR-1"]},
        {"name": "record_status", "type": "varchar(32)", "constraint": "NOT NULL", "default": "'ACTIVE'", "note": "状态", "ddr": ["DDR-1"]},
        {"name": "version", "type": "int", "constraint": "NOT NULL", "default": "0", "note": "乐观锁版本", "ddr": ["DDR-1"]},
        {"name": "deleted", "type": "tinyint", "constraint": "NOT NULL", "default": "0", "note": "逻辑删除", "ddr": ["DDR-1"]},
        {"name": "create_time", "type": "datetime", "constraint": "NOT NULL", "default": "CURRENT_TIMESTAMP", "note": "创建时间", "ddr": ["DDR-1"]},
        {"name": "create_by", "type": "bigint", "constraint": "NULL", "default": "NULL", "note": "创建人", "ddr": ["DDR-1"]},
        {"name": "update_time", "type": "datetime", "constraint": "NULL", "default": "NULL", "note": "更新时间", "ddr": ["DDR-1"]},
        {"name": "update_by", "type": "bigint", "constraint": "NULL", "default": "NULL", "note": "更新人", "ddr": ["DDR-1"]},
    ]}
api_page = {
    "anchor": "§5.3.1", "detail_anchor": "§5.3.1", "name": "分页查询", "method": "GET",
    "path": "/api/demo/page", "permission": "demo:view",
    "request": {"anchor": "§5.3.1", "fields": [
        {"name": "pageNum", "type": "integer", "required": True, "rule": ">=1", "source": "请求参数", "masking": "否"},
        {"name": "pageSize", "type": "integer", "required": True, "rule": "1~100", "source": "请求参数", "masking": "否"},
        {"name": "name", "type": "string", "required": False, "rule": "trim 后 <=128", "source": "请求参数→name 查询条件", "masking": "否"},
        {"name": "status", "type": "string", "required": False, "rule": "必须属于状态枚举", "source": "请求参数→status 查询条件", "masking": "否"}]},
    "response": {"anchor": "§5.3.1", "fields": [
        {"name": "total", "type": "long", "always": "是", "rule": "满足过滤条件的总数", "source": "count 查询", "masking": "否"},
        {"name": "records[].id", "type": "long", "always": "是", "rule": "记录主键", "source": "demo_record.id", "masking": "否"},
        {"name": "records[].recordNo", "type": "string", "always": "是", "rule": "业务编号", "source": "demo_record.record_no", "masking": "否"},
        {"name": "records[].name", "type": "string", "always": "是", "rule": "名称", "source": "demo_record.record_name", "masking": "否"},
        {"name": "records[].status", "type": "string", "always": "是", "rule": "状态枚举", "source": "demo_record.record_status", "masking": "否"},
        {"name": "records[].createTime", "type": "datetime", "always": "是", "rule": "创建时间", "source": "demo_record.create_time", "masking": "否"}]}}
api_create = {
    "anchor": "§5.3.2", "detail_anchor": "§5.3.2", "name": "新增", "method": "POST",
    "path": "/api/demo", "permission": "demo:add",
    "request": {"anchor": "§5.3.2", "fields": [
        {"name": "name", "type": "string", "required": True, "rule": "trim 后 1~128；唯一范围在本模块内明确", "source": "请求体", "masking": "否"},
        {"name": "description", "type": "string", "required": False, "rule": "0~256", "source": "请求体", "masking": "否"}]},
    "response": {"anchor": "§5.3.2", "fields": [
        {"name": "id", "type": "long", "always": "是", "rule": "新增记录主键", "source": "INSERT 返回主键", "masking": "否"},
        {"name": "recordNo", "type": "string", "always": "是", "rule": "按 R1 生成", "source": "demo_record.record_no", "masking": "否"}]}}
rules = [
    {"id": "R1", "anchor": "§5.3.2", "summary": "record_no 自动生成，同日唯一"},
    {"id": "R2", "anchor": "§2.3.2", "summary": "record_name trim 后非空"},
    {"id": "R3", "anchor": "§2.3.2", "summary": "record_status 缺省默认值"},
    {"id": "R4", "anchor": "§4.2.3", "summary": "已删除记录不允许更新"},
    {"id": "R5", "anchor": "§4.2", "summary": "不可变字段禁止修改"},
    {"id": "R6", "anchor": "§2.3.2", "summary": "乐观锁版本控制"},
    {"id": "R7", "anchor": "§4.2.3", "summary": "逻辑删除原子设置"},
    {"id": "R8", "anchor": "§4.2.3", "summary": "存在有效关联数据时拒绝删除"},
    {"id": "R9", "anchor": "§4.2.3", "summary": "删除后 record_no 永不复用"}]
for _r in rules[1:]:
    _r["unreferenced_reason"] = "写入路径边界校验，主流程不直接引用"
design = {
    "feature": "subf", "generated_at": "2026-09-17T00:00:00Z",
    "template": {"id": "详细设计-总分分文档-模板", "version": "SET_BY_SHELL", "mode": "sub"},
    "acceptance": [{"id": "M-01-F01-A01", "prd_anchor": "docs/需求/subf-prd.md#L1",
                    "page": ["§7.1"], "api": ["§5.3.1", "§5.3.2"], "data": ["§2.3.1", "§2.3.2"],
                    "rule": "R1", "test_case": "TC-SUB-001", "status": "COMPLETE"}],
    "tables": [tbl_cfg, tbl_rec], "apis": [api_page, api_create],
    "pages": [{"anchor": "§7.1", "name": "列表页", "permission": "demo:view", "route": "/demo/list", "component": "views/demo/ListPage.vue", "page_type": "列表+详情抽屉"}],
    "rules": rules,
    "test_isolation": {"applicable": True, "strategy": "类内 @Order + 每类自清理登录态（fixture）"},
    "business_operations": [{"id": "BOP-1", "name": "新增记录", "trigger": "用户提交新增表单",
        "actor": "demo:add 持有者", "input": "name/description", "preconditions": ["name 校验（R2）"],
        "stateless": False, "source_state": "无（新记录）", "target_state": "ACTIVE",
        "steps": ["字段校验", "TX：生成 record_no → INSERT"], "concurrency": "record_no 唯一约束",
        "result": "返回 id/recordNo", "failure": "校验失败 400；唯一冲突重试后 409",
        "related_objects": ["示例_config"], "side_effects": ["Outbox 审计"],
        "test_scenarios": ["正常新增", "重名拒绝"], "acceptance_refs": ["M-01-F01-A01"], "anchor": "§4.2.1"}],
    "baseline": {"repo_root": ".", "db_evidence": {"source": "migration_ddl"},
        "entries": [{"id": "BL-1", "target": "backend/demo/DemoService.java", "decision": "ADD",
                     "target_module": "demo 模块", "verify": "DemoServiceTest"}]},
    "client": {"scope": "pc-web", "journeys": [{"name": "列表查看", "page": "§7.1", "evidence": "真实浏览器"}]},
    "migrations": {"applicable": True, "strategy": "B", "dialects": ["h2", "postgresql", "oracle", "kingbase"]},
    "decisions": [
        {"id": "DDR-1", "topic": "字段与命名", "reason": "遵循 §12 规范条目：小写+下划线，varchar 长度按上限量化"},
        {"id": "DDR-2", "topic": "全局状态存储", "reason": "状态数固定 3 个，tinyint 足够", "unreferenced_reason": "全局决策，覆盖多表状态字段"}],
    "zero_results": [
        {"path": "resources", "reason": "无跨请求资源占用"},
        {"path": "operations", "reason": "无资源即无补偿链"},
        {"path": "integrations", "reason": "无外部调用"},
        {"path": "configs", "reason": "无新增配置键"}],
}
design["template"]["version"] = "TEMPLATE_VERSION_MARK"
json.dump(design, open(f"{d}/.devflow/subf/design.json", "w"), ensure_ascii=False)
PYEOF
  tplv=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-总分分文档-模板.md" | head -1)
  sed -i '' "s/TEMPLATE_VERSION_MARK/$tplv/" "$d/.devflow/subf/design.json" 2>/dev/null || \
    sed -i "s/TEMPLATE_VERSION_MARK/$tplv/" "$d/.devflow/subf/design.json"
  cat > "$d/.devflow/subf/design-package.json" <<'EOF'
{"feature":"subf","docs":[
  {"path":"docs/详细设计/subf-详细设计.md","mode":"sub","acceptance_ids":["M-01-F01-A01"]}]}
EOF
  cp "$ROOT/examples/structured/需求追溯.skeleton.md" "$d/docs/详细设计/subf-需求追溯.md"
  sed "s/{{template_version}}/$tplv/" "$ROOT/templates/实现交接-模板.md" > "$d/docs/详细设计/subf-实现交接.md"
  (cd "$d" && WORKSPACE="$d" bash "$ROOT/scripts/devflow-state.sh" init subf --frontend=pc-web >/dev/null 2>&1)
}

SUBF="$WORK/subf"
build_sub_fixture "$SUBF"
# 管线（校验+渲染）先于 Gate——与 phases/02 管线契约一致
check_rc 0 "sub mode: template copy fills and passes pipeline (A07)" \
  bash -c "cd '$SUBF' && \$DEVFLOW_PY_STR '$PI' design --input .devflow/subf/design.json --doc docs/详细设计/subf-详细设计.md --criteria docs/需求/subf-验收点.md --trace-doc docs/详细设计/subf-需求追溯.md"
check_rc 0 "sub mode: filled template passes s2 Gate end-to-end (A07/A05)" \
  bash -c "cd '$SUBF' && bash '$S2' docs/详细设计/subf-详细设计.md docs/需求/subf-验收点.md --mode=sub"
# 总分模式缺设计包 → 拒
mv "$SUBF/.devflow/subf/design-package.json" "$SUBF/.devflow/subf/design-package.json.bak"
assert_out "design-package.json 缺失" "sub mode without design-package manifest rejected (A05)" \
  bash -c "cd '$SUBF' && bash '$S2' docs/详细设计/subf-详细设计.md docs/需求/subf-验收点.md --mode=sub"
mv "$SUBF/.devflow/subf/design-package.json.bak" "$SUBF/.devflow/subf/design-package.json"

# ---------- v3.27.7：s2 --mode 与 P1 冻结 design_doc_structure 对账 ----------
# sub fixture 无选型报告 → WARN 不阻断（非标准/在途布局）
# 选型报告冻结 total 时，--mode=sub 放行（total 家族内）；冻结 monolith 时 --mode=sub 必须 FAIL
printf '# subf 技术选型\n## 决策矩阵\nx\n## 决策结论\n用户确认: YES\n## 详设文档结构决策\ndesign_doc_structure_mode=total\n' \
  > "$SUBF/docs/详细设计/subf-技术选型.md"
check_rc 0 "s2 --mode=sub 与 P1 total 一致放行 (v3.27.7)" \
  bash -c "cd '$SUBF' && bash '$S2' docs/详细设计/subf-详细设计.md docs/需求/subf-验收点.md --mode=sub"
printf '# subf 技术选型\n## 决策矩阵\nx\n## 决策结论\n用户确认: YES\n## 详设文档结构决策\ndesign_doc_structure_mode=monolith\n' \
  > "$SUBF/docs/详细设计/subf-技术选型.md"
assert_out "总分结构未在 P1 决策登记" "s2 --mode=sub 与 P1 monolith 错配被拒 (v3.27.7)" \
  bash -c "cd '$SUBF' && bash '$S2' docs/详细设计/subf-详细设计.md docs/需求/subf-验收点.md --mode=sub"
rm -f "$SUBF/docs/详细设计/subf-技术选型.md"

# ---------- A07/A05：total 模式完整正向 ----------
build_total_fixture() { # <dir>
  local d="$1" tplv
  mkdir -p "$d/docs/需求" "$d/docs/详细设计" "$d/.devflow/totf"
  tplv=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-总分总文档-模板.md" | head -1)
  "${DEVFLOW_PY[@]}" - "$ROOT/templates/详细设计-总分总文档-模板.md" "$d/docs/详细设计/totf-系统详细设计.md" "$tplv" <<'PYEOF'
import re, sys
from pathlib import Path
src, dst, ver = sys.argv[1], sys.argv[2], sys.argv[3]
t = Path(src).read_text(encoding="utf-8")
lines = t.split("\n")
start = next(i for i, ln in enumerate(lines) if ln.strip() == "<!--")
end = next(i for i, ln in enumerate(lines[start + 1:], start + 1) if ln.strip() == "-->")
t = "\n".join(lines[:start] + lines[end + 1:])
t = re.sub(r"> 模板版本：.*", f"> 模板版本：`{ver}`", t)
t = re.sub(r"\{[^{}\n]{1,24}\}", "示例", t)
# 全局关键操作：WHEN 伪代码 + 时序图（total 文档跨模块口径）
t = t.replace("### 6.2 流程定义", """### 6.2 跨模块关键操作

```text
WHEN 跨模块结算汇总 (period):
  1. 汇聚各模块结果
  2. 生成汇总并写审计
```

```mermaid
sequenceDiagram
    participant 调度
    participant Service
    调度->>Service: settle(period)
    Service-->>调度: 200 OK
```

### 6.3 流程定义""")
# 全局规则编号行（s2 §6 R 编号口径）
t = t.replace("### 4.1 通用规则", "### 4.1 通用规则\n\n| 规则编号 | 规则描述 | 约束/错误处理 |\n|---|---|---|\n| R1 | 跨模块汇总必须幂等 | 重复请求返回原结果 |")
Path(dst).write_text(t, encoding="utf-8")
PYEOF
  printf '| M-01-F01-A01 | FROZEN |\n' > "$d/docs/需求/totf-验收点.md"
  printf '# totf PRD\n' > "$d/docs/需求/totf-prd.md"
  cat > "$d/docs/需求/totf-技术约束.md" <<'EOF'
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
  "${DEVFLOW_PY[@]}" - "$d" <<'PYEOF'
import json, sys
d = sys.argv[1]
design = {
    "feature": "totf", "generated_at": "2026-09-17T00:00:00Z",
    "template": {"id": "详细设计-总分总文档-模板", "version": "TEMPLATE_VERSION_MARK", "mode": "total"},
    "acceptance": [{"id": "M-01-F01-A01", "prd_anchor": "docs/需求/totf-prd.md#L1",
                    "page": "—", "api": "—", "data": "—", "rule": "R1",
                    "test_case": "TC-TOT-001", "status": "COMPLETE"}],
    "tables": [], "apis": [], "pages": [],
    "rules": [{"id": "R1", "anchor": "§4.1", "summary": "跨模块汇总必须幂等"}],
    "test_isolation": {"applicable": True, "strategy": "类内 @Order + 每类自清理登录态（fixture）"},
    "business_operations": [{"id": "BOP-1", "name": "跨模块结算汇总", "trigger": "每日定时",
        "actor": "调度系统", "stateless": True,
        "steps": ["汇聚各模块结果", "生成汇总并写审计"],
        "result": "汇总完成", "failure": "失败重试并告警",
        "test_scenarios": ["正常汇总", "模块缺失跳过并告警"],
        "acceptance_refs": ["M-01-F01-A01"], "anchor": "§6"}],
    "baseline": {"repo_root": ".", "db_evidence": {"source": "none"},
        "entries": [{"id": "BL-1", "target": "backend/settle/SettleJob.java", "decision": "ADD",
                     "target_module": "settle 模块", "verify": "SettleJobTest"}]},
    "client": {"scope": "not-applicable", "not_applicable_reason": "全局架构文档，客户端契约在分文档"},
    "migrations": {"applicable": False, "not_applicable_reason": "模块内迁移在各分文档冻结"},
    "decisions": [{"id": "DDR-1", "topic": "全局枚举存储", "reason": "枚举数固定，统一字典表", "unreferenced_reason": "全局决策"}],
    "zero_results": [
        {"path": "tables", "reason": "全局文档只收跨域公约数，表结构在分文档"},
        {"path": "apis", "reason": "接口定义在分文档展开"},
        {"path": "pages", "reason": "页面在分文档"},
        {"path": "resources", "reason": "无跨请求资源占用"},
        {"path": "operations", "reason": "无资源即无补偿链"},
        {"path": "integrations", "reason": "无外部调用"},
        {"path": "configs", "reason": "无新增配置键"}],
}
design["template"]["version"] = "TEMPLATE_VERSION_MARK"
json.dump(design, open(f"{d}/.devflow/totf/design.json", "w"), ensure_ascii=False)
PYEOF
  tplv=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-总分总文档-模板.md" | head -1)
  sed -i '' "s/TEMPLATE_VERSION_MARK/$tplv/" "$d/.devflow/totf/design.json" 2>/dev/null || \
    sed -i "s/TEMPLATE_VERSION_MARK/$tplv/" "$d/.devflow/totf/design.json"
  cat > "$d/.devflow/totf/design-package.json" <<'EOF'
{"feature":"totf","docs":[
  {"path":"docs/详细设计/totf-系统详细设计.md","mode":"total","acceptance_ids":["M-01-F01-A01"]}]}
EOF
  cp "$ROOT/examples/structured/需求追溯.skeleton.md" "$d/docs/详细设计/totf-系统详细设计-需求追溯.md"
  sed "s/{{template_version}}/$tplv/" "$ROOT/templates/实现交接-模板.md" > "$d/docs/详细设计/totf-系统详细设计-实现交接.md"
  (cd "$d" && WORKSPACE="$d" bash "$ROOT/scripts/devflow-state.sh" init totf --frontend=not-applicable >/dev/null 2>&1)
}

TOTF="$WORK/totf"
build_total_fixture "$TOTF"
printf '# totf 技术选型\n## 决策矩阵\nx\n## 决策结论\n用户确认: YES\n## 详设文档结构决策\ndesign_doc_structure_mode=total\n' \
  > "$TOTF/docs/详细设计/totf-技术选型.md"
check_rc 0 "total mode: template copy fills and passes pipeline (A07)" \
  bash -c "cd '$TOTF' && \$DEVFLOW_PY_STR '$PI' design --input .devflow/totf/design.json --doc docs/详细设计/totf-系统详细设计.md --criteria docs/需求/totf-验收点.md --trace-doc docs/详细设计/totf-系统详细设计-需求追溯.md"
check_rc 0 "total mode: filled template passes s2 Gate end-to-end (A07/A05)" \
  bash -c "cd '$TOTF' && bash '$S2' docs/详细设计/totf-系统详细设计.md docs/需求/totf-验收点.md --mode=total"
# v3.27.7：P1 冻结 total 但 s2 以 monolith 运行 → FAIL
assert_out "不得在 P2 自行改回单文档" "s2 --mode=monolith 与 P1 total 错配被拒 (v3.27.7)" \
  bash -c "cd '$TOTF' && bash '$S2' docs/详细设计/totf-系统详细设计.md docs/需求/totf-验收点.md --mode=monolith"

# ---------- v3.27.10(H1)：total + 前端页面/旅程——模块级对象不在总文档对账 ----------
"${DEVFLOW_PY[@]}" - "$TOTF" <<'PYEOF'
import json, sys
p = f"{sys.argv[1]}/.devflow/totf/design.json"
d = json.load(open(p))
d["acceptance"][0]["page"] = "§7.2.1"
d["pages"] = [{"anchor": "§7.2.1", "name": "列表页", "permission": "demo:view",
               "route": "/demo/list", "component": "views/demo/ListPage.vue",
               "page_type": "列表+详情抽屉"}]
d["client"] = {"scope": "pc-web",
               "journeys": [{"name": "列表查看", "page": "§7.2.1", "evidence": "真实浏览器"}]}
d["zero_results"] = [z for z in d["zero_results"] if z["path"] != "pages"]
json.dump(d, open(p, "w"), ensure_ascii=False)
PYEOF
jq '.scope.frontend="pc-web"' "$TOTF/.devflow/totf.state.json" > "$TOTF/.devflow/totf.state.json.tmp" \
  && mv "$TOTF/.devflow/totf.state.json.tmp" "$TOTF/.devflow/totf.state.json"
check_rc 0 "total mode: UI page+journey re-render (doc-mode auto-resolved from design-package)" \
  bash -c "cd '$TOTF' && \$DEVFLOW_PY_STR '$PI' design --input .devflow/totf/design.json --doc docs/详细设计/totf-系统详细设计.md --criteria docs/需求/totf-验收点.md --trace-doc docs/详细设计/totf-系统详细设计-需求追溯.md"
check_rc 0 "total mode: UI page+journey passes s2 (module-level checks skipped on total doc, H1)" \
  bash -c "cd '$TOTF' && bash '$S2' docs/详细设计/totf-系统详细设计.md docs/需求/totf-验收点.md --mode=total"
# v3.27.10(M2)：design.json template.mode 与 Gate --mode 漂移 → 拒
"${DEVFLOW_PY[@]}" - "$TOTF" <<'PYEOF'
import json, sys
p = f"{sys.argv[1]}/.devflow/totf/design.json"
d = json.load(open(p)); d["template"]["mode"] = "monolith"
json.dump(d, open(p, "w"), ensure_ascii=False)
PYEOF
assert_out "template.mode=monolith 与 Gate --mode=total 不一致" "s2 rejects JSON template.mode drift (v3.27.10)" \
  bash -c "cd '$TOTF' && bash '$S2' docs/详细设计/totf-系统详细设计.md docs/需求/totf-验收点.md --mode=total"
# v3.27.10(M3)：design.json constraints[] 登记冻结集合之外的约束 → 拒
"${DEVFLOW_PY[@]}" - "$TOTF" <<'PYEOF'
import json, sys
p = f"{sys.argv[1]}/.devflow/totf/design.json"
d = json.load(open(p)); d["template"]["mode"] = "total"
d["constraints"] = [{"id": "TC-TECH-999"}]
json.dump(d, open(p, "w"), ensure_ascii=False)
PYEOF
assert_out "冻结集合之外" "s2 rejects design.json constraints outside frozen set (v3.27.10)" \
  bash -c "cd '$TOTF' && bash '$S2' docs/详细设计/totf-系统详细设计.md docs/需求/totf-验收点.md --mode=total"

# ---------- A06：适用性正向夹具（纯 UI / 消息消费者 / 小程序 / APP） ----------
mkaux() { # <name> — validate 级正向变体（含独立 criteria）
  printf '| M01-F01-A01 | x |\n' > "criteria-$1.md"
  "${DEVFLOW_PY[@]}" - "$1" <<'PYEOF'
import json, sys
name = sys.argv[1]
d = json.load(open("design.json"))
d["feature"] = name
_acc_page = "§7.2.1" if name != "mq-consumer" else "—"
d["acceptance"] = [dict(d["acceptance"][0], id="M01-F01-A01", page=_acc_page, api="—", data="—")]
d["tables"] = []
d["apis"] = []
d["pages"] = [d["pages"][0]]
for _dlg in d["pages"][0].get("dialogs", []):
    _dlg["api"] = "—"  # 该场景复用既有接口、本期不新增 APIs——弹窗接口位显式 —（v3.27.9 闭环校验）
for _act in d["pages"][0].get("actions", []):
    _act["api"] = "—"  # 同上：apis 清空后操作接口锚点必然悬空，操作接口位显式 —（§7.2↔§3.2 闭环校验）
d["rules"] = [{"id": "R1", "anchor": "§5", "summary": "重复提交幂等"}]
_bop = dict(d["business_operations"][0],
    name="界面操作", acceptance_refs=["M01-F01-A01"], anchor="§6.1",
    input="页面输入", stateless=True, steps=["用户操作", "前端校验"],
    result="界面反馈", failure="校验失败提示", related_objects=[], side_effects=[])
_bop.pop("source_state", None); _bop.pop("target_state", None)
d["business_operations"] = [_bop]
d["baseline"]["entries"] = [dict(d["baseline"]["entries"][0], id="BL-1", decision="ADD",
    target="frontend/src/views/Demo.vue", target_module="demo 前端模块", verify="DemoE2E")]
d["decisions"] = [dict(d["decisions"][0], unreferenced_reason="无表字段")]
d["resources"] = []; d["operations"] = []; d["configs"] = []
if name in ("pure-ui", "mini-app-ui", "app-ui"):
    d["migrations"] = {"applicable": False, "not_applicable_reason": "纯前端无持久化"}
    d["integrations"] = []
    d["zero_results"] = [
        {"path": "tables", "reason": "纯前端无持久化"},
        {"path": "apis", "reason": "复用既有接口，本期不新增"},
        {"path": "resources", "reason": "无资源占用"},
        {"path": "operations", "reason": "无资源即无补偿链"},
        {"path": "integrations", "reason": "无外部调用"},
        {"path": "configs", "reason": "无新增配置键"}]
    if name == "pure-ui":
        d["client"] = {"scope": "pc-web", "journeys": [{"name": "列表查看", "page": "§7.2.1", "evidence": "真实浏览器"}]}
    elif name == "mini-app-ui":
        d["client"] = {"scope": "mini-program", "journeys": [{"name": "列表查看", "page": "§7.2.1", "evidence": "微信开发者工具"}]}
    else:
        d["client"] = {"scope": "app", "journeys": [{"name": "列表查看", "page": "§7.2.1", "evidence": "真机"}]}
else:
    d["migrations"] = {"applicable": True, "strategy": "B", "dialects": ["h2", "postgresql", "oracle", "kingbase"]}
    d["pages"] = []
    d["client"] = {"scope": "not-applicable", "not_applicable_reason": "MQ 消费者"}
    d["integrations"] = [{"id": "INT-1", "name": "订单事件消费", "direction": "inbound",
        "anchor": "§8.1", "endpoint": "TOPIC order-events", "timeout": "30 秒 × 3 次",
        "idempotency": "事件 ID 去重表", "failure_path": "重试耗尽进死信并告警",
        "fallback": "定时补偿扫描与消费同一执行方法"}]
    d["zero_results"] = [
        {"path": "tables", "reason": "消费既有表，无新增字段"},
        {"path": "apis", "reason": "消息消费者无对外 REST"},
        {"path": "pages", "reason": "无前端页面"},
        {"path": "resources", "reason": "无资源占用"},
        {"path": "operations", "reason": "无资源即无补偿链"},
        {"path": "configs", "reason": "无新增配置键"}]
json.dump(d, open(f"d-{name}.json", "w"), ensure_ascii=False)
PYEOF
  check_rc 0 "applicability forward fixture accepted: $1 (A06)" \
    "${DEVFLOW_PY[@]}" "$V" --kind design --input "d-$1.json" --criteria "criteria-$1.md" --doc doc.md
}
mkaux pure-ui
mkaux mq-consumer
mkaux mini-app-ui
mkaux app-ui

echo "=== design package / modes RESULT PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ] || exit 1
