---
name: severity-tiers
version: "3.30.0"
description: P0/P1/P2 严重程度分级定义（单一来源，被 audit-completeness 和 devflow 共同引用）
---

# P0/P1/P2 严重程度分级定义

> **背景**：v2.0 在 `commands/audit-completeness.md` 和 `commands/devflow.md` 各定义了一份 P0/P1/P2 处理逻辑，容易漂移。本文件作为**单一来源**，两个命令文件都引用本文件。

## 分级定义

| 严重程度 | 含义 | 不允许的处理 |
|----------|------|----------------|
| **P0 阻断** | 阻塞核心功能、安全、数据完整性、合规、不可逆故障 | ❌ "标注为已知风险继续推进"<br>❌ "不影响主流程放过"<br>❌ "下版本修" |
| **P1 高优** | 影响体验但可绕路、有变通方案 | ❌ 默默吞掉不提<br>❌ 拖延 ≥ 1 sprint |
| **P2 中优** | 改进型、非阻塞 | ❌ 默默吞掉不提 |
| **Nit** | 拼写 / 注释 / 命名 | 不阻塞，可忽略 |

## 处理规则

| 严重程度 | 进入下 Phase | 自检报告必含 | owner + ETA |
|----------|--------------|----------------|-------------|
| P0 | ❌ 必须 P0 = 0 | ✅ 完整 stdout + 修复计划 | ✅ 必填 |
| P1 | ✅ 可推进但 | ✅ 列在 "未修复清单" | ✅ 必填 |
| P2 | ✅ 可推进 | ✅ 列在 "未修复清单" | ✅ 必填 |
| Nit | ✅ 可推进 | ❌ 可省略 | ❌ 可省略 |

## 历史教训对应（M-03 案例）

| 严重度 | M-03 实际例子 | v1.7 错误做法 | v2.1 正确做法 |
|--------|---------------|----------------|----------------|
| P0 | 元素删除无 `@PreAuthorize` | 标"有条件不通过"放行 | 必须修复重跑 |
| P0 | Process 删除无分布式锁 | 标"基本就绪"放行 | 必须修复重跑 |
| P0 | merge 编码格式错 | 乐观标 ✅ | 必须修复重跑 |
| P0 | 引用 ACTIVE 唯一性未校验 | 没发现 | 必跑自检 |
| P0 | E2E 48/48 SKIP | 标"通过率 100%" | 必须修复凭据或显式 BLOCKED |
| P0 | 监控三件套缺失 | 标"基本就绪" | 必须 curl + 文件检查 |
| P0 | 文档"已完成"无路径 | 一句话 ✅ | 必须列实际路径 |
| **P0** | **测试报告"尝试 admin/admin123 及多个常见密码"** | **盲猜密码 + 瞎写结论** | **必须从代码 seed 找真实凭证 + 列 3 个候选阻塞原因** |
| **P0** | **新增前端页面但无菜单 seed** | **后端跑通但前端侧边栏不显示 = 用户看不到** | **sql-dev 必须自动生成 4 方言菜单 seed 脚本** |
| **P0** | **菜单 seed 缺 sys_user_effective_perm（admin 授权）** | **admin 看不到菜单** | **必须 4 表 INSERT 齐全** |
| **P0** | **菜单 seed 缺 postgresql setval 序列同步** | **下次 INSERT id 冲突** | **末尾追加 setval 调用** |
| P1 | 部分接口缺缓存 | 不记录 | 列 backlog + ETA |
| P2 | 注释不全 | 不记录 | 列 backlog |

## 新功能交付物不完整（菜单/权限缺失）— P0 阻断

> **背景**：上次执行 M-03 skill 时，前端页面已写完，但 skill 没主动创建菜单 seed SQL 脚本（虽然 M-03 实际有 `V1.0.15__seed_governance_menus.sql`）。这次补上自动检测 + 自动生成机制。

### 触发条件（任意一条 → P0）

| # | 触发场景 | 检测方法 | 修复 |
|---|----------|----------|------|
| 1 | 新增前端 .vue ≥ 1 但无菜单 seed 脚本 | `find frontend/src/views/<feature> -name "*.vue"` vs `find backend/org-service/.../migration -name "*seed_<feature>_menus*.sql"` | sql-dev 必须生成 4 方言菜单 seed |
| 2 | 菜单 seed 缺 `sys_menu` INSERT | grep `INSERT INTO sys_menu` | 补 INSERT |
| 3 | 菜单 seed 缺 `sys_menu_operation` | grep `INSERT INTO sys_menu_operation` | 补 INSERT（每菜单至少 VIEW） |
| 4 | 菜单 seed 缺 `sys_permission_group` | grep `INSERT INTO sys_permission_group` | 补 INSERT（与 perm_code 对齐） |
| 5 | 菜单 seed 缺 `sys_user_effective_perm`（admin 授权） | grep `INSERT INTO sys_user_effective_perm` + `user_id.*1` | 补 admin 全部权限授予 |
| 6 | postgresql 方言缺 `setval` 序列同步 | grep `setval` | 末尾追加 4 行 `setval` |
| 7 | 菜单 seed 只在 1-2 个方言，漏 3-4 个方言 | 4 方言目录逐一 check | 全 4 方言补齐 |
| 8 | 新增 .vue 但 router/*.ts 未注册 | `grep -c "path.*/<feature>" frontend/src/router/*.ts` | frontend-dev 补 router |

### sql-dev 交付物铁律

**生成菜单 seed 的完整模板**（postgresql 方言）：

```sql
-- ============================================================
-- V{VERSION}__seed_{FEATURE}_menus.sql
-- {MODULE} 菜单与权限初始化（{N} 个菜单 + N 个操作 + N 个权限组 + admin 授权）
-- ============================================================

-- ---------- 1. 菜单 ----------
INSERT INTO sys_menu
    (id, parent_id, menu_type, menu_name, route_path, component_path, perm_code, icon, sort_order, visible, status, is_builtin, create_time, create_by, update_time, update_by, version, deleted)
VALUES
    (CATALOG_ID, NULL, 'CATALOG', '<模块中文名>', NULL, NULL, '<feature>:catalog', '<Icon>', 140, 1, 1, 1, CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0, 0, 0),
    (MENU_ID_1, CATALOG_ID, 'MENU', '<页面1>', '/<feature>/<page1>', '<feature>/<page1>/index', '<feature>:<page1>:view', '<Icon>', 10, 1, 1, 1, CURRENT_TIMESTAMP, 0, CURRENT_TIMESTAMP, 0, 0, 0)
ON CONFLICT (id) DO NOTHING;  -- postgresql 方言
-- h2: MERGE INTO 或 IF NOT EXISTS；oracle: WHERE NOT EXISTS；kingbase: 同 postgresql

-- ---------- 2. 菜单操作（每菜单至少 VIEW） ----------
INSERT INTO sys_menu_operation (id, menu_id, op_code, op_name, ...) VALUES ...

-- ---------- 3. 权限组 ----------
INSERT INTO sys_permission_group (id, pg_code, pg_name, ...) VALUES ...

-- ---------- 4. admin 用户权限授予 ----------
INSERT INTO sys_user_effective_perm (id, user_id, pg_id, source, source_id, ...) VALUES
    (XX, 1, XX, 'ROLE', 1, 'ALL', 'ALL', '1', '', ...)
ON CONFLICT (id) DO NOTHING;

-- ---------- 5. 同步序列（postgresql 必需，否则下次 INSERT id 冲突） ----------
SELECT setval(pg_get_serial_sequence('sys_menu', 'id'), GREATEST((SELECT MAX(id) FROM sys_menu), MAX_MENU_ID));
SELECT setval(pg_get_serial_sequence('sys_menu_operation', 'id'), GREATEST((SELECT MAX(id) FROM sys_menu_operation), MAX_OP_ID));
SELECT setval(pg_get_serial_sequence('sys_permission_group', 'id'), GREATEST((SELECT MAX(id) FROM sys_permission_group), MAX_PG_ID));
SELECT setval(pg_get_serial_sequence('sys_user_effective_perm', 'id'), GREATEST((SELECT MAX(id) FROM sys_user_effective_perm), MAX_UEP_ID));
```

### 完整示例参考

参考 M-03 实际产物：`backend/org-service/src/main/resources/db/migration/postgresql/org/V1.0.15__seed_governance_menus.sql`（13 菜单 + 13 操作 + 13 权限组 + 13 admin 授权 + 4 setval）。

### 引用规则

- `commands/build.md` §4 编码范围应链接到本节
- `commands/audit-completeness.md` P3 §12-15 应链接到本节
- `commands/build.md` §2 sql-dev 职责行应链接到本节（开发角色无独立 subagent 文件，职责内联于 build 命令与 `concepts/core.md` §3 角色表）

## 审计错误（盲猜凭证）— P0 阻断

> **背景**：M-03 测试报告 §3.3 写"尝试凭据 `admin/admin123` 及多个常见密码，均返回 `401 WRONG_PASSWORD`"，**属审计错误**。正确做法是从代码 seed 找真实凭证，绝不盲猜。

### 触发条件（任意一条 → P0）

| # | 触发模式 | 检测正则 | 触发后果 |
|---|----------|----------|----------|
| 1 | 测试报告中"尝试.*admin[0-9]+" | `尝试.*admin[0-9]+` | 测试报告必须重写 |
| 2 | 测试报告中"尝试.*多个密码" / "尝试.*常见密码" | `尝试.*(多个\|常见)密码` | 测试报告必须重写 |
| 3 | 测试报告中"穷举.*密码" | `穷举.*密码` | 测试报告必须重写 |
| 4 | 测试报告中"盲猜.*密码" | `盲猜.*密码` | 测试报告必须重写 |
| 5 | 测试用例文档"前置条件"无凭证表（只有"已用 admin 登录"） | 不含 `\| 用户名` 或 `\| 密码` | 测试用例必须重写 |
| 6 | 测试用例文档"前置条件"凭证无代码来源（无 `V*.sql` / `helpers.ts` 等定位） | 不含 `代码来源` 或 `V[0-9].*seed` | 测试用例必须重写 |
| 7 | E2E 脚本硬编码常见密码 `admin123` / `admin888` / `12345678` | `fill\([^)]*['\"](admin123\|admin888\|12345678)['\"]` | E2E 脚本必须改为 `ADMIN_PASSWORD` 常量 |

### 正确做法（凭证可追溯性铁律）

```bash
# 1. 查代码 seed（铁证 — 真实凭证所在地）
grep -l "username.*admin" backend/<service>/src/main/resources/db/migration/*/<service>/V*.sql

# 2. 查 Java 注释（铁证 — 默认密码明示）
grep -B2 -A5 "默认密码\|内置数据" backend/<service>/src/main/java/.../init/BuiltinDataInitializer.java

# 3. 查 E2E helper 默认值
grep "ADMIN_USERNAME\|ADMIN_PASSWORD" frontend/e2e/helpers.ts
```

凭据确定后，测试用例"前置条件"必须用三列表：

| 项 | 值 | 代码来源 |
|---|----|---------|
| 用户名 | 从seed解析 | 精确seed/初始化器路径 |
| 密码 | 报告中脱敏 | 受控环境变量 + seed来源 |
| E2E helper | 从 `process.env` 读取，无常见密码回退 | `frontend/e2e/helpers.ts` |
| 环境变量覆盖 | `E2E_ADMIN_USERNAME` / `E2E_ADMIN_PASSWORD` | 同上 |

### 登录失败时的正确处理流程（5 步）

1. 查代码 seed（铁证）
2. 查 E2E helper 默认值
3. 确认 E2E 主库是否执行 seed（数据库方言 vs profile 一致）
4. 确认密码是否被手工改（用 `E2E_ADMIN_PASSWORD` 覆盖）
5. 如仍失败，BLOCKED 转 SKIP 必须列**真实的 3 个候选阻塞原因**（不许"凭据失效" 4 字了事）

### 修复模板（测试报告 §3 重写示范）

```markdown
### 3.3 阻塞原因（v2 修订）

❌ 旧版结论已作废：原 §3.3 误判"尝试 admin/admin123 及多个常见密码"。

✅ 正确做法：测试登录凭证从代码 seed 获取。

| 来源 | 凭证 | 文件 |
|------|------|------|
| 内置 seed（4 个方言） | 用户名 + 密码hash/受控说明 | 精确seed路径 |
| 初始化器注释 | 凭据来源说明（不复制明文） | 初始化器精确路径 |
| E2E helper | ADMIN_USERNAME/PASSWORD | helpers.ts:9-10 |

#### 当前实际登录失败原因（3 个候选）
1. 数据库未运行 seed 脚本
2. admin 密码已被手工改过
3. 环境差异（方言不一致）
```

### 引用规则

- `phases/06e-浏览器E2E.md` 的"🚨 登录失败时的正确处理流程"应链接到本节
- `phases/05-测试用例.md` 的"凭证可追溯性铁律"应链接到本节
- `commands/audit-completeness.md` P6 自检应链接到本节
- `commands/test.md` 自检应链接到本节
- `subagents/test-engineer.md` v2.3.1 Gate 应链接到本节

## 自检报告模板中的"未修复清单"段

```markdown
## 未修复 P1/P2 清单

| # | 严重度 | 描述 | 影响范围 | owner | ETA |
|---|--------|------|----------|-------|-----|
| P1-1 | P1 | 列表查询缺缓存 | GET /api/elements | backend-dev | 2026-08-01 |
| P2-1 | P2 | 注释不全 | ElementServiceImpl.java:120 | backend-dev | 2026-08-15 |
```

> **铁律**：自检报告**不含本段** = FAIL 处理。

## 引用规则

- `commands/audit-completeness.md` 的"P0 vs P1/P2 处理逻辑表"应链接到本文件
- `commands/devflow.md` 的"P0/P1/P2 处理逻辑表"应链接到本文件
- 各命令文件的"P0 自检命令"应链接到本文件
