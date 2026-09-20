---
name: retro
version: "3.29.0"
description: >-
  Use when conducting a retrospective or lessons-learned session after a feature ships, mentions
  "/retro", "复盘", "回顾", "retrospective", "知识沉淀", "lessons learned", or "post-mortem".
  Output: docs/复盘/<feature>-复盘报告.md. Must include a "上次遗漏了什么" section.
paths:
  - "docs/复盘/**"
  - "docs/PRD/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
---

# /retro - 复盘总结（P10）

> **核心约束**：复盘 markdown 必须含 "上次遗漏了什么" + "本次新发现的坑" + "修复策略" 三段。
> **P10 硬闭环约束**：复盘教训必须当场进入项目 `.devflow/<feature>/feedback/feedback.md`，并由 P10 Gate 写入 receipt；未经用户明确批准不得修改已安装 skill。

## 使用方式

```
/retro <feature>
/retro <feature> --template=v2
```

## 示例

```
/retro m-03-basic-library
/retro payment-system
```

## 命名约定

| 文档 | 路径 |
|------|------|
| 复盘报告 | `docs/复盘/<feature>-复盘报告.md` |
| 知识分享 | `docs/知识沉淀/<feature>-知识分享.md` |

## 执行步骤

### 1. 收集所有 Phase 输出

```bash
# 列出所有阶段产出
find docs/ -name "<feature>-*.md" -type f
ls -la docs/复盘/<feature>-P*审计*.md
```

### 2. 起草复盘 markdown

`docs/复盘/<feature>-复盘报告.md` 必须含：

```markdown
# <feature> 复盘总结

## 基本信息
- Feature：<feature>
- Date：YYYY-MM-DD
- 主 Agent：<name>
- 子 Agent：<roles>

## 上次遗漏了什么

> 本段要求把教训固化为可复查的检查项。

- [ ] P0 阻断留到 P5 之后
- [ ] 后端 Controller 无 `@PreAuthorize`
- [ ] 监控三件套缺失
- [ ] E2E 48/48 SKIP
- [ ] 文档"已完成"无路径
- [ ] 无复盘总结
- [ ] 自我感觉良好

## 本次新发现的坑

### 1. <坑名>
- 现象：<现象>
- 原因：<根因>
- 修复：<方案>
- 预防：<预防策略>

### 2. <坑名>
...

## 修复策略

| 坑 | 短期修复 | 长期预防 |
|----|----------|----------|
| <坑 1> | <当下> | <流程 / 工具 / 培训> |
| ... | ... | ... |

## 全流程数据

| Phase | 产出 | 自检状态 |
|-------|------|----------|
| P0 需求澄清 | <doc> | ✅ |
| P0b PRD 评审 | <doc> | ✅ |
| P1 技术选型 + 事实源 | <doc> | ✅ |
| P2 详细设计 | <doc> | ✅ |
| P2a 设计评审 | <doc> | ✅ |
| P2b 原型 Demo | <gate receipt> | ✅ / ⏭️（授权跳过） |
| P3 全栈编码 | <code> | ✅ |
| P3b Code Review | <doc> | ✅ |
| P3c 安全审计 | <doc> | ✅ |
| P3d 性能审计 | <doc> | ✅ |
| P4 PRD 验证 | <doc> | ✅ |
| P4b PRD-vs-Code | <doc + 脚本退出码> | ✅ |
| P5 测试用例 | <doc> | ✅ |
| P6 测试执行 | <reports> | ✅ |
| P7 发布部署 | <doc> | ✅ |
| P8 监控配置 | <doc> | ✅ |
| P9 文档更新 | <docs> | ✅ |
| P10 复盘 | <this doc> | - |

## 项目反馈记录

- 队列：`.devflow/<feature>/feedback/feedback.md`
- feedback_id：`FB-YYYYMMDD-001`
- scope：`project`
- status：`PROPOSED / ACCEPTED`
- 已安装 skill 的修改：仅记录为 proposal，等待用户明确批准。

## 团队 / 个人收获

- 技术：...
- 流程：...
- 工具：...

## 待办事项（流入下一个 sprint）

- [ ] ...

## 总结
- 本次 Feature 完成度：100%
- 已登记的历史教训是否规避：是 / 否（具体项）
- 下一个 Feature 注意事项：...
```

### 3. 起草知识分享 markdown

`docs/知识沉淀/<feature>-知识分享.md` 必须含 ≥3 条本次新发现的坑。

### 4. 项目反馈队列（P10 硬闭环）

> 复盘不能只写“待改进”。但项目交付也不能未经用户批准修改已安装 skill。因此先形成可审查的项目反馈队列；只有用户明确批准后，才可调用 `s8b_feedback_gate.sh --apply --authorize-apply --write` 修改 skill。

```bash
# 1) 在项目内创建反馈条目；不得写入 $SKILL_ROOT。
mkdir -p .devflow/<feature>/feedback
cat > .devflow/<feature>/feedback/feedback.md <<EOF
FEEDBACK_ID=FB-$(date +%Y%m%d)-001
SCOPE=project
STATUS=PROPOSED
ROOT_CAUSE=<现象 → 根因 → 预防>
EOF

# 2) 校验 P10 项目闭环并写入 P10 receipt。
bash "$SKILL_ROOT/scripts/p10_feedback_gate.sh" <feature>

# 3) 仅在用户明确批准“修改 skill”后执行。默认 s8b 只收集，不会 apply。
# bash "$SKILL_ROOT/maintenance/s8b_feedback_gate.sh" <feature> --apply --authorize-apply --write
# bash "$SKILL_ROOT/scripts/check-copies.sh"
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 复盘路径 | `docs/复盘/<feature>-复盘报告.md` 实际写入 |
| "上次遗漏了什么"段 | **必须存在**（grep 命中） |
| "本次新发现"段 | **必须存在**（grep 命中） |
| 知识分享 markdown | `docs/知识沉淀/<feature>-知识分享.md` 实际写入 |
| 知识分享条数 | **≥ 3 条** |
| 全流程数据表 | 必须覆盖 P0-P10（含 P2a/P2b/P4b 行） |
| 项目反馈队列 | `.devflow/<feature>/feedback/feedback.md` 含 ID、`SCOPE=project`、`STATUS=PROPOSED/ACCEPTED` |
| Skill 应用/同步收据 | `s8b-apply-receipt.env` 显式记录 `NOTHING_TO_APPLY/DRY_RUN/FAILED/APPLIED/VERIFIED/VERIFY_FAILED`、应用数量、报告 SHA 和 `COPY_VERIFY_REQUIRED`；P10 gate 拒绝悬挂的 `STATUS=APPLIED` |
| P10 feedback gate | `bash "$SKILL_ROOT/scripts/p10_feedback_gate.sh" <feature>` 退出码 = 0 |

## 输出

- `docs/复盘/<feature>-复盘报告.md`
- `docs/知识沉淀/<feature>-知识分享.md`
- `.devflow/<feature>/feedback/feedback.md`

## 自检命令

```bash
# P10 自检：复盘含关键段
RETRO=docs/复盘/<feature>-复盘报告.md
grep -q "上次遗漏" "$RETRO" && echo "上次遗漏段 OK" || echo "MISSING"
grep -q "本次新发现" "$RETRO" && echo "本次新发现段 OK" || echo "MISSING"

# 知识分享条数 ≥ 3
KNOW=docs/知识沉淀/<feature>-知识分享.md
COUNT=$(grep -c "^### [0-9]" "$KNOW")
echo "知识分享条数: $COUNT"
test "$COUNT" -ge 3  # 必须 ≥ 3

# P10 项目反馈 gate
bash "$SKILL_ROOT/scripts/p10_feedback_gate.sh" <feature>
```

## 角色约束

- 主 Agent 执行
- 团队复盘会的主持人角色

## 与其他命令关系

- 前置：所有 Phase（P0-P9）全部 PASS
- **本命令是 P10，**是流程的最后一个阶段
- 完成后运行 `/audit-completeness P10 <feature>`
- P10 PASS → 流程完结

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/p10_feedback_gate.sh" <feature>
# 期望：exit 0 = 反馈队列闭环有效
```
