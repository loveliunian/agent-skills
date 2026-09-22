---
name: performance
version: "3.29.2"
description: >-
  Use when auditing performance bottlenecks, slow queries, or scalability issues, mentions
  "/performance", "性能", "performance audit", "性能审计", "N+1", "slow query", "优化", or "load test".
  Must run in independent session (performance-auditor subagent). Focus: N+1, missing indexes, cache hit rate, connection pool.
paths:
  - "backend/**/*.java"
  - "backend/**/*.yml"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
---

# /performance - 性能审计（P3d）

> **核心约束**：必须由 `performance-auditor` 角色在**独立 session** 中执行，**禁止开发 Agent 自评**。

## 使用方式

```
/performance <feature>
/performance <feature> --scope=<path>
```

## 示例

```
/performance m-03-basic-library
/performance payment-system --scope=backend/payment-service
```

## 命名约定

输出：`docs/评审/<feature>-性能审计报告.md`

## 执行步骤

### 1. N+1 查询扫描

```bash
# 查找典型 N+1 反模式（POSIX：find 替代 ** glob）
find backend/<service>/src/main/java -name "*.java" -type f | grep "/service/impl/" \
  | xargs grep -nE "for.*in.*\\bList" 2>/dev/null | head -20

# 关联查询：mapper 一个方法内 selectList 多次
find backend/<service>/src/main/java -name "*.java" -type f | grep "/service/impl/" \
  | xargs grep -nE "selectList|selectById" 2>/dev/null | wc -l
```

### 2. 索引覆盖审计

```bash
# 详设表清单（table-index 渲染块，回退 CREATE TABLE）与 Flyway 索引交叉对比
Windows / macOS / Linux 通用：while-read 替代 for f in $(...)
grep -hiE "^CREATE[[:space:]]+TABLE([[:space:]]+IF[[:space:]]+NOT[[:space:]]+EXISTS)?[[:space:]]+" \
              backend/<service>/src/main/resources/db/migration/postgresql/*.sql 2>/dev/null \
  | awk '{print $NF}' | tr -d '(' | sort -u > /tmp/tables.txt

while IFS= read -r table; do
  index_count=$(grep -cE "CREATE INDEX.*${table}|INDEX.*ON ${table}" \
    backend/<service>/src/main/resources/db/migration/postgresql/*.sql 2>/dev/null | awk '{s+=$1} END {print s+0}')
  echo "$table: $index_count 个索引"
done < /tmp/tables.txt
rm -f /tmp/tables.txt
```

### 3. 慢查询风险（抽象规则）

```bash
# 批量写操作是否在循环内逐条 commit（应为事务批量）
grep -rnA5 "batchDelete\|batchSave" backend/<service>/src/main/java --include="*.java" | grep -E "commit|for|while"

# 导出/报表是否全表加载到内存（应分页/流式）
grep -rnE "export|导出" backend/<service>/src/main/java --include="*.java" -A5 | grep -E "selectList|findAll|stream"
```

项目特定专项示例（治理模块类）见 `examples/xyls/domain-checklist.md`。

### 4. 缓存配置合理性

```bash
# Redisson 配置
find backend/<service>/src/main/java -name "*Config.java" -type f \
  -exec grep -nE "RedissonClient|RLock|RBucket" {} +

# 是否有缓存穿透/击穿/雪崩防护
find backend/<service>/src/main/java -name "*.java" -type f \
  -exec grep -nE "@Cacheable|@CacheEvict" {} + | head -20
```

### 5. 输出报告

写入 `docs/评审/<feature>-性能审计报告.md`：

```markdown
# <feature> 性能审计报告

## 基本信息
- Auditor：performance-auditor
- Date：YYYY-MM-DD
- Scope：<服务范围>

## 关键 API P95（待压测填充）
| API | 详设阈值 | 实测 | 结论 |
|----|---------|------|------|
| GET /api/<resource> | <300ms | 待压测 | — |
| POST /api/<resource> | <500ms | 待压测 | — |

## N+1 风险
| # | 位置 | 描述 | 修复 |
|---|------|------|------|
| PERF-1 | <ServiceImpl>.java:<line> | 循环内逐条 selectList | 用 JOIN/IN 聚合 |

## 索引缺失
| # | 表 | 详设索引 | 实际 | 证据 |
|---|----|----------|------|------|
| PERF-2 | gov_reference | (source_element_id, status) | 缺失 | grep 输出 |

## 慢查询风险
...

## 连接池 / 缓存
- HikariCP 配置：...
- Redisson 配置：...

## 结论
- [ ] PASS — 无 P0
- [ ] FAIL — P0 > 0
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 报告路径 | `docs/评审/<feature>-性能审计报告.md` 实际写入 |
| 关键 API P95 | < 详设阈值（待压测填充） |
| N+1 风险 | P0 项必须 = 0 |
| 索引覆盖 | 详设要求的索引必须全部建 |
| 独立性 | 必须独立 session |

## 输出

- `docs/测试/<feature>-压测报告.md`——**由 JSON 正本渲染**（见下）

### 结构化产物层（v3.25.2 · 失败关闭）

压测结果先落结构化正本，再渲染为报告，最后进 Gate：

1. 按 `schemas/performance.schema.json` 填 `.devflow/<feature>/performance.json`：
   `scenarios[]`（每场景 name、`p95_ms` 实测、`threshold_ms` 冻结阈值、status；
   p95 超阈值不得标 PASS）、`nplus1_suspicious`、`report_path`；
2. 渲染：`python3 "$SKILL_ROOT/scripts/df_pipeline.py" performance \
   --input .devflow/<feature>/performance.json \
   --out docs/测试/<feature>-压测报告.md`（校验失败不渲染；渲染含逐场景
   `P95 <p95> ms` 机器行，Gate 与 JSON 逐场景对账，双事实源漂移即拦截）；
3. `p3_security_perf_gate.sh` 失败关闭校验该 JSON，收据绑定其 SHA 并纳入证据树。

## 自检命令

```bash
# P3d Gate: 性能审计（v3.9.4）
bash "$SKILL_ROOT/scripts/p3_security_perf_gate.sh" <feature> --mode performance
P0_COUNT=$(grep -c "^### PERF-\\|^| PERF-" docs/评审/<feature>-性能审计报告.md)
echo "性能 P0 项数: $P0_COUNT"
test "$P0_COUNT" -eq 0  # 必须 = 0

# Flyway 索引覆盖率
DETAIL_TABLES=$(grep -c "^### 表\\|^#### 表\\|CREATE TABLE" docs/详细设计/<feature>-详细设计.md)
FLYWAY_INDEXES=$(grep -rc "CREATE INDEX" backend/<service>/src/main/resources/db/migration/postgresql/ | awk -F: '{s+=$2} END {print s}')
echo "索引数: $FLYWAY_INDEXES, 详设表数: $DETAIL_TABLES"
```

## 角色约束

- ❌ **禁止同 session 自评**
- ✅ **独立 session** 切换 `performance-auditor` 角色
- ✅ **每个 P0 项附 grep 输出**
- ❌ **禁止"性能可接受"无证据**

## 与其他命令关系

- 与 `/review` `/security` **并行**执行（旁路命令）
- `/performance` P0 = 0 不是 P3 → P3b 的硬 Gate
- 但 P0 项进入"未修复清单"跟踪
- 实测 P95 数据由 P6d 压测阶段填充
- 完成后由独立 session 的 `completeness-auditor` 运行 `/audit-completeness P3d <feature>` 复核

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/p3_security_perf_gate.sh" <feature>
# 期望：exit 0 = 性能审计证据齐备；FAIL 即阻断
```

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
