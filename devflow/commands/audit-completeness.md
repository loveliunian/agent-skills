---
name: audit-completeness
version: "3.30.1"
description: >-
  Use when checking Phase completion before transitioning to the next phase, mentions
  "/audit", "/audit-completeness", "检查完成度", "阶段门控", "P3 自检", or "gate self-check".
  Executes all completion items for the specified Phase. Must run in an independent session — never in the same session as the developer who wrote the code.
  Phase targets: P0-P10 lifecycle phases (single track).
paths:
  - "**/*.md"
  - "backend/**/*.java"
  - "frontend/src/**"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
  - task
---

# /audit-completeness - 完成度自检

> **核心角色**：`completeness-auditor`（独立于开发与审查的第三视角）
>
> **强制原则**：任何 Phase 切换前必须运行本命令。**禁止开发 Agent 自评** —— 防止"自我感觉良好"。

## 如何真正起一个独立 session

> **核心问题**：v2.0 只说"独立 session"，但没说怎么起。以下是 Cursor / Claude Code / Codex 三平台的标准化做法。

### Cursor

```bash
# 方法 A：用 Task tool（推荐）
spawn_fresh(role="completeness-auditor", task="运行 /audit-completeness P3 <feature> ...")

# 方法 B：新开 Cursor 窗口 + 在 prompt 显式写角色
"切换为 completeness-auditor 角色。运行 /audit-completeness P3 <feature>"
```

**强制**：调用前必须满足"独立 session"硬约束——
- ❌ 在刚写完 P3 代码的同一个会话里立刻调 Task = 自评
- ✅ 另起会话窗口，或开无状态 Cursor 子 Agent

### Claude Code

```bash
# 开新 CLI 会话
claude "你是 completeness-auditor。运行 /audit-completeness P3 <feature> ..."
```

### Codex

使用Codex多Agent能力创建无开发历史的独立审计Agent，并在任务中显式加载本Skill和`subagents/completeness-auditor.md`。若当前运行环境没有独立Agent/新任务能力，则要求用户开启新任务；同一开发会话不能签发Gate。

### 通用规则

| 维度 | 自评（❌） | 独立（✅） |
|------|-----------|-----------|
| git log 最近作者 | 当前 Agent | 不同的 Agent / human |
| 会话历史 | 包含刚才写代码的输出 | 完全空白或仅含"切换角色" |
| 凭据 | 同 API key | 同 API key 也可，但**session 必须独立** |
| Task tool prompt | 直接调用 | `你是 completeness-auditor。` 前缀 |

## 使用方式

```
/audit-completeness <phase> [feature-name]
```

## 强制：每项检查必须 PASS 才算自检通过

### P0 vs P1/P2 处理逻辑

| 严重程度 | 处理规则 | 不允许的处理 |
|----------|----------|----------------|
| **P0 阻断** | 必须全 P0 修复 → 重跑自检 → PASS → 才签字 | ❌ "标注为已知风险继续推进"<br>❌ "不影响主流程放过" |
| **P1 高优** | 自检报告中**显式列出** + 强带 owner + ETA，**可继续推进**但下一 Phase 优先解决 | ❌ 默默吞掉不提 |
| **P2 中优** | 自检报告中**显式列出**，**可继续推进** | ❌ 默默吞掉不提 |
| **Nit** | 不阻塞，可忽略 | — |

**自检报告除 PASS/FAIL 外必须有"未修复 P1/P2 清单 + owner + ETA"段**，否则按 FAIL 处理。

## 示例

```
/audit-completeness P0 <feature>   # 原子验收点冻结
/audit-completeness P3 <feature>   # P3 完成度自检
/audit-completeness P3b <feature>  # P3b Code Review 自检
/audit-completeness P3c <feature>  # P3c Security Audit 自检
/audit-completeness P3d <feature>  # P3d Performance Audit 自检
/audit-completeness P4 <feature>   # P4 PRD 验证 P0 阻断项清单检查
/audit-completeness P5 <feature>   # P5 用例数 ≥ 详设功能点
/audit-completeness P6 <feature>   # P6 E2E 通过率 ≥95%（禁 100% SKIP）
/audit-completeness P7 <feature>   # P7 部署健康检查
/audit-completeness P8 <feature>   # P8 监控三件套
/audit-completeness P9 <feature>   # P9 文档路径清单
/audit-completeness P10 <feature>  # P10 复盘路径清单
/audit-completeness P2 m-03-basic-library            # 100%字段级详设
/audit-completeness 图谱健康 m-03-basic-library      # 图谱ready或显式回退（P4b 后可选）
```

## Phase Gate 检查项

### PRD实施方法论Gate

以下命令必须返回0并将完整stdout写入审计报告：

```bash
# P0
bash "$SKILL_ROOT/scripts/s0_acceptance_gate.sh" <feature>

# P1
bash "$SKILL_ROOT/scripts/s1_fact_sources_gate.sh" docs/详细设计

# P2
bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/<feature>-详细设计.md docs/需求/<feature>-验收点.md

# P2 迁移映射（A自动豁免；B/C必须映射）
bash "$SKILL_ROOT/scripts/s3_migration_mapping_gate.sh" <A|B|C> docs/数据映射/<feature>-映射.md <source-count>

# P4/P6
test -f .devflow/<feature>/first-pass-baseline.tsv
bash "$SKILL_ROOT/scripts/s6_first_pass_accuracy.sh" <feature> 80

# P5（A自动豁免）
bash "$SKILL_ROOT/scripts/s5_migration_gate.sh" <A|B|C> docs/测试/<feature>-migration-evidence.env

# 图谱健康（P4b 后可选）——REPORT 环境变量传报告路径（feature 已嵌入路径）
# v3.15.17: 移除误传的 <feature> 位置参数——s8 为二选一设计（feature→默认路径
# .devflow/<feature>/graph-health-report.env；REPORT/--report→显式路径）。REPORT 已
# 显式指定时传 feature 仅剩 scope 标签冗余 + 触发 .devflow/<feature>/ 空目录 mkdir
# 副作用（REPORT_FILE 被 REPORT 覆盖，目录白建）。与编排方 s8b/方法论口径对齐。
REPORT=docs/测试/<feature>-graph-evidence.env bash "$SKILL_ROOT/maintenance/s8_graph_health_gate.sh"
```

P0-P2缺失时不得进入P3；P4 baseline必须在代码前冻结。P6准确率仅在首次Review/测试结果记录后运行。独立审计会话不可用时返回`BLOCKED`。

### 全局开关：退出码传播（fail-closed，v3.15.1）

> **核心问题**（用户负向夹具实证）：旧指导教人 `set +e` / 全局 `|| true` 兜底，导致
> P9 五个文件全部 MISSING 仍 exit 0、Gate 失败被吞、"审计通过"是假的。
>
> **铁律（废除 fail-open）**：
> 1. 每条检查命令的**真实退出码必须捕获并进入报告**：`cmd; rc=$?`。
> 2. **任何非零退出码 = 该检查项 FAIL = 阻塞**，不得 `|| true`、不得 `set +e` 吞码。
> 3. `grep` 的"无匹配 exit 1"本身就是判定信号——由报告区分"命令失败"与"期望不满足"，而不是吞掉它。
> 4. 报告分两段：段 1 每项命令的完整 stdout + 退出码；段 2 按期望判定 PASS/FAIL。

```bash
# 标准模式（示例）
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P9 <feature>
rc=$?
echo "command: artifact_gate.sh P9 <feature>"; echo "exit_code: $rc"
[ "$rc" -eq 0 ] || { echo "[FAIL] P9 Gate 阻断（退出码 ${rc}）——修复后重跑"; exit "$rc"; }
```

### 命名约定

| 占位符 | 规则 | 示例 |
|--------|------|------|
| `<feature>` | kebab-case，全小写，连接符 `-`，禁止中文 / 空格 / 下划线 | `m-03-basic-library-governance` / `user-management` |
| `<service>` | 从项目模块与部署清单解析的服务目录名 | `order-service` |
| `<port>` | 从配置、环境变量或部署清单解析的实际端口 | `8080` |

> **示例**：`/audit-completeness P3 <feature>` 在 `docs/复盘/<feature>-audit-P3.md` 写报告（kebab-case）。

### P3 完成度自检（权威入口）

```bash
# P3-1: 代码完成度（产物 + 11 grep + 8 专项）
bash "$SKILL_ROOT/scripts/p3_completion_gate.sh" <service> <feature>

# P3-2 (v3.9.4 NEW): build-watchdog 编译验证
# 任何 Phase 切换前必须跑 — 验证 mvn compile + npm build + tsc 全部 PASS
bash "$SKILL_ROOT/scripts/build-watchdog.sh" gate <feature>

# 收据路径：
#   .devflow/<feature>/gates/P3-build/receipt.txt
# 阻断条件：EXIT_CODE != 0
```

退出码非0即阻断；完整stdout写入独立审计报告。

### P3b 完成度自检（Code Review P0 = 0 — ）

```bash
# Review 报告存在性 + P0 阻断项数
REPORT=docs/评审/<feature>-代码审查报告.md
test -f "$REPORT" || { echo "[P0] Report not found: $REPORT"; exit 1; }
# P0-7 修复: 先检查文件存在性，缺失报告应该 FAIL 而不是 0
P0_COUNT=$(grep -cE "\| P0-" "$REPORT" 2>/dev/null || echo 0)
echo "Code Review P0 阻断项数: $P0_COUNT"
test "$P0_COUNT" -eq 0  # 必须 = 0
```

### P3c 完成度自检（Security Audit P0 = 0 — ）

```bash
# Security 报告 P0 阻断项数
REPORT=docs/评审/<feature>-安全审计报告.md
test -f "$REPORT" || { echo "[P0] Report not found: $REPORT"; exit 1; }
# P0-7 修复: 先检查文件存在性，缺失报告应该 FAIL 而不是 0
P0_COUNT=$(grep -cE "\| P0-" "$REPORT" 2>/dev/null || echo 0)
echo "Security Audit P0 阻断项数: $P0_COUNT"
test "$P0_COUNT" -eq 0
```

### P3d 完成度自检（Performance Audit — ）

```bash
# Performance 报告存在性
REPORT=docs/评审/<feature>-性能审计报告.md
test -f "$REPORT" || { echo "[P0] Report not found: $REPORT"; exit 1; }
P95=$(grep -oE "P95[^|]*[0-9]+ms" "$REPORT" | head -1 | grep -oE "[0-9]+")
THRESHOLD=500  # 阈值：P95 < 500ms
echo "P95 延迟: ${P95}ms (阈值 ${THRESHOLD}ms)"
test "${P95:-99999}" -lt "$THRESHOLD"
```

### P4 完成度自检（验证报告 + P4 收据）

```bash
bash "$SKILL_ROOT/scripts/p4_validation_gate.sh" <feature>
test -f .devflow/<feature>/gates/P4/receipt.txt
```

### P7 完成度自检（部署健康检查 — 权威 Gate）

```bash
# v3.15.1: 只调用权威 Gate，原样传播退出码（零散 curl/grep 拼凑已废除）
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P7 <feature>
rc=$?
# 收据写入 .devflow/<feature>/gates/P7/receipt.txt；rc != 0 即阻塞
# Gate 校验：DEPLOYMENT_ID / ARTIFACT_PATH+SHA256 / ENVIRONMENT / HEALTH_URL 实时 200 /
#           BUILD_INFO_URL 回显制品 SHA 前缀或部署 ID / RELEASE_EVIDENCE_PATH 实质化 / 客户端 release
exit $rc
```

### P5 完成度自检（用例数 ≥ 详设功能点 — ）

```bash
# 详设功能点（关键流程小节：完整版 §6 / 分文档 §4）
FUNC_POINTS=$(grep -cE "^### (6|4)\.[0-9]+" docs/详细设计/<feature>-详细设计.md 2>/dev/null | tr -d ' ')

# 测试用例数（kebab-case 文档）
TEST_CASES=$(find docs/测试用例 -name "<feature>*.md" -type f -exec grep -cE "^[0-9]+\." {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')

# 客户端旅程用例清单：PC Web、小程序、APP 使用同一证据契约
CLIENT_CASES=$(grep -cE '^\|[[:space:]]*CLIENT-' "docs/测试用例/<feature>-客户端旅程.md" 2>/dev/null || echo 0)

echo "详设功能点=$FUNC_POINTS, 业务用例=$TEST_CASES, 客户端旅程=$CLIENT_CASES"
TOTAL=$((TEST_CASES + CLIENT_CASES))
test "$TOTAL" -ge "$FUNC_POINTS" && echo "用例覆盖 OK"
```

### P6 完成度自检（客户端适配器 + 真实旅程证据）

```bash
CLIENT_ROOT="<client-root>"
PLATFORM="<pc-web|mini-program|app|not-applicable>"
bash "$SKILL_ROOT/scripts/client-adapter.sh" test "$PLATFORM" "$CLIENT_ROOT" --strict

REPORT="docs/测试/<feature>-客户端旅程报告.md"
test "$PLATFORM" = "not-applicable" || test -f "$REPORT" || {
  echo "BLOCKED: 缺少真实客户端旅程报告"; exit 1;
}
grep -qE '平台:[[:space:]]*(PC Web|微信小程序|APP)|platform:[[:space:]]*(pc-web|mini-program|app)' "$REPORT" 2>/dev/null
grep -qE 'PASS_RATE[=:][[:space:]]*(9[5-9]|100)%|通过率[：:][[:space:]]*(9[5-9]|100)%' "$REPORT" 2>/dev/null
grep -qE 'SKIP[=:][[:space:]]*100%|100%[[:space:]]*SKIP' "$REPORT" 2>/dev/null && {
  echo "BLOCKED: 客户端旅程 100% SKIP"; exit 1;
} || true
```

### P6 凭证可追溯性自检

> **背景**：历史项目中曾出现"盲猜常见密码均 401"式假审计；正确凭证在代码 seed 中是确定的，禁止穷举式"验证"。
>
> 直接调用 `scripts/p6_credential_gate.sh <feature>`。

```bash
# 推荐：一键执行
bash "$SKILL_ROOT/scripts/p6_credential_gate.sh" <feature>
# 手动分项
REPORT=docs/测试报告/<feature>-测试报告.md
test -f "$REPORT" || { echo "FAIL: 测试报告不存在"; exit 1; }
if grep -vE "已作废|v[0-9] 修订|错误做法|反例引用" "$REPORT" \
   | grep -qE "尝试.*admin[0-9]+|尝试.*常见密码|尝试.*多个密码|盲猜|穷举.*密码"; then
  echo "BLOCKED: 测试报告含盲猜密码审计错误 — P0 阻断"
  exit 1
fi
CASES=$(find docs/测试用例 docs/测试报告 -name "<feature>*端到端测试用例*.md" -o -name "<feature>*test-cases*.md" 2>/dev/null | head -1)
if [ -n "$CASES" ] && [ -f "$CASES" ]; then
  HAS_USERNAME=$(grep -cE "\| 用户名" "$CASES")
  HAS_PASSWORD=$(grep -cE "\| 密码" "$CASES")
  HAS_SOURCE=$(grep -cE "代码来源|V[0-9].*__seed.*user|init/BuiltinDataInitializer|helpers\.ts" "$CASES")
  if [ "$HAS_USERNAME" -eq 0 ] || [ "$HAS_PASSWORD" -eq 0 ] || [ "$HAS_SOURCE" -eq 0 ]; then
    echo "BLOCKED: $CASES 凭证表不完整"
    exit 1
  fi
fi
```

### P8 完成度自检（监控三件套 — 权威 Gate）

```bash
# v3.15.1: 只调用权威 Gate，原样传播退出码（伪 Prometheus 响应不再能通过）
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P8 <feature>
rc=$?
# Gate 校验：METRICS_ENDPOINT 真实 Prometheus 内容 + ≥5 采样行 / LOG_QUERY + LOG_QUERY_EVIDENCE
#           查询结果文件 / ALERT_RULE 规则文件（含 alert:/expr:）/ ALERT_TEST_OUTPUT 非空且含
#           ALERT_TRIGGERED / NOTIFICATION_CONFIRMED / RECOVERY_RECORDED 三要素
exit $rc
```

### P9 完成度自检（文档交付索引 — 权威 Gate）

```bash
# v3.15.1: 只调用权威 Gate，原样传播退出码（五个文件全 MISSING 却 exit 0 的旧循环已废除）
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P9 <feature>
rc=$?
# Gate 校验：docs/<feature>-文档索引.md 声明五类文档路径 + 各自 <KEY>_SHA256；
#           每份文档 ≥10 行、≥2 标题、≥5 正文行、含类别语义章节（用户/开发/API/运维/发布）
exit $rc
```

> 命名约定：所有产物路径使用 kebab-case（如 `docs/测试/<feature>-PRD验证报告.md`），禁止中英混合文件名。

### P10 完成度自检（复盘内容）

```bash
# 复盘必须含"上次遗漏了什么"段
grep -c "上次遗漏\|本次新发现" docs/复盘/<feature>-复盘报告.md
# 必须 ≥ 1
```

## 输出

完成度自检报告（写入 `docs/复盘/<feature>-audit-<phase>.md`）：

```markdown
# 完成度自检报告 — <feature> / <phase>

## 执行人
<completeness-auditor 角色名 + session ID>

## 检查项
| # | 项目 | 命令 | 预期 | 实际 | 结果 |
|---|------|------|------|------|------|
| 1 | TODO 残留 | grep TODO | 0 | 0 | ✅ |
| 2 | @PreAuthorize 覆盖 | grep -L | 空 | 空 | ✅ |
| ... | ... | ... | ... | ... | ... |

## 通过项
N / N

## 失败项（如有）
1. <失败项> — 命令输出 — 修复计划 — owner — ETA

## 结论
- ✅ PASS — 进入下个 Phase
- ❌ FAIL — 阻塞，必须修复后重跑
```

## 角色约束

- ❌ **禁止开发 Agent 自评**：写完 P3 代码的开发 Agent 不得立即运行 `/audit-completeness P3`
- ✅ **必须独立 session**：另起 session 切换 `completeness-auditor` 角色运行
- ✅ **必须附命令输出**：每项检查的完整 stdout 都要进入报告
- ✅ **FAIL 必阻塞**：任何一项 FAIL 不得"标注为已知风险继续推进"，必须修复 → 重跑 → 通过

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/audit-receipts.sh" <feature> .devflow docs
# 期望：exit 0 = 全部 Gate 收据证据绑定有效；FAIL > 0 即未通过，禁止自报 PASS
```
