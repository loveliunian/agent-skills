---
name: profile-java-spring-flyway
version: "3.30.8"
description: 内置参考 Profile——Java/Spring Boot/Flyway 四方言 + 菜单权限 seed + JaCoCo。
---

# Profile: java-spring-flyway

`PROFILE_ID=java-spring-flyway` 时，以下规则生效；它们**只属于本 Profile**，不属于核心流程。其他后端技术栈必须在 P1 冻结等价 adapter，不得直接套用本文件断言。

## 能力位绑定

| 能力位 | 本 Profile 实现 |
|---|---|
| `BUILD_ADAPTER` | `mvn -q compile`（Maven 包装器以仓库为准） |
| `TEST_ADAPTER` | `mvn test` |
| `COVERAGE_ADAPTER` | JaCoCo 报告，核心业务覆盖率 ≥ 80% |
| `AUTHORIZATION_ADAPTER` | 所有 Controller 至少一个 `@PreAuthorize`；权限码与权限矩阵对账 |
| `MIGRATION_ADAPTER` | Flyway，四方言目录 `{h2,oracle,postgresql,kingbase}` |
| `CLIENT_BUILD_ADAPTER` | 前端 build + type-check（PC Web/小程序/APP 各自命令） |
| `CLIENT_JOURNEY_ADAPTER` | 真实浏览器 / 开发者工具 / 模拟器或真机旅程 |
| `SECURITY_ADAPTER` | `checks/` 安全与架构陷阱检查器 |

## 1. 代码与分层

- 后端路径：`backend/<service>/src/main/java/...`；单测：`backend/<service>/src/test/java/...`。
- 编码强制基准：`concepts/Java开发手册_黄山版.md`【强制】条款无豁免。
- Mapper = 实体一一对应；接口 + 表名 + 菜单 100% 命中冻结详设。

## 2. 权限与菜单 seed

- 所有 Controller 必须加 `@PreAuthorize`，权限码与 `docs/详细设计/_权限矩阵.md` 对账。
- 新增 PC Web 页面 = 新增菜单 seed（4 方言），含 5 段：
  1. `sys_menu`（CATALOG + 页面 MENU，含 `route_path` + `component_path` + `perm_code`）
  2. `sys_menu_operation`（每菜单至少 VIEW）
  3. `sys_permission_group`（与 `perm_code` 对齐）
  4. `sys_user_effective_perm`（admin `user_id=1` 自动授予全部）
  5. `setval` 序列同步（postgresql 必须）
- 新增 `.vue` 页面必须在 `frontend/src/router/*.ts` 注册 route；无菜单 seed = 前端不可达 = 未完成。

## 3. 数据库迁移（四方言铁律）

- 每个 `CREATE TABLE` / 结构变更同步 4 个方言目录：
  `backend/<service>/src/main/resources/db/migration/{h2,oracle,postgresql,kingbase}/V*.sql`
- 表名 / 字段与 Entity 保持同步；禁止跳过 Flyway 直接改库。
- `concepts/Java开发手册_黄山版.md` 的 MySQL 章节与四方言契约冲突时，以四方言契约为准。

## 4. 前端

- 前端技术栈约束见 `references/frontend-tech-stack.md`；客户端范围由 `--frontend` 冻结并写入 `devflow-client.json`。
