---
name: audit-pitfalls
version: "3.23.0"
description: |
  架构陷阱自检命令。独立于 /audit-completeness，专门扫描 30+ 通用架构陷阱。
  触发场景：任意 Phase 切换前必跑 / Postmortem 后 / 跨项目 onboarding。
  入口：bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all
  修复参考：concepts/architecture-pitfalls.md + docs/架构升级改造计划.md
license: MIT
paths: ["backend/**", "frontend/**", "scripts/*"]
disable-model-invocation: false
allowed-tools: [read, write, exec, glob, grep, task]
metadata:
  author: "xingyunliushui"
  tags: "pitfalls,anti-patterns,architecture,phase-gate"
---

# /audit-pitfalls — 架构陷阱自检

> **核心目标**：把每次"踩过的坑"沉淀为机器可检查的规则，避免后续项目重蹈覆辙。
>
> **与 /audit-completeness 关系**：
> - `/audit-completeness`：广义完成度自检（P0-P10 单轨真实退出码）
> - **`/audit-pitfalls`**：聚焦架构陷阱（30+ Anti-Pattern，跨 Phase 通用）

## 1. 使用场景

| 场景 | 是否触发 | 阻塞？ |
|------|---------|--------|
| 任意 Phase 切换前 | ✅ 必跑 | critical > 0 = 阻塞 |
| /build 后 | ✅ 必跑 | critical > 0 = 阻塞 |
| /audit-completeness 前 | ✅ 必跑 | critical > 0 = 阻塞 |
| 跨服务代码合并前 | ✅ 必跑 | critical > 0 = 阻塞 |
| Postmortem 后 | ✅ 必跑 | 触发新坑登记 |
| 日常开发 | ⚠️ 建议 | 警告不阻塞 |

## 2. 用法

```bash
# 推荐：一键全跑
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all

# 按类别跑
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category security
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category code
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category perf
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category obs
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category deploy
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category test

# 帮助
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --help
```

## 3. 工作流程

### 3.1 阶段 Gate（自动）

1. 跑 `bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all`
2. 退出码 = 0：PASS，可进入下一 Phase
3. 退出码 = 1：FAIL，至少 1 个 critical，**阻塞**

### 3.2 失败的修复流程

1. 看输出中的 `[CRITICAL]` 行
2. 跳到 `concepts/architecture-pitfalls.md` 对应章节
3. 按"修复"段操作
4. 重跑 `bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all`
5. 直到 critical = 0

### 新坑登记（演进机制）

每发现一个 Postmortem（P11）对应的新坑：

1. 在 `concepts/architecture-pitfalls.md` 新增一条 Anti-Pattern
2. 在 `checks/check-arch-pitfalls.sh` 新增对应检查
3. 更新 `audit-pitfalls.md` 本文档
4. 提交 PR，由独立 reviewer 评审

## 4. 11 类陷阱清单

| 类别 | 章节 | 关键检查项 |
|------|------|-----------|
| 配置分散 | §2 | 环境变量命名、配置类重复、硬编码 URL、密钥默认值 |
| API/接口契约 | §3 | 跨服务调用散落、契约无验证、OpenAPI 缺失 |
| 安全/密钥 | §4 | JWT 默认值、部署脚本硬编码密码、CSRF 分散 |
| 依赖/版本 | §5 | 版本不一致、`:latest` 镜像、前端双锁文件 |
| 代码规范 | §6 | 巨型 Service、DTO 重复、ObjectMapper 绕过 |
| 文档同步 | §7 | 测试策略缺失、口径冲突 |
| 性能/缓存 | §8 | N+1 查询、无界缓存、Outbox 散落 |
| 可观测性 | §9 | Actuator 端点、日志格式、监控端点 |
| 运维/部署 | §10 | 备份缺失、资源约束、供应链 |
| 测试 | §11 | 覆盖率 < 70%、契约测试缺失 |

## 实战数据

跑 `bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all` 的真实捕获样例（治理模块类项目）见 `examples/xyls/domain-checklist.md`。典型分布：巨型 Service（>1000 行）、部署脚本硬编码密码、缺 API 文档依赖——均属 §6.1/§4.2 陷阱。

## 6. 与 devflow 阶段对应

| Phase | 必读 Pitfalls | 必跑命令 |
|-------|--------------|---------|
| P0 需求澄清 | §7 文档同步 | `check-arch-pitfalls.sh --category config` |
| P1 技术选型 | §5 依赖/版本 | `check-arch-pitfalls.sh --category deploy` |
| **P2 详细设计** | **§2 配置 + §3 API** | **`check-arch-pitfalls.sh --category config,api`** |
| **P3 编码** | **§6 代码 + §8 性能** | **`check-arch-pitfalls.sh --all`** |
| P3b Review | §6.5 + §9 | `check-arch-pitfalls.sh --category code,obs` |
| P3c Security | §4 | `check-arch-pitfalls.sh --category security` |
| P3d Performance | §8 | `check-arch-pitfalls.sh --category perf` |
| P4 验证 | §3.4 | `check-arch-pitfalls.sh --all` |
| P5-P6 测试 | §11 | `check-arch-pitfalls.sh --category test` |
| P7 部署 | §10 | `check-arch-pitfalls.sh --category deploy` |
| P8 监控 | §9 | `check-arch-pitfalls.sh --category obs` |
| P9 文档 | §7 | `check-arch-pitfalls.sh --all` |
| P10 复盘 | §7.4 | `check-arch-pitfalls.sh --all` |
| **P11 Postmortem** | **§6 + 新坑登记** | 触发 `concepts/architecture-pitfalls.md` 增量 |

## 7. 详细陷阱清单

完整内容见 `concepts/architecture-pitfalls.md`（22 KB）。

每个 Anti-Pattern 包含：
- ❌ 反例代码
- ✅ 正例代码
- 规则说明
- 机器检查命令
- 人工 checklist
- 修复参考

## 8. 用户复盘

> **永远是工程事实优先**：本命令不是简单的"代码风格检查"，而是把**多次 Postmortem + 偏差清单 + 改造经验**固化为自动门控。每个新坑都必须经过"check-arch-pitfalls.sh 验证 → 修复 → 复跑 → 0 critical"流程。

**铁律**：
- ❌ 任何"我知道这是坑但来不及修" → **禁止**
- ❌ 任何"这个坑只在我们项目出现" → **必须**沉淀到 `concepts/architecture-pitfalls.md`
- ✅ 每次发现新坑 → 立刻登记 → 滚动更新门禁脚本

## 9. 一句话原则

> **架构不是一次性设计，而是与坑的持续对抗。把每次踩过的坑变成不可绕过的规则。**
