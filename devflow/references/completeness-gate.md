---
name: completeness-gate
version: "3.29.5"
description: 完成度门控参考手册（机器可验证证据 + 历史教训专项检查）
---

# 完成度门控参考手册

> **背景**：v1.7 流程跑完后产生"页面 100% / 接口 95.7% / 后端权限 0%" 的失衡结论，6 项 P0 阻断 + 监控三件套 + 48 个 E2E + 5 份标准文档均未真正闭合。根本原因是**"完成度"判定依赖 Agent 自评 + check-list 文字**，缺乏机器可验证证据。
>
> **本文件**：提供可重用的完成度自检命令清单 + 历史教训专项检查。

---

## 0. 跨平台兼容性

> **背景**：v2.0 早期命令依赖 GNU grep / GNU find 扩展，在 macOS BSD 工具链上 100% 失败。v2.1 全部命令已 POSIX 通用化。

| 反模式（GNU 专用） | v2.1 替代（POSIX 通用） | 影响 |
|--------------------|--------------------------|------|
| `grep -P`（PCRE） | `grep -E`（ERE）或 `awk` | macOS BSD grep 不支持 `-P` |
| `find -path "*/X/*"` | `find ... -name "*.java" \| grep "/X/"` | 行为依赖 GNU find |
| `**/*.java` globstar | `find ... -name "*.java" \| xargs ...` | bash 3.2 不支持 globstar |
| `grep -oP "(?<=...)"` | `grep -oE "..." \| awk '...'` | macOS 无 `-P` |
| `wc -l` 空格前缀 | `wc -l \| tr -d ' '` | macOS wc 输出有前导空格 |
| `cd frontend && cmd && cd ..` | `(cd frontend && cmd)` | 子 shell 更安全 |

**验证方式**：在 macOS / Linux 各跑一次下面命令，全部退出码 0 才算兼容：

```bash
# 自检"跨平台命令兼容性"
test "$(uname)" = "Darwin" && echo "macOS" || echo "Linux/其他"

# 验证 grep -E 可用
echo "test123" | grep -E "test[0-9]+" && echo "grep -E OK"

# 验证 find | grep 链式过滤
find . -name "*.md" -type f | grep "/audit-completeness" | head -3
```

---

## 1. 设计原则

| 原则 | v1.7（旧） | v2.0（新） |
|------|------------|------------|
| 完成判定 | "我写完了" → check-list 打勾 | **grep 命令输出 = 0 / 文件存在 / HTTP 200** |
| 证据要求 | 文档 markdown | **命令 stdout + 文件路径 + curl 响应** |
| 自评者 | 开发 Agent 自己 | **独立的 `completeness-auditor` 角色** |
| Phase 切换 | 自动推进 / 阻塞才汇报 | **完成度自检通过才能进下 Phase** |
| 失败处理 | 标"有条件不通过"继续 | **FAIL = 阻塞，必须修复** |

---

## 2. 历史教训清单（针对 M-03 2026-07-24 复盘）

### 2.1 后端权限覆盖（0% → 100%）

：7 个 Controller 全部 0 个 `@PreAuthorize`，被标"后端权限 0%"但 P3 仍判定 ✅

（POSIX 通用）：
```bash
# P3 Gate — 必须输出 0 行
find backend/<service>/src/main/java -name "*Controller.java" -type f \
  | xargs grep -L "@PreAuthorize" 2>/dev/null
# 替代 v2.0 的 `grep -rL "@PreAuthorize" backend/<service>/src/main/java/**/*Controller.java`
# 后者在 macOS 上失败（** glob 不被 grep 识别）
```

### 2.2 P0 阻断项穿越 Phase 边界

：6 项 P0 阻断在 P4 验证报告里被标注为"待修复"，P5 照常进入

：
```bash
# P4 Gate — P0 阻断项数必须 = 0
P0_COUNT=$(grep -c "| P0-" docs/测试/<feature>-PRD验证报告.md)
test "$P0_COUNT" -eq 0
```

### 2.3 监控三件套全缺失但被标"基本就绪"

：prometheus 端点 / logback 文件 / docker healthcheck 全部缺失，P7-P8 仍标 ✅

：
```bash
# P8 Gate — 三件套必须齐全
curl -sS -o /dev/null -w "%{http_code}" http://localhost:<port>/actuator/prometheus  # 200
test -f backend/<service>/src/main/resources/logback-spring.xml                       # 存在
grep "micrometer-registry-prometheus" backend/<service>/pom.xml                       # 命中
grep "prometheus" backend/<service>/src/main/resources/application.yml                # 命中
grep "healthcheck:" deploy/docker-compose.prod.yml                                   # 命中
```

### 2.4 E2E 48/48 SKIP 但被标"按执行通过率 100%"

：48 个 E2E 因凭据失效全部 SKIP，报告里却写"按执行通过率 100%（5/5）"

：
- P6e Gate：E2E 通过率 ≥95%，**禁止 100% SKIP**
- 如遇凭据失效 → 必须修复凭据 → 重跑，或**显式标记 BLOCKED**（不能蒙混）

### 2.5 文档"已完成"无实际路径

：`docs/复盘/` `knowledge/` `review/` `test/` `test-cases/` 五个标准目录 M-03 全部缺失，但 P9-P10 仍标 ✅

：
```bash
# P9 Gate — 标准目录文件路径必须存在
for f in docs/测试/<feature>-PRD验证报告.md \
         docs/测试用例/<feature>-测试用例.md \
         docs/复盘/<feature>-复盘.md \
         docs/知识沉淀/<feature>-知识分享.md \
         docs/评审/<feature>-代码审查报告.md; do
  test -f "$f" && echo "$f OK" || echo "$f MISSING"
done
# 至少 5 个必须 OK
```

### 2.6 详细设计冻结口径被代码忽略

：详设 §6.1.4 步骤 4 要求"updateElement 创建新版本同时把原 ACTIVE 引用边转 HISTORICAL"，代码完全未实现

（按场景的专项检查 — 修复 `**/*.java` glob 与 `grep -P`）：
```bash
# Process 删除流程级共享锁
find backend/<service>/src/main/java -name "ElementServiceImpl.java" \
  -exec grep -nE "gov:process|instance-delete|getActiveInstanceSummary" {} +
# 必须命中

# updateElement 引用边迭代（修复：grep -A 在多文件下行为不一致 → 用 awk）
awk '/ElementServiceImpl\.java/ {file=$1; line=$2; next} 
     /HISTORICAL|gov_reference|updateReference/ {print file ":" line ":" $0}' \
  <(grep -nE "HISTORICAL|gov_reference|updateReference" \
        backend/<service>/src/main/java/*/service/impl/ElementServiceImpl.java)
# 在 updateElement 函数体内必须命中

# createReference ACTIVE 唯一性校验
find backend/<service>/src/main/java -name "ReferenceServiceImpl.java" \
  -exec grep -nE "existsBy|count.*ACTIVE.*source.*target|UNIQUE" {} +
# 必须命中

# runInspection 指纹
find backend/<service>/src/main/java -name "ReferenceServiceImpl.java" \
  -exec grep -nE "getSourceVersionId|getTargetVersionId|getIssueType|issueFingerprint" {} +
# 必须命中

# mergeMemberBefore 编码
grep -nE "elementId.*versionId|mergeMemberBefore.*:.*:" \
  backend/<service>/src/main/java/*/service/impl/ElementServiceImpl.java
# 必须命中
```

### 2.7 模块类型模板

> **背景**：v2.0 的 8 项专项全部针对 M-03 治理类模块。在支付 / 用户管理 / 工作流等其他模块中，`ElementServiceImpl` / `gov:process` / `mergeMemberBefore` 等关键字根本不存在，会导致自检永远 FAIL。

**模块类型与专项检查对照表**：

| 模块类型 | 关键文件前缀 | 8 项专项关键字 |
|----------|--------------|----------------|
| **治理类（M-03 等）** | `ElementServiceImpl` / `ReferenceServiceImpl` | `gov:process` / `getActiveInstanceSummary` / `mergeMemberBefore` |
| **支付类** | `PaymentServiceImpl` / `OrderServiceImpl` | `idempotent` / `refund` / `alipayCallback` / `wechatNotify` |
| **用户管理类** | `UserServiceImpl` / `AuthServiceImpl` | `passwordHash` / `mfa` / `sessionTimeout` / `rbac` |
| **工作流类** | `WorkflowServiceImpl` / `ProcessInstanceImpl` | `transition` / `assignee` / `deadline` / `rollback` |

**Agent 自检决策**：
1. **第一步**：用详设 §0 章节标题或文件名判断模块类型
2. **第二步**：选对应专项表跑 grep
3. **第三步**：运行权威P3脚本；模块特有规则由验收ID证据和项目专项Gate补充

```bash
# 模块类型自动判断
MODULE_TYPE=$(find docs/详细设计/<feature>-详细设计.md -exec grep -lE \
  "gov:process|gov_element|gov_reference|gov_form" {} \; | wc -l | tr -d ' ')
if [ "$MODULE_TYPE" -gt 0 ]; then
  echo "检测到治理类模块 → 跑 8 项专项"
  # 跑治理类 8 项专项
else
  echo "非治理类模块 → 跑权威P3 Gate + 对应类型专项"
  # 跳过治理类专项
fi
```

---

## 3. 完成度自检统一模板

```markdown
# 完成度自检报告 — <feature> / <phase>

## 执行人
<completeness-auditor 角色 + session>

## 时间
<YYYY-MM-DD HH:MM>

## 检查项矩阵
| # | 项目 | 命令 | 预期 | 实际 | 结果 |
|---|------|------|------|------|------|
| 1 | TODO 残留 | grep TODO | 0 | <actual> | ✅/❌ |
| 2 | @PreAuthorize 覆盖 | grep -L | 空 | <actual> | ✅/❌ |
| ... | ... | ... | ... | ... | ... |

## 通过项
N / 总数

## 失败项（如有）
### 失败项 1: <名称>
- 命令：<cmd>
- 预期：<expect>
- 实际：<actual>
- 影响范围：<scope>
- 修复计划：<plan>
- owner：<person/role>
- ETA：<date>

## 结论
- ✅ PASS — 进入下个 Phase
- ❌ FAIL — 阻塞

## 命令输出附件
<完整 stdout>
```

---

## 4. 使用流程

```
1. 主 Agent 完成 P3 编码
   ↓
2. 另起 session 切换 completeness-auditor 角色
   ↓
3. 运行 /audit-completeness P3 <feature>
   ↓
4. 读命令输出 → 填检查矩阵
   ↓
5. 全部 PASS → 输出报告 → 签发 Phase 3b 入场券
   ↓
6. 任一 FAIL → 列修复计划 → 主 Agent 修复 → 重跑自检
```

---

## 5. 常见反模式（必须避免）

| 反模式 | 后果 | v2.0 替代 |
|--------|------|-----------|
| "我写完了，标 ✅" | 假完成 → 上线后翻车 | 必须 grep 命令输出 |
| "凭据失效，先 SKIP 全部" | 48/48 SKIP → 蒙混过关 | 修复凭据或显式 BLOCKED |
| "差不多就行" | 标准不达标 | 必须按详设冻结口径 grep |
| "P0 阻断以后再说" | 阻断穿越 Phase 边界 | P0 必须 = 0 才能进 P5 |
| "由开发 Agent 自评" | 自我感觉良好 | 独立 completeness-auditor 角色 |
| "本次发现 N 个坑" 但不写入 retro | 经验丢失 | 必须写入 `retrospectives/<feature>-复盘.md` |
| 监控/日志"基本就绪" | 缺失被掩盖 | 三件套 curl 必须返回 200 |
