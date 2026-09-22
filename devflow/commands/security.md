---
name: security
version: "3.29.3"
description: >-
  Use when auditing security vulnerabilities, permission gaps, or data exposure risks, mentions
  "/security", "security audit", "安全审计", "权限审计", "auth", "authorization", or "vulnerability scan".
  Must run in independent session (security-auditor subagent). Focus: @PreAuthorize coverage, SQL injection, secret exposure.
paths:
  - "backend/**/*.java"
  - "backend/**/*.yml"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - grep
  - glob
---

# /security - 安全审计（P3c）

> **核心约束**：必须由 `security-auditor` 角色在**独立 session** 中执行，**禁止开发 Agent 自评**。

## 使用方式

```
/security <feature>
/security <feature> --service <path-or-name>
/security <feature> --service=<path-or-name>
```

`--service` 支持两种取值（v3.26.1 统一契约）：

- 服务目录路径（相对项目根）：`backend/payment-service`（推荐，显式）
- 裸服务名：`payment-service`——仅当 `backend/payment-service` 存在时等价

## 示例

```
/security m-03-basic-library
/security payment-system --service backend/payment-service
```

## 命名约定

输出：`docs/评审/<feature>-安全审计报告.md`

## 执行步骤

### 1. 权限矩阵审计

```bash
# 找出所有 Controller（POSIX 通用）
find backend/<service>/src/main/java -name "*Controller.java" -type f > /tmp/controllers.txt

# 检查每个 Controller 至少 1 个 @PreAuthorize
while IFS= read -r f; do
  count=$(grep -cE "@PreAuthorize|@Secured" "$f")
  if [ "$count" -eq 0 ]; then
    echo "FAIL 权限缺失: $f"
  fi
done < /tmp/controllers.txt

# 检查写操作（POST/PUT/DELETE/PATCH）权限覆盖（POSIX 通用：find|xargs）
find backend/<service>/src/main/java -name "*Controller.java" -type f \
  | xargs grep -L "@PreAuthorize" 2>/dev/null
```

### 2. SQL 注入审计

```bash
# 原生 SQL 是否有 ${} 拼接（应使用 #{}）
find backend/<service>/src/main/java -name "*Mapper.xml" -type f \
  -exec grep -nE '\$\{' {} + | grep -v "@Param"

# like 拼接
find backend/<service>/src/main/java -name "*Mapper.xml" -type f \
  -exec grep -nE 'like.*\$' {} +
```

### 3. 敏感信息审计

```bash
# 日志输出是否含密码字段
find backend/<service>/src/main/java -name "*.java" -type f \
  -exec grep -nE "log\..*\(.*password.*\)" {} +

# 配置文件硬编码
find backend/<service>/src/main/resources -name "application*.yml" -type f \
  -exec grep -nE "password\s*=" {} + | grep -v "^\s*#"
```

### 4. 跨服务鉴权审计

```bash
# Feign / RestTemplate 调用是否带 token
find backend/<service>/src/main/java -name "*.java" -type f \
  -exec grep -nE "Authorization|Bearer" {} +

# 检查 @FeignClient 是否传递 token
find backend/<service>/src/main/java -name "*.java" -type f | grep "/client/" \
  -exec grep -B2 -A5 "@FeignClient" {} +
```

### 5. 输出报告

写入 `docs/评审/<feature>-安全审计报告.md`：

```markdown
# <feature> 安全审计报告

## 基本信息
- Auditor：security-auditor
- Date：YYYY-MM-DD
- Scope：<服务范围>

## 权限矩阵

| 详设权限码 | Controller 方法 | @PreAuthorize 覆盖 | 证据 |
|----------|----------------|---------------------|------|
| governance:metadata:create | POST /api/elements/metadata | ✅ | ElementLibraryController.java:58 |
| governance:metadata:delete | DELETE /api/elements/metadata/{id} | ❌ P0 | <grep 输出> |

## P0 阻断项
| # | 项 | 详设 | 实际 | 证据 |
|---|----|----|------|------|
| SEC-1 | 元数据删除无权限 | governance:metadata:delete | 无 @PreAuthorize | grep 输出 |

## P1 优化项
...

## 注入防护
- [ ] SQL 注入：grep 结果
- [ ] XSS：grep 结果
- [ ] CSRF：grep 结果

## 敏感信息
- [ ] 密码字段不脱敏：grep 结果

## 结论
- [ ] PASS — P0 = 0
- [ ] FAIL — P0 > 0，列修复计划
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 报告路径 | `docs/评审/<feature>-安全审计报告.md` 实际写入 |
| 权限矩阵完整 | 每个写操作覆盖 = 100% |
| P0 项 | **必须 = 0** |
| 独立性 | 必须独立 session（不得与开发同 session） |

## 输出

- `docs/评审/<feature>-安全审计报告.md`——**由 JSON 正本渲染**（见下）

### 结构化产物层（v3.25.2 · 失败关闭）

审计结论先落结构化正本，再渲染为报告，最后进 Gate：

1. 按 `schemas/security.schema.json` 填 `.devflow/<feature>/security.json`：
   `write_operations_total` / `preauthorize_coverage` / `findings[]`（每条
   id=SEC-n、severity、status、evidence；P0/P1 必须 CLOSED，WAIVED 须绑定
   `waiver_ref` + `waiver_file`）/ `report_path`；
2. 渲染：`python3 "$SKILL_ROOT/scripts/df_pipeline.py" security \
   --input .devflow/<feature>/security.json \
   --out docs/评审/<feature>-安全审计报告.md`（校验失败不渲染）；
3. `p3_security_perf_gate.sh` 失败关闭校验该 JSON，收据绑定其 SHA 并纳入证据树。

## 自检命令

```bash
# P3c Gate: 安全审计（v3.9.4）
bash "$SKILL_ROOT/scripts/p3_security_perf_gate.sh" <feature> --mode security
```

```bash
# P3c 自检：P0 项必须 = 0
P0_COUNT=$(grep -c "^### SEC-\\|^| SEC-" docs/评审/<feature>-安全审计报告.md)
echo "安全 P0 项数: $P0_COUNT"
test "$P0_COUNT" -eq 0  # 必须 = 0

# Controller @PreAuthorize 覆盖率
TOTAL_CONTROLLERS=$(find backend/<service>/src/main/java -name "*Controller.java" -type f | wc -l | tr -d ' ')
COVERED=0
TMP_CONTROLLERS=$(mktemp)
find backend/<service>/src/main/java -name "*Controller.java" -type f > "$TMP_CONTROLLERS"
while IFS= read -r f; do
  if grep -q "@PreAuthorize" "$f" 2>/dev/null; then
    COVERED=$((COVERED + 1))
  fi
done < "$TMP_CONTROLLERS"
rm -f "$TMP_CONTROLLERS"
echo "@PreAuthorize 覆盖: $COVERED / $TOTAL_CONTROLLERS"
test "$COVERED" -eq "$TOTAL_CONTROLLERS"  # 必须 100%
```

## 角色约束

- ❌ **禁止同 session 自评**
- ✅ **独立 session** 切换 `security-auditor` 角色
- ✅ **每个 P0 项必须附 grep 命令 + 输出**
- ❌ **禁止"已通过审计"等无证据文字**

## 与其他命令关系

- 与 `/review` `/performance` **并行**执行（旁路命令，不阻塞彼此）
- `/security` P0 = 0 不是 P3 → P3b 的硬 Gate（与 `/review` 并行）
- 但 `/security` 失败会进入"未修复 P1/P2 清单" 跟踪
- 完成后由独立 session 的 `completeness-auditor` 运行 `/audit-completeness P3c <feature>` 复核
---

## Acceptance Test

> **Gather → Act → Verify**：验证 @PreAuthorize 覆盖率和凭证安全。

```bash
# Gather：统计调用方冻结范围内的 Controller
SERVICE="<service>"
SOURCE_ROOT="backend/$SERVICE/src/main/java"
CONTROLLER_COUNT=$(find "$SOURCE_ROOT" -name "*Controller.java" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "Controller总数=$CONTROLLER_COUNT"

# Act：跑权限覆盖检查
PREAUTH_COVERED=$(find "$SOURCE_ROOT" -name "*Controller.java" -type f 2>/dev/null | xargs grep -l "@PreAuthorize" 2>/dev/null | wc -l | tr -d ' ')
echo "含权限注解的Controller=$PREAUTH_COVERED"

# Verify
if [ "$PREAUTH_COVERED" -ge "$CONTROLLER_COUNT" ] && [ "$CONTROLLER_COUNT" -gt 0 ]; then
  echo "权限注解覆盖率=100% PASS"
else
  echo "WARN: 覆盖率=$(( PREAUTH_COVERED * 100 / CONTROLLER_COUNT ))% (需人工确认)"
fi

# 检查凭证安全
grep -rE "password.*=.*['\"]admin|admin123|123456" "$SOURCE_ROOT" 2>/dev/null | grep -v ".class" | head -3 && echo "含硬编码凭证 WARN" || echo "无硬编码凭证 OK"
```

---

## 状态机口径（单命令模式 · P1-6）

- 本命令运行于**单命令模式**：豁免状态机——不调用 `devflow-state.sh complete`，不推进阶段状态、不产出阶段收据链。
- 执行时必须在输出首部显式携带降级声明：`MODE=single-command STATE_MACHINE=exempt（阶段状态不推进；完整门禁链走 /devflow 编排）`。
- 需要完整门禁、收据链、checkpoint 恢复与"不可跳过阶段"约束时，改走 `/devflow` 编排路径（commands/devflow.md）。
