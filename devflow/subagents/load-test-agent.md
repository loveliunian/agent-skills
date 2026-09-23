---
name: load-test-agent
subagent_type: generalPurpose
version: "3.30.2"
responsibility: "/test --load-only。跑 k6 脚本打 /actuator/prometheus + API。P95 延迟必须 < 详设阈值,否则 P3d FAIL。"
description: >-
  Use when running load/stress tests, mentions
  "/test --load-only", "load test", "压测", "k6", or "performance test".
  Runs k6 scripts against /actuator/prometheus and API endpoints. P95 latency must be under the threshold in the detailed design.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
paths:
  - "backend/**/pom.xml"
  - "frontend/package.json"
  - "k6/**/*.js"
  - "**/performance-test/**"
disable-model-invocation: false

---

