# Phase 与经验教训映射表

> **版本**: v1.0.0  
> **更新**: 2026-09-15  
> **用途**: 快速查找各阶段应该应用哪些经验教训

---

## 映射表

| Phase | 阶段名称 | 适用教训 | 关键预防措施 |
|-------|----------|----------|--------------|
| **P0** | 需求澄清 | L-P0-001 | 权限码双口径在 P0b 拦截（对账 _权限矩阵.md） |
| **P0b** | PRD评审 | L-P0-001, L-RETRO-002 | 权限事实源一致性检查；包含 Prior-Gap 章节 |
| **P1** | 技术选型 | - | 遵循 P0 冻结的技术硬约束 |
| **P2** | 详细设计 | L-P2-001, L-P2-003, L-STACK-001 | 分文档与聚合投影独立文件；Entity ↔ Flyway 对账；四方言一致性 |
| **P2a** | 设计评审 | L-P0-001, L-P2-002, L-P2-003, L-PROC-002 | 五角色评审不跳过；表结构对账；DF 逐一复核 |
| **P2b** | 原型Demo | L-PROC-001 | 复杂交互场景必须有可运行 Demo + 截图 |
| **P3** | 规范实现 | L-P3-001, L-P3-002, L-P3-003, L-STACK-001, L-STACK-002, L-MON-001 | 真实容器启动验证；独立代码审查；认证逻辑不绕过；build-watchdog 留痕 |
| **P3b** | 代码审查 | L-P3-002, L-P3-003, L-STACK-001, L-STACK-002, L-PROC-002 | DEVELOPER_ID ≠ REVIEWER_ID；P3c/P3d 独立报告；DF 逐一复核 |
| **P3c** | 安全审计 | L-P3-003 | 独立产出安全审计报告（@PreAuthorize 覆盖率、SQL 注入检测） |
| **P3d** | 性能审计 | L-P3-003 | 独立产出性能审计报告（N+1 查询、P95 响应时间） |
| **P4** | PRD验证 | L-P3-001, L-P4-001 | 真实容器 E2E 冒烟；如遇 P4b 模板模式误报，构建聚合投影 |
| **P4b** | PRD-vs-Code | L-P4-001 | 如 --mode 未透传，临时构建聚合投影文档 |
| **P5** | 测试用例 | - | 测试用例数 ≥ 详设验收点数 |
| **P6** | 测试执行 | L-P6-001, L-MON-003 | 真实容器 E2E 证据；orphans-detector 检测 |
| **P7** | 发布部署 | L-STACK-002 | 生产环境 dev-privileged=false；health 端点 200 |
| **P8** | 监控配置 | - | 三件套齐全（日志/指标/告警） |
| **P9** | 文档更新 | - | 5+ 份文档齐全 |
| **P10** | 知识沉淀 | L-RETRO-001, L-RETRO-002, L-MON-003 | feedback queue；Prior-Gap + New-Findings；orphans-detector |

---

## 工具与基础设施问题（跨阶段）

| 教训 ID | 问题 | 触发条件 | 临时方案 |
|---------|------|----------|----------|
| L-TOOL-001 | Skill Tree 漂移 | 外部同步更新 .cursor/skills/devflow | migrate→gate→complete→audit 原子执行 |
| L-TOOL-002 | macOS BSD awk 差异 | 使用 awk 解析 markdown 表格 | 无空格表格行；或改用 Python/jq |
| L-TOOL-003 | set -u 脚本调试 | 自动化注入日志行 | 日志行置于变量定义之后 |
| L-MON-001 | build-watchdog 无留痕 | P3 编码阶段 | 手动记录每次 mvn compile 退出码 |
| L-MON-002 | checkpoint-state 无日志 | Gate 完成后 | 手动记录 checkpoint 触发时机 |
| L-MON-003 | orphans-detector 缺失 | P6/P10 阶段 | 补充执行 checkpoint-state.sh orphans |

---

## 按优先级查找

### P0 级教训（必须应用）

| ID | 阶段 | 教训 | 预防措施 |
|----|------|------|----------|
| L-P2-002 | P2a | P2a 五角色评审是最高 ROI 阶段 | 不可跳过或形式化；拦截 43 DF 避免 5-10 倍返工 |
| L-P3-001 | P3, P4, P6 | MockMvc 全绿 ≠ 真实容器可用 | P3 至少一次 java -jar 启动；P6 真实容器 E2E |
| L-P3-002 | P3b | 独立代码审查 | DEVELOPER_ID ≠ REVIEWER_ID |
| L-STACK-002 | P3, P7 | 认证通道不能绕过 | P3 实现真实认证；P7 强制 dev-privileged=false |

### P1 级教训（强烈建议）

| ID | 阶段 | 教训 | 预防措施 |
|----|------|------|----------|
| L-P0-001 | P0, P0b, P2a | 权限码双口径 | P0 增加权限码对账检查项 |
| L-P2-001 | P2 | 跨模板视图硬链接事故 | 分文档与聚合投影独立文件 |
| L-P2-003 | P2, P2a | 表结构对账 | P2 gate 增加 Entity ↔ Flyway 一致性检查 |
| L-P3-003 | P3c, P3d | 安全+性能审计独立报告 | 即使合并执行也分别产出文件 |
| L-P4-001 | P4b | PRD-vs-Code Gate 模板模式 | 如误报，构建聚合投影文档 |
| L-P6-001 | P6 | 真实容器 E2E | P6 gate 增加真实容器证据检查 |

### P2 级教训（建议改进）

| ID | 阶段 | 教训 | 预防措施 |
|----|------|------|----------|
| L-TOOL-001 | 任意 | Skill Tree 漂移 | 同步稳定窗口内原子恢复 |
| L-MON-001 | P3 | build-watchdog 留痕 | 建议 skill 下版本纳入 P3 gate |
| L-MON-002 | 任意 | checkpoint-state 留痕 | 建议 skill 下版本强制输出日志 |
| L-MON-003 | P6, P10 | orphans-detector 留痕 | 建议 skill 下版本纳入 gate |
| L-PROC-001 | P2b | Demo 签收不形式化 | 复杂交互场景强制截图/视频 |

---

## 快速查询命令

### 查看某阶段的所有教训
```bash
grep "适用 Gate: P2a" ~/.cursor/skills/devflow/concepts/lessons-learned.md
```

### 查看所有 P0 级教训
```bash
grep -B 5 "P0 级教训" ~/.cursor/skills/devflow/concepts/lessons-learned.md
```

### 查看某个具体教训
```bash
grep -A 20 "^### L-P2-002" ~/.cursor/skills/devflow/concepts/lessons-learned.md
```

### 项目启动时批量读取
```bash
# P0 阶段
cat ~/.cursor/skills/devflow/concepts/lessons-learned.md | grep -E "L-P0|L-P2|L-TOOL"

# P2a 前
grep "P2a" ~/.cursor/skills/devflow/concepts/phase-lessons-map.md

# P3 前
grep "P3" ~/.cursor/skills/devflow/concepts/phase-lessons-map.md
```

---

## 使用建议

### 项目启动时（P0 阶段）

1. 读取 `phase-lessons-map.md` 了解全局
2. 读取 `lessons-learned.md` 了解详细预防措施
3. 将 P0 相关教训加入风险清单

### 各阶段 Gate 前

1. 查询当前阶段适用教训
2. 检查预防措施是否已执行
3. 在 Gate 证据中附上"已应用教训"清单

### P10 复盘后

1. 将新发现追加到 `lessons-learned.md`
2. 更新 `phase-lessons-map.md` 映射表
3. 如具有普遍性，提 PR 到 skill 仓库

---

**维护者**: devflow 社区  
**完整经验库**: `concepts/lessons-learned.md` (633行，25条教训)  
**许可证**: MIT
