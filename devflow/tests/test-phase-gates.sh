#!/usr/bin/env bash
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== devflow phase gate tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/docs/prd" "$TMP/docs/requirements" "$TMP/docs/detailed-design" \
  "$TMP/docs/数据映射" "$TMP/docs/test" "$TMP/backend/x/src/main/java" "$TMP/backend/x/src/test"

cat > "$TMP/docs/prd/foo.md" <<'EOF'
# Foo PRD
必须实现可持久化的查询功能。
EOF

cat > "$TMP/docs/requirements/foo-source-matrix.md" <<'EOF'
# Source matrix
| source | authority |
|---|---|
| foo PRD | PRD |
EOF

cat > "$TMP/docs/requirements/foo-clarification.md" <<'EOF'
# Foo 需求澄清
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | foo |
| 验收点来源 | foo-acceptance-criteria.md |
| 备注 | 来源为 foo PRD；冻结时点为评审完成时 |
## 模糊点清单
| 编号 | 模糊点 | 澄清结论 | 状态 |
|---|---|---|---|
| Q1 | 查询口径 | 以 PRD 为准 | 已闭环 |
## 澄清结论汇总
全部闭环，无未决项。
## 遗留项（需后续跟进）
无。
## 签字确认
甲方：fixture 甲方 2026-08-24
乙方：fixture 乙方 2026-08-24
EOF

cat > "$TMP/docs/requirements/foo-acceptance-criteria.md" <<'EOF'
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | foo |
| 状态 | FROZEN |
## 验收清单
| acceptance_id | requirement | status |
|---|---|---|
| M-01-F01-A01 | 查询真实数据 | FROZEN |
| 总计 | 1 | FROZEN |
EOF

cat > "$TMP/docs/requirements/foo-technology-constraints.md" <<'EOF'
# foo 技术约束契约
## 基本信息
| 状态 | FROZEN |
## 机器契约
<!-- DEVFLOW:CONSTRAINTS
constraint_id=TC-TECH-001
type=MUST_USE
subject=database
required_product=postgresql
required_version=16
status=FROZEN
confirmed=true
DEVFLOW:END -->
## 约束清单
| constraint_id | 类型 | 技术/组件 | 必须值/禁止值 | 来源锚点 | 确认人 | 状态 |
|---|---|---|---|---|---|---|
| TC-TECH-001 | MUST_USE | PostgreSQL | 16 | docs/prd/foo.md#L2 | user | FROZEN |
EOF

cat > "$TMP/docs/detailed-design/foo-tech-selection.md" <<'EOF'
# foo 技术选型
## 决策矩阵
| 维度 | PostgreSQL | MySQL |
|---|---|---|
| 成本 | 4 | 4 |
## 决策结论
用户确认: YES
## 详设文档结构决策
design_doc_structure_mode=monolith
## 硬约束绑定
<!-- DEVFLOW:CONSTRAINT-BINDINGS
constraint_id=TC-TECH-001
selected_product=postgresql
selected_version=16
compliance=PASS
evidence=backend/x/src/main/resources/application.yml
DEVFLOW:END -->
EOF

# v3.28.2：设计决策记录改名，s1 按新名查找；保留旧名兼容
cp "$TMP/docs/detailed-design/foo-tech-selection.md" "$TMP/docs/detailed-design/foo-设计决策.md"

cat > "$TMP/docs/detailed-design/foo-design.md" <<'EOF'
# Foo 详细设计
> 模板 ID：`详细设计-完整版-模板`
> 模板版本：`__TEMPLATE_VERSION__`
## §0 文档结构
单体 fixture，边界由 foo 模块负责（结构经 P1 选型决策：design_doc_structure_mode=monolith）。
## §1 功能概述
分页查询 foo 数据。
## §2 数据模型
<!-- anchor: data-model -->
CREATE TABLE foo (id BIGINT PRIMARY KEY, page INT);
### 表: foo
| 字段名 | 类型 | 约束 | 默认值 | 口径说明 |
|---|---|---|---|---|
| id | BIGINT | PK | auto | 主键 |
| page | INT | 非空 | 1 | 页码；最大值由接口校验 |
## §3 接口设计
<!-- anchor: api-contracts -->
本模块对外提供分页查询接口，概览与详细定义一一对应。
### 3.2 详细接口定义
#### 3.2.1 分页列表

> 说明：GET /api/foo/list ｜权限：foo:view

| 方法 | 路径 | 接口 |
|---|---|---|
| GET | /api/foo/list | 分页列表 |
| 字段 | 类型 | 必填 | 校验规则 | 数据来源 | 脱敏 |
|---|---|---|---|---|---|
| page | INT | 否 | >=1 | 请求 | 否 |
| 字段 | 类型 | 恒出性 | 取值规则 | 数据来源 | 脱敏 |
|---|---|---|---|---|---|
| id | Long | 是 | 主键 | foo.id | 否 |
| page | Integer | 是 | 页码 | foo.page | 否 |
## §4 权限矩阵
| 操作 | 角色 | 允许 |
|---|---|---|
| 查询 | admin | 是 |
## §5 业务规则
<!-- anchor: business-rules -->
| 规则编号 | 规则描述 |
|----------|----------|
| R1 | page 必须大于等于 1。 |
| R2 | name 非空且 <=128 字符。 |
## §6 关键流程
WHEN 查询 foo (page): [R1][R2]
  1. 校验 page
  2. 返回分页结果

```mermaid
sequenceDiagram
    participant 前端
    participant Service
    participant DB
    前端->>Service: GET /api/foo/list
    Service->>DB: SELECT
    Service-->>前端: 200 OK
```
## §7 前端页面

### 7.1 页面清单

| # | 子域/分组 | 页面 | 路径 | 组件（真实路径） | 类型 | 权限 |
|---|---|---|---|---|---|---|
| 1 | foo | foo-list | /foo/list | views/foo/FooList.vue | 列表页 | foo:view |

foo-list.vue；列表可达。

## 7.2 页面交互设计

### 7.2.1 列表页交互

列表交互说明（页组覆盖 §7.1 全部页面，调用接口 §3.2.1）。
## §8 数据库迁移
V1001__foo.sql 四方言。
## §9 验收标准
| 验收点ID | PRD原文锚点 | 页面/任务 | 接口契约 | 数据字段 | 规则/准伪代码 | 测试用例 | 设计状态 |
|---|---|---|---|---|---|---|---|
| M-01-F01-A01 | docs/prd/foo.md#L2 | §7.1 | §3.2.1 | §2 | R1 | TC-foo-001 | COMPLETE |
## §10 依赖项
TC-TECH-001：数据库使用 postgresql 16。
## §8 验收标准（零结果）（追溯矩阵在存量位置，s2 回退读取）
<!-- anchor: acceptance-traceability -->
设计覆盖率 = 100%
## §10 组件复用与公共抽取
成熟组件复用清单：hibernate-validator；公共抽取登记：分页契约复用。
## §9 依赖项（规范）
命名/开发/注释规范：阿里巴巴 Java 开发手册；无偏离。
## §11 异常处理、安全与性能设计
沿用平台统一异常/认证/性能基线；本模块无额外事务与缓存决策。
## §12 实现交接（Implementation Handoff）
<!-- anchor: implementation-handoff -->
| 文件/符号 | ADD/MODIFY/DELETE | 设计依据 | 验收点 |
|---|---|---|---|
| `FooController#list` | MODIFY | anchor: api-contracts §3 | M-01-F01-A01 |
## §12 变更历史
v1 fixture。
## 设计决策记录（DDR）
BIGINT 用于主键以覆盖长期增长；INT 用于页码因其业务上限明确。
## 评审记录
fixture 评审通过。
EOF
# 模板版本从模板 frontmatter 动态派生（防止 skill 升版后夹具硬编码漂移）
sed -i '' "s/__TEMPLATE_VERSION__/$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-完整版-模板.md" | head -1)/" \
  "$TMP/docs/detailed-design/foo-design.md"

# v3.17.1: §2c design.json 必填——夹具同步产出结构化产物层（概览↔详细定义 + DDR↔字段闭环）
mkdir -p "$TMP/.devflow/foo"
cat > "$TMP/.devflow/foo/design.json" <<EOF
{
  "feature": "foo",
  "generated_at": "2026-01-01T00:00:00Z",
  "template": {"id": "详细设计-完整版-模板", "version": "__TEMPLATE_VERSION__", "mode": "monolith"},
  "acceptance": [
    {"id": "M-01-F01-A01", "prd_anchor": "docs/prd/foo.md#L2", "page": "§7.1", "api": "§3.2.1",
     "data": "§2", "rule": "R1", "test_case": "TC-foo-001", "status": "COMPLETE"}
  ],
  "tables": [
    {"anchor": "§2", "name": "foo", "fields": [
      {"name": "id", "type": "BIGINT", "constraint": "PK", "default": "auto", "note": "主键", "ddr": ["DDR-1"]},
      {"name": "page", "type": "INT", "constraint": "非空", "default": "1", "note": "页码", "ddr": ["DDR-2"]}
    ]}
  ],
  "apis": [
    {"anchor": "§3.2.1", "detail_anchor": "§3.2.1", "name": "分页列表", "method": "GET", "path": "/api/foo/list",
     "permission": "foo:view",
     "request": {"anchor": "§3.2.1", "fields": [
       {"name": "page", "type": "INT", "required": false, "rule": ">=1", "source": "请求", "masking": "否"}]},
     "response": {"anchor": "§3.2.1", "fields": [
       {"name": "id", "type": "Long", "always": "是", "rule": "主键", "source": "foo.id", "masking": "否"}]}}
  ],
  "pages": [{"anchor": "§7.1", "name": "foo-list", "permission": "foo:view", "route": "/foo/list", "component": "views/foo/FooList.vue", "page_type": "列表页"}],
  "rules": [
    {"id": "R1", "anchor": "§5", "summary": "page 必须大于等于 1"},
    {"id": "R2", "anchor": "§5", "summary": "name 非空且 <=128 字符", "unreferenced_reason": "写入路径边界校验，查询主流程不直接引用"}
  ],
  "client": {"scope": "not-applicable", "not_applicable_reason": "fixture 纯服务端，无前端"},
  "migrations": {"applicable": true, "dialects": ["h2", "postgresql", "oracle", "kingbase"]},
  "business_operations": [{"id": "BOP-1", "name": "分页查询 foo", "trigger": "用户请求列表", "actor": "foo:view 持有者", "stateless": true, "steps": ["校验 page>=1（R1）", "查询并返回分页结果"], "result": "返回分页数据", "failure": "参数越界返回 400", "test_scenarios": ["正常查询", "page<1 拒绝"], "acceptance_refs": ["M-01-F01-A01"], "anchor": "§6"}],
  "baseline": {"repo_root": ".", "db_evidence": {"source": "migration_ddl"}, "entries": [{"id": "BL-1", "target": "backend/x/src/main/java/foo/FooController.java", "decision": "MODIFY", "existing_contract": "FooController#list 现有分页查询，响应结构不变", "related_acceptance": ["M-01-F01-A01"], "verify": "FooControllerTest"}]},
  "decisions": [
    {"id": "DDR-1", "topic": "主键类型", "alternatives": "BIGINT / INT", "chosen": "BIGINT", "reason": "长期增长量化：行数预估超 INT 上限 21 亿"},
    {"id": "DDR-2", "topic": "页码类型", "alternatives": "INT / BIGINT", "chosen": "INT", "reason": "业务上限明确，页码不会超 21 亿"}
  ],
  "zero_results": [{"path": "resources", "reason": "无跨请求资源占用"}, {"path": "operations", "reason": "无资源即无补偿链"}, {"path": "integrations", "reason": "无外部调用"}, {"path": "configs", "reason": "无新增配置键"}]
}
EOF
sed -i '' "s/__TEMPLATE_VERSION__/$(sed -n 's/^version: "\([0-9.]*\)"/\1/p' "$ROOT/templates/详细设计-完整版-模板.md" | head -1)/" \
  "$TMP/.devflow/foo/design.json"

for f in _commons.md _权限矩阵.md _环境与账号.md _菜单Seed索引.md INDEX-章节锚点.md INDEX-表.md INDEX-接口.md; do
  cat > "$TMP/docs/detailed-design/$f" <<EOF
# $f fixture
工程事实源。
| key | value |
|---|---|
| fixture | $f |
| status | frozen |
EOF
done

# v3.27.12：§7.1 页面清单表引入权限码后，须在事实源矩阵登记（L-P2-008 探针）
cat >> "$TMP/docs/detailed-design/_权限矩阵.md" <<'EOF'
| foo:view | 查询 |
EOF

cat > "$TMP/docs/数据映射/foo-映射.md" <<'EOF'
| 目标对象/字段 | 来源系统 | 来源对象/字段 | 转换规则 | 空值/默认策略 | 主键/引用映射 | 敏感处理 | 验证SQL/方法 |
|---|---|---|---|---|---|---|---|
| foo.id | legacy-a | a.id | 直迁 | 不允许空 | a.id→foo.id | 否 | count |
| foo.page | legacy-b | b.page | cast | 默认1 | b.id→foo.id | 否 | checksum |
适配器 legacy-a = LegacyAAdapter
适配器 legacy-b = LegacyBAdapter
EOF

mkdir -p "$TMP/backend/x/src/main/resources"
cat > "$TMP/backend/x/src/main/resources/application.yml" <<'EOF'
spring:
  datasource:
    url: jdbc:postgresql://localhost:5432/foo
EOF
cat > "$TMP/docs/test/foo-migration-evidence.env" <<'EOF'
structure=PASS
full_reconciliation=PASS
sample=PASS
boundary=PASS
recovery=PASS
mapping_coverage=100
difference_count=0
EOF
cat > "$TMP/docs/test/foo-graph-evidence.env" <<'EOF'
status=fallback
checked_at=2026-08-24T00:00:00Z
scope=foo
error=Transport closed
source_fallback_evidence=docs/test/foo-source-review.md
EOF
# v3.15.1: fallback 证据须实质化——记录 命令/范围/文件清单/发现/hash 五要素
# v3.20.3: 清单重算契约——FALLBACK_FILE_LIST 逐行 <sha> <path>；FALLBACK_SHA256=清单文件自身 SHA
FB_SHA=$(shasum -a 256 "$TMP/docs/detailed-design/foo-design.md" 2>/dev/null | awk '{print $1}' || sha256sum "$TMP/docs/detailed-design/foo-design.md" 2>/dev/null | awk '{print $1}')
printf '%s  docs/detailed-design/foo-design.md\n' "$FB_SHA" > "$TMP/docs/test/foo-fb-list.txt"
FB_LIST_SHA=$(shasum -a 256 "$TMP/docs/test/foo-fb-list.txt" 2>/dev/null | awk '{print $1}' || sha256sum "$TMP/docs/test/foo-fb-list.txt" 2>/dev/null | awk '{print $1}')
cat > "$TMP/docs/test/foo-source-review.md" <<EOF
FALLBACK_COMMAND=grep -rn "WHEN 查询 foo" docs/detailed-design/foo-design.md
FALLBACK_SCOPE=foo
FALLBACK_FILES=1
FALLBACK_FINDINGS=2
FALLBACK_SHA256=$FB_LIST_SHA
FALLBACK_FILE_LIST=docs/test/foo-fb-list.txt
# 人工源码走查记录（图谱不可达时的替代证据）
走查范围：foo 模块设计与实现的关键流程。
发现一：R1 校验规则与实现一致。
发现二：R2 字段长度约束已覆盖。
EOF

# v3.14.1: s 系 gate 拒绝无 state 运行（default 回退已移除），fixture 先建工作流
if (cd "$TMP" && WORKSPACE="$TMP" bash "$ROOT/scripts/devflow-state.sh" init foo --frontend=not-applicable >/dev/null 2>&1); then :; else bad "phase-gates init fixture"; fi
bash "$ROOT/tests/mk_p0_artifacts.sh" foo "$TMP" >/dev/null 2>&1
if (cd "$TMP" && WORKSPACE="$TMP" bash "$ROOT/scripts/s0_acceptance_gate.sh" foo); then ok "P0 fixture"; else bad "P0 fixture"; fi
if (cd "$TMP" && WORKSPACE="$TMP" bash "$ROOT/scripts/devflow-state.sh" constraints-freeze foo >/dev/null 2>&1); then :; else bad "constraints-freeze fixture"; fi
if (cd "$TMP" && WORKSPACE="$TMP" bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design); then ok "P1 fixture"; else bad "P1 fixture"; fi
# v3.27.14：scaffold_audit 登记但报告缺《脚手架重合度审计》章节 → s1 拦截（铁律 18 接线）
printf '{"feature":"foo","scaffold_audit":[{"domain":"F01","verdict":"裁剪"}]}\n' > "$TMP/.devflow/foo/tech-selection.json"
if (cd "$TMP" && WORKSPACE="$TMP" bash "$ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design >/dev/null 2>&1); then
  bad "scaffold_audit 登记但报告缺章节未被拦截"
else
  ok "scaffold_audit 登记但报告缺章节被拦截（v3.27.14）"
fi
rm -f "$TMP/.devflow/foo/tech-selection.json"
if (cd "$TMP" && bash "$ROOT/scripts/s2_design_coverage_gate.sh" docs/detailed-design/foo-design.md docs/requirements/foo-acceptance-criteria.md); then ok "P2 fixture"; else bad "P2 fixture"; fi
# v3.27.11：响应恒出性 JSON↔正文对账（foo 夹具 §3.2.1 响应表恒出性=是）
python3 - "$TMP" <<'PYEOF'
import json, sys
p = sys.argv[1] + "/.devflow/foo/design.json"
d = json.load(open(p))
d["apis"][0]["response"]["fields"][0]["always"] = "否"
json.dump(d, open(sys.argv[1] + "/.devflow/foo/d-always.json", "w"), ensure_ascii=False)
PYEOF
if (cd "$TMP" && python3 "$ROOT/scripts/df_validate.py" --kind design --input .devflow/foo/d-always.json \
     --criteria docs/requirements/foo-acceptance-criteria.md --doc docs/detailed-design/foo-design.md >/dev/null 2>&1); then
  bad "response 恒出性与正文冲突未被拦截"
else
  ok "response 恒出性 JSON↔正文对账生效（v3.27.11）"
fi
if (cd "$TMP" && bash "$ROOT/scripts/s3_migration_mapping_gate.sh" C docs/数据映射/foo-映射.md 2); then ok "P2 migration fixture"; else bad "P2 migration fixture"; fi

if (cd "$TMP" && bash "$ROOT/scripts/s4_first_pass_snapshot.sh" freeze foo docs/requirements/foo-acceptance-criteria.md docs/detailed-design/foo-design.md); then ok "P4 freeze fixture"; else bad "P4 freeze fixture"; fi
printf 'acceptance_id\tstatus\nM-01-F01-A01\tPASS\n' > "$TMP/first-pass-test.tsv"
# v3.15.8: review 夹具改 markdown 评审表（真实格式）——旧夹具直接写目标 TSV 格式，
# s4 的 BSD 失效提取管道（[^\n]/\b bug）把输入原样落盘恰好合法，恒绿掩盖断裂。
# markdown 行含字母 n（function/login）正是旧 bug 的漏匹配场景。
cat > "$TMP/first-pass-review.md" <<'REVEOF'
| 验收点 | 评审结论 | 说明 |
|--------|----------|------|
| M-01-F01-A01 | PASS | query function works (login action verified) |
REVEOF
if (cd "$TMP" && bash "$ROOT/scripts/s4_first_pass_snapshot.sh" record foo first-pass-test.tsv first-pass-review.md); then ok "P4 record fixture"; else bad "P4 record fixture"; fi
# record 后校验 review 提取真实生效（markdown → per-ID TSV），防止提取管道再静默断裂
if [ "$(wc -l < "$TMP/.devflow/foo/first-pass-review.tsv" | tr -d ' ')" -ge 2 ] \
   && grep -q '^M-01-F01-A01\tPASS$' "$TMP/.devflow/foo/first-pass-review.tsv"; then
  ok "s4 record 从 markdown 评审表提取 per-ID 明细（BSD awk 通用）"
else
  bad "s4 record review 提取断裂（tsv 行数/内容不符）"
fi
if (cd "$TMP" && bash "$ROOT/scripts/s5_migration_gate.sh" C docs/test/foo-migration-evidence.env); then ok "P5 fixture"; else bad "P5 fixture"; fi
if (cd "$TMP" && bash "$ROOT/scripts/s6_first_pass_accuracy.sh" foo 80); then ok "P6 fixture"; else bad "P6 fixture"; fi
if (cd "$TMP" && REPORT=docs/test/foo-graph-evidence.env bash "$ROOT/maintenance/s8_graph_health_gate.sh" foo); then ok "graph fallback fixture"; else bad "graph fallback fixture"; fi

# v3.16.0（P0-2）: p3b 角色隔离结构化字段——同人自签/缺字段必须阻断
RV="$TMP/rv-p3b"; mkdir -p "$RV/docs/review" "$RV/docs/detailed-design" "$RV/docs/requirements" "$RV/backend/svc-x/src/main/java"
printf '# design\nM-01-F01-A01\n' > "$RV/docs/detailed-design/foo-design.md"
printf '# criteria\nM-01-F01-A01\n' > "$RV/docs/requirements/foo-acceptance-criteria.md"
printf '# review\nDEVELOPER_ID: alice\nREVIEWER_ID: alice\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$RV/docs/review/foo-code-review-report.md"
(cd "$RV" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1) && bad "p3b 同人自签被阻断" || ok "p3b 同人自签被阻断（DEVELOPER_ID=REVIEWER_ID）"
printf '# review\n开发者: alice\n审查者: bob\n' > "$RV/docs/review/foo-code-review-report.md"
(cd "$RV" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1) && bad "p3b 缺结构化角色字段被阻断" || ok "p3b 缺结构化角色字段被阻断（缺失即 P0）"
printf '# review\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$RV/docs/review/foo-code-review-report.md"
(cd "$RV" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1) && ok "p3b 角色隔离通过（不同 ID + 单服务推导）" || bad "p3b 角色隔离通过（不同 ID）"
# v3.16.0（P0-3）: 收据证据绑定——删证据后 audit-receipts 必须阻断
(cd "$RV" && bash "$ROOT/scripts/p3b_code_review_gate.sh" foo >/dev/null 2>&1 || true)
rm "$RV/docs/review/foo-code-review-report.md"
(cd "$RV" && bash "$ROOT/scripts/audit-receipts.sh" foo .devflow docs >/dev/null 2>&1) && bad "p3b 删证据后审计阻断" || ok "p3b 删证据后审计阻断（EVIDENCE_TREE 绑定生效）"
printf '# review\nDEVELOPER_ID: alice\nREVIEWER_ID: bob\nREVIEW_SESSION_ID: s1\nM-01-F01-A01 ok\n' > "$RV/docs/review/foo-code-review-report.md"
(cd "$RV" && bash "$ROOT/scripts/audit-receipts.sh" foo .devflow docs >/dev/null 2>&1) && ok "p3b 证据齐备后审计通过" || bad "p3b 证据齐备后审计通过"

# v3.16.0（P0-1）: s6_final_verification_gate——FAIL>0/证据缺失必须阻断，齐备才通过
FV="$TMP/fv-s6"; mkdir -p "$FV/.devflow/foo"
printf 'ID\tSTATUS\nA01\tPASS\nA02\tFAIL\n' > "$FV/.devflow/foo/final-verification.tsv"
(cd "$FV" && bash "$ROOT/scripts/s6_final_verification_gate.sh" foo >/dev/null 2>&1) && bad "s6-final FAIL 验收点被阻断" || ok "s6-final FAIL 验收点被阻断（部署前 FAIL=0）"
printf 'ID\tSTATUS\nA01\tPASS\nA02\tPASS\n' > "$FV/.devflow/foo/final-verification.tsv"
(cd "$FV" && bash "$ROOT/scripts/s6_final_verification_gate.sh" foo >/dev/null 2>&1) && bad "s6-final 零测试证据被阻断" || ok "s6-final 零测试证据被阻断（五类证据必须齐备）"
printf 'UNIT_CMD=mvn test\nUNIT_EXIT=1\nUNIT_REPORT_PATH=/nonexistent\nUNIT_REPORT_SHA256=deadbeef\nINTEGRATION_CMD=x\nINTEGRATION_EXIT=1\nINTEGRATION_REPORT_PATH=/nx\nINTEGRATION_REPORT_SHA256=deadbeef\nCLIENT_CMD=x\nCLIENT_EXIT=1\nCLIENT_REPORT_PATH=/nx\nCLIENT_REPORT_SHA256=deadbeef\nLOAD_CMD=x\nLOAD_EXIT=1\nLOAD_REPORT_PATH=/nx\nLOAD_REPORT_SHA256=deadbeef\nSTAGING_CMD=x\nSTAGING_EXIT=1\nSTAGING_REPORT_PATH=/nx\nSTAGING_REPORT_SHA256=deadbeef\nENVIRONMENT=invalid\n' > "$FV/.devflow/foo/test-evidence.env"
(cd "$FV" && bash "$ROOT/scripts/s6_final_verification_gate.sh" foo >/dev/null 2>&1) && bad "s6-final 伪证据（exit≠0/报告缺失/环境非法）被阻断" || ok "s6-final 伪证据（exit≠0/报告缺失/环境非法）被阻断"

# v3.15.1 负向：一行式占位 fallback 证据不再被认可（须五要素记录）
printf '# source review\n' > "$TMP/docs/test/foo-source-review.md"
if (cd "$TMP" && REPORT=docs/test/foo-graph-evidence.env bash "$ROOT/maintenance/s8_graph_health_gate.sh" foo >/dev/null 2>&1); then
  bad "graph gate 拒绝一行式占位 fallback 证据"
else
  ok "graph gate 拒绝一行式占位 fallback 证据"
fi
# 还原实质化 fallback（保持后续报告状态干净）
cat > "$TMP/docs/test/foo-source-review.md" <<EOF
FALLBACK_COMMAND=grep -rn "WHEN 查询 foo" docs/detailed-design/foo-design.md
FALLBACK_SCOPE=foo
FALLBACK_FILES=1
FALLBACK_FINDINGS=2
FALLBACK_SHA256=$FB_LIST_SHA
FALLBACK_FILE_LIST=docs/test/foo-fb-list.txt
EOF

# v3.15.18: s8 options-only 解析回归——flag 首参不再被误当 feature
#（原 FEATURE="${1:-}" 在解析循环前预赋值：--force-fallback/--report/--git-range 全部 exit 2）
OPTOUT=$(cd "$TMP" && bash "$ROOT/maintenance/s8_graph_health_gate.sh" --force-fallback 2>&1); OPTRC=$?
# v3.15.19: rc 维度补强——rc=2 是参数/用法错误（解析失败），rc=1 是无证据的
# 合法 fail-closed 判定；输出与 rc 双断言防两类回归互相掩盖
if ! printf '%s' "$OPTOUT" | grep -q 'invalid feature name' && [ "$OPTRC" -ne 2 ]; then
  ok "s8 options-only 解析不再把 flag 误当 feature"
else
  bad "s8 options-only 解析把 flag 误当 feature（rc=${OPTRC}）"
fi

# v3.15.18: 伪 fallback 实质校验——FINDINGS=0/SHA256=not-a-hash 首次运行即拒
printf 'FALLBACK_COMMAND=x\nFALLBACK_SCOPE=foo\nFALLBACK_FILES=2\nFALLBACK_FINDINGS=0\nFALLBACK_SHA256=not-a-hash\n' > "$TMP/docs/test/foo-fake-review.md"
printf 'status=fallback\nsource_fallback_evidence=docs/test/foo-fake-review.md\n' > "$TMP/docs/test/foo-fake-evidence.env"
if (cd "$TMP" && REPORT=docs/test/foo-fake-evidence.env bash "$ROOT/maintenance/s8_graph_health_gate.sh" foo >/dev/null 2>&1); then
  bad "s8 拒绝伪 fallback（FINDINGS=0/SHA 占位首次即拒）"
else
  ok "s8 拒绝伪 fallback（FINDINGS=0/SHA 占位首次即拒）"
fi

# v3.15.18: s8 幂等——合法 fallback 首跑后报告保留证据指针，二跑同判 WARN 放行
IDEM1=$(cd "$TMP" && REPORT=docs/test/foo-graph-evidence.env bash "$ROOT/maintenance/s8_graph_health_gate.sh" foo >/dev/null 2>&1; echo $?)
IDEM2=$(cd "$TMP" && REPORT=docs/test/foo-graph-evidence.env bash "$ROOT/maintenance/s8_graph_health_gate.sh" foo >/dev/null 2>&1; echo $?)
if [ "$IDEM1" = "0" ] && [ "$IDEM2" = "0" ] && grep -q '^source_fallback_evidence=' "$TMP/docs/test/foo-graph-evidence.env"; then
  ok "s8 幂等（报告保留证据指针，二跑不误判 blocking）"
else
  bad "s8 幂等（首跑=${IDEM1} 二跑=${IDEM2}——旧版二跑丢指针 FAIL）"
fi

cat > "$TMP/backend/x/src/main/java/Placeholder.java" <<'EOF'
// TODO placeholder only
class Placeholder { String marker = "RestClient"; }
EOF
if (cd "$TMP" && bash "$ROOT/scripts/p4_prd_vs_code.sh" foo --prd docs/prd/foo.md --design docs/detailed-design/foo-design.md --criteria docs/requirements/foo-acceptance-criteria.md --evidence docs/test/foo-implementation-evidence.tsv --service x >p4.out 2>&1); then
  bad "P4 rejects empty implementation"
else
  grep -q 'P4 GATE: FAIL' "$TMP/p4.out" && ok "P4 rejects empty implementation" || bad "P4 emits deterministic failure"
fi

rm "$TMP/backend/x/src/main/java/Placeholder.java"
mkdir -p "$TMP/backend/x/src/main/java/example" "$TMP/backend/x/src/test/java/example"
cat > "$TMP/backend/x/src/main/java/example/FooController.java" <<'EOF'
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;
@RestController class FooController {
  @PreAuthorize("hasAuthority('SCOPE_foo:list')")
  @GetMapping("/api/foo/list")
  public String list(String page) { return "ok"; }
}
EOF
cat > "$TMP/backend/x/src/main/java/example/FooEntity.java" <<'EOF'
import javax.persistence.Entity;
import javax.persistence.Table;
@Entity @Table(name = "foo") public class FooEntity { private Long id; private Integer page; }
EOF
printf 'class FooControllerTest {}\n' > "$TMP/backend/x/src/test/java/example/FooControllerTest.java"
for dialect in h2 postgresql oracle kingbase; do
  mkdir -p "$TMP/backend/x/src/main/resources/db/migration/$dialect"
  printf 'CREATE TABLE foo (id BIGINT PRIMARY KEY, page INT);\n' > "$TMP/backend/x/src/main/resources/db/migration/$dialect/V1001__foo.sql"
done
# v3.16.26: p3_detail_diff.sh 已并入 p3_completion_gate.sh（不再孤立存在）
# v3.28.1: 正文解析统一到 design_parse_lib.sh（渲染块优先 + CREATE TABLE 回退）
if [ ! -f "$ROOT/scripts/p3_detail_diff.sh" ] \
   && grep -q 'design declares tables missing in Flyway' "$ROOT/scripts/p3_completion_gate.sh" \
   && grep -q 'design_tables_from_doc' "$ROOT/scripts/p3_completion_gate.sh" \
   && grep -qF 'seed_*_menus' "$ROOT/scripts/p3_completion_gate.sh" \
   && grep -qF '(views|pages)/' "$ROOT/scripts/p3_completion_gate.sh" \
   && grep -qF 'CREATE TABLE' "$ROOT/scripts/design_parse_lib.sh"; then
  ok "P3 design-to-Flyway diff merged into p3_completion_gate"
else
  bad "P3 design-to-Flyway diff merged into p3_completion_gate"
fi
cat > "$TMP/docs/test/foo-implementation-evidence.tsv" <<'EOF'
acceptance_id	code_paths	test_paths	status
M-01-F01-A01	backend/x/src/main/java/example/FooController.java	backend/x/src/test/java/example/FooControllerTest.java	PASS
EOF
if (cd "$TMP" && bash "$ROOT/scripts/p4_prd_vs_code.sh" foo --prd docs/prd/foo.md --design docs/detailed-design/foo-design.md --criteria docs/requirements/foo-acceptance-criteria.md --evidence docs/test/foo-implementation-evidence.tsv --service x >p4-green.out 2>&1); then
  grep -q 'P4 GATE: PASS' "$TMP/p4-green.out" && ok "P4 accepts exact evidence" || bad "P4 pass report is missing"
else
  cat "$TMP/p4-green.out"
  bad "P4 accepts exact evidence"
fi

# v3.28.1：渲染版式（api-index 详细定义首列 / table-index 块）必须可解析——不再静默 skip
python3 - "$TMP" <<'PYEOF'
import sys
from pathlib import Path
base = Path(sys.argv[1])
t = (base / "docs/detailed-design/foo-design.md").read_text(encoding="utf-8")
t = t.replace(
    "| GET | /api/foo/list | 分页列表 |",
    "<!-- df:begin:api-index -->\n"
    "| 详细定义 | 方法 | 路径 | 接口名称 | 权限 | 请求字段 | 响应字段 |\n"
    "|---|---|---|---|---|---|---|\n"
    "| §3.2.1 | GET | /api/foo/list | 分页列表 | foo:view | 1 | 1 |\n"
    "<!-- df:end:api-index -->", 1)
t = t.replace(
    "CREATE TABLE foo (id BIGINT PRIMARY KEY, page INT);",
    "<!-- df:begin:table-index -->\n"
    "| 锚点 | 表名 | 字段数 |\n"
    "|---|---|---|\n"
    "| §2 | foo | 2 |\n"
    "<!-- df:end:table-index -->", 1)
assert "df:begin:api-index" in t and "df:begin:table-index" in t
(base / "docs/detailed-design/foo-design-rendered.md").write_text(t, encoding="utf-8")
PYEOF
if (cd "$TMP" && bash "$ROOT/scripts/p4_prd_vs_code.sh" foo --prd docs/prd/foo.md --design docs/detailed-design/foo-design-rendered.md --criteria docs/requirements/foo-acceptance-criteria.md --evidence docs/test/foo-implementation-evidence.tsv --service x >p4-rendered.out 2>&1); then
  if grep -q '详设接口数: 1' "$TMP/p4-rendered.out" \
     && grep -q '所有详设接口已在代码中实现 (1/1)' "$TMP/p4-rendered.out" \
     && grep -q '所有详设表的四方言 Flyway 脚本已生成' "$TMP/p4-rendered.out"; then
    ok "P4 parses rendered api-index/table-index layout (v3.28.1)"
  else
    bad "P4 rendered-layout assertions missing: $(grep -E '详设接口数|详设中无接口|详设表数|详设中无' "$TMP/p4-rendered.out" | tr '\n' ' ')"
  fi
else
  cat "$TMP/p4-rendered.out"
  bad "P4 rejects rendered api-index/table-index layout (v3.28.1)"
fi

# v3.15.11: 负回归钉住——flag 吞参守卫（--prd --design x 必须拒绝而非把 --design 吞为值）
# v3.15.12: 归因精确化——仅 exit 非零时下游 unknown-arg 兜底也能过，加报错文本断言钉住守卫本身
P4OUT=$(cd "$TMP" && bash "$ROOT/scripts/p4_prd_vs_code.sh" foo --prd --design x 2>&1); P4RC=$?
if [ "$P4RC" -ne 0 ] && printf '%s' "$P4OUT" | grep -q "non-flag"; then
  ok "P4 flag-as-value rejected (guard message verified)"; else bad "P4 flag-as-value rejected (guard message verified)"; fi
# v3.15.11: 负回归钉住——build-watchdog feature 白名单（../../evil 路径穿越必须拒绝）
if (cd "$TMP" && bash "$ROOT/scripts/build-watchdog.sh" check "../../evil" >/dev/null 2>&1); then
  bad "build-watchdog path traversal rejected"; else ok "build-watchdog path traversal rejected"; fi
# v3.15.11: 负回归钉住——after-gate-fail-hook 白名单（../../evil 不得在项目外写 feedback）
if (cd "$TMP" && bash "$ROOT/scripts/hooks/after-gate-fail-hook.sh" "../../evil" P3 "boom" >/dev/null 2>&1); then
  bad "fail-hook path traversal rejected"; else ok "fail-hook path traversal rejected"; fi
# v3.15.11: 负回归钉住——s6/s3 无参 fail-closed（v3.15.9 前旧 usage exit 0 = 空跑放行）
if (cd "$TMP" && bash "$ROOT/scripts/s6_first_pass_accuracy.sh" >/dev/null 2>&1); then
  bad "s6 no-arg fail-closed"; else ok "s6 no-arg fail-closed"; fi
if (cd "$TMP" && bash "$ROOT/scripts/s3_migration_mapping_gate.sh" >/dev/null 2>&1); then
  bad "s3 no-arg fail-closed"; else ok "s3 no-arg fail-closed"; fi

finish PHASE_GATES
