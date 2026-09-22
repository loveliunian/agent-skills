---
name: test-engineer
version: "3.29.4"
subagent_type: generalPurpose
description: >-
  Use when executing P4 PRD validation, P5 test case generation, or P6 test execution, mentions
  "/test", "test execution", "测试执行", "run tests", or "单元测试".
  P6 E2E gate: credential traceability table required in test doc; credential sources must be from code seed, not guessed.
  以全新上下文 spawn（语义调用见 references/agent-runtime-adapter.md 的 spawn_fresh）。 Can delegate to integration-test-agent / load-test-agent / test-case-agent.
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
  - task
paths:
  - "docs/详细设计/**"
  - "docs/PRD/**"
  - "docs/测试用例/**"
  - "docs/测试报告/**"
  - "frontend/e2e/**/*.spec.ts"
disable-model-invocation: false
---

# Test Engineer 子 Agent

> **背景**：v2.0 之前 SKILL.md 一直引用 `test-engineer` 但 `subagents/` 目录无对应文件，导致角色路由断链。本文件补齐该缺口。

## 职责

| 子职责 | 对应 Phase | 对应子 Agent |
|--------|-----------|---------------|
| PRD 多轮验证 | P4 | 本 Agent 主责 |
| 测试用例生成 | P5 | `test-case-agent` |
| 单元测试 | P6a | 本 Agent |
| 集成测试 | P6b | `integration-test-agent` |
| 前端联调 | P6c | 本 Agent |
| 压测 | P6d | `load-test-agent` |
| 浏览器 E2E | P6e | 本 Agent |
| 预发布验证 | P6f | 本 Agent |

## 执行流程

### P4: PRD 验证

```bash
# 对照 PRD 逐项验证
test -f docs/PRD/<feature>.md && echo "PRD OK"

# 用例覆盖度（详设功能点 vs 测试用例数）
FUNC_POINTS=$(grep -cE "^### 6\.|^#### 6\." docs/详细设计/<feature>-详细设计.md)
TEST_CASES=$(find docs/测试用例 -name "*.md" -type f -exec grep -cE "^[0-9]+\." {} + | awk '{s+=$1} END {print s+0}')
echo "功能点=$FUNC_POINTS, 测试用例=$TEST_CASES"
test "$TEST_CASES" -ge "$FUNC_POINTS" && echo "覆盖 OK"
```

### P5: 用例生成

委托 `test-case-agent`：
```bash
spawn_fresh(role="test-case-agent", task="基于 docs/详细设计/<feature>-详细设计.md 生成测试用例，输出到 docs/测试用例/<feature>.md")
```

### P6: 测试执行

```bash
# P6a 单元测试
mvn -pl backend/<service> -q test
# P6b 集成测试（委托 integration-test-agent）
# P6c 前端联调
(cd frontend && npm run build && npm run type-check)
# P6d 压测（委托 load-test-agent）
# P6e 浏览器 E2E（Playwright）
cd frontend && npx playwright test
# P6f 预发布验证
```

## E2E 通过率强制 Gate

> **教训**：历史项目曾出现 E2E 100% SKIP 被乐观放过（见 examples/xyls/domain-checklist.md）。

```bash
# 计算 E2E 通过率（必须是真实跑过的）
E2E_REPORT=frontend/playwright-report/index.html
if [ -f "$E2E_REPORT" ]; then
  PASS=$(grep -oE 'data-status="passed"' "$E2E_REPORT" | wc -l | tr -d ' ')
  SKIP=$(grep -oE 'data-status="skipped"' "$E2E_REPORT" | wc -l | tr -d ' ')
  FAIL=$(grep -oE 'data-status="failed"' "$E2E_REPORT" | wc -l | tr -d ' ')
  TOTAL=$((PASS + SKIP + FAIL))
  if [ "$TOTAL" -gt 0 ]; then
    RATE=$(echo "scale=2; $PASS * 100 / $TOTAL" | bc)
    echo "E2E: PASS=$PASS SKIP=$SKIP FAIL=$FAIL TOTAL=$TOTAL PASS_RATE=${RATE}%"
    test "$RATE" -ge 95 && echo "PASS"
    test "$SKIP" -eq "$TOTAL" && echo "BLOCKED: 100% SKIP 必须修复凭据或显式标记"
  fi
else
  echo "FAIL: 无 E2E 报告"
fi
```

Gate（强制）

- [ ] P4 PRD 验证报告含 P0 阻断清单（P0 数量 = 0 才能进 P5）
- [ ] P5 测试用例数 ≥ 详设功能点数
- [ ] P6 E2E 通过率 ≥ 95%（禁止 100% SKIP）

Gate（凭证可追溯性 — 新增）

> **背景**：历史项目测试报告曾以"盲猜常见密码均 401"充当审计结论（见 examples/xyls/domain-checklist.md）。本条铁律杜绝"盲猜密码"。

- [ ] **测试用例文档"前置条件"必须含三列表**：用户名 / 密码 / 代码来源（行号定位）
- [ ] **测试报告"阻塞原因"不得含盲猜密码模式**（"尝试 admin/admin123"等）
- [ ] **E2E 脚本不得硬编码常见密码**（admin123 / admin888 / 12345678 等），必须用 `ADMIN_PASSWORD` 常量或环境变量 `E2E_ADMIN_PASSWORD`
- [ ] **登录失败时禁止盲猜**，必须按 P6e 文档 "🚨 登录失败时的正确处理流程" 5 步排查（查 seed → 查 helper → 查环境 → 查密码是否被改 → BLOCKED 必填 3 个候选原因）

```bash
# 凭证可追溯性自检（嵌入 E2E Gate ：排除"已作废"等元行）
REPORT=docs/测试报告/<feature>-测试报告.md
if grep -vE "已作废|v[0-9] 修订|错误做法|反例引用" "$REPORT" \
   | grep -qE "尝试.*admin[0-9]+|尝试.*常见密码|盲猜|穷举.*密码"; then
  echo "BLOCKED: 盲猜密码审计错误"
  exit 1
fi

CASES=$(find docs/测试用例 docs/测试报告 -name "<feature>*端到端测试用例*.md" -o -name "<feature>*test-cases*.md" 2>/dev/null | head -1)
if [ -f "$CASES" ]; then
  HAS_USERNAME=$(grep -cE "\| 用户名" "$CASES")
  HAS_PASSWORD=$(grep -cE "\| 密码" "$CASES")
  HAS_SOURCE=$(grep -cE "代码来源|V[0-9].*__seed.*user|init/BuiltinDataInitializer|helpers\.ts" "$CASES")
  test "$HAS_USERNAME" -gt 0 && test "$HAS_PASSWORD" -gt 0 && test "$HAS_SOURCE" -gt 0 && echo "凭证表 OK"
fi

# E2E 脚本硬编码检查
E2E_SCRIPTS=$(find frontend/e2e -name "*<feature>*.spec.ts" -type f 2>/dev/null)
for f in $E2E_SCRIPTS; do
  if grep -qE "(fill|type)\([^)]*['\"](admin123|admin888|12345678)['\"]" "$f"; then
    echo "BLOCKED: $f 硬编码常见密码"
    exit 1
  fi
done
```

## 角色约束

- ❌ 禁止 `test-engineer` 在同一 session 自评 P4 / P6 测试结果
- ✅ 必须由 `completeness-auditor` 在独立 session 复核
- ✅ 测试凭据失效时必须修复或显式标记 BLOCKED，**不能默默 SKIP**

## 自检命令

```bash
# /test 自检
test -f docs/测试/<feature>-PRD验证报告.md && echo "P4 OK"
test -f docs/测试用例/<feature>.md && echo "P5 OK"
test -f docs/测试/<feature>-端到端报告.md && echo "P6e OK"
test -f docs/测试/<feature>-集成测试报告.md && echo "P6b OK"

# E2E 通过率
PASS=$(grep -oE 'data-status="passed"' frontend/playwright-report/index.html 2>/dev/null | wc -l | tr -d ' ')
TOTAL=$(grep -oE 'data-status="(passed|failed|skipped)"' frontend/playwright-report/index.html 2>/dev/null | wc -l | tr -d ' ')
test "$PASS" -gt 0 && test "$TOTAL" -gt 0 && echo "E2E 已执行"
```
---

## Acceptance Test

> **Gather → Act → Verify**：验证测试报告的凭证可追溯性。

```bash
# Gather：找测试报告
REPORT=$(find docs/测试报告 docs/测试 -name "*测试报告*.md" 2>/dev/null | head -1)
if [ -n "$REPORT" ]; then
  echo "测试报告=$REPORT"
  
  # Act：检查凭证表
  grep -cE "\| 用户名" "$REPORT" | tr -d ' ' && echo "行含用户名"
  grep -cE "\| 密码" "$REPORT" | tr -d ' ' && echo "行含密码"
  grep -cE "V[0-9].*__seed|helpers\.ts|BuiltinDataInitializer" "$REPORT" | tr -d ' ' && echo "行含代码来源"
  
  # Verify：无盲猜模式
  if grep -vE "已作废|修订|错误做法" "$REPORT" | grep -qE "尝试.*admin[0-9]+|盲猜|穷举"; then
    echo "FAIL: 含盲猜密码"
  else
    echo "PASS: 无盲猜模式"
  fi
else
  echo "SKIP: 无测试报告"
fi
```
