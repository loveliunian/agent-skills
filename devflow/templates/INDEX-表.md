---
name: INDEX-表
version: "3.30.3"
description: 表索引模板（详设期望逻辑表 + 与 auto 生成版并存）
---

# INDEX-表.md


> **本文件由 `scripts/generate-table-index.sh` 自动生成**
> **手工维护请在每个 `M-*` 详设数据模型节（完整版 §2.2 / 分文档 §2.3）用标准格式填表**
> **生成时间: {DATE}**

---

## 1. 表前缀清单

| 前缀 | 服务 | 说明 |
|---|---|---|
| `{prefix}_*` | {service} | 由项目总详设冻结 |

> **本项目实际表前缀**：

```bash
find backend -name '*.sql' -type f -exec grep -hE '^[[:space:]]*CREATE[[:space:]]+TABLE' {} + \
  | sed -E 's/.*CREATE[[:space:]]+TABLE[[:space:]]+([a-zA-Z0-9_]+).*/\1/' | sort -u
```

---

## 2. 全量表索引（按服务聚合）

> **本节由脚本自动填入**：聚合各 `M-*` 详设数据模型节中的表结构小节（完整版 §2.2 / 分文档 §2.3）+ 实际 Flyway DDL

| 表名 | 服务 | 详设章节 | Flyway 脚本 | 备注 |
|---|---|---|---|---|
| _(自动生成)_ | | | | |

---

## 3. 跨服务外键

| 源表.字段 | 目标表.字段 | 跨服务 | 用途 |
|---|---|---|---|
| _(自动生成 — 基于 `_ER图索引.md` 复用)_ | | | |

---

## 4. 表前缀 vs 服务 映射（断言 / 反断言）

- 反断言：所有表都必须在 `<service>` 服务的 Flyway 目录中定义
- 断言：跨服务外键只能通过 MQ / OpenFeign / id 弱引用，不允许硬外键
- 反断言：每个项目冻结的表前缀只能由对应服务维护

---

## 5. 生成命令

```bash
bash "$SKILL_ROOT/scripts/generate-table-index.sh" [DOC_DIR]
# 默认 DOC_DIR=docs/详细设计
```

> **再生成**：每次详设更新或 DDL 变更后跑一次。
