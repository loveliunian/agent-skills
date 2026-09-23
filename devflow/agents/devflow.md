---
name: devflow
agent_type: orchestrator
version: "3.30.12"
description: >-
  Agent-type alias for `commands/devflow.md`. Use when the platform expects
  an `agent_type:` declaration (e.g. Codex / Trae); for Cursor / Claude Code
  use `commands/devflow.md` instead.
deprecated: true
deprecated-since: "3.9.0"
deprecation-reason: "本 skill v3.9 起只有一套 SKILL.md 权威入口。本文件保留仅为兼容 Codex/Trae 平台的 agent_type 元数据声明;任何内容更新只改 commands/devflow.md。"
paths: []
---

# agents/devflow.md — Agent 类型声明

> 
>
> **编排内容请见 `commands/devflow.md`** —— 两者内容以 commands 版本为准。
>
> **为什么两个文件**：
> - `commands/devflow.md`：用户命令入口（`/devflow`），含完整 P0→P10 编排
> - `agents/devflow.md`：agent_type 元数据，供需要 `agent_type: orchestrator` 的平台
>
> **维护规则**：
> 1. 内容更新 → 改 `commands/devflow.md`
> 2. 本文件仅在版本号变化时同步
