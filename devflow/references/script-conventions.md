# 脚本错误处理约定（Script Conventions）

> 来源：v3.26.9 深度审查报告发现 4——93 个脚本的 `set -e` 使用不一致
> （`p6_credential_gate.sh` 用 `set -euo pipefail`；`build-watchdog.sh`/
> `checkpoint-state.sh`/`p5_test_cases_gate.sh` 仅 `set -uo pipefail`；
> `s0_acceptance_gate.sh`/`p4_prd_vs_code.sh`/`s2_design_coverage_gate.sh`
> 无 `-e`）。本文件立约定与迁移清单；批量迁移随维护窗口逐个审计执行。

## 约定

1. **新增或整体重写的 Gate/工具脚本**：一律 `set -euo pipefail`。
2. **需要容忍失败的命令**：显式 `cmd || true` 或 `if cmd; then … fi` 包裹，
   禁止依赖"没开 -e 所以失败也没关系"的隐式行为。
3. **后台/管道取码**：用 `PIPESTATUS[0]`（bash 3.2 兼容）或 `if … | tee` 前先
   确认 pipefail 语义（参照 `build-watchdog.sh` gate 模式）。
4. **存量脚本不盲改**：`-e` 会让"此前被静默吞掉的失败路径"提前退出——每转换
   一个脚本必须跑全量 `tests/run-tests.sh` 回归（23 组全绿才算完成）。

## 存量迁移清单（截至 v3.26.9）

| 现状 | 脚本 |
|---|---|
| 无 `-e`（仅手写 rc 判断） | `s0_acceptance_gate.sh`、`p4_prd_vs_code.sh`（约 31KB，优先人工审计）、`s2_design_coverage_gate.sh` |
| `set -uo pipefail`（无 `-e`） | `build-watchdog.sh`、`checkpoint-state.sh`、`p5_test_cases_gate.sh`、`p3_security_perf_gate.sh`、`devflow-state-core.sh` 等 |
| `set -euo pipefail` ✓ | `p6_credential_gate.sh`、`gen-review-keypair.sh`、`devflow_profile.sh` 等 |

> 清单为快照，转换一个划掉一个；转换时在脚本头注释标注版本与回归结论。
