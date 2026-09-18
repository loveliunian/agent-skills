# 部署记录 - 演示支付

> 部署日期：2026-09-16　部署人：运维-吴九　环境：staging　方式：滚动


<!-- 审计指纹: deployment.json sha256=4cb02e0e5b66c41727711e0916acb5346f13886696388f080eee90b55ee73332（由 df_render 自动生成，人工勿改） -->

<!-- P7 Gate 机器可读证据（由 df_render 从 JSON 派生，人工勿改） -->
DEPLOYMENT_ID=dep-20260916-demo-pay-01
ARTIFACT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ARTIFACT_PATH=backend/pay/target/pay-1.0.0.jar
ENVIRONMENT=staging
HEALTH_HTTP_STATUS=200
HEALTH_URL=https://staging.demo.example.com/actuator/health
BUILD_INFO_URL=https://staging.demo.example.com/actuator/info
RELEASE_EVIDENCE_PATH=docs/发布/demo-pay-release-run.md

## 部署信息

| 项 | 内容 |
|---|---|
| 功能 | 演示支付 |
| 部署环境 | staging |
| 部署方式 | 滚动 |
| 部署人 | 运维-吴九 |

## 部署前检查

### 服务状态

| 服务 | 部署前状态 | 负责人 |
|---|---|---|
| pay-service | 运行中 | 吴九 |

### 数据库备份

| 数据库 | 备份时间 | 备份文件 | 备份人 |
|---|---|---|---|
| pay | 2026-09-16 09:50 | backups/pay-20260916.sql.gz | 吴九 |

### 依赖检查

| 依赖 | 版本 | 状态 |
|---|---|---|
| PostgreSQL | 15 | ✅ |
| Redis | 7 | ✅ |

## 部署步骤

| # | 步骤 | 命令 | 退出码 | 证据 |
|---|---|---|---|---|
| 1 | 数据库迁移 | `flyway -url=jdbc:postgresql://… migrate` | 0 | Successfully applied 2 migrations |
| 2 | 后端滚动更新 | `kubectl rollout status deployment/pay-service` | 0 | successfully rolled out |

## 部署后验证

### 健康检查

| 检查项 | 命令 | 预期 | 实际 | 状态 |
|---|---|---|---|---|
| 后端健康 | `curl /actuator/health` | UP | {"status":"UP"} | ✅ |
| Prometheus | `curl /actuator/prometheus` | 200 | 200 | ✅ |

### 功能验证

| # | 功能点 | 验证方式 | 结果 |
|---|---|---|---|
| 1 | 创建支付单 | `curl -X POST /api/pay/orders` | ✅ |
| 2 | 关闭支付单 | `curl -X PUT /api/pay/orders/{no}/close` | ✅ |

## 回滚方案

### 自动回滚触发条件

- [ ] 健康检查失败持续超过 5 分钟
- [ ] 错误率大于 1%
- [ ] P0 问题导致功能不可用

### 回滚步骤

```bash
kubectl rollout undo deployment/pay-service
curl -sS https://staging.demo.example.com/actuator/health
通知研发与测试负责人
```

## 部署结果

| 项 | 内容 |
|---|---|
| 部署状态 | ✅ 成功 |
| 开始时间 | 10:00 |
| 结束时间 | 10:30 |
| 总耗时 | 30 分钟 |
| 问题记录 | 无 |

## 签字确认

| 角色 | 姓名 | 日期 |
|---|---|---|
| 部署人 | 吴九 | 2026-09-16 |
| 运维负责人 | 郑十 | 2026-09-16 |
