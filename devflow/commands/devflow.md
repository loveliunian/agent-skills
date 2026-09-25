---
name: devflow-command
version: "3.31.1"
description: Use when running the complete devflow lifecycle or resuming a checkpoint.
allowed-tools: [read, write, exec, glob, grep, task]
---

# /devflow — P0-P10 编排入口

本文件只保留参数、顺序、Gate 调用、跳过与恢复。阶段产物、角色和模板从 `commands/ROUTING.md` 路由到对应文件，不在此重复。

## 参数

```text
/devflow <prd-path> [--mode=new|change|extend|small-change]
         --frontend=pc-web|mini-program|app|not-applicable
         [--frontend-dir=<path>] [--service=<service>]
         [--scaffold=<path>] [--prototype=<path>] [--ui-spec=<path>] [--design-rules=<path>]
         [--migration=A|B|C] [--source-count=<n>] [--profile=<id>]
         [--design-only] [--skip=<phase>]
```

- `--frontend` 必须显式冻结；不得从目录存在与否猜测。
- **`--scaffold=<path>`（输入含脚手架/存量代码时必填）**：P1 强制「脚手架重合度审计」（铁律 18）——
  逐功能域对照「本次新功能 vs 脚手架已有能力」，产出裁剪/复用清单：**重合 → 裁剪脚手架对应实现并由本次设计
  重新实现（宜独立新模块承载）；不重合 → 复用脚手架既有能力**；禁止同一功能域新旧双实现并存。
  清单写入 P1 设计决策记录《脚手架重合度审计》章节并被 P2 baseline（DELETE/MODIFY/REUSE/ADD）承接。
- **`--prototype` / `--ui-spec` / `--design-rules`（提供时）**：原型图/交互稿、UI 规范、设计规则为
  设计硬约束（铁律 19）：P2 详设与 P3 实现必须遵循物料，脚手架既有设计只作实现载体，
  不得覆盖物料的样式/交互/信息架构；冲突时 `BLOCKED` 回用户裁决。
- `new` 从 P0 开始；`change`/`extend` 先读取当前实现与已有冻结基线，再从最早受影响阶段恢复。
- **`change`/`extend` 增量标记（强制）**：详设遵循「新建不标记、增量/修改必标记」——凡触及既有产物（存量表/接口/页面/公共层/事实源）的点以【增量字段】【修改-行为】【追加登记】【扩展-公共层】标记，按 phases/02《增量/修改点标记》三处落点（详设总表/正文内联/实现交接 M-NN 清单）输出；新建物不加标记。
- `small-change` 先加载 `commands/small-change.md` 扫描项目并分类；结果为 FULL 时自动回到 `change`，不得继续快速路径。
- `--design-only` 在 **P2a 评审 Gate 通过后**停止（设计完成 = P2 内容校验 + P2a 实施可行性评审，v3.24.0 与 /spec、/plan、/build 统一口径）；只能声明设计完成。
- 小程序或 APP 在 P2 后必须生成并冻结 `devflow-client.json`；PC Web 也推荐使用同一契约。
- `--profile=<id>` 冻结 Runtime Profile 到 `state.scope.profile_id`（须存在
  `references/profiles/<id>.md`；缺省 `java-spring-flyway`）。当前 P3/P4b 的
  build/test/coverage 命令位仅实现该参考 profile，其他 profile 在这些阶段
  `BLOCKED(MISSING_CAPABILITY)`（见 `references/runtime-profile.md` 实现状态节）。

## Required load order

1. `concepts/core.md`
2. 本文件与 `commands/ROUTING.md`
3. 当前 `phases/<phase>.md`
4. 当前 `subagents/<role>.md`
5. 当前模板和 Gate 脚本

P0 需求澄清、P1 技术选型、P2 详细设计、P3 实现、P4 验证、P5/P6 测试、P7-P10 发布闭环都必须加载对应阶段说明。图谱健康仅在 P4b 后按项目可用性执行，不得把图谱不可用伪装成通过。

## 单轨顺序

```text
P0 → P0b → P1 → P2 → P2a → P2b → P3 → P3b → P3cd
   → P4 → P4b → P5 → P6 → P7 → P8 → P9 → P10
```

> 阶段命名说明：`P3cd` 是安全（P3c）+ 性能（P3d）**共用 Gate 的收据别名**——状态机模型保留
> P3c/P3d 两个原子阶段，`complete P3cd` 同时标记两者完成；`p3_security_perf_gate.sh`
> 单项模式（--mode security|performance）仍可分别产出 P3c/P3d 收据。

P11 是独立事故复盘，不属于正常交付完成条件。

## 执行编排（子代理策略）

全链执行时按阶段选择单线/并行/独立子代理——**编排方式不改变任何 Gate 契约**（子代理产出仍走同一套 Gate）：

- **P0~P2 / P4~P5 / P7~P10**：主会话单线（契约对齐循环、单一正本原子链、收据链一致性）；
- **P2a / P3b**：独立上下文子代理评审（必选）——认知独立≠收据的过程独立，评审输入只喂正本文件（详设/验收点/模板），刻意不含编排器的实现过程叙述；
- **P3**：backend/frontend 并行子代理 ×2（以详设 §3.2 接口契约为唯一耦合点）；
- **P6**：五类测试命令可并行（CLIENT 依赖前端 dev server、STAGING 依赖后端容器，服务前置须先行就绪——
  P5 开始即后台跑 `p6-prewarm.sh` 预热，幂等可重复执行，L-PROC-005 冷启动预算前置消化）；
  **修复循环增量重跑（v3.28.12）**：测试失败→修复后用 `p6-iterate.sh <feature> <kind> [--filter <类名>]`
  只重跑失败套件（`--dry-run` 预检拼接），产物落 `.devflow/<feature>/iterations/`（非终验证据、
  只读 test-evidence.env）——收敛后 P6-final 仍全量真实重执行五类命令，反自报契约不变。

子代理任务书六要素（输入正本路径 / 产出+验收命令 / 边界声明 / 结构化回传 / 评审附加契约 /
收据由编排器两阶段签发——子代理不得自签）、反模式清单与实测基线见
`concepts/subagent-orchestration.md`（编排前必读）。

## Gate 参数矩阵

| 阶段 | 命令 |
|---|---|
| P0 | 非首个 feature 先 `devflow-state.sh constraints-inherit <feature>`（继承机器块，只澄清 delta，v3.28.13）→ `s0_acceptance_gate.sh <feature>`；通过后立即 `devflow-state.sh constraints-freeze <feature>`（冻结技术约束 SHA，P1 强制校验） |
| P0b | `artifact_gate.sh P0b <feature>` |
| P1 | `s1_fact_sources_gate.sh docs/详细设计`（校验技术选型机读绑定 + 约束文件 SHA 与 state 一致） |
| P2 | `df_pipeline.py design`（design.json 校验 + 详设确定性层渲染，失败关闭）→ `s2_design_coverage_gate.sh <design> <criteria> [--mode=monolith|total|sub]`（详设必须逐条引用 constraint_id；design.json 存在时 §2c 强制对账；总分模式须有 design-package.json 设计包清单——子集并集=冻结分母，缺文档即失败）；B/C 再跑 `s3_migration_mapping_gate.sh` |
| P2a | `p2a_design_review_gate.sh <feature>`（前置：编排器以 review-receipt.sh begin/complete 两阶段为 AUTHOR+5 角色写独立收据——begin 必须先于报告产出） |
| P2b | `p2b_demo_gate.sh <feature>` |
| P3 | `build-watchdog.sh gate <feature>`（P3-build 收据）+ `p3_completion_gate.sh <service> <feature>` |
| P3b | `p3b_code_review_gate.sh <feature>` |
| P3cd | `p3_security_perf_gate.sh <feature>` |
| P4 | `p4_validation_gate.sh <feature>` |
| P4b | `p4_prd_vs_code.sh <feature> ...` |
| P5 | `p5_test_cases_gate.sh <feature>`（主收据）+ `s5_migration_gate.sh <A|B|C> <evidence>`（B/C 辅助，P5-migration 收据） |
| P6 | `s6_first_pass_accuracy.sh <feature> 80`（首轮质量指标）+ `s6_final_verification_gate.sh <feature>`（**部署前终验：验收点 FAIL=0；Gate 实际执行五类命令并绑定报告、日志与真实退出码；verification.json 必填**，Gate 执行通过后自动渲染终验报告并入收据证据树；CLIENT_EXEMPT 仅对冻结前端范围 not-applicable 生效）+ `p6_credential_gate.sh <feature>`（凭证收据 `gates/P6-credential/`）（终验收据 `gates/P6-final/receipt.txt`，complete P6 强制） |
| P7 | `artifact_gate.sh P7 <feature>`（前置：存在有效发布授权收据 `.devflow/<feature>/authorizations/release.json`，见 Release Authorization） |
| P8 | `artifact_gate.sh P8 <feature>` |
| P9 | `artifact_gate.sh P9 <feature>` |
| P10 | `p10_feedback_gate.sh <feature>` |

实际参数由当前 command/phase 冻结；禁止把上表占位符原样执行。

> **git 检查点（v3.28.9，m01-base 教训：6.7h 全程零 commit 无回滚点）**：P2/P3/P6/P10
> 的 Gate PASS 后、`devflow-state.sh complete` 之前，必须运行
> `bash scripts/git-checkpoint.sh <feature> <phase>`——commit 消息携带收据哈希，
> 台账写入 `.devflow/<feature>/git-checkpoints.tsv`，`complete` 对这四个阶段强制校验
> 台账条目（豁免仅限 `DEVFLOW_GIT_CHECKPOINT=off` 或 skip-log 显式授权）。收据时间
> 从此获得 commit 时间交叉验证。

> **架构陷阱门禁（True North 接线）**：P3b Gate 内联执行
> `check-arch-pitfalls.sh --all --receipt <feature>`（§6 组合口径）——ARCH-PITFALLS
> 收据（含证据绑定）随 P3b 产出，并由 `complete P3b` 强制校验（缺收据/非成功
> 即拒绝推进）；audit-receipts 对账重验其证据绑定。

## Gate Execution Engine

以下伪代码定义编排语义。它不是替代各 Gate 参数校验的通用 shell 包装器。

```bash
execute_gate() {
  phase="$1"
  shift
  # v3.27.11: Gate 输出落盘（.devflow/<feature>/gates/<phase>/gate-output.log），
  # 失败钩子据此做错误分类/教训匹配（gate-fail-classify.sh）。
  gate_log=".devflow/$FEATURE/gates/$phase/gate-output.log"
  mkdir -p "$(dirname "$gate_log")"
  # v3.14.6: 用户显式授权跳过——gate 自身读取 skip-log.txt 并产出 SKIPPED=1 的成功收据，
  #          complete 按普通收据关闭阶段（如 p2b_demo_gate.sh）。未实现 skip 分支的 gate 不适用。
  if check_skip_authorization "$phase"; then
    if "$@" > "$gate_log" 2>&1; then
      cat "$gate_log"
      bash "$SKILL_ROOT/scripts/devflow-state.sh" complete "$FEATURE" "$phase" || return $?
      return 0
    fi
    code=$?
    cat "$gate_log"
    echo "[WARN] SKIP_${phase} 已授权但 gate 未通过（exit=${code}）——按失败处理" >&2
    return "$code"
  fi
  if "$@" > "$gate_log" 2>&1; then
    cat "$gate_log"
    # v3.14.0: complete 被拒（收据/顺序/证据校验失败）时必须向上传播，不得吞掉
    bash "$SKILL_ROOT/scripts/devflow-state.sh" complete "$FEATURE" "$phase" || return $?
    return 0
  else
    code=$?
    cat "$gate_log"
  fi
  GATE_LOG="$gate_log" bash "$SKILL_ROOT/scripts/hooks/after-gate-fail-hook.sh" \
    "$FEATURE" "$phase" "gate exit=$code" || true
  bash "$SKILL_ROOT/scripts/checkpoint-state.sh" save \
    "$FEATURE" "$phase" "gate-fail" "$code" "见 $gate_log" "修复后恢复" || true
  return "$code"
}

check_skip_authorization() {
  phase="$1"
  grep -qE "^SKIP_${phase}=.+" ".devflow/$FEATURE/skip-log.txt" 2>/dev/null
}
# skip-log.txt 行格式：SKIP_<PHASE>=<理由>（理由必填；当前仅 p2b_demo_gate.sh 实现了
# skip 分支——其余阶段写 SKIP_ 不会跳过 Gate 本体，将按"已授权但 gate 未通过"处理为失败；
# P3、P4b、P6、P7、P8、P9、P10 一律不可跳过）
```

每一阶段按 `Gather → Act → Verify → Receipt` 执行：

1. 读取冻结输入与当前事实源。
2. 产出该阶段实际文件或运行结果。
3. 用矩阵中的确定性 Gate 验证，保留 stdout 和真实退出码。
4. Gate 为 0 后更新 state；非 0 时保存 checkpoint 并停止。

## 客户端路由

| 范围 | 构建/测试/发布 | 必需旅程证据 |
|---|---|---|
| PC Web | `client-adapter.sh <action> pc-web <dir> --strict` | 真实浏览器 |
| 微信小程序 | `client-adapter.sh <action> mini-program <dir> --strict` | 开发者工具或模拟器 |
| APP | `client-adapter.sh <action> app <dir> --strict` | 模拟器或真机 |
| 无前端 | `not-applicable` | 冻结的不适用理由 |

构建成功不是旅程通过；模拟器证据不是生产发布证明。

## Skip Authorization Rules

- 只有用户在当前请求中明确授权，才可写 `SKIP_<phase>=<reason> (user/date)`。
- P3、P4b、P6、P7、P8、P9、P10 不可跳过。
- “已有产物”只有在当前 Gate 重新返回 0 后才算前置条件满足。
- 不使用 `read -p` 等交互等待；未授权时直接 `BLOCKED`。

## Release Authorization（外部副作用人工授权）

进入 P7 前，若目标包含任何外部副作用——staging/production 部署、数据库迁移、merge、push 或对外通知——必须存在显式人工授权收据：

`.devflow/<feature>/authorizations/release.json`

```json
{
  "feature": "<feature>",
  "target": "<environment>",
  "authorized_by": "<user-or-approved-actor>",
  "authorization_source": "explicit-user-request",
  "authorized_at": "<timestamp>",
  "scope": ["deploy"]
}
```

- 收据只能由用户在当前会话中的明确指令生成；模型不得自行推断或代签。
- 无有效收据时最高只能声明 `READY_TO_RELEASE`；不得声明 `RELEASED`，也不得执行任何外部副作用命令。
- 授权范围以 `scope` 为准；超出范围的副作用需要新的授权。
- 破坏性 migration、生产数据回填、不可逆操作与 `EXTERNAL`/`IRREVERSIBLE` 副作用一律要求人工批准。
- **机器执行点（v3.28.4）**：`artifact_gate.sh P7` 与 `small-change --target=released` 均机检本收据——`feature` 匹配、`scope` 含 `deploy`、`authorized_by`/`authorization_source` 非空、`authorized_at` 合法且不超过 24h 时效（过期须重新授权）。

## Checkpoint recovery

```bash
bash "$SKILL_ROOT/scripts/devflow-state.sh" resume <feature>
bash "$SKILL_ROOT/scripts/checkpoint-state.sh" orphans <feature>
```

恢复时先核验产物哈希、Gate 收据和 `devflow-client.json` 冻结哈希；漂移则回到最早受影响阶段，不从显示中的“当前阶段”盲目继续。

## 进度可视化

```text
已完成: P0 ✓ P0b ✓ P1 ✓
当前:   P2 →
待执行: P2a ○ ... P10 ○
阻塞:   <none | phase + evidence>
```

## Completion

只有满足以下条件才能声明完成：

- P0-P10 所有适用 Gate 均有新鲜的零退出码收据；
- 设计覆盖率 100%，首轮准确率达到冻结阈值，B/C 迁移零差异；
- 数据库、客户端旅程、部署、监控和文档证据分别标明“已验证/运行未验证”；
- 独立审查与完成度审计未由开发者自签；
- 声明 `RELEASED` 时另有有效发布授权收据（`authorizations/release.json`）；无授权最高为 `READY_TO_RELEASE`；
- P10 项目反馈队列已通过 `p10_feedback_gate.sh`；安装 skill 的改动另行经用户批准。
