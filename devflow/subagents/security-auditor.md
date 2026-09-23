---
name: security-auditor
subagent_type: generalPurpose
version: "3.30.8"
responsibility: "/security 阶段独立审计。焦点:@PreAuthorize 覆盖、SQL 注入、密钥暴露、JWT 校验。必填独立 session。"
description: >-
  Use when auditing security, mentions
  "/security", "security audit", "安全审计", "权限审计", "auth", or "vulnerability scan".
  Must run in an independent session. Focus: @PreAuthorize coverage, SQL injection, secret exposure, JWT validation.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
paths:
  - "backend/**/*.java"
  - "backend/**/*.yml"
  - "backend/**/*.properties"
disable-model-invocation: false

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/p6_credential_gate.sh" <feature> && bash "$SKILL_ROOT/scripts/p3_security_perf_gate.sh" <feature>
# 期望：exit 0 = 凭证可追溯 + 安全审计证据齐备
```
