# 安全审计报告 - demo-pay

> 生成时间：2026-09-17 10:00:00（UTC）　数据来源：security.json 自动汇总（人工勿改）


<!-- 审计指纹: security.json sha256=6044e930be20f5bbc62d4f89adffd72afa4776bf261925991611df0e3a1c6220（由 df_render 自动生成，人工勿改） -->

## 覆盖概览

| 项 | 数值 |
|---|---|
| 写操作端点总数 | 3 |
| @PreAuthorize 覆盖率 | 100% |
| 发现总数 | 1 |
| OPEN（P0/P1 即阻断） | 0 |
| WAIVED（须绑定豁免依据） | 0 |

## Gate 机器字段（由 df_render 从 JSON 派生，人工勿改）

```text
SECURITY_COVERAGE=100
WRITE_OPERATIONS_TOTAL=3
FINDINGS_TOTAL=1
FINDINGS_OPEN=0
```

### 结构化 FINDING 行（p3 gate 消费口径）

```text
FINDING|P1|SEC-1|STATUS=CLOSED|ExportController#export 已补 @PreAuthorize("@ss.hasPermi('pay:export')") 并加数据范围过滤；复测命令 mvn -pl pay-service test -Dtest=ExportScopeTest
```

## 发现明细

| ID | 严重性 | 状态 | 标题 | 证据 | 豁免依据 |
|---|---|---|---|---|---|
| SEC-1 | P1 | CLOSED | 导出接口未校验数据范围，存在越权导出风险 | ExportController#export 已补 @PreAuthorize("@ss.hasPermi('pay:export')") 并加数据范围过滤；复测命令 mvn -pl pay-service test -Dtest=ExportScopeTest | — |

豁免声明文件：—
