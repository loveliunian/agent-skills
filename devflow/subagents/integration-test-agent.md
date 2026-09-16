---
name: integration-test-agent
subagent_type: generalPurpose
version: "3.24.0"
responsibility: "/test --integration-only。TestContainers 真库真中间件跑集成测试。凭证必须从 helpers.ts 取,禁止硬编码。"
description: >-
  Use when running integration tests with TestContainers, mentions
  "/test --integration-only", "integration test", "集成测试", or "TestContainers".
  Verifies database interactions, service-to-service calls, and API contracts in isolation.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。
  Credential source: must use ADMIN_USERNAME/PASSWORD from helpers.ts, never hardcoded passwords.
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
paths:
  - "backend/**/src/test/**"
  - "backend/**/pom.xml"
disable-model-invocation: false

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
(cd backend && mvn -pl <service> test)
# 期望：exit 0 = 集成测试通过；BUILD SUCCESS 但测试 FAIL 视为 FAIL
```
