# 索引表（v3.9.4 抽出 · 节省 SKILL.md 词数）

## 快捷命令表

| 命令 | 入口文件 | 说明 |
|------|----------|------|
| `/devflow` | `commands/devflow.md` | 完整生命周期编排（P0→P11） |
| `/spec` | `commands/spec.md` | PRD + 详细设计（P0-P2） |
| `/plan` | `commands/plan.md` | 任务分解规划 |
| `/build` | `commands/build.md` | 全栈编码（P3） |
| `/test` | `commands/test.md` | 业务测试 + 迁移测试 |
| `/review` | `commands/review.md` | Code Review（P3b） |
| `/arch-review` | `commands/arch-review.md` | 架构审查（公共类/配置归一化） |
| `/security` | `commands/security.md` | 安全审计（P3c） |
| `/performance` | `commands/performance.md` | 性能审计（P3d，含 N+1） |
| `/deploy` | `commands/deploy.md` | 发布部署（P7） |
| `/monitor` | `commands/monitor.md` | 监控配置（P8） |
| `/docs` | `commands/docs.md` | 文档更新（P9） |
| `/retro` | `commands/retro.md` | 复盘总结（P10） |
| `/postmortem` | `commands/postmortem.md` | 事故复盘（P11） |
| `/audit-completeness` | `commands/audit-completeness.md` | 完成度自检 |
| `/audit-pitfalls` | `commands/audit-pitfalls.md` | 架构陷阱自检（30+ Anti-Pattern） |
| `/qa-check` | `commands/qa-check.md` | 一键代码质量检测 |
| `/prd-vs-code` | `commands/prd-vs-code.md` | PRD vs 代码对比（P4b） |
| `/init-fact-sources` | `commands/init-fact-sources.md` | 初始化 7 份事实源 |
| `/devflow-state` | `commands/devflow-state.md` | 工作流状态管理 |

---

## Phase 文件索引

| 文件 | 说明 |
|------|------|
| `phases/00-需求澄清.md` | P0 · PRD → 原子验收点 |
| `phases/00b-PRD评审.md` | P0b · PRD 评审 |
| `phases/01-技术选型.md` | P1 · 架构定纲 + 事实源 |
| `phases/02-详细设计.md` | P2 · 字段级详设 + 准伪代码 + P2 迁移映射（DDL + 新老映射） |
| `phases/02a-详细设计评审.md` | P2a · 详设评审 |
| `phases/02b-原型Demo.md` | P2b · 原型验证门 |
| `phases/03-规范实现.md` | P3 · 垂直切片实施 |
| `phases/03b-代码审查.md` | P3b · Code Review |
| `phases/04-PRD验证.md` | P4 · PRD 验证 |
| `phases/04b-PRD-实现对比.md` | P4b · PRD vs Code |
| `phases/05-测试用例.md` | P5 · 测试用例 |
| `phases/06a-单元测试.md` ... `phases/06f-预发布验证.md` | P6 · 测试执行（业务轨 + 数据轨） |
| `phases/07-发布部署.md` | P7 · 发布部署 |
| `phases/08-监控配置.md` | P8 · 监控配置 |
| `phases/09-文档更新.md` | P9 · 文档更新 |
| `phases/10-知识沉淀.md` | P10 · 修正循环 + 全量执行 + 图谱健康（P4b 后可选） |

---

## 权威参考

- **True North**：`concepts/SKILL.md`（不可违背的铁律）
- **PRD 方法论**：`concepts/PRD实施方法论.md`
- **版本历史**：`references/CHANGELOG.md`
- **回归测试**：`tests/run-tests.sh`

---

## 加载顺序

```
1. concepts/SKILL.md（铁律）
2. commands/<cmd>.md（命令）
3. phases/*.md（Phase）
4. subagents/<role>.md（角色）
5. scripts/*.sh（按需）
```