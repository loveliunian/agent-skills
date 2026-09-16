# Agent Runtime Adapter（平台无关的子 Agent 调用语义）

> devflow 声明兼容 Codex / Claude Code / Cursor / Trae 等平台，但各平台 spawn 子 Agent 的
> 工具名与参数不同。**核心提示词（commands/phases/subagents）不得写死任何平台调用语法**，
> 一律引用本文定义的语义操作；各平台由运行时适配到具体工具。

## 语义操作

### spawn_fresh(role, inherited_context=false)

以全新上下文启动一个指定角色的子 Agent。

- `role`：`subagents/` 下的角色文件名（不含扩展名），如 `architecture-reviewer`、`backend-dev`。
- `inherited_context=false`（默认）：不继承编排器的对话历史；子 Agent 只获得任务提示中
  显式列出的产物路径与约束。需要上下文时，编排器必须把材料**显式写进任务提示**。
- 返回 `agent_id`。

平台适配示例（仅示意，核心提示词禁止内嵌）：

| 平台 | 适配 |
|---|---|
| Claude Code | `Task(subagent_type=<role>)`，子代理获得干净上下文 |
| Codex / Trae | 新会话运行对应角色的 subagent 提示文件 |
| Cursor | 新 Agent 会话加载 `subagents/<role>.md` |

### wait_all(agent_ids)

阻塞等待一组子 Agent 全部完成，收集各自的结构化输出（报告路径 + 关键结论）。
任一子 Agent 失败不静默吞掉：编排器必须把失败事实写进评审记录。

### record_receipt(role, agent_id, session_id, output) —— v3.20.3 两阶段

为子 Agent 的产出写独立收据（当前实现：`scripts/review-receipt.sh`），两阶段缺一不可：

- `begin`：spawn 该角色**之前**调用，此时评审报告文件必须尚不存在（否则拒绝）——
  登记 `role / agent_id / input_artifact_sha / started_at` 并锁定 session 台账的 role→agent 映射；
- `complete`：该角色产物落盘后调用，绑定 `output_report_sha / completed_at`；
  评审期间输入产物被改写 → 拒绝。

字段全集：`agent_id / session_id / role / input_artifact_sha / output_report_sha /
started_at / completed_at / status(begin|complete)`。
Gate 只信收据，不信报告里自报的 ID 字符串；`verify` 校验角色集合恰等于 AUTHOR+5、
两阶段齐备、时间窗单调、评审者≠作者。旧单阶段 `create` 已移除（报告后整批补写的伪造通道）。

## 当前落地点

- P2a 独立评审：`phases/02a-详细设计评审.md`（AUTHOR + 5 角色收据，`p2a_design_review_gate.sh` 验证）。
- 新增多 Agent 阶段时，必须走同一套语义操作，禁止在提示词中内嵌平台工具名。
