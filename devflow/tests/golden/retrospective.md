# 复盘报告 - 演示支付

> 复盘日期：2026-09-16　参与人：张三、李四、王五　周期：2026-09-10 ~ 2026-09-16


<!-- 审计指纹: retrospective.json sha256=917d935368486e798b9f34d28cb23fc9c188893555e80d9e7addd396b638f5b8（由 df_render 自动生成，人工勿改） -->

## 阶段合规事实（每行附真实收据路径，禁止无证据自评）

| Phase | Gate 结果 | 收据路径 | SKIP 说明 |
|---|---|---|---|
| P0 | PASS | `.devflow/demo-pay/gates/P0/receipt.txt` | — |
| P2 | PASS | `.devflow/demo-pay/gates/P2/receipt.txt` | — |
| P3c | SKIPPED | `.devflow/demo-pay/skip-log.txt` | 压测：非支付峰值路径，用户授权跳过（skip-log 第 3 行） |

阶段执行率：2/3 PASS（SKIP 需附 skip-log 授权记录说明）。

## 复盘事实与根因

### P4 阶段发现越权漏洞

- **发生了什么**：close 接口未校验属主，普通用户可关闭他人支付单
- **为什么会发生**：详设接口清单只写了权限码，未写属主校验规则
- **为什么会漏掉**：P2a 评审安全角色走了 ZERO-DF，越权路径核查停留在权限矩阵层面
- **影响**：P4 返工一轮，进度延后 1 天
- **Owner / ETA**：张三 / 2026-09-17

## 上次遗漏了什么

| # | 遗漏项 | 影响 | 本次修复方案 |
|---|---|---|---|
| 1 | 越权场景未纳入 AW 走查必选清单 | 安全缺陷漏到 P4 才发现 | AW 模板固化「越权访问」场景（已在本次评审执行） |

## 本次新发现

| # | 新发现 | 影响 | 处置方案 |
|---|---|---|---|
| 1 | 幂等键口径在两份文档中不一致（§3.2 与接口卡） | 若按接口卡实现会与回调幂等冲突 | P2 渲染 biz-ops 块后已统一为 order_no+渠道 |

## 行动计划

| # | 改进项 | 优先级 | Owner | ETA |
|---|---|---|---|---|
| 1 | 详设接口卡增加「属主校验」必填字段 | P0 | 老周 | 2026-09-20 |
| 2 | P2a 安全角色 ZERO-DF 必须附越权走查证据 | P1 | 王五 | 2026-09-25 |

## 反馈队列（P10 硬闭环）

| 项 | 值 |
|---|---|
| feedback_id | `FB-20260916-001` |
| scope | `project` |
| status | `PROPOSED` |
| 用户批准 skill 修改 | 否（未批准不得 apply） |

> 本复盘已形成项目本地 `.devflow/<feature>/feedback/feedback.md`（--out-feedback 由管线产出）：

```text
FEEDBACK_ID=FB-20260916-001
SCOPE=project
STATUS=PROPOSED
ROOT_CAUSE=详设接口卡模板缺「属主校验」必填字段，安全设计停留在权限码层面
TARGET_FILES=docs/详细设计/demo-pay-详细设计.md,schemas/design.schema.json
DECISION=fix
```

## 复核命令输出（防自评失真，实际输出由 JSON 粘贴）

```bash
$ find .devflow docs -name receipt.txt | sort
.devflow/demo-pay/gates/P0/receipt.txt
.devflow/demo-pay/gates/P2/receipt.txt
$ bash p10_feedback_gate.sh demo-pay
P10 RESULT: PASS=3 FAIL=0
```
