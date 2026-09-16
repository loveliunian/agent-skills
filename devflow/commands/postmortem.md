---
name: postmortem
version: "3.25.0"
description: |
  触发条件：生产 P0/P1 故障、SLA 违约、安全事件、影响用户的 Bug。
  强制产出 docs/事故复盘/<incident>-事故复盘.md（§1-§10 完整 + 5 Why + 改进项可追溯）。
  与 P10 区别：P10 是项目级复盘，P11 是事件级无指责根因分析。
license: MIT
paths: ["docs/事故复盘/**", "docs/incidents/**", "docs/复盘/**"]
disable-model-invocation: false
allowed-tools: [read, write, exec, glob, grep, task]
metadata:
  author: "xingyunliushui"
  tags: "postmortem,incident,rca,phase-p11"
---

# /postmortem — 事故复盘命令

> **对应阶段**：P10 后置 Postmortem（事故复盘，详见本文 §4 报告模板）

## 1. 使用场景

| 场景 | 是否触发 |
|------|---------|
| 生产 P0/P1 故障 | ✅ 必跑 |
| SLA 违约（P95 > 阈值 持续 > 1h） | ✅ 必跑 |
| 数据泄露 / 安全事件 | ✅ 必跑 |
| 影响线上用户的 Bug | ⚠️ 建议 |
| 性能严重退化 | ⚠️ 建议 |
| 仅本地开发问题 | ❌ 不跑（走 /retro） |

## 2. 用法

```bash
/postmortem                          # 交互式引导
/postmortem <incident-slug>          # 指定事故名，自动生成报告骨架
/postmortem --list                   # 列出所有 Postmortem
/postmortem --index                  # 重新生成 docs/事故复盘/INDEX.md
/postmortem --check <file>           # 校验单篇报告完整性（§1-§10 / 5 Why / 改进项）
/postmortem --gate                   # 阶段门控检查（用于 /audit-completeness P11）
```

## 3. 工作流程

### 3.1 交互式模式（默认）

1. **收集基本信息**
   - 事故简称（slug，e.g. `order-db-pool-exhaustion`）
   - 严重等级（P0/P1/P2）
   - 时间窗口（start ~ end）
   - 主写人 / 参与人

2. **自动生成报告骨架**
   - 写入 `docs/事故复盘/<YYYY-MM-DD>-<slug>-事故复盘.md`
   - §1-§10 全空模板

3. **引导填写关键章节**
   - §3 时间线：要求精确到分钟
   - §4 5 Why：要求至少 5 层
   - §5 改进项：要求每个有"责任人 + 截止 + 优先级"

4. **校验门控**
   - § 完整性
   - 5 Why 深度
   - 无个人指责（grep 检测）

### 3.2 命令参数模式

```bash
/postmortem order-db-pool-exhaustion
# 生成 docs/事故复盘/2026-08-12-order-db-pool-exhaustion-事故复盘.md
```

自动填充：
- 日期（今日）
- slug（参数）
- 模板骨架

## 4. 报告模板（强制 §）

完整模板见本文 §3.1 与下方强制章节。

**强制章节**：
- §1 一句话总结
- §2 影响范围
- §3 时间线
- §4 根因分析（5 Why）
- §5 防御性改进项
- §6 检测能力
- §7 响应能力
- §8 沟通能力
- §9 经验沉淀
- §10 反思

## 5. INDEX 自动生成

```bash
# 自动扫描所有 docs/事故复盘/*-事故复盘.md
# 输出：事故简称 / 日期 / 等级 / 状态 / 影响 / 责任人 / 链接
bash "$SKILL_ROOT/scripts/generate-postmortem-index.sh" > docs/事故复盘/INDEX.md
```

INDEX 示例：

```markdown
# Postmortem 索引

| 日期 | 事故简称 | 等级 | 状态 | 影响用户 | 改进项数 | 责任人 | 链接 |
|------|---------|------|------|----------|---------|--------|------|
| 2026-08-12 | order-db-pool-exhaustion | P0 | 已修复 | 12 万 | 5 | @sre | [链接] |
```

## 6. 阶段门控（`--gate`）

| 检查项 | 通过条件 | 失败动作 |
|--------|---------|---------|
| 报告存在 | `docs/事故复盘/<slug>-事故复盘.md` 存在 | 阻塞 |
| § 完整 | 含 §1~§10 标题 | 阻塞 |
| 5 Why ≥ 5 层 | §4 至少 5 个 "Why" 编号 | 阻塞 |
| 改进项可追溯 | §5 表格至少有 P0 项且含责任人 | 阻塞 |
| 无个人指责 | grep 检测无 `@xxx` 开头 + 无"应该""早就" | 警告 |
| INDEX 更新 | `INDEX.md` 含本次记录 | 阻塞 |

```bash
/postmortem --gate
# 输出：PASS / FAIL + 详细原因
```

## 7. 与其它命令的联动

| 联动命令 | 行为 |
|----------|------|
| `/audit-completeness P11` | 自动跑 `--gate` |
| `/retro` | Postmortem 数据作为 Retro 输入 |
| `/build` | 重大事故后，新模块开发时引用相关 Postmortem 编号 |
| `/spec` | 需求澄清时如引用 Postmortem，必须在内层写入约束 |

## 8. Postmortem 文化（强制）

- ✅ **Blameless**：不写"因为 @某人"
- ✅ **5 Why**：至少 5 层根因
- ✅ **Action Items 可追溯**：责任人 + 截止 + 优先级
- ✅ **3 个月回头看**：改进项必须验证落地
- ✅ **INDEX 公开**：所有 Postmortem 团队可见

## 9. 与 SRE 实践对齐

参考 Google SRE Book：
- **Chapter 14: Postmortem Culture: Learning from Failure**
- **Chapter 15: Postmortem Process: Just Culture**

我们的实践与之对齐，但增加了：
- 与 devflow P0-P10 阶段的回流
- Action Items 强制责任人 + 截止日期
- INDEX 自动化生成
