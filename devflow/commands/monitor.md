---
name: monitor
version: "3.31.4"
description: >-
  Use when configuring application monitoring after P6 testing, mentions
  "/monitor", "监控", "监控配置", "prometheus", "metrics", "actuator", or "observability setup".
  Three mandatory items: prometheus /actuator/prometheus endpoint + logback-spring.xml + micrometer-registry-prometheus dep.
  Must curl the prometheus endpoint before signing off.
paths:
  - "backend/**/*.yml"
  - "backend/**/*.xml"
  - "backend/**/pom.xml"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
---

# /monitor - 监控配置（P8）

> **核心约束**：**监控三件套必须齐全**——prometheus 端点 + logback 文件 + micrometer 依赖。

## 使用方式

```
/monitor <feature>
/monitor <feature> --service=<service>
```

## 示例

```
/monitor m-03-basic-library
/monitor payment-system --service=payment-service
```

## 命名约定

输出：`docs/发布/<feature>-监控配置.md`

证据文件（人类可读产物一律中文名，与监控配置同目录）：

| 证据 | 路径 |
|------|------|
| 指标采样（≥5 条真实采样行） | `docs/发布/<feature>-指标采样.txt` |
| 指标端点快照 | `docs/发布/<feature>-指标快照.txt` |
| 日志查询证据（≥2 行真实查询结果） | `docs/发布/<feature>-日志查询证据.txt` |
| 告警规则（含 `alert:` + `expr:`） | `docs/发布/<feature>-告警规则.yml` |
| 告警实测输出（三要素） | `docs/发布/<feature>-告警测试输出.txt` |

## 执行步骤

### 1. Prometheus 端点

```bash
SERVICE="<service>"
PORT="${PORT:-$(grep -E '^[[:space:]]*port:' "backend/$SERVICE/src/main/resources/application.yml" 2>/dev/null | grep -oE '[0-9]+' | head -1)}"
test -n "$PORT" || { echo "BLOCKED: 无法解析服务端口"; exit 1; }
# v3.14.1: 监控阶段服务应处于运行状态——端口必须监听且属于目标服务（与 deploy 前的"必须空闲"相反）
bash "$SKILL_ROOT/scripts/preflight-port.sh" --expect-listening "$PORT" "$SERVICE"
# 必须 200
PROM=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$PORT/actuator/prometheus")
echo "Prometheus: $PROM"
test "$PROM" -eq 200  # 必须 = 200

# 必须返回 metrics（不能 404）
curl -sS "http://localhost:$PORT/actuator/prometheus" | grep "^# HELP"
```

### 2. logback 文件

```bash
test -f backend/<service>/src/main/resources/logback-spring.xml && echo "logback OK"

# 检查日志输出格式（必须含 JSON / 时间戳 / 级别）
grep -E "pattern|encoder" backend/<service>/src/main/resources/logback-spring.xml
```

### 3. micrometer 依赖

```bash
grep "micrometer-registry-prometheus" backend/<service>/pom.xml
# 必须命中
```

### 4. actuator 配置

```bash
# application.yml 必须暴露 prometheus
grep "prometheus" backend/<service>/src/main/resources/application.yml
# 必须命中

# 检查 health / info / prometheus 都暴露
grep -A20 "management:" backend/<service>/src/main/resources/application.yml | grep "endpoint"
```

### 5. 自定义业务指标（可选）

```bash
# 查找 Micrometer Counter / Gauge / Timer 使用
grep -rn "MeterRegistry\|Counter\\.builder\|Gauge\\.builder\\|Timer\\.builder" \
  backend/<service>/src/main/java | head -10
```

### 6. 写入监控配置记录

输出到 `docs/发布/<feature>-监控配置.md`：

```markdown
# <feature> 监控配置

## 基本信息
- 服务：<service>
- Date：YYYY-MM-DD

METRICS_ENDPOINT=<actual-prometheus-endpoint>
LOG_QUERY=<saved-query-or-dashboard-link>
LOG_QUERY_EVIDENCE=docs/发布/<feature>-日志查询证据.txt
ALERT_RULE=docs/发布/<feature>-告警规则.yml
ALERT_TESTED=PASS
ALERT_TEST_OUTPUT=docs/发布/<feature>-告警测试输出.txt

## 三件套检查

### 1. Prometheus 端点
\`\`\`bash
$ curl -sS -o /dev/null -w "%{http_code}" http://localhost:<port>/actuator/prometheus
200

$ curl -sS http://localhost:<port>/actuator/prometheus | head -5
# HELP jvm_memory_used_bytes The amount of used memory
# TYPE jvm_memory_used_bytes gauge
...
\`\`\`

### 2. logback 文件
\`\`\`bash
$ ls -la backend/<service>/src/main/resources/logback-spring.xml
-rw-r--r--  logback-spring.xml
\`\`\`

配置片段：
\`\`\`xml
<pattern>%d{ISO8601} [%thread] %-5level %logger{36} - %msg%n</pattern>
\`\`\`

### 3. micrometer 依赖
\`\`\`bash
$ grep "micrometer-registry-prometheus" backend/<service>/pom.xml
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
\`\`\`

## actuator 配置
\`\`\`yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus
  endpoint:
    health:
      show-details: always
\`\`\`

## 业务指标（如有）
| 指标名 | 类型 | 描述 |
|--------|------|------|
| gov_element_create_total | Counter | 元素创建总数 |
| gov_reference_query_seconds | Timer | 引用查询耗时 |

## 告警规则（如已配置）
...

## 结论
- [ ] PASS — 三件套齐全
- [ ] FAIL — 任一项缺失 → 阻塞进 P9
```

Gate（强制，v3.15.1 起证据实质化）

| 项 | 强制条件 |
|----|----------|
| 监控记录路径 | `docs/发布/<feature>-监控配置.md` 实际写入 |
| METRICS_ENDPOINT | 必须 = 200 且含 ≥5 条真实采样行（仅 HELP/TYPE 头不算） |
| LOG_QUERY + LOG_QUERY_EVIDENCE | 查询声明 + 含真实查询结果（≥2 行）的证据文件 |
| ALERT_RULE | 指向含 `alert:` 与 `expr:` 的规则文件 |
| ALERT_TEST_OUTPUT | 非空（≥20B）且含 ALERT_TRIGGERED / NOTIFICATION_CONFIRMED / RECOVERY_RECORDED 三要素 |
| logback-spring.xml | **必须存在** |
| micrometer-registry-prometheus | **必须在 pom.xml** |
| application.yml | **必须含 prometheus 暴露配置** |

## 输出

- `docs/发布/<feature>-监控配置.md`

## 自检命令

```bash
# v3.15.1: 权威 Gate 自检（退出码必须为 0；禁止 || true 吞码）
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P8 <feature>
# 三件套人工核对（补充证据，不替代 Gate）：
PROM=$(curl -sS -o /dev/null -w "%{http_code}" http://localhost:<port>/actuator/prometheus)
test "$PROM" -eq 200 && echo "prom OK"
test -f backend/<service>/src/main/resources/logback-spring.xml && echo "logback OK"
grep -q "micrometer-registry-prometheus" backend/<service>/pom.xml && echo "dep OK"
grep -q "prometheus" backend/<service>/src/main/resources/application.yml && echo "yml OK"
```

## 角色约束

- 主 Agent 执行
- 与 DevOps / SRE 协作配置告警规则（Grafana / AlertManager）

## 与其他命令关系

- 前置：`/deploy`（P7）PASS
- 完成后：**强制**运行 `/audit-completeness P8 <feature>`
- P8 PASS 后才能进 `/docs` (P9)

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P8 <feature>
# 期望：exit 0 = 监控配置检查通过
```

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
