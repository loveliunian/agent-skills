---
name: qa-check
description: 一键代码质量检测命令
version: "3.30.6"
allowed-tools: [read, write, exec, glob, grep, task]
alwaysApply: true
---

# /qa-check — 一键代码质量检测

paths: ["backend/**", "frontend/**"]
> 运行完整的代码质量检测套件

## 功能

一键运行所有代码质量检测：
1. **N+1 查询检测** — 检测数据库查询性能问题
2. **代码规范检测** — 日志/异常/事务/命名规范
3. **Entity 一致性检测** — Entity 与数据库结构一致性
4. **前端规范检测** — Vue/TypeScript 规范
5. **P3 完成度 Gate** — 开发完成度自检

## 使用方式

```
/qa-check M-04
/qa-check <feature-name> [service]
```

### 示例

```bash
# 检测整个模块
/qa-check M-04

# 指定服务
/qa-check M-04 org-service
```

## 手动运行

```bash
# 全量检查（默认后端+前端，脚本从 state 推导 feature）
bash "$SKILL_ROOT/checks/run-all-checks.sh"

# 指定子集 / 跳过前端
bash "$SKILL_ROOT/checks/run-all-checks.sh" --only n+1,code
bash "$SKILL_ROOT/checks/run-all-checks.sh" --no-frontend
```

## 输出

检查结果直接输出到终端（每项尾部 3 行 + 总结），不落报告文件；
退出码 0 = 全部 PASS，非 0 = 至少一项 FAIL。需要留档时由调用方重定向：

```bash
bash "$SKILL_ROOT/checks/run-all-checks.sh" 2>&1 | tee docs/评审/<feature>-质量检查.log
```

## 报告解读

### 汇总报告格式

```markdown
## 检测概览

| 检测项 | 状态 | 报告文件 |
|--------|------|----------|
| N+1 查询检测 | ✅ 通过 | 01-n-plus-one.log |
| 代码规范检测 | ⚠️ 存在问题 | 02-code-standards.log |
| Entity 一致性 | ✅ 通过 | 03-entity-db.log |
| 前端规范检测 | ⚠️ 存在问题 | 04-frontend-standards.log |
| P3 完成度 Gate | ✅ 通过 | 05-p3-gate.log |

## 结论

| 项目 | 状态 |
|------|------|
| **总体状态** | ⚠️ 需要修复 |
| P0 问题数 | 2 |
| P1 问题数 | 5 |
```

## 与 /devflow 的关系

| 场景 | 命令 | 说明 |
|------|------|------|
| 开发完成后 | `/qa-check <feature>` | 在 /build 后运行 |
| Code Review 前 | `/qa-check <feature>` | 确保代码质量 |
| 发布前 | `/qa-check <feature>` | 最终质量检查 |

## 单独检测脚本

如需单独运行某个检测：

```bash
# N+1 查询检测
bash "$SKILL_ROOT/checks/detect-n-plus-one.sh" <service> <feature>

# 代码规范检测
bash "$SKILL_ROOT/checks/check-code-standards.sh" <service> <feature>

# Entity 一致性检测
bash "$SKILL_ROOT/checks/check-entity-db-consistency.sh" <service> <feature>

# 前端规范检测（参数是前端源码目录，默认 frontend）
bash "$SKILL_ROOT/checks/check-frontend-standards.sh" frontend

# P3 完成度 Gate
bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" <service> <feature>
```
