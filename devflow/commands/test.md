---
name: test
version: "3.30.9"
description: Use when a user asks to generate or run unit, integration, browser, load, business, or legacy-migration tests.
paths: [scripts/**, docs/测试/**, docs/测试用例/**, frontend/**, miniprogram/**, app/**]
allowed-tools: [read, write, exec, glob, grep, task]
---

# /test — P5-P6

## Preconditions and order

Load `phases/05-测试用例.md`.

1. P4/P4b 已通过；首轮 baseline 在 P3 编码前已冻结。
2. Independent Code Review/security/performance and PRD-vs-Code pass first.
3. Generate tests from atomic acceptance IDs and numbered rules.
4. Run unit, integration, client-platform contract, load, E2E/device automation, and staging tests as applicable.
5. For B/C run migration reconciliation, boundary, and recovery tests.
6. Record immutable first-pass results, then calculate pilot accuracy.

## Commands

```bash
# Existing lifecycle tests
bash "$SKILL_ROOT/scripts/p6_credential_gate.sh" <feature>

# P5 测试用例是主收据；迁移仅是 B/C 辅助证据，不能覆盖 P5 主收据
bash "$SKILL_ROOT/scripts/p5_test_cases_gate.sh" <feature> docs/测试用例/<feature>-测试用例.md

# Migration evidence; A is exempt
# P5-migration 收据
bash "$SKILL_ROOT/scripts/s5_migration_gate.sh" <feature> <A|B|C> docs/测试/<feature>-migration-evidence.env

# P6 首轮结果必须包含每个冻结 ID 一次。第一个文件
# is a per-ID TSV (`acceptance_id<TAB>status`); the review report is required.
bash "$SKILL_ROOT/scripts/s4_first_pass_snapshot.sh" record <feature> docs/测试/<feature>-first-pass-results.tsv docs/评审/<feature>-首轮准确率评审.md
bash "$SKILL_ROOT/scripts/s6_first_pass_accuracy.sh" <feature> 80

# P6 部署前终验（P6-final，v3.16.0 起 P6 强制组成——首轮准确率仅是指标，终验 FAIL=0 才能部署）：
# v3.19.0 因果序（P0 修复）：只有 s6 Gate 能产生真实执行记录，所以顺序是——
#   ① 组装 test-evidence.env + verification.json（契约 schemas/verification.schema.json）
#   ② 跑一次 Gate：执行五类命令 → 校验 verification.json（含冻结前端范围/命令逐字对账）
#      → 通过后自动渲染 docs/测试/<feature>-终验报告.md 并连同
#      verification.json 一起绑定进 P6-final 收据证据树
#   verification.json 缺失 = Gate 直接 FAIL（不再只是告警）
bash "$SKILL_ROOT/scripts/s6_final_verification_gate.sh" <feature>

# 可选预检（不替代 Gate）：Gate 跑过一次后，可用管线校验/预览报告——
# --baseline 与 --exec-record 必填（无执行记录的渲染曾产出假「可以部署」结论，已禁止）：
python3 "$SKILL_ROOT/scripts/df_pipeline.py" verification \
  --input .devflow/<feature>/verification.json \
  --out docs/测试/<feature>-终验报告-预览.md \
  --baseline .devflow/<feature>/first-pass-baseline.tsv \
  --exec-record .devflow/<feature>/test-execution-results.env
```

## 报告命名（人类可读产物一律中文名）

| 类型 | 报告路径（新产物默认） |
|------|------------------------|
| Unit | `docs/测试/<feature>-单元测试报告.md` |
| Integration | `docs/测试/<feature>-集成测试报告.md` |
| Client journey | `docs/测试/<feature>-客户端旅程报告.md` |
| Load | `docs/测试/<feature>-压测报告.md` |
| Staging | `docs/测试/<feature>-预发布验证报告.md` |
| P4 原始证据 | `docs/测试/<feature>-PRD验证原始证据.md` |

`test-evidence.env` 的 `*_REPORT_PATH` 必须指向上表中文路径；Gate 仍接受历史英文名（`*-unit-report.md`、`*-validation-report.md` 等），但新产物不得再起英文名。
机器契约层不翻译、不改名：`<feature>-implementation-evidence.tsv`、`<feature>-p4-results.tsv`、`<feature>-first-pass-results.tsv`、`<feature>-migration-evidence.env`、`.devflow/` 下产物保留英文名。

## Required evidence

| Area | Gate |
|------|------|
| Unit | Tests pass and actual JaCoCo threshold is met |
| Integration | Real integration suite passes; H2 alone is labelled |
| Client journey | Platform-appropriate report exists, >=95% passed, not 100% skipped |
| PC Web | `scripts.test` + browser journey evidence for the configured Web client |
| Mini Program | `devflow-client.json` test command passes + simulator/Developer Tools journey evidence |
| APP | `devflow-client.json` test command passes + emulator/device journey evidence |
| Load | Measured P95 is below the frozen threshold |
| Credentials | P6-credential gate: `p6_credential_gate.sh` PASS; seed/source trace exists; no guessed secret |
| Migration B/C | mapping=100, full reconciliation/sample/boundary/recovery=PASS, difference_count=0 |
| First pass | Results are immutable and accuracy>=80 for pilot |
| Final verification | `s6_final_verification_gate.sh` PASS: frozen-ID set equality, FAIL=0；Gate 实际执行五类命令并绑定报告、非空执行日志与真实退出码；`*_CMD` 不得用 `> ... 2>&1` 把运行器输出全部重定向走；`verification.json` **必填**（§3.5 对账冻结范围/命令/退出码），Gate 通过后自动渲染终验报告并入收据证据树；CLIENT_EXEMPT 仅对冻结前端范围 not-applicable 生效 |

Any missing runtime, browser, database, graph, or staging evidence remains `运行未验证`; it cannot be promoted by static success.

## Output

- `docs/测试/<feature>-测试报告.md`
- 五类测试报告：单元/集成/客户端旅程/压测/预发布验证（`docs/测试/<feature>-<中文类型>报告.md`）
- `docs/测试/<feature>-migration-evidence.env` for B/C
- `.devflow/<feature>/first-pass-results.tsv`
- P4/P5/P6 reports required by their phase files

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
