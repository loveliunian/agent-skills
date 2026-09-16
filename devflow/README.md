---
name: devflow-readme
version: "3.25.0"
description: devflow 的非权威导航页。
---

# devflow v3.25.0

`SKILL.md` 是唯一权威入口；本文件只用于人工导航，不重复流程、Gate 或执行规则。

## 30 秒上手

```text
用户：用 devflow 根据 docs/需求/refund-需求澄清.md 做存量功能改造，
      前端是 PC Web，先做到详细设计，不部署。

预期：P0 → P0b → P1 → P2 逐阶段 PASS（每阶段返回 Receipt），
      因 --design-only 在 P2 后停止；产物在 docs/详细设计/。
      任一 Gate FAIL → BLOCKED + checkpoint，修复后重跑同一 Gate。
```

安装：见仓库根 `README.md`。Claude Code 为 `~/.claude/skills/devflow`；Codex 当前用户级目录为 `$HOME/.agents/skills/devflow`（旧的 `~/.codex/skills` 已过时）；
也可用 `bash scripts/install.sh --platform <claude|codex|cursor|trae|trae-cn>`，再用 `bash scripts/doctor.sh` 体检依赖。

## 整体流程图

```mermaid
flowchart LR
    Start["PRD / 新增 / 修改需求"] --> Mode{"交付模式"}
    Mode -->|new| P0
    Mode -->|change / extend| Impact["影响分析：定位最早受影响 Phase"]
    Mode -->|small-change / 自然语言小需求| SmallScan["扫描当前项目十个影响表面"]
    SmallScan --> SmallDecision{"MICRO / FULL"}
    SmallDecision -->|FULL| Impact
    SmallDecision -->|MICRO| SmallGate["SMALL-CHANGE 聚焦验证"] --> MergeReady["MERGE_READY"]
    MergeReady -.明确要求上线.-> P7
    Impact -.需求基线变化.-> P0
    Impact -.架构变化.-> P1
    Impact -.设计变化.-> P2
    Impact -.仅实现变化.-> P3

    subgraph Delivery["P0-P10 唯一交付主链"]
        P0["P0 需求澄清"] --> P0b["P0b PRD 评审"] --> P1["P1 技术选型 + 事实源"] --> P2["P2 字段级详细设计"]
        P2 --> P2a["P2a 五角色设计评审"] --> P2b["P2b 原型 Demo"] --> P3["P3 垂直切片实现"]
        P3 --> P3b["P3b 独立代码审查"] --> P3cd["P3c/P3d 安全 + 性能审计"]
        P3cd --> P4["P4 PRD 验证"] --> P4b["P4b PRD vs Code"] --> P5["P5 测试设计"]
        P5 --> P6["P6 单元/集成/客户端/迁移测试"] --> P7["P7 部署发布"] --> P8["P8 监控"] --> P9["P9 文档"] --> P10["P10 复盘 + 反哺"]
    end

    P2 -->|--design-only| DesignDone["仅声明设计完成"]

    P2 -.冻结 frontend scope 与 manifest.-> Scope{"客户端范围"}
    Scope --> PC["PC Web：浏览器旅程"]
    Scope --> Mini["微信小程序：开发者工具/模拟器"]
    Scope --> App["APP：模拟器/真机"]
    Scope --> NA["not-applicable：冻结理由"]
    PC --> ClientBuild["P3 build"]
    Mini --> ClientBuild
    App --> ClientBuild
    NA --> ClientBuild
    ClientBuild --> ClientContract["P4 页面/接口契约"] --> ClientJourney["P6 真实旅程"] --> ClientRelease["P7 release"]
    ClientBuild -.证据.-> P3
    ClientContract -.证据.-> P4
    ClientJourney -.证据.-> P6
    ClientRelease -.证据.-> P7

    Gate["任一当前 Phase Gate"] -->|Gate FAIL| Save["保存 checkpoint + 阻断"]
    Save --> Fix["修复根因与证据"] --> Retry["重跑当前 Gate"] --> Gate
    Gate -->|PASS| Next["进入下一 Phase"]

    Incident["独立生产事件"] -.-> P11["P11 事故复盘；不属于交付主链"]
```

图中的客户端链是各阶段必须提交的并行证据，不是另一套 Phase；任何 Gate 失败都回到当前 Gate，不允许沿主链继续。

## 从哪里开始

- 全流程、增量需求、修改需求、断点恢复：读 [`SKILL.md`](SKILL.md)。
- “小需求/小改动、局部 UI、配置、修复、字段/默认值/校验”：读 [`commands/small-change.md`](commands/small-change.md)，由项目扫描自动决定 MICRO 或完整 change。
- 命令、Phase、Gate、产物映射：读 [`commands/ROUTING.md`](commands/ROUTING.md)。
- 不可违背的工程约束：读 [`concepts/core.md`](concepts/core.md)。
- 版本变化：读 [`references/CHANGELOG.md`](references/CHANGELOG.md)。
- 回归与发布校验：运行 `bash tests/run-tests.sh`。

## 支持范围

- 交付形态：从零构建、已有系统新增、已有需求修改。
- 客户端：PC Web、微信小程序、APP、无前端后端交付。
- 流程：P0-P10 主交付链；SMALL-CHANGE 是受控小改动入口；P11 仅用于独立事故复盘。

详细操作只保留在对应 command、phase、subagent、template 和 script 中，避免多份规则漂移。
