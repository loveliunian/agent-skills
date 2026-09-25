---
name: deploy
version: "3.31.1"
description: >-
  Use when deploying to staging or production after P6 and Review Gates pass, mentions
  "/deploy", "部署", "发布", "go live", "上线", "staging", or "production release".
  Must attach real health output; P8 runtime monitoring verification follows deployment.
  NOT for local dev — see docker-compose.dev.yml.
disable-model-invocation: true
paths: ["docker-compose*.yml", "k8s/**", "deploy/**", "Dockerfile*"]
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
---

# /deploy - 发布部署（P7）

> **核心约束**：**禁止"部署成功"文字**，必须附 `curl /actuator/health` 输出 + docker-compose healthcheck grep。

## 使用方式

```
/deploy <feature>
/deploy <feature> --env=prod
/deploy <feature> --service=<service>
```

## 示例

```
/deploy m-03-basic-library --env=prod
/deploy payment-system --service=payment-service
```

## 命名约定

输出：`docs/发布/<feature>-部署记录.md`

## 执行步骤

### 1. 前置检查（强制）

```bash
# P6 完成度自检必须 PASS
test -f docs/复盘/<feature>-audit-P6.md || { echo "BLOCKED: P6 自检未完成"; exit 1; }
# E2E 通过率 ≥95%
# 单测覆盖率 ≥80%
# 集成测试 全 PASS

# 外部副作用人工授权（强制）：staging/production 部署、迁移、push/merge、对外通知
test -f ".devflow/<feature>/authorizations/release.json" || { echo "BLOCKED: 缺少发布授权收据；最高只能声明 READY_TO_RELEASE"; exit 1; }
```

发布授权收据字段与规则见 `commands/devflow.md` §Release Authorization：无收据不得执行任何外部副作用命令，也不得声明 `RELEASED`。

### 2. 部署到目标环境

```bash
# 拉取镜像
docker-compose -f deploy/docker-compose.prod.yml pull <service>

# 启动服务
SERVICE="<service>"
PORT="${PORT:-$(grep -E '^[[:space:]]*port:' "backend/$SERVICE/src/main/resources/application.yml" 2>/dev/null | grep -oE '[0-9]+' | head -1)}"
test -n "$PORT" || { echo "BLOCKED: 无法解析服务端口"; exit 1; }
# 重发布场景须先由发布平台切流并停止旧实例；预检不允许把旧实例误当作新服务可用。
bash "$SKILL_ROOT/scripts/preflight-port.sh" "$PORT"
docker-compose -f deploy/docker-compose.prod.yml up -d <service>

# 等待健康
sleep 30
```

### 3. 健康检查

```bash
SERVICE="<service>"
PORT="${PORT:-$(grep -E '^[[:space:]]*port:' "backend/$SERVICE/src/main/resources/application.yml" 2>/dev/null | grep -oE '[0-9]+' | head -1)}"
test -n "$PORT" || { echo "BLOCKED: 无法解析服务端口"; exit 1; }
# 必须 200
HEALTH=$(curl -sS -o /dev/null -w "%{http_code}" "http://localhost:$PORT/actuator/health")
echo "Health: $HEALTH"
test "$HEALTH" -eq 200  # 必须 = 200

# 必须 status: UP
curl -sS "http://localhost:$PORT/actuator/health" | grep '"status":"UP"'
```

### 4. 容器 healthcheck 指令验证

```bash
# docker-compose 中必须包含 healthcheck
grep -A3 "healthcheck:" deploy/docker-compose.prod.yml | grep "test:"
# 必须命中（形如 test: ["CMD", "curl", "-f", "http://localhost:<port>/actuator/health"])
```

### 4a. 运行实例与制品绑定（v3.15.1 强制）

```bash
# BUILD_INFO_URL 必须回显本制品 ARTIFACT_SHA256 前 12 位 hex 或 DEPLOYMENT_ID 原值，
# 证明"正在运行的实例就是该制品"——任意静态 HTTP 200 不构成运行证据。
curl -sS "http://localhost:$PORT/actuator/info" | grep -F "$(printf '%s' "$ARTIFACT_SHA256" | cut -c1-12)"
# 必须命中（actuator/info 或等价 build-info 端点须回显制品哈希/部署 ID）
```

### 5. 写入部署记录

输出到 `docs/发布/<feature>-部署记录.md`：

```markdown
# <feature> 部署记录

## 基本信息
- 环境：prod
- 服务：<service>
- 版本：<git SHA>
- 操作人：主 Agent
- Date：YYYY-MM-DD HH:MM

## 部署命令
\`\`\`bash
docker-compose -f deploy/docker-compose.prod.yml up -d <service>
\`\`\`

## 健康检查输出

DEPLOYMENT_ID=<deployment-id>
ARTIFACT_SHA256=<64-hex-sha256>
ARTIFACT_PATH=<relative-artifact-path>
ENVIRONMENT=<staging-or-production>
DEV_PRIVILEGED=false
HEALTH_HTTP_STATUS=<2xx-status-declared（默认 200；Gate 实测须与声明一致）>
HEALTH_URL=http://localhost:<port>/actuator/health
BUILD_INFO_URL=http://localhost:<port>/actuator/info
RELEASE_EVIDENCE_PATH=docs/发布/<feature>-发布证据.md

### curl /actuator/health
\`\`\`bash
$ curl -sS -o /dev/null -w "%{http_code}" http://localhost:<port>/actuator/health
200
\`\`\`

### status 字段
\`\`\`bash
$ curl -sS http://localhost:<port>/actuator/health | grep '"status":"UP"'
"status":"UP"
\`\`\`

## docker-compose healthcheck
\`\`\`bash
$ grep -A3 "healthcheck:" deploy/docker-compose.prod.yml
  healthcheck:
    test: ["CMD", "curl", "-f", "http://localhost:<port>/actuator/health"]
    interval: 30s
    timeout: 10s
    retries: 3
\`\`\`

## 镜像信息
\`\`\`bash
$ docker images | grep <service>
<service>:<tag>   <id>   <date>   <size>
\`\`\`

## 结论
- [ ] PASS — Health 200 + status UP + healthcheck 命中
- [ ] FAIL — 任一项不通过 → 阻塞进 P8
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 部署记录路径 | `docs/发布/<feature>-部署记录.md` 实际写入 |
| curl /actuator/health | **必须 = 200 + status: UP**（**附真实命令输出**） |
| docker-compose healthcheck | **必须 grep 命中** |
| 不允许仅有"部署成功"文字 | 强制附命令 stdout |

## 输出

- `docs/发布/<feature>-部署记录.md`

## 自检命令

```bash
# P7 自检：Health 200 + status UP
HEALTH=$(curl -sS -o /dev/null -w "%{http_code}" http://localhost:<port>/actuator/health)
STATUS=$(curl -sS http://localhost:<port>/actuator/health | grep -o '"status":"UP"')
test "$HEALTH" -eq 200 && test -n "$STATUS" && echo "P7 PASS"

# docker-compose healthcheck 命中
grep -q "healthcheck:" deploy/docker-compose.prod.yml && echo "P7 docker PASS"
```

## 角色约束

- 主 Agent 执行
- 实际操作人需是 DevOps / SRE，但**命令文件输出**由主 Agent 收集

## 与其他命令关系

- 前置：`/test`（P6）PASS
- 完成后：**强制**运行 `/audit-completeness P7 <feature>`
- P7 PASS 后才能进 `/monitor` (P8)

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P7 <feature>
# 期望：exit 0 = 部署产物检查通过
```

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
