# devflow 经验教训沉淀日志

> **用途**: 记录每次经验教训沉淀到 skill 的变更历史  
> **维护**: 每次应用经验教训到 skill 时更新本文件

---

## v3.20.9 - 2026-09-15

### 新增经验教训库

**文件**: `concepts/lessons-learned.md` (633行, 25条教训)

从 detailed-design-v2 项目复盘中提取的 25 条可复现经验教训，覆盖：
- 设计阶段（4条）
- 实施阶段（4条）
- 测试阶段（1条）
- 工具基础设施（3条）
- 监控可观测（3条）
- 流程协作（2条）
- 技术栈特定（2条）
- 复盘反馈（2条）

每条教训包含：问题描述、影响范围、根因分析、解决方案、预防措施、适用 Gate。

### 新增映射表

**文件**: `concepts/phase-lessons-map.md` (137行)

Phase 与经验教训的快速映射表，包含：
- P0-P10 各阶段适用教训清单
- 工具与基础设施问题（跨阶段）
- 按优先级分类（P0/P1/P2 级教训）
- 快速查询命令示例

### 应用到 Phase 文档

**修改**: `phases/00-需求澄清.md`
- 在"原子验收点拆分"章节增加 L-P0-001 经验教训引用
- 在"澄清问卷模板"增加"权限与事实源对账"章节

**修改**: `phases/02-详细设计.md`
- 在"目标"章节增加 L-P2-001、L-P2-003、L-STACK-001 经验教训应用说明

**修改**: `phases/02a-详细设计评审.md`
- 在"评审产物"章节增加 L-P2-002、L-PROC-002 经验教训应用说明

**修改**: `phases/03-规范实现.md`
- 在"目标"章节增加 L-P3-001、L-P3-002、L-STACK-002、L-MON-001 经验教训应用说明

### 应用到 Gate 脚本

**修改**: `scripts/s0_acceptance_gate.sh` (新增 §7)
- 增加权限码对账检查（L-P0-001）
- 从 `docs/detailed-design/_权限矩阵.md` 提取权限码
- 与需求澄清文档中的权限码双向对账
- 不一致时产生 P0 阻断

### 更新主入口

**修改**: `SKILL.md`
- 在"不可违背的原则"章节增加对经验教训库的引用
- 说明：完整铁律见 `concepts/SKILL.md`；细节原则见 `concepts/principles-detailed.md`；经验教训见 `concepts/lessons-learned.md`（25 条可复现教训）

---

## 价值量化

### P2a 五角色评审（L-P2-002）
- 拦截缺陷：43 个（2 P0 + 24 P1 + 17 P2）
- 评审耗时：1h 19min
- 估算返工成本：评审成本 × 5-10 倍
- **ROI**: 极高

### MockMvc vs 真实容器（L-P3-001）
- MockMvc 测试：105 个全绿
- 真实容器暴露问题：3 类（schema 漂移、静态资源 500、探活 fail-open）
- 额外修复成本：~30min
- **教训**: 验证基线必须包含真实运行环境

### P3b 独立代码审查（L-P3-002）
- 拦截缺陷：7 个（1 P0 + 6 P1）
- 关键发现：回收站恢复未复活对象（P0）、认证通道缺失（P1）
- **价值**: 避免开发者确认偏差

---

## 待跟进改进（已反馈给 skill 维护者）

### 工具层面（需 skill 下版本修复）

1. **FB-20260915-governance-p4b-monolith** (defer)
   - `p4_prd_vs_code.sh` 增加 --mode 透传支持
   - 批量收据刷新命令（Skill Tree 漂移时自动化恢复）

2. **监控产物强制化**
   - build-watchdog 纳入 P3 gate 强制检查项
   - checkpoint-state 强制输出日志文件
   - orphans-detector 纳入 P6/P10 gate

3. **P3c/P3d 独立报告**
   - 即使合并执行，也应分别产出独立报告文件

4. **P2b Demo 签收强化**
   - Demo 运行截图/视频强制产物检查

### 当前状态

- ✅ L-P0-001：已应用到 s0_acceptance_gate.sh §7
- ✅ L-P2-001/002/003：已在 phase 文档中说明
- ✅ L-P3-001/002：已在 phase 文档中说明
- ⏳ L-P4-001：等待 skill 下版本修复 --mode 透传
- ⏳ L-MON-001/002/003：等待 skill 下版本纳入 gate

---

## 使用方法

### 新项目启动时
```bash
# P0 阶段读取经验教训
cat ~/.cursor/skills/devflow/concepts/lessons-learned.md

# 读取映射表
cat ~/.cursor/skills/devflow/concepts/phase-lessons-map.md

# 按阶段过滤
grep "适用 Gate: P0" ~/.cursor/skills/devflow/concepts/lessons-learned.md
```

### 各阶段 Gate 前
```bash
# 查询当前阶段适用教训
grep "P2a" ~/.cursor/skills/devflow/concepts/phase-lessons-map.md

# 查看预防措施
grep -A 10 "预防措施" ~/.cursor/skills/devflow/concepts/lessons-learned.md
```

### P10 复盘后
```bash
# 将新发现追加到项目本地
echo "## 新发现" >> .devflow/<feature>/knowledge/new-findings.md

# 如具有普遍性，提 PR 到 devflow skill 仓库
```

---

## 相关文档

- **经验教训库**: `concepts/lessons-learned.md` (633行)
- **Phase 映射表**: `concepts/phase-lessons-map.md` (137行)
- **项目复盘报告**: `/Users/huymac/工作/数智/xyls/code0914/devflow-implementation-audit-report.md`
- **项目知识索引**: `/Users/huymac/工作/数智/xyls/code0914/.devflow/detailed-design-v2/knowledge/README.md`

---

**维护者**: devflow 社区  
**许可证**: MIT  
**反馈渠道**: 在项目 `.devflow/<feature>/feedback/` 中创建 FB，或提交 PR 到本 skill 仓库
