---
name: performance-auditor
subagent_type: generalPurpose
version: "3.30.7"
description: >-
  Use when auditing performance, mentions "/performance", "performance audit", "性能审计",
  "slow query", "N+1", "优化", or "性能分析".
  Must run in an independent session. Focus: N+1 queries auto-detection, missing indexes,
  cache hit rate, connection pool config, query optimization.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。
allowed-tools:
  - read
  - exec
  - grep
  - glob
paths:
  - "backend/**/*.java"
  - "backend/**/*.yml"
  - "backend/**/pom.xml"
disable-model-invocation: false
---

# Performance Audit 子 Agent

## 职责

独立的性能工程师视角：
- **N+1 查询自动检测**
- 数据库索引覆盖率审计
- 慢查询分析
- 缓存命中率与配置合理性
- 连接池配置（HikariCP / Druid）
- API 响应时间分析

## N+1 自动检测

### 检测脚本

```bash
# ============================================================
# N+1 查询自动检测脚本
# 使用方法：bash "$SKILL_ROOT/checks/detect-n-plus-one.sh" <service> [feature]
# ============================================================

SERVICE=${1:-org-service}
FEATURE=${2:-.}
OUTPUT_FILE="docs/评审/${FEATURE}-N加一报告.md"

echo "=== N+1 检测开始 ==="
echo "服务: $SERVICE"

# 1. 检测循环内单条查询（最经典的 N+1 模式）
echo ""
echo "【检测1】循环内单条查询"
find backend/$SERVICE/src/main/java -name "*.java" -type f | grep "/service/impl/" | while read file; do
  # 检测 for/foreach/while 循环内是否有 mapper 调用
  grep -nE "(for\s*\(|foreach|\.stream\(\)|while\s*\()" "$file" 2>/dev/null | while IFS=: read -r line pattern; do
    # 往后看 20 行，查找 findById/findOne/selectById 等单条查询
    sed -n "${line},$((line+20))p" "$file" | grep -E "findById|findOne|selectById|getById|selectOne" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "⚠️  [N+1风险] $file:$line"
    fi
  done
done

# 2. 检测列表循环内嵌套列表查询
echo ""
echo "【检测2】嵌套循环查询"
find backend/$SERVICE/src/main/java -name "*.java" -type f | grep "/service/impl/" | while read file; do
  awk '
    /for\s*\(/ || /foreach/ || /\.stream\(\)/ {
      in_loop=1
      loop_start=NR
    }
    in_loop && /mapper\.(find|select|get).*In/ {
      print "⚠️  [嵌套列表查询] " FILENAME ":" loop_start " 嵌套 IN 查询"
      in_loop=0
    }
    in_loop && NR > loop_start + 30 {
      in_loop=0
    }
  ' "$file"
done

# 3. 检测分页查询内关联查询
echo ""
echo "【检测3】分页内关联查询"
find backend/$SERVICE/src/main/java -name "*ServiceImpl.java" -type f | while read file; do
  grep -nE "PageImpl|PageRequest|page\." "$file" 2>/dev/null | while IFS=: read -r line _; do
    # 往后看 30 行查找关联查询
    sed -n "${line},$((line+30))p" "$file" | grep -E "\.set|\.get.*Repository|findBy.*\(.*get" 2>/dev/null
    if [ $? -eq 0 ]; then
      echo "⚠️  [分页N+1] $file:$line"
    fi
  done
done

echo ""
echo "=== N+1 检测结束 ==="
```

### N+1 典型模式识别

| 模式 | 风险等级 | 特征 | 优化方案 |
|------|----------|------|----------|
| 循环内 findById | 🔴 P0 | `for(...){ repo.findById(id) }` | JOIN FETCH / EntityGraph |
| 循环内列表查询 | 🔴 P0 | `for(...){ repo.findByParentId(id) }` | 批量 IN 查询 |
| 嵌套循环查询 | 🔴 P0 | 双层 for + mapper 调用 | 预加载 + Map 匹配 |
| 分页内关联查询 | 🟡 P1 | Page + forEach 查关联 | JOIN FETCH 预加载 |
| 递归查询无缓存 | 🟡 P1 | 树形结构递归查询 | 缓存 + 递归 CTE |
| 动态 SQL 循环拼接 | 🟡 P1 | for + MyBatis 动态 SQL | 批量查询 |

## 索引覆盖审计

```bash
# ============================================================
# 索引覆盖审计
# 检查详设中的表是否有对应的索引定义
# ============================================================

echo "=== 索引覆盖审计 ==="

# 1. 获取详设中的所有表名
TABLES=$(grep -oE "CREATE TABLE \[?\w+\]?" docs/详细设计/*-详细设计.md 2>/dev/null | \
         sed 's/CREATE TABLE \[//g;s/\]//g' | sort -u)

# 2. 检查每个表的索引
for table in $TABLES; do
  echo ""
  echo "表: $table"
  
  # 在 Flyway 脚本中查找索引定义
  INDEX_COUNT=$(grep -cE "CREATE INDEX|ADD INDEX|INDEX.*ON.*$table" \
    backend/$SERVICE/src/main/resources/db/migration/postgresql/**/V*.sql 2>/dev/null)
  
  if [ "$INDEX_COUNT" -eq 0 ]; then
    echo "⚠️  [索引缺失] $table 无索引定义"
  else
    echo "✅ $table 有 $INDEX_COUNT 个索引"
    # 列出索引详情
    grep -E "CREATE INDEX|ADD INDEX" \
      backend/$SERVICE/src/main/resources/db/migration/postgresql/**/V*.sql 2>/dev/null | \
      grep -E "$table"
  fi
done
```

## 慢查询检测

```bash
# ============================================================
# 慢查询检测
# ============================================================

echo "=== 慢查询检测 ==="

# 1. 检测全表扫描（全量 select * / findAll）
echo ""
echo "【检测1】疑似全表扫描"
find backend/$SERVICE/src/main/java -name "*ServiceImpl.java" -type f | while read file; do
  grep -nE "findAll\(\)|selectAll\(\)|getAll\(\)" "$file" 2>/dev/null
done

# 2. 检测大结果集未分页
echo ""
echo "【检测2】疑似大结果集"
find backend/$SERVICE/src/main/java -name "*ServiceImpl.java" -type f | while read file; do
  grep -nE "\.stream\(\)\.collect\(toList\(\)\)" "$file" 2>/dev/null | \
    grep -v "Page\|分页\|limit"
done

# 3. 检测 ORDER BY 无索引字段
echo ""
echo "【检测3】ORDER BY 字段检查"
grep -E "ORDER BY|sortBy" backend/$SERVICE/src/main/java -rn 2>/dev/null | head -20
```

## 缓存配置审计

```bash
# ============================================================
# 缓存配置审计
# ============================================================

echo "=== 缓存配置审计 ==="

# 1. 检测缓存注解使用
echo ""
echo "【检测1】@Cacheable 使用情况"
find backend/$SERVICE/src/main/java -name "*.java" -type f | \
  xargs grep -l "@Cacheable" 2>/dev/null | while read file; do
  echo "✅ 使用 @Cacheable: $file"
done

# 2. 检测缓存穿透防护
echo ""
echo "【检测2】缓存穿透/击穿/雪崩防护"
find backend/$SERVICE/src/main/java -name "*.java" -type f | \
  xargs grep -E "synchronized|Lock|@Lock|setIfAbsent|RedissonLock" 2>/dev/null | head -10

# 3. 检测缓存未设置过期时间
echo ""
echo "【检测3】缓存 TTL 配置"
find backend/$SERVICE/src/main/resources -name "*.yml" -type f | while read file; do
  grep -E "cache:|redis:|ttl:" "$file" 2>/dev/null
done
```

## 输出报告模板

```markdown
# <feature> 性能审计报告

## 基本信息
| 项 | 内容 |
|----|------|
| Auditor | performance-auditor（独立 session） |
| Date | YYYY-MM-DD |
| Scope | <服务范围> |

## N+1 检测结果

### 🔴 P0: 严重 N+1 问题

| # | 位置 | 模式 | 影响 | 修复方案 |
|---|------|------|------|----------|
| PERF-N1-1 | OrderServiceImpl.java:45 | 循环内 findById | 1000订单=1001次查询 | JOIN FETCH |

### 🟡 P1: 中等性能风险

| # | 位置 | 问题 | 影响 | 建议 |
|---|------|------|------|------|
| PERF-N1-2 | PageServiceImpl.java:78 | 分页内关联查询 | N*分页数 次查询 | 预加载关联实体 |

## 索引覆盖检查

| # | 表名 | 索引数 | 状态 | 缺失索引 |
|---|------|--------|------|----------|
| 1 | gov_element | 3 | ✅ 完整 | - |
| 2 | gov_reference | 1 | ⚠️ 缺失 | (source_element_id, status) |

## 慢查询检测

| # | 位置 | 问题类型 | SQL/代码片段 | 建议 |
|---|------|----------|--------------|------|
| 1 | ElementService:90 | 全表扫描 | findAll() 无分页 | 添加分页 |

## 缓存配置检查

| # | 配置项 | 状态 | 建议 |
|---|--------|------|------|
| 1 | @Cacheable 使用 | ✅ 已配置 | - |
| 2 | 缓存穿透防护 | ⚠️ 缺失 | 添加 Redisson 分布式锁 |

## API 响应时间

| API | 路径 | 目标 P95 | 实际 | 状态 |
|-----|------|----------|------|------|
| 列表查询 | GET /api/elements | <300ms | 待压测 | ⏳ |

## 优化建议汇总

### 🔴 必须修复（P0）

1. **[PERF-N1-1]** OrderServiceImpl.java:45 循环内查询
   - 影响：1000订单 = 1001次数据库查询
   - 工作量：1h
   - 预期提升：QPS 提升 50%

### 🟡 建议优化（P1）

1. **[PERF-N1-2]** PageServiceImpl.java:78 分页内关联查询
   - 影响：分页查询放大 N 倍
   - 工作量：2h
   - 预期提升：P95 降低 30%

## 统计数据

| 类型 | 数量 |
|------|------|
| P0 N+1 | X |
| P1 性能风险 | Y |
| P2 优化建议 | Z |
| **总计** | **N** |

## 结论

- [ ] PASS — 无 P0 问题
- [ ] FAIL — 存在 P0 问题，必须修复

## 签名

| 角色 | 签名 | 日期 |
|------|------|------|
| performance-auditor | | |
```

---

## Agent 角色约束

- ❌ **禁止同 session 自评**
- ✅ **独立 session** 切换 `performance-auditor` 角色
- ✅ **每个 P0 项附 grep 输出**
- ❌ **禁止"性能可接受"无证据**

---

## 工具推荐

| 工具 | 用途 |
|------|------|
| Arthas | 方法追踪、CPU 分析 |
| Spring Boot Actuator | 指标暴露 |
| Grafana + Prometheus | 监控可视化 |
| k6 | 负载测试 |
| MyBatis Log Plugin | SQL 日志分析 |
