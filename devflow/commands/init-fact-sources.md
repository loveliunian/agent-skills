---
name: init-fact-sources
description: "Use when initializing or validating a project's engineering fact sources before detailed design or implementation."
version: "3.31.0"
license: MIT
paths: ["docs/**", "scripts/*", "backend/**"]
compatibility: Devflow agent skill; requires a repository workspace and command execution.
metadata:
 author: "xingyunliushui"
 tags: "documentation,baseline,auto-generation,p2,fact-sources"
allowed-tools: [read, write, exec, glob, grep, task]
---

# /init-fact-sources — 项目文档基线初始化

> 
> 单一职责：在任意项目根目录生成 **7份事实源模板 + 5份自动产物**

## 快速使用

```bash
# 在Skill根执行，或将scripts复制到项目后执行
SKILL_DIR=/absolute/path/to/devflow
bash "$SKILL_DIR/scripts/init-fact-sources.sh"

# 3. （如需强制覆盖）
bash "$SKILL_ROOT/scripts/init-fact-sources.sh" --force

# 4. （如需自定义 DOC_DIR）
DOC_DIR=docs/detailed-design bash "$SKILL_ROOT/scripts/init-fact-sources.sh"
```

## 生成的产物

**6份手维护事实源**（从 `templates/` 复制）：
- `${DOC_DIR}/_commons.md` — 工程公约
- `${DOC_DIR}/_环境与账号.md` — 环境与账号
- `${DOC_DIR}/_菜单Seed索引.md` — 菜单 seed 索引
- `${DOC_DIR}/INDEX-章节锚点.md` — 章节锚点
- `${DOC_DIR}/INDEX-表.md` — 表索引
- `${DOC_DIR}/INDEX-接口.md` — 接口索引

**1份自动+手维护混合**：
- `${DOC_DIR}/_权限矩阵.md` — `scripts/generate-permission-matrix.sh` 自动生成 §2，其他手维护

**5 个 auto 索引**：
- `${DOC_DIR}/_ER图索引.md` ← `scripts/generate-er-index.sh`
- `${DOC_DIR}/_Schema变更日志.md` ← `scripts/generate-schema-changelog.sh`
- `${DOC_DIR}/INDEX-表-auto.md` ← `scripts/generate-table-index.sh`（人工版 INDEX-表.md 不被覆盖）
- `${DOC_DIR}/INDEX-接口-auto.md` ← `scripts/generate-interface-index.sh`（同上）
- `主索引.md`（项目根）← `scripts/generate-master-index.sh`（兼容历史 MASTER.md）

**项目入口**：
- `CLAUDE.md` — Claude Code 项目入口
- `AGENTS.md` — Codex/Cursor 等通用入口

> 重新跑会跳过已存在文件；`--force` 强制覆盖。
> v3.1 起的脚本默认会生成全部 12+ 文件（含 主索引.md + CLAUDE.md + AGENTS.md；3.24.0 前主索引名为 MASTER.md，历史文件存在时沿用不重命名）。

## 使用场景

| 场景 | 命令 |
|---|---|
| **项目初始化（首次）** | `bash "$SKILL_ROOT/scripts/init-fact-sources.sh"` |
| **P2 详设完成后** | 同上（让 §1 §3 自动集成） |
| **新增服务 / 表** | `bash "$SKILL_ROOT/scripts/generate-er-index.sh" && bash "$SKILL_ROOT/scripts/generate-schema-changelog.sh"` |
| **新增 @PreAuthorize** | `bash "$SKILL_ROOT/scripts/generate-permission-matrix.sh"` |
| **CI 检查一致性** | `bash "$SKILL_ROOT/checks/check-permission-consistency.sh"` |

## 与 P3 / P4b 的关系

| 阶段 | 用法 |
|---|---|
| **P2 详细设计后** | 跑一次初始化，把手维护事实源冻结 |
| **P3 编码后** | 重新跑自动生成（permission / ER / schema） |
| **P1 Gate** | `scripts/s1_fact_sources_gate.sh ${DOC_DIR}` 强制7份事实源存在且非空 |
| **P4b Gate** | `scripts/p4_prd_vs_code.sh` 逐原子验收ID检查实现证据 |
| **CI / 提交前** | `bash "$SKILL_ROOT/checks/check-permission-consistency.sh"` |

## 示例输出（执行后）

```
=============================================
  初始化事实源
=============================================
Skill templates : /path/to/skill/templates
项目文档目录    : docs/详细设计
强制覆盖        : 0

  [OK]   _commons.md
  [OK]   _权限矩阵.md
  [OK]   _环境与账号.md
  [OK]   _菜单Seed索引.md
  [OK]   INDEX-章节锚点.md

模板复制完成：5 新建，0 跳过

>>> 权限矩阵
[OK] 已写入 docs/详细设计/_权限矩阵.md
>>> ER图索引
[OK] 完成。输出：docs/详细设计/_ER图索引.md
>>> Schema变更日志
[OK] 完成。输出：docs/详细设计/_Schema变更日志.md

=============================================
  初始化完成
=============================================
```

## 相关命令

| 命令 | 文档 |
|---|---|
| `/prd-vs-code` | `commands/prd-vs-code.md` |
| `/audit-completeness` | `commands/audit-completeness.md` |
| `/spec` | `commands/spec.md` |
