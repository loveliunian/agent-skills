# 系统架构基线（skill 内置，详设生成的默认上下文）

> 生成详设时**必须先读本文件**：
> `meta.techStack` 从此继承（不再写"PRD 未指定"）；REST 契约、表结构按本基线的规范设计。
> 模块基线与系统基线冲突时，在问题清单登记 conflict 交裁决，禁止静默二选一。

## 1. 技术栈

### 前端

| 选型                              | 说明                          |
| --------------------------------- | ----------------------------- |
| Vue 3 + TypeScript + Vite         | PC Web 单页应用，路由全懒加载 |
| Element Plus + Pinia + Vue Router | UI/状态/路由                  |

### 后端

| 选型                      | 说明                                   |
| ------------------------- | -------------------------------------- |
| Java 17 + Spring Boot 3.x | 单体服务，内嵌容器，无网关、无注册中心 |
| MyBatis-Plus + Flyway     | 数据访问 + 启动自动迁移与 seed         |

### 数据库与运行环境

- H2 文件模式 `jdbc:h2:file:./data/{service}`，仅此一种方言；
- 后端 `mvn spring-boot:run` + 前端 `npm run dev`（代理 /api），或前端构建产物交 Spring Boot 静态托管；
- **不引入**：Redis、MinIO、消息队列、调度中心、Docker 编排。

## 2. 全局接口规范（REST 契约设计的强制约束）

| 规范项    | 要求                                                           |
| --------- | -------------------------------------------------------------- |
| 协议/格式 | HTTP JSON，UTF-8                                               |
| 路径      | 统一`/api/**`，资源名复数小写（如 `/api/organizations`）   |
| 动词语义  | GET 查询 / POST 新建 / PUT 全量改 / PATCH 局部改 / DELETE 删除 |
| 分页      | `{ total, records[] }`，size ∈ [1,200]                      |
| 幂等      | 关键写操作携带 Idempotency-Key / request_id                    |

### 统一响应结构

```json
{ "code": 200, "message": "success", "data": { }, "timestamp": "2026-09-15 10:00:00" }
{ "code": 400, "bizCode": "VALIDATION_FAILED", "message": "请求参数错误", "data": null, "timestamp": "..." }
```

- `code` 恒为数字且与 HTTP 状态码一致；`bizCode` 仅失败时出现（大写下划线业务码）；
- 设计接口时 `errors` 优先引用下方**通用 bizCode 表**；模块专属业务码（如 ORG_HAS_USERS）由各详设按需自定义，不进本表。

### 全局错误码（通用 bizCode 枚举，仅保留三个，详设可直接引用）

| bizCode           | HTTP | 语义                                       |
| ----------------- | ---- | ------------------------------------------ |
| VALIDATION_FAILED | 400  | 请求参数/字段校验错误（按 fieldPath 定位） |
| NOT_FOUND         | 404  | 资源不存在（越权对象不以 404 泄露存在性）  |
| INTERNAL_ERROR    | 500  | 服务器内部错误                             |

> 业务语义冲突（重复、状态不允许、引用保护等）不走全局码，由各详设定义模块专属 bizCode。

### DTO/VO 命名

`XxxRequest`（请求）/ `XxxResponse`（响应）/ `XxxDto`（内部传输）/ `XxxVo`（视图）。

## 3. 全局业务规则（详设 rules 的公共底座，不重复登记）

| 规则ID | 描述                                        |
| ------ | ------------------------------------------- |
| GR02   | 时间存储本地时区、展示按客户端              |
| GR05   | LocalDateTime 序列化`yyyy-MM-dd HH:mm:ss` |

详设 rules 只登记**模块专属**规则；通用规则默认继承本表，特殊情况才覆写并在问题清单说明。

## 4. 数据库迁移约定

- Flyway：`backend/{service}/src/main/resources/db/migration/`，仅 H2 方言，启动自动执行；
- 表名前缀按模块定（如治理 `gov_`/`recycle_`），详设 tables 的 name 必须带模块前缀；
- 每表默认携带：`id bigint PK`、`created_by/created_at/updated_by/updated_at`（AR01）、逻辑删除标记（GR03）——**这些公共列不必逐表罗列，用一行说明"含公共列(基线 §3)"即可，但模块专属列必须完整**。
