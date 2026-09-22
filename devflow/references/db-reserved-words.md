---
name: db-reserved-words
version: "3.29.2"
description: >-
  数据库关键字规避规则与各数据库关键字清单（P2 详设表/字段命名必读）。
  P2 管线 df_validate 按本文 DEVFLOW:RESERVED-TIERS 契约块对表名/字段名分层机检。
metadata:
  tags: "database,reserved-words,naming,sql"
---

# 数据库关键字规避规则

> P2 详设阶段强制：所有表名、字段名必须规避目标数据库关键字（覆盖所有支持的数据库）。
> 多数据库目标时逐库检查；冲突必须在详设冻结前改完。
> 设计阶段按 §1/§2 全清单规避；机检按下方契约块分层——fail 层命中即 FAIL，warn 层命中输出 ⚠ 警告（不阻断）。

<!-- DEVFLOW:RESERVED-TIERS
fail=user, group, order, desc, key, index, table, column, primary, foreign, references, unique, default, check, select, from, where, insert, update, delete, create, drop, alter, level, condition
warn=username, status, name, type, comment, date, time, timestamp, boolean, integer, text, varchar, char, file, limit, by, sequence, rowid, varchar2, clob, blob, value
-->

## 1. 各数据库关键字清单

| 数据库 | P0-极高风险关键字 | P1-高风险关键字 | P2-中风险关键字 |
|--------|------------------|----------------|----------------|
| **PostgreSQL** | `user`, `group`, `order`, `status`, `name`, `type`, `desc`, `level`, `comment` | `check`, `date`, `time`, `timestamp`, `boolean`, `integer`, `text`, `varchar`, `char` | `select`, `from`, `where`, `insert`, `update`, `delete`, `create`, `drop`, `alter` |
| **MySQL** | `user`, `group`, `order`, `status`, `name`, `type`, `desc`, `key`, `file` | `date`, `time`, `timestamp`, `text`, `table`, `index`, `condition` | `select`, `from`, `where`, `order`, `by`, `limit` |
| **Oracle** | `user`, `group`, `order`, `status`, `name`, `type`, `desc`, `level`, `comment` | `date`, `time`, `timestamp`, `boolean`, `integer`, `varchar2`, `clob`, `blob` | `select`, `from`, `where`, `table`, `index`, `sequence` |
| **KingBase** (人大金仓) | `user`, `group`, `order`, `status`, `name`, `type`, `desc`, `level`, `comment` | `date`, `time`, `timestamp`, `boolean`, `integer`, `text`, `varchar` | `select`, `from`, `where`, `insert`, `update`, `delete`, `create` |

**通用 P0 关键字（所有数据库必须规避）**：

```
user, username, group, order, status, name, type, desc, level, comment,
key, index, table, column, date, time, timestamp, primary, foreign, references,
default, unique, check, boolean, integer, text, varchar, char
```

## 2. 规避策略

| 策略 | 示例 | 适用场景 |
|------|------|----------|
| **前缀法** | `user` → `sys_user`，`order` → `biz_order` | 字段名 |
| **后缀法** | `status` → `status_cd`，`type` → `type_code` | 枚举类字段 |
| **下划线法** | `name` → `user_name`，`date` → `create_date` | 通用场景 |
| **完整词法** | `level` → `priority_level`，`comment` → `remark` | 语义明确 |

## 3. 设计检查点

| 机检层级 | 判定口径 | df_validate 行为 |
|----------|----------|------------------|
| fail（真保留字） | 出现在 ≥1 个受支持数据库的保留字表；未加引号建表/查询即报错 | 校验 FAIL，必须改名后再继续 |
| warn（高风险软关键字） | 关键字/伪列/类型名，部分库可裸用但易踩坑 | 输出 ⚠ 警告（不阻断），建议改名或在表口径说明写明规避理由 |

> 机检范围为 design.json `tables[].name` 与 `tables[].fields[].name`（精确匹配、大小写不敏感；`biz_order`、`status_cd` 这类已按策略规避的名字不算命中）。清单正本即上方 `DEVFLOW:RESERVED-TIERS` 契约块，改动清单只改此处。

```
分文档/单体文档完成后，Agent 必须执行：
1. 检查所有表名、字段名是否命中 §1 清单
2. 如目标多数据库：分别检查各数据库关键字
3. 命中 fail 层立即改名；命中 warn 层改名或写明规避理由
```

## 4. 验证 SQL（按数据库执行）

```sql
-- PostgreSQL
SELECT * FROM pg_get_keywords() WHERE reserved = true;

-- MySQL
SELECT * FROM information_schema.keywords WHERE reserved = true;

-- Oracle（查询数据字典）
SELECT * FROM v$reserved_words WHERE reserved = true;

-- KingBase（兼容 PostgreSQL）
SELECT * FROM pg_get_keywords() WHERE reserved = true;
```
