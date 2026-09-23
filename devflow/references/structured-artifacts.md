# 结构化产物层 · Gate 强制矩阵（v3.30.6）

> 正本契约与管线口径见 `SKILL.md`「全阶段结构化产物」；本文是各阶段 Gate 对 JSON 正本的
> 强制状态与接线模式的唯一明细页。

## 强制状态

| 阶段 | 正本 kind | Gate | 强制状态 | 收据绑定 |
|---|---|---|---|---|
| P0 | acceptance | `s0_acceptance_gate.sh` §1b | ✅ 已强制：缺失 / 校验失败 / 与 Markdown 冻结分母集合不一致，任一即 P0 | `ACCEPTANCE_JSON` + `ACCEPTANCE_JSON_SHA256` |
| P2 | design | `s2_design_coverage_gate.sh` §2c | ✅ 已强制（v3.17.1 起） | `DESIGN_JSON_SHA256` + 证据树 |
| P3c | security | `p3_security_perf_gate.sh` | ✅ 已强制（v3.25.2） | `SECURITY_JSON_SHA256` |
| P3d | performance | `p3_security_perf_gate.sh` | ✅ 已强制（v3.25.2） | `PERFORMANCE_JSON_SHA256` |
| P6 | verification | `s6_final_verification_gate.sh` | ✅ 已强制（校验 + 执行记录对账） | 证据树 |
| P0b | prd-review | `artifact_gate.sh P0b` | ✅ 已强制（v3.30.0 Gate 侧接入） | `PRD_REVIEW_JSON` + SHA256 |
| P1 | tech-selection / clarification / constraints | `s1_fact_sources_gate.sh` | ✅ 已强制（v3.30.0，三正本逐一） | 三组 `*_JSON` + SHA256 |
| P2a | design-review | `p2a_design_review_gate.sh` | 同上 | — |
| P2b | demo-signoff | `p2b_demo_gate.sh` | 同上 | — |
| P3 | self-check | `p3_completion_gate.sh` | 同上 | — |
| P3b | code-review | `p3b_code_review_gate.sh` | 同上 | — |
| P4 | prd-validation | `p4_validation_gate.sh` | 同上 | — |
| P5 | test-cases | `p5_test_cases_gate.sh` | 同上 | — |
| P7 | deployment | `artifact_gate.sh P7` | 同上 | — |
| P8 | monitoring | `artifact_gate.sh P8` | 同上 | — |
| P9 | docs-index | `artifact_gate.sh P9` | 同上 | — |
| P10 | retrospective / sharing | `p10_feedback_gate.sh` | ✅ 已强制（v3.30.0，双正本） | 双组 `*_JSON` + SHA256 |
| 小改动 | small-change | `small-change-gate.sh` | ✅ 已强制（v3.30.0 Gate 侧接入） | `SMALL_CHANGE_JSON` + SHA256 |

## 接线模式（其余阶段照抄即可）

每个 Gate 三步（以 s0 §1b 为模板）：

1. **解析正本**：`ACCEPTANCE_JSON="${STATE_DIR:-.devflow}/${EFF_FEATURE}/acceptance.json"`；
2. **失败关闭校验**：缺失即 P0（提示管线命令）；`(unset LC_ALL; python3 df_validate.py --kind <kind> --input <json> --workspace .)` 非零即 P0；
3. **收据绑定**：`<KIND>_JSON=<path>` + `<KIND>_JSON_SHA256=<hash>`（与 `EVIDENCE_SHA256` 同口径，audit-receipts 重验即篡改拦截）。

需要跨文件对账的 kind（如 acceptance ↔ criteria、test-cases ↔ acceptance）在 Gate 内
追加集合全等检查（双正本矛盾在进 Gate 前拦截，参照 s0 §1b 的 JSON↔Markdown 对账）。
