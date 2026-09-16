---
name: interactive-demo
version: "3.21.1"
description: Use when user asks to build interactive demo, validate design with stakeholders, or complete P2b phase.
paths: [docs/demo/**, frontend/demo/**]
disable-model-invocation: false
allowed-tools: [read, write, exec, glob, grep, task]
---

# Phase 2b: 交互 Demo（Interactive Demo）

## 目标

- 在编码前用可交互原型验证设计的合理性
- 让业务方、产品方、前端团队对交互流程、UI 布局、数据展示达成共识
- 及早发现交互设计问题，避免 P3 编码后大规模返工
- 签收确认：Demo 通过 = 设计方案冻结，进入 P3 编码

## 进入条件

- [ ] P2 详细设计已完成（`<feature>-design.md` 存在）
- [ ] P2a 设计评审已通过（所有 DF 已修复）
- [ ] 已明确需要前端交互的功能范围（非纯后端服务）

## 适用场景

### ✅ 必须执行 P2b

- 面向用户的 Web UI / 小程序 / App 页面
- 管理后台（列表、表单、工作流）
- 数据可视化（图表、仪表盘、大屏）
- 复杂交互流程（多步骤表单、向导式操作）
- 新的 UI 组件或交互模式

### ⚠️ 可选执行 P2b

- 简单 CRUD（使用成熟模板，无特殊交互）
- 纯后端 API 服务（无前端界面）

### ❌ 不适用 P2b

- 纯后端服务（如定时任务、消息队列消费者）
- 标准 REST API（无前端）

## Demo 类型选择

根据项目特点选择合适的 Demo 类型：

### 1. 静态原型（推荐优先）

**工具**: Figma / Sketch / 墨刀 / Axure

**适用**:
- 首次设计，需要快速验证布局和流程
- 多方评审，需要可视化沟通
- 交互简单，主要验证信息架构

**产物**:
- `docs/demo/<feature>-prototype.pdf`（导出的原型截图）
- `docs/demo/<feature>-prototype-link.txt`（在线链接）

**时间成本**: 0.5-1 天

---

### 2. 交互原型（推荐）

**工具**: Figma Prototype / ProtoPie / Framer

**适用**:
- 需要验证交互逻辑（点击、跳转、状态变化）
- 多页面流程（列表→详情→编辑）
- 需要模拟真实操作感受

**产物**:
- `docs/demo/<feature>-interactive-demo.mp4`（操作录屏）
- 在线可交互链接

**时间成本**: 1-2 天

---

### 3. 前端 Mock（高保真）

**技术栈**: 
- PC Web: Vue 3 + Element Plus / React + Ant Design
- 小程序: 微信小程序原生 / uni-app
- Mock 数据: JSON 文件 / Mock.js

**适用**:
- 已有设计系统，需要验证真实组件效果
- 需要验证响应式布局、动画效果
- 业务方要求"真实感"

**产物**:
- `frontend/demo/<feature>/`（可运行的前端代码）
- `docs/demo/<feature>-demo-guide.md`（使用说明）

**时间成本**: 2-3 天

---

### 4. 全栈 Demo（最高保真）

**技术栈**: 
- 后端: Spring Boot + H2 / SQLite（内存数据库）
- 前端: 真实前端技术栈
- 集成: 完整的前后端联调

**适用**:
- 复杂业务逻辑需要验证可行性
- 需要演示真实数据流转
- 关键功能需要高层决策

**产物**:
- `backend/demo/<feature>/`（可运行的后端）
- `frontend/demo/<feature>/`（可运行的前端）
- `docs/demo/<feature>-full-demo-guide.md`（部署和演示说明）

**时间成本**: 3-5 天

---

## Demo 评审角色

| 角色 | 评审重点 |
|------|----------|
| **产品经理** | 功能完整性、流程合理性、与 PRD 一致性 |
| **业务方** | 实际使用场景、操作便利性、数据准确性 |
| **前端开发** | 技术可行性、组件复用、响应式设计 |
| **UI/UX 设计师** | 视觉规范、交互一致性、可访问性 |
| **测试开发** | 边界场景、异常处理、用户体验 |

## Demo 评审产物

`docs/demo/<feature>-demo-review.md`

**必须包含**:

### 1. Demo 基本信息
- Demo 类型（静态/交互/Mock/全栈）
- 访问方式（链接 / 本地启动命令 / 视频）
- 演示日期和参与人员

### 2. 功能清单
```markdown
| 功能模块 | 演示内容 | 状态 |
|---------|---------|------|
| 用户列表 | 查询、分页、筛选 | ✅ |
| 用户新增 | 表单验证、提交 | ✅ |
| 用户编辑 | 回显、更新 | ⚠️ 待优化 |
```

### 3. 评审意见

**每个角色的意见**:
```markdown
#### 产品经理
- ✅ 整体流程符合 PRD
- ⚠️ DF-DEMO-001: 删除操作缺少二次确认
- 💡 SF-DEMO-001: 建议增加批量操作

#### 业务方
- ✅ 数据展示清晰
- ⚠️ DF-DEMO-002: 查询条件缺少"状态"筛选
```

### 4. 修复清单

所有 DF 必须在 P2b 通过前修复：
```markdown
| ID | 问题描述 | 修复状态 | 复核人 |
|----|---------|---------|--------|
| DF-DEMO-001 | 删除缺少确认 | ✅ 已修复 | 产品经理 |
| DF-DEMO-002 | 缺少状态筛选 | ✅ 已修复 | 业务方 |
```

### 5. 签收确认

```markdown
## 签收确认

**业务方签收**: ✅  
签收人: @张三  
签收时间: 2026-09-15 14:30  
签收意见: Demo 已验证，同意进入编码阶段

**产品经理签收**: ✅  
签收人: @李四  
签收时间: 2026-09-15 14:35  
签收意见: 所有 DF 已修复，同意冻结设计

**前端开发签收**: ✅  
签收人: @王五  
签收时间: 2026-09-15 14:40  
签收意见: 技术方案可行，可以开始编码
```

**⚠️ 签收规则**:
- 必须至少 3 个角色签收（业务方 + 产品 + 前端）
- 所有 DF 必须修复并复核通过
- 签收后设计方案冻结，不得随意变更

---

## Gate 检查

```bash
bash "$SKILL_ROOT/scripts/p2b_demo_gate.sh" <feature>
```

| # | 检查项 | 通过条件 |
|---|--------|----------|
| 1 | Demo 评审报告存在 | `docs/demo/<feature>-demo-review.md` 存在 |
| 2 | Demo 产物存在 | 至少有一个 Demo 产物（原型/视频/代码） |
| 3 | 评审角色完整 | 至少 3 个角色评审（业务方/产品/前端） |
| 4 | DF 全部修复 | `grep -c '⚠️.*待修复\|⚠️.*待优化' <report>` = 0 |
| 5 | 签收完整 | 至少 3 个角色签收 ✅ |
| 6 | 签收时间有效 | 签收时间在 Demo 评审后（防止提前签收） |
| 7 | P2a 已通过 | `p2a_design_review_gate.sh` exit = 0 |

## Demo 构建指南

### 静态原型构建（Figma）

```bash
# 1. 创建 Figma 文件
#    - 使用项目设计系统
#    - 按页面组织 Frame
#    - 标注交互说明

# 2. 导出产物
#    - 导出 PDF: File → Export → PDF
#    - 截图: 每个关键页面截图保存到 docs/demo/

# 3. 生成评审文档
cat > docs/demo/<feature>-demo-review.md << 'EOF'
# <Feature> Demo 评审

## Demo 信息
- 类型: 静态原型
- 工具: Figma
- 链接: https://figma.com/...
- 导出: docs/demo/<feature>-prototype.pdf

## 页面清单
- [ ] 列表页
- [ ] 详情页
- [ ] 编辑页
...
EOF
```

---

### 交互原型构建（Figma Prototype）

```bash
# 1. 在 Figma 中设置交互
#    - Prototype 模式
#    - 设置页面跳转（On Click → Navigate to）
#    - 设置 Overlay 弹窗

# 2. 录制操作视频
#    - 使用 Figma 自带录屏或 QuickTime
#    - 录制关键流程操作

# 3. 发布可交互链接
#    - Share → Get link → View only
#    - 保存链接到 docs/demo/<feature>-prototype-link.txt
```

---

### 前端 Mock 构建（Vue 3 + Element Plus）

```bash
# 1. 创建 Demo 项目
cd frontend
mkdir -p demo/<feature>
cd demo/<feature>

# 2. 初始化前端项目
npm create vite@latest . -- --template vue
npm install element-plus

# 3. 创建 Mock 数据
cat > src/mock/data.json << 'EOF'
{
  "users": [
    {"id": 1, "name": "张三", "status": "active"},
    {"id": 2, "name": "李四", "status": "inactive"}
  ]
}
EOF

# 4. 实现页面
#    - src/views/UserList.vue
#    - src/views/UserDetail.vue
#    - src/views/UserEdit.vue

# 5. 启动 Demo
npm run dev
# 访问 http://localhost:5173

# 6. 录制演示视频
#    - 录制关键操作流程
#    - 保存到 docs/demo/<feature>-demo.mp4
```

---

### 全栈 Demo 构建（Spring Boot + Vue）

```bash
# 1. 后端 Demo
cd backend/demo
mkdir <feature>-demo

# 使用 H2 内存数据库
cat > application-demo.yml << 'EOF'
spring:
  datasource:
    url: jdbc:h2:mem:demo
    driver-class-name: org.h2.Driver
  h2:
    console:
      enabled: true
      path: /h2-console
  jpa:
    generate-ddl: true
    show-sql: true
EOF

# 2. 前端 Demo（同上）

# 3. 集成启动脚本
cat > start-demo.sh << 'EOF'
#!/bin/bash
# 启动后端
cd backend/demo/<feature>-demo
mvn spring-boot:run -Dspring.profiles.active=demo &
BACKEND_PID=$!

# 等待后端启动
sleep 10

# 启动前端
cd ../../frontend/demo/<feature>
npm run dev &
FRONTEND_PID=$!

echo "Backend: http://localhost:8080"
echo "Frontend: http://localhost:5173"
echo "H2 Console: http://localhost:8080/h2-console"
echo ""
echo "Press Ctrl+C to stop"

# 等待用户中断
trap "kill $BACKEND_PID $FRONTEND_PID" EXIT
wait
EOF

chmod +x start-demo.sh
```

---

## 经验教训应用

### L-PROC-001: P2b Demo 签收不可形式化

**问题**：早期项目 Demo 评审走过场，业务方"看了一眼"就签收，进入编码后发现交互流程不符合实际业务，返工 3 天。

**预防措施**：
1. **签收前必须实际操作**：业务方必须亲自操作 Demo，而不是只看截图
2. **记录操作路径**：在评审报告中记录"业务方已完成 X、Y、Z 三个典型场景操作"
3. **异常场景走查**：至少走查 3 个异常场景（如数据为空、权限不足、网络错误）
4. **签收时间限制**：Demo 交付后至少 1 个工作日后才能签收（给业务方充分时间试用）

**Gate 检查**：
- 签收时间 ≥ Demo 交付时间 + 1 天
- 评审报告中必须有"已操作场景清单"章节

---

## 反模式

❌ **跳过 P2b 直接编码**：认为"设计已经很清楚了"，结果编码完成后业务方说"不是这样的"  
❌ **Demo 只做一个页面**：只做列表页，编辑页、详情页编码时才发现问题  
❌ **签收走过场**：业务方没有实际操作就签收  
❌ **DF 未修复就签收**：认为"小问题，编码时再改"，结果编码时发现影响架构  
❌ **签收后频繁变更**：签收后还在讨论交互细节，导致编码反复调整  
❌ **用 P2a 评审替代 P2b Demo**：设计评审不能替代交互验证

---

## 输出清单

P2b 完成后必须有以下产物：

### 必须产物
- [ ] `docs/demo/<feature>-demo-review.md`（评审报告）
- [ ] Demo 产物（原型/视频/代码，至少一种）
- [ ] 3 个及以上角色签收 ✅

### 可选产物
- [ ] `docs/demo/<feature>-prototype.pdf`（静态原型）
- [ ] `docs/demo/<feature>-demo.mp4`（演示视频）
- [ ] `frontend/demo/<feature>/`（前端 Mock 代码）
- [ ] `docs/demo/<feature>-demo-guide.md`（Demo 使用说明）

---

## 与其他阶段的关系

| 前置阶段 | 关系 | 后续阶段 | 关系 |
|---------|------|---------|------|
| P2 详细设计 | Demo 基于设计实现 | P3 编码 | 编码基于签收的 Demo |
| P2a 设计评审 | 评审通过后才能做 Demo | P3b 代码审查 | Demo 是前端实现的参考 |

**关键决策点**：P2b 签收 = 设计方案冻结，不得随意变更

---

## 参考资料

- `scripts/p2b_demo_gate.sh`（Gate 脚本）
- `templates/交互Demo评审-模板.md`（评审报告模板）
- `concepts/lessons-learned.md` § L-PROC-001
- `references/agent-runtime-adapter.md`（跨平台 Demo 构建）

---

**最后更新**: 2026-09-15  
**版本**: v3.21.1
