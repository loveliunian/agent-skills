---
name: phase-2b-demo-gate
version: "3.31.1"
description: >-
  Demo gate——先原型确认再写正式代码。
  在 P2 详细设计后、P3 编码前插入"原型验证"门。
  必须先看 mockup / UI 草图 / 关键流程图得到用户签字确认，才能进入 P3 全栈编码。
  避免"代码写完才发现方向错了"的巨大浪费。
number-scheme: legacy-P-retained
devflow-phase: P2b
s-phase: (无对应)
rationale: "原型验证是独立动作,P2/P3 之间不涵盖。保留 P 编号。"
---
paths:
  - "docs/原型/**"
  - "docs/需求/**"
  - "docs/详细设计/**"
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
disable-model-invocation: false
---

# Phase 2b: Demo Gate

> **核心创新**：在 P2 详细设计和 P3 编码之间插入原型验证门
> **目的**：避免"代码写完才发现方向错了"——大型功能编码几周后才发现 UX/UI 错位，返工成本是预先做 mockup 的 10-100 倍
> **核心**："Demo gate"（Demo → 后端 → 前端 → 强化 → 安全审计 → 部署）

---

## 1. 触发条件

进入 P2b 之前必须满足：

- [x] P2 详细设计已完成（详见 `phases/02-详细设计.md`）
- [x] 详设三大冻结：数据模型（`anchor: data-model`）/ 接口契约（`anchor: api-contracts`）/ 关键流程（`anchor: business-operations`）
- [x] USER PERSONA / KEY USER FLOW 已识别

如果任一不满足，必须**先回到 P2** 完成。

---

## 2. P2b 必须产出（不可跳过）

### 2.1 三种原型之一（按功能选）

| 原型类型 | 适用场景 | 工具 |
|----------|----------|------|
| **HTML 静态 mockup** | 纯前端功能 / 业务流程 | `frontend/mockup/` + 简单 Vue 组件 |
| **API 草图 + 流程图** | 纯后端 / 复杂业务逻辑 | `docs/原型/<feature>-接口流程.md` + Mermaid |
| **端到端 walkthrough** | 全栈功能 | 视频 / 录屏 / 多文件 walkthrough |

### 2.2 关键用户流程（KUF）3-5 个

每个 KUF 必须含：

```markdown
## KUF-1: <场景名>

**用户**：<角色>（admin / 普通用户 / 运维）
**目标**：<一句话目标>
**前置**：<环境 / 账号 / 权限>
**步骤**：
1. 用户进入 ...... 看到 ......
2. 点击 ...... 触发 ......
3. 系统展示 ................
4. 用户确认 / 取消 / 修改

**截图 / 草图**：[docs/原型/<feature>/kuf-1-mockup.png]
**预期产出**：<业务结果>
**反向确认**：<如果做错了会怎样?>
```

### 2.3 用户签字确认

`docs/原型/<feature>-原型确认.md`：

```markdown
# Demo Sign-Off — M-XX

> **本文件必须由 PO/Product Owner 签字后才能进 P3**

## 验证清单

- [ ] KUF-1 走查通过
- [ ] KUF-2 走查通过
- [ ] KUF-3 走查通过
- [ ] UI/UX 符合设计稿
- [ ] 关键交互（拖拽 / 表单 / 弹窗）符合预期
- [ ] 异常路径（空状态 / 错误提示）已考虑

## 签字

| 角色 | 姓名 | 签字 | 日期 |
|------|------|------|------|
| Product Owner | | | |
| Tech Lead | | | |
| UX Designer | | | |

## 反馈 / 调整项

（PO 反馈后必须回 P2b 调整，再次签字）
```

### 2.4 P2b Gate 收据（确定性强制门控）

> v3.14：P2b 的完成证据由 `p2b_demo_gate.sh` 收据承载（EXIT_CODE/VERSION/PHASE/PASS/FAIL/WARN），
> 不再使用旧 VERIFICATION-<PHASE>.md 机制。

```bash
# 运行 P2b Gate（写收据后由 complete P2b 关闭阶段）
bash "$SKILL_ROOT/scripts/p2b_demo_gate.sh" <feature>

# Gate 通过后：devflow-state.sh complete <feature> P2b
```

包含：
- 3-5 个 KUF walkthrough 记录
- Demo sign-off 签字
- 输出文件路径，必须有实物

---

## 3. 详细子流程

### 3.1 阶段 1：原型生成（Agent 主导）

```bash
# 1. 创建原型目录
mkdir -p docs/原型/M-XX

# 2. 写 KUF（基于 02 详设关键流程 anchor: business-operations）
# 在 docs/原型/M-XX/kuf-1.md ... kuf-5.md
```

**Agent 职责**：
- 基于 P2 详设关键流程（`anchor: business-operations`）抽 3-5 个 KUF
- 为每个 KUF 写一份:<10 页的"UI 草图描述"或实际 HTML
- 标注关键决策点（哪个按钮、哪个弹窗、哪个表单字段）

### 3.2 阶段 2：演示交付（双方协商时间）

```bash
# 演示形式（任选）：
# A. 录屏：obs / quicktime 录 5-10 分钟 walkthrough
# B. 在线会议：演示 + 实时讨论
# C. 异步反馈：发 sign-off 文档给 PO，24-48h 内收集反馈
```

### 3.3 阶段 3：调整 + 签字（PO 主导）

```bash
# PO 反馈可能 3 种：
# 1. "通过" → 填 sign-off → 进入 P3
# 2. "小调整" → Agent 调整原型 → 二次演示 → 通过
# 3. "大改" → 回到 P2 重新设计
```

---

## 4. 与其他阶段的关系

```
P0 → P0b → P1 → P2 → P2a（五角色评审） → P2b（Demo Gate） → P3 → P3b/c/d → P4 → P4b → ...
                                                      ↓
                                              ~~首次插入 P2b~~
```

### 4.1 何时可以跳过 P2b？

- **小改动（< 1 人日）**：跳过 P2b，直接进 P3
- **纯 bug 修复**：跳过
- **纯性能优化**：跳过
- **纯重构**：跳过
- **全新模块 / 跨多服务功能**：**必须 P2b**

判断标准：**改动涉及 ≥ 2 个前端页面 或 ≥ 1 个新 API 端点** → 必须 P2b。

### 4.2 跳过时的占位声明

如果用户显式授权跳过 P2b，必须写入 `.devflow/<feature>/skip-log.txt`（SKIP_P2b=1 及理由），并由 p2b gate 的 skip 分支识别：

```markdown
## P2b 跳过声明

- [ ] 改动 < 1 人日 / 纯 bug / 纯性能 / 纯重构
- [ ] 不涉及新前端页面
- [ ] 不涉及新 API 端点
- [ ] Tech Lead 签字：___________
```

---

## 5. 借鉴来源

| 项目 | 借鉴点 |
|------|--------|
| **Demo gate** | 先 mockup/原型再写正式代码 |
| **spec_driven_develop** | Phase 2 Intent Refinement（用户确认） |
| **genkovich/sdd** | Socratic clarify（多轮澄清） |
| **本 skill 已有的** | p2b_demo_gate.sh 收据门控 |

---

## 6. 验收 Gate

| 维度 | 阈值 | 工具 |
|------|------|------|
| KUF 数量 | ≥ 3 个 | 列表计数 |
| 走查通过率 | 100% | sign-off |
| 用户签字 | ≥ 1 人 | sign-off 文档 |
| P2b 收据 | EXIT_CODE=0 且 FAIL=0 | `p2b_demo_gate.sh`（收据双写 gates/P2b） |

**0 P0 才能进 P3**。

---

## 7. 常见错误

| 错误 | 后果 | 正确做法 |
|------|------|----------|
| 跳过 P2b 直接编码 | 写完才发现 UX 错位，返工 | 即使 1 人日也至少画个草图 |
| KUF 写成"技术流程" | 用户看不懂 | 写"用户视角的步骤" |
| sign-off 流于形式 | 后期再改 | 必须 PO 真实签字 |
| 副作用"延伸到 P3" | P2b 边界模糊 | 严格只做原型，不实现业务 |

---

## 结构化产物层（v3.25.2）

本阶段产物已结构化：AI 按 `schemas/demo-signoff.schema.json`（样例 `examples/structured/demo-signoff.sample.json`）填 `.devflow/<feature>/demo-signoff.json`，再跑管线校验并确定性渲染原型确认文档——KUF ≥3 且逐条走查、原型文件实存（docs/原型/ 反查）、PO 结论明确、签字齐备，全部机器校验后才渲染；**校验失败不渲染、不进 Gate**。

```bash
python3 scripts/df_pipeline.py demo-signoff --input .devflow/<feature>/demo-signoff.json --out docs/原型/<feature>-原型确认.md
```
