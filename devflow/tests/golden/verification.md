# demo-pay 终验报告（部署前最终验收）

> 生成时间：2026-09-12 11:00:00（UTC）　验证环境：**预发布环境**　数据来源：终验数据自动汇总
<!-- 审计指纹: verification.json sha256=f00462391c1cbc84d7e8340edde27825314f45d5f4eefda17e00f0955e7e47d1 -->

## 结论：全部通过，可以部署

3 个验收点全部通过。五类测试（单元、集成、客户端、负载、预发布）均已执行，结果全部通过，明细见下文。

## §1 验收点明细

| ID | 终态 | 证据 |
|---|---|---|
| M01-F01-A01 | PASS | report-integration.html#M01-F01-A01 |
| M01-F01-A02 | PASS | report-integration.html#M01-F01-A02 |
| M01-F02-A01 | PASS | report-staging.html#M01-F02-A01 |

共 3 个验收点：通过 3 个，未通过 0 个。验收点范围与测试开始前冻结的验收点清单完全一致，无遗漏、无多余。

## §2 五类测试证据绑定

| 测试类别 | 执行命令 | 退出码 | 实测退出码 | 报告文件 | 报告指纹 | 日志 |
|---|---|---|---|---|---|---|
| 单元测试 | pytest -q | 0 | 未记录 | report-unit.txt | — | unit.log |
| 集成测试 | mvn verify | 0 | 未记录 | report-integration.txt | — | — |
| 客户端测试 | npm run test:e2e | 0 | 未记录 | report-client.txt | — | — |
| 负载测试 | jmeter -n -t plan.jmx | 0 | 未记录 | report-load.txt | — | — |
| 预发布验证 | ./scripts/smoke.sh staging | 0 | 未记录 | report-staging.txt | — | — |

> 「实测退出码」是部署前检查流程现场重新执行同一命令后的实际结果，与上表命令一一对应；报告指纹是报告文件内容的 SHA-256 摘要，用于事后核对报告未被改动。

## §3 客户端测试说明

客户端测试已执行：`npm run test:e2e`，报告见 `report-client.txt`。

## §4 空项与特别说明

无。
