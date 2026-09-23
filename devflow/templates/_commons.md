---
name: _commons
version: "3.29.7"
description: 工程公约骨架（公共字段/错误码/缓存/幂等/2FA/审计等单一事实源）
---

# 工程公约（Engineering Commons）


> 
> **目的**：把"公共字段 / 错误码 / 缓存 / 幂等 / 异步 / 菜单 seed / 2FA / 审计 / 数据权限"等约定统一到**单一事实源**
> **生成方式**：手写 §0～§N（无自动生成）
> **联动**：`s1_fact_sources_gate.sh` 强制存在；P4按冻结验收ID检查实现证据。

---

## 0. 速览

| # | 主题 | 状态 | 关键指标 |
|---|---|---|---|
| 1 | 公共字段约定 | {已冻结/草拟} | 7 字段 / 4 方言一致 |
| 2 | 统一响应格式 | {已冻结/草拟} | `{code, data, message, timestamp}` |
| 3 | 错误码体系 | {已冻结/草拟} | 段位 0XXX/1XXX/2XXX |
| 4 | 缓存策略 | {已冻结/草拟} | Redis 多级 + Caffeine 本地 |
| 5 | 幂等协议 | {已冻结/草拟} | Header `Idempotency-Key` |
| 6 | 异步处理 | {已冻结/草拟} | XXL-JOB + ThreadPool |
| 7 | 菜单 Seed 规范 | {已冻结/草拟} | 5 段 + 4 方言 |
| 8 | 2FA 主开关 | {已冻结/草拟} | sys_unlock_otp + 配置项 |
| 9 | 审计规约 | {已冻结/草拟} | audit_log + 全链路 |
| 10 | 数据权限维度 | {已冻结/草拟} | 5 维：all/dept/self/role/... |

---

## 1. 公共字段约定（7 字段）

> 适用于所有业务表。BaseEntity 含这 7 字段。

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `id` | bigint | auto | 主键 |
| `create_by` | varchar(64) | 'system' | 创建人 |
| `create_by_name` | varchar(100) | '' | 创建人姓名 |
| `create_at` | datetime | now() | 创建时间 |
| `update_by` | varchar(64) | 'system' | 最后修改人 |
| `update_at` | datetime | now() | 最后修改时间 |
| `is_deleted` | tinyint | 0 | 逻辑删除 |

```sql
-- h2 / postgresql / oracle / kingbase 通用
-- 公共字段定义参见 common/BaseEntity.java
```

---

## 2. 统一响应格式

```java
public class ApiResponse<T> {
    private int code;          // 0 = 成功
    private T data;            // 业务数据
    private String message;    // 中文错误描述
    private long timestamp;    // 服务端时间戳
}
```

| 段位 | 含义 | 状态 |
|---|---|---|
| `code` | 错误码（成功 0） | 必含 |
| `data` | 业务数据 | 可空 |
| `message` | 描述 | 成功时 `OK` |
| `timestamp` | ms 时间戳 | 必含 |

---

## 3. 错误码体系

### 3.1 段位定义

| 段位 | 范围 | 模块 | 容量 |
|---|---|---|---|
| 0XXX | 成功 / 客户端通用 | 通用 | 1000 |
| 1XXX | 业务错误 | 业务通用 | 1000 |
| 2XXX | 数据错误 | 数据 | 1000 |
| 3XXX | 系统错误 | 系统 | 1000 |
| 4XXX | 第三方错误 | 外部 | 1000 |
| 5XXX | 认证授权 | 安全 | 1000 |
| 8XXX | 治理 / 回收站 | 治理 | 1000 |
| 9XXX | 预留 | — | 1000 |

### 3.2 错误码示例

| 码 | msg | 模块 |
|---|---|---|
| 0 | 成功 | 通用 |
| 1001 | 参数校验失败 | 业务 |
| 2001 | 数据不存在 | 数据 |
| 3001 | 系统异常 | 系统 |
| 4001 | 第三方接口失败 | 外部 |
| 5001 | 未认证 | 安全 |
| 5003 | 无权限 | 安全 |

---

## 4. 缓存策略

| 维度 | 选型 | 适用 |
|---|---|---|
| 本地缓存 | Caffeine | 字典项/常量（高频读） |
| 分布式缓存 | Redis | 跨节点共享 |
| 一级缓存 | SQL 内部 HCache | 单服务高频 |
| 二级缓存 | Redis | 跨服务中频 |
| 多级失效 | TTL + 事件广播 | 字典变更 |

---

## 5. 幂等协议

- **Header**: `Idempotency-Key: <UUID-v4>`
- **生效范围**: 写操作（POST/PUT/DELETE）
- **存储**: `std_idempotency_log` 表
- **TTL**: 24h
- **冲突**: 重复 key 直接返回上一次的响应（不重处理）

---

## 6. 异步处理

- **定时任务**: XXL-JOB + `ops_execution` + `xxl_job_*` 表
- **领域事件**: Spring Event + 异步 @Async
- **重试**: Spring Retry + 死信表 `std_dead_letter_operation`

---

## 7. 菜单 Seed 规范（5 段）

| 段 | 表 | 说明 |
|---|---|---|
| 1 | `sys_menu` | 菜单树 |
| 2 | `sys_menu_operation` | 菜单关联的按钮/操作 |
| 3 | `sys_permission_group` | 内置权限组 |
| 4 | `sys_user_effective_perm` | 用户最终有效权限 |
| 5 | `ALTER SEQUENCE ...` | 重置序列（4 方言独立） |

> 详见 `_菜单Seed索引.md` §2 命名规则

---

## 8. 2FA 主开关

- **依赖**: `sys_unlock_otp` 表 + `auth.2fa.enabled` 配置
- **默认**: dev=true, prod=false
- **强制角色**: `system_admin` / `super_admin` 始终强制

---

## 9. 审计规约

| 维度 | 选型 | 说明 |
|---|---|---|
| 业务审计 | `audit_log` | 写关键状态变化 |
| 登录审计 | `sys_login_audit` | 登录失败/锁定 |
| 数据审计 | 影子表 | 关键表的数据变更 |
| AOP 拦截 | `audit-log-service` 注解 | `@Audited` |

---

## 10. 数据权限维度

| 维度 | 含义 |
|---|---|
| `all` | 全部数据 |
| `dept` | 本部门 |
| `dept_and_sub` | 本部门及子部门 |
| `self` | 仅本人 |
| `role` | 同角色 |
| `custom` | 自定义 SQL |

---

## 11. 联动索引

- 权限矩阵：`./_权限矩阵.md`
- 环境账号：`./_环境与账号.md`
- 接口清单：`./INDEX-接口.md`
- 章节锚点：`./INDEX-章节锚点.md`
- 菜单 Seed：`./_菜单Seed索引.md`
- ER 图：`./_ER图索引.md`
- Schema 变更：`./_Schema变更日志.md`

---

## 12. 模板变量约定

- 所有未解析变量必须使用双花括号：`{{variable_name}}`。
- 不得引入新的 `<name>` 或 `{name}` 占位符；历史产物保持原样，不回改。
- 常用变量：

| 变量 | 含义 |
|---|---|
| `{{feature_id}}` | feature / change 标识 |
| `{{service_name}}` | 目标服务 |
| `{{frontend_scope}}` | 冻结的客户端范围 |
| `{{acceptance_id}}` | 原子验收点 ID |
| `{{evidence_path}}` | 证据文件路径 |

产物中残留任何未解析 `{{...}}` 记号即视为未完成，对应 Gate 不得判定通过（本文档举例说明处除外）。
