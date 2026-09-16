---
name: prd-code-reconciliation
version: "3.21.1"
description: Use when user asks to verify PRD vs code consistency, check implementation completeness, or complete P4b phase.
paths: [docs/test/**, docs/requirements/**]
disable-model-invocation: false
allowed-tools: [read, write, exec, glob, grep, task]
---

# Phase 4b: PRD-代码对账（PRD vs Code Reconciliation）

## 目标

- 验证 PRD 中的**每个功能点**都已在代码中实现
- 验证代码实现的功能与 PRD 描述**完全一致**
- 发现实现遗漏、实现偏差、过度实现
- 确保产品交付与需求文档的可追溯性

## 进入条件

- [ ] P3 编码已完成（所有代码已提交）
- [ ] P3 Gate 通过（11 个 grep 全绿）
- [ ] P3b 代码审查已通过（P0 缺陷 = 0）
- [ ] P4 PRD 验证已完成（基本功能验证通过）
- [ ] PRD 文档存在且版本明确

## 为什么需要 P4b？

### 问题场景

在实际项目中常见以下问题：

1. **实现遗漏**：PRD 要求"支持批量删除"，但代码只实现了单个删除
2. **实现偏差**：PRD 要求"审批通过后发送通知"，但代码实现成"审批通过后直接执行"
3. **过度实现**：PRD 只要求"列表查询"，但代码实现了"高级搜索 + 导出 + 统计"（功能蔓延）
4. **隐式变更**：编码过程中口头讨论改了需求，但 PRD 未更新

### P4 vs P4b 的区别

| 维度 | P4 (PRD 验证) | P4b (PRD-代码对账) |
|------|-------------|------------------|
| **验证对象** | 运行时行为 | 代码 + PRD 文档 |
| **验证方式** | 手工测试 / 自动化测试 | 静态分析 + 文档比对 |
| **验证粒度** | 功能级 | 需求点级（原子验收点） |
| **验证人** | 测试人员 | 独立审计人员 |
| **产物** | 测试报告 | 对账报告 |

**关键**：P4 验证"做得对不对"，P4b 验证"做全了没有"

---

## 对账方法

### 方法 1: 基于 P0 验收点对账（推荐）

使用 P0 需求澄清阶段生成的**原子验收点**作为对账清单。

#### 步骤

```bash
# 1. 提取 P0 验收点清单
grep -E "^-.*M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}" \
  docs/requirements/<feature>-clarification.md > /tmp/acceptance-points.txt

# 2. 逐一对账
while IFS= read -r point; do
  acceptance_id=$(echo "$point" | grep -oE "M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}")
  description=$(echo "$point" | sed "s/.*${acceptance_id}: //")
  
  echo "检查: $acceptance_id - $description"
  
  # 在详细设计中查找追溯
  if grep -q "$acceptance_id" docs/detailed-design/<feature>-design.md; then
    echo "  ✅ 详设已追溯"
    
    # 在代码中查找实现证据
    # （根据具体项目调整搜索模式）
    if grep -rq "$(echo $description | cut -d' ' -f1-3)" backend/src/; then
      echo "  ✅ 代码已实现"
    else
      echo "  ❌ 代码未实现或无法追溯"
    fi
  else
    echo "  ❌ 详设未追溯"
  fi
done < /tmp/acceptance-points.txt
```

---

### 方法 2: 基于 PRD 功能点对账

从 PRD 中提取功能点清单，逐一验证代码实现。

#### PRD 功能点提取规则

```markdown
# PRD 中的功能点标记格式
- 【功能】用户列表查询
- 【功能】用户新增
- 【功能】用户编辑
- 【功能】用户删除
- 【功能】批量删除
```

#### 代码实现证据

| 功能类型 | 证据来源 | 示例 |
|---------|---------|------|
| **接口** | Controller 方法 | `@PostMapping("/users")` |
| **业务逻辑** | Service 方法 | `public void createUser(...)` |
| **数据持久化** | Repository 方法 | `userRepository.save(...)` |
| **前端页面** | Vue 组件 | `UserList.vue`, `UserEdit.vue` |
| **权限控制** | 注解 / 配置 | `@PreAuthorize("hasPermission('user:create')")` |

---

### 方法 3: 基于模板模式透传（L-P4-001）

**问题**：模板视图项目（如小程序多租户）PRD 只描述模板逻辑，但实际交付包含 N 个租户实例。

**解决方案**：
```bash
# P4b Gate 必须识别模板模式
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature> --mode template

# 验证逻辑：
# 1. PRD 描述 1 个模板功能 → 代码实现 1 个模板 + N 个实例
# 2. 对账时只验证模板逻辑，不验证实例数量
# 3. 实例一致性由独立脚本验证（instance-consistency-check.sh）
```

**经验教训**：L-P4-001 - PRD-vs-Code Gate 必须透传模板模式

---

## 对账产物

`docs/test/<feature>-prd-vs-code-report.md`

### 必须包含的内容

#### 1. 对账范围

```markdown
## 对账范围

- PRD 版本: v1.2 (2026-09-01)
- 代码版本: commit abc123 (2026-09-15)
- 对账方法: 基于 P0 验收点
- 验收点总数: 42 个
- 模块范围: 用户管理、角色管理、权限管理
```

---

#### 2. 对账清单

```markdown
## 对账清单

| 验收点 ID | 描述 | PRD 章节 | 详设追溯 | 代码实现 | 状态 |
|-----------|------|---------|---------|---------|------|
| M-01-F01-A01 | 用户列表查询支持分页 | §2.1 | §3.1.1 | UserController.listUsers() | ✅ |
| M-01-F01-A02 | 用户列表支持姓名模糊查询 | §2.1 | §3.1.1 | UserQueryParam.name | ✅ |
| M-01-F02-A01 | 用户新增表单必填字段验证 | §2.2 | §3.1.2 | @NotBlank 注解 | ✅ |
| M-01-F02-A02 | 用户新增成功后发送通知 | §2.2 | §3.1.2 | ❌ 未实现 | ❌ |
| M-01-F03-A01 | 用户编辑支持部分字段更新 | §2.3 | §3.1.3 | UserService.updateUser() | ✅ |
| M-01-F04-A01 | 用户删除需要二次确认 | §2.4 | § 前端 UserList.vue | ✅ |
| M-01-F04-A02 | 支持批量删除 | §2.4 | ❌ 详设未追溯 | ❌ 未实现 | ❌ |
```

**统计**:
- 总数: 7
- ✅ 已实现: 5 (71%)
- ❌ 未实现: 2 (29%)

---

#### 3. 问题清单

```markdown
## 问题清单

### 🔴 P0 - 实现遗漏（阻塞发布）

#### GAP-001: 用户新增成功后发送通知未实现

**验收点**: M-01-F02-A02  
**PRD 描述**: 用户新增成功后，系统应向管理员发送通知  
**当前状态**: 代码中只有 `userRepository.save(user)`，无通知逻辑  
**影响**: 管理员无法及时感知新用户注册  
**建议**: 在 `UserService.createUser()` 中增加 `notificationService.send(...)`

---

#### GAP-002: 批量删除功能未实现

**验收点**: M-01-F04-A02  
**PRD 描述**: 支持选中多个用户后批量删除  
**当前状态**: 只有单个删除接口 `DELETE /users/{id}`  
**详设状态**: 详设文档未追溯此功能  
**影响**: 用户体验差，需要逐个删除  
**建议**: 
1. 补充详设：增加批量删除接口设计
2. 实现接口：`POST /users/batch-delete` + `List<Long> ids`
3. 前端实现：多选 + 批量操作按钮

---

### 🟡 P2 - 实现偏差（需确认）

#### GAP-003: 权限控制粒度不一致

**验收点**: M-03-F01-A03  
**PRD 描述**: 权限控制到"操作"级别（查看/新增/编辑/删除）  
**当前状态**: 代码实现到"模块"级别（user:*）  
**建议**: 与产品确认是否需要细化权限粒度

---

### 🟢 P3 - 过度实现（可保留）

#### OVER-001: 用户导出功能

**当前状态**: 代码实现了用户列表导出 Excel 功能  
**PRD 状态**: PRD 未要求此功能  
**建议**: 
- 如需保留：补充 PRD，更新版本
- 如不需要：删除相关代码
```

---

#### 4. 修复计划

```markdown
## 修复计划

| 问题 ID | 优先级 | 修复方式 | 预计工时 | 负责人 | 状态 |
|---------|--------|---------|---------|--------|------|
| GAP-001 | P0 | 增加通知逻辑 | 0.5 天 | @张三 | 待修复 |
| GAP-002 | P0 | 补充详设 + 实现批量删除 | 1 天 | @李四 | 待修复 |
| GAP-003 | P2 | 与产品确认 | - | @产品 | 待确认 |
| OVER-001 | P3 | 补充 PRD 或删除代码 | 0.5 天 | @王五 | 待确认 |
```

---

#### 5. 对账结论

```markdown
## 对账结论

**对账状态**: ❌ 不通过  
**通过率**: 71% (5/7)  
**阻塞问题**: 2 个 P0 问题未实现

**放行条件**:
- [ ] GAP-001 已修复并验证
- [ ] GAP-002 已修复并验证
- [ ] GAP-003 与产品达成一致
- [ ] OVER-001 处置方案明确
- [ ] 对账通过率 = 100%

**预计修复时间**: 1.5 天  
**复查计划**: 2026-09-17 复查
```

---

## Gate 检查

```bash
bash "$SKILL_ROOT/scripts/p4_prd_vs_code.sh" <feature> [--mode template]
```

| # | 检查项 | 通过条件 |
|---|--------|----------|
| 1 | 对账报告存在 | `docs/test/<feature>-prd-vs-code-report.md` 存在 |
| 2 | 对账范围明确 | 包含 PRD 版本、代码版本、验收点总数 |
| 3 | 对账清单完整 | 每个 P0 验收点都有对账记录 |
| 4 | 实现完整性 | ✅ 已实现 = 100% |
| 5 | 无 P0 遗漏 | P0 实现遗漏数 = 0 |
| 6 | 偏差已确认 | 所有 P2 偏差都有"产品确认"记录 |
| 7 | 过度实现已处置 | 所有过度实现都有处置决策（保留/删除） |
| 8 | PRD 版本一致 | PRD 版本与对账报告中声明的版本一致 |
| 9 | 代码版本一致 | 代码 commit hash 与对账报告中声明的一致 |
| 10 | 模板模式透传 | 如果是模板项目，必须传 `--mode template` |

---

## 对账工具脚本

### 自动化对账脚本

```bash
#!/bin/bash
# scripts/prd-code-reconciliation.sh

set -euo pipefail

FEATURE=$1
PRD_FILE="docs/requirements/${FEATURE}-prd.md"
CLARIFICATION_FILE="docs/requirements/${FEATURE}-clarification.md"
DESIGN_FILE="docs/detailed-design/${FEATURE}-design.md"
OUTPUT="docs/test/${FEATURE}-prd-vs-code-report.md"

echo "PRD-代码对账: $FEATURE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 1. 提取 P0 验收点
echo "1️⃣  提取验收点..."
ACCEPTANCE_POINTS=$(grep -E "M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}" "$CLARIFICATION_FILE" | wc -l)
echo "   验收点总数: $ACCEPTANCE_POINTS"

# 2. 检查详设追溯
echo "2️⃣  检查详设追溯..."
TRACED_IN_DESIGN=$(grep -cE "M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}" "$DESIGN_FILE" || true)
echo "   详设追溯数: $TRACED_IN_DESIGN / $ACCEPTANCE_POINTS"

# 3. 检查代码实现（简化版，实际需要更复杂的分析）
echo "3️⃣  检查代码实现..."
# TODO: 实际项目需要根据验收点类型（接口/逻辑/UI）分别检查

# 4. 生成对账报告
echo "4️⃣  生成对账报告..."
cat > "$OUTPUT" << EOF
# ${FEATURE} PRD-代码对账报告

## 对账范围
- PRD 版本: $(grep -m1 "版本:" "$PRD_FILE" | sed 's/.*版本: *//')
- 代码版本: $(git rev-parse --short HEAD)
- 对账时间: $(date +"%Y-%m-%d %H:%M:%S")
- 验收点总数: $ACCEPTANCE_POINTS
- 详设追溯数: $TRACED_IN_DESIGN

## 对账清单
$(grep -E "M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}" "$CLARIFICATION_FILE" | while IFS= read -r line; do
  id=$(echo "$line" | grep -oE "M-[0-9]{2}-F[0-9]{2}-A[0-9]{2}")
  desc=$(echo "$line" | sed "s/.*${id}: //")
  
  # 检查详设
  if grep -q "$id" "$DESIGN_FILE"; then
    design_status="✅"
  else
    design_status="❌"
  fi
  
  # 检查代码（TODO: 实际需要更精确的检查）
  code_status="⚠️ 待人工确认"
  
  echo "| $id | $desc | $design_status | $code_status |"
done)

## 对账结论
- 详设追溯率: $((TRACED_IN_DESIGN * 100 / ACCEPTANCE_POINTS))%
- 状态: $([ $TRACED_IN_DESIGN -eq $ACCEPTANCE_POINTS ] && echo "✅ 通过" || echo "❌ 待修复")
EOF

echo "✅ 对账报告已生成: $OUTPUT"
```

---

## 经验教训应用

### L-P4-001: PRD-vs-Code Gate 必须透传模板模式

**场景**：小程序多租户项目，PRD 只描述模板逻辑，但实际交付包含 20 个租户实例。

**问题**：P4b 对账时，脚本只找到 1 个模板实现，报告"实现不完整"。

**解决方案**：
```bash
# 识别模板项目
if grep -q "模板模式" docs/requirements/<feature>-prd.md; then
  MODE="--mode template"
else
  MODE=""
fi

# 透传模板模式
bash scripts/p4_prd_vs_code.sh <feature> $MODE
```

**预防措施**：
1. PRD 中明确标注"模板模式"或"多租户模式"
2. P4b Gate 自动识别模板模式
3. 模板项目对账只验证模板逻辑，不验证实例数量

---

## 反模式

❌ **跳过 P4b 直接发布**：认为"P4 测试通过就够了"，结果上线后发现遗漏功能  
❌ **对账只看代码不看 PRD**：只检查代码实现了什么，不检查 PRD 要求什么  
❌ **对账粒度太粗**：只检查"用户管理模块实现了"，不检查每个具体功能  
❌ **过度实现不记录**：发现代码实现了 PRD 没要求的功能，但不记录不处置  
❌ **对账报告只有结论无证据**：只写"已实现"，不写代码位置和文件名  
❌ **对账后 PRD 不更新**：发现实现偏差后修改了代码，但 PRD 未同步更新

---

## 输出清单

P4b 完成后必须有以下产物：

### 必须产物
- [ ] `docs/test/<feature>-prd-vs-code-report.md`（对账报告）
- [ ] 对账清单（每个验收点的对账记录）
- [ ] 问题清单（GAP 列表 + 修复计划）
- [ ] 对账结论（通过 / 不通过）

### 可选产物
- [ ] 对账工具脚本输出（自动化对账日志）
- [ ] 代码追溯矩阵（验收点 → 代码文件映射表）

---

## 与其他阶段的关系

| 前置阶段 | 关系 | 后续阶段 | 关系 |
|---------|------|---------|------|
| P0 需求澄清 | P4b 基于 P0 验收点对账 | P5 测试策略 | 对账通过后制定测试策略 |
| P2 详细设计 | 检查详设追溯完整性 | P6 测试执行 | GAP 修复后进入测试 |
| P3 编码 | 对账代码实现完整性 | P7 部署 | 对账通过是部署前提 |
| P4 PRD 验证 | P4 验证功能，P4b 验证完整性 | P10 复盘 | GAP 分析是复盘输入 |

---

## 参考资料

- `scripts/p4_prd_vs_code.sh`（对账 Gate 脚本）
- `templates/PRD-代码对账报告-模板.md`（报告模板）
- `concepts/lessons-learned.md` § L-P4-001
- `phases/00-需求澄清.md` § 原子验收点定义
- `phases/04-PRD验证.md` § P4 vs P4b 区别

---

**最后更新**: 2026-09-15  
**版本**: v3.21.1
