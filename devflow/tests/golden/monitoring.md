# 监控配置文档 - 演示支付

> 配置日期：2026-09-16　配置人：运维-吴九


<!-- 审计指纹: monitoring.json sha256=75cae24557740c62e7fce96781dc9f79af0b287acaea4499726fd404908d5b49（由 df_render 自动生成，人工勿改） -->

<!-- P8 Gate 机器可读证据（由 df_render 从 JSON 派生，人工勿改） -->
METRICS_ENDPOINT=https://staging.demo.example.com/actuator/prometheus
LOG_QUERY=https://logs.demo.example.com/saved/pay-error-dashboard
LOG_QUERY_EVIDENCE=docs/监控/demo-pay-log-query.txt
ALERT_RULE=deploy/prometheus/rules/demo-pay-alerts.yml
ALERT_TESTED=PASS
ALERT_TEST_OUTPUT=docs/监控/demo-pay-alert-test.txt

## 监控三件套（必须齐全）

| 件 | 证据 | 状态 |
|---|---|---|
| 1. Prometheus 端点 | `https://staging.demo.example.com/actuator/prometheus` | ✅ |
| 2. 日志查询证据 | `docs/监控/demo-pay-log-query.txt` | ✅ |
| 3. 告警规则与验证 | `deploy/prometheus/rules/demo-pay-alerts.yml`（PASS） | ✅ |

## Prometheus 指标

| 指标名称 | 类型 | 描述 | 单位 |
|---|---|---|---|
| pay_request_total | Counter | 支付请求总数 | 次 |
| pay_request_duration_seconds | Histogram | 支付请求耗时 | 秒 |
| pay_error_total | Counter | 支付错误总数 | 次 |

## Grafana 大盘

| 面板 | 数据源 | 刷新频率 |
|---|---|---|
| 请求量趋势 | Prometheus | 10s |
| 响应时间 P95 | Prometheus | 10s |
| 错误率 | Prometheus | 10s |

## 告警规则

| 告警名称 | 级别 | 条件 | 持续时间 | 通知方式 |
|---|---|---|---|---|
| 服务不可用 | P0 | up == 0 | 1m | 电话+短信 |
| 错误率飙升 | P0 | error_rate > 5% | 5m | 电话+短信 |
| 响应慢 | P1 | p95_latency > 2s | 10m | 钉钉 |

## 日志规范

| 场景 | 级别 | 必须包含字段 |
|---|---|---|
| 关键业务操作 | INFO | traceId, userId, operation, result |
| 系统异常 | ERROR | traceId, userId, exception, stackTrace |

## 验证检查清单

| # | 检查项 | 验证命令 | 预期结果 | 实际 | 状态 |
|---|---|---|---|---|---|
| 1 | prometheus 端点 | `curl /actuator/prometheus` | 200 | 200 | ✅ |
| 2 | 业务指标有数据 | `curl prometheus \| grep pay_` | 有数据 | pay_request_total 12 | ✅ |
| 3 | 告警规则文件 | `test -f rules/demo-pay-alerts.yml` | 存在 | 存在 | ✅ |

## 签字确认

| 角色 | 姓名 | 日期 |
|---|---|---|
| 配置人 | 吴九 | 2026-09-16 |
| 运维负责人 | 郑十 | 2026-09-16 |
