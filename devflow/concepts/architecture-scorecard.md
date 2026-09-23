---
name: architecture-scorecard
version: "3.30.1"
description: >-
  架构评分卡权威定义。v3.9 起从 concepts/core.md 抽出。
  包含两个互补框架:
  - L-GEVITY (4 维,Marlo-AI): 架构治理视角,Phase 切换时用,≥16/20 PASS
  - S.U.P.E.R (5 维,spec_driven_develop): 代码质量视角,每次 PR 用,≥20/25 PASS
  Use when scoring architecture decisions, generating PR scorecards,
  or when /audit-pitfalls references "L-GEVITY" / "S.U.P.E.R".
paths:
  - "docs/评审/**/l-gevity-scorecard.md"
  - "docs/评审/**/super-scorecard.md"
---

## 13. L-GEVITY Architecture Discipline（架构纪律，铁律）

> **借鉴 Marlo-AI 的 L-GEVITY 框架** —— 用 4 维纪律约束所有架构决策，避免"过度设计"和"过简设计"两个极端。

任何 phase 的架构决策（新增服务 / 引入中间件 / 拆分模块 / 重构）必须满足全部 4 维评估：

### 13.1 Minimalism（极简）

| 反模式 | 正例 |
|--------|------|
| 一个 CRUD 加 7 个抽象层 | Controller → Service → Mapper 直白 3 层 |
| 引入 EventBus / Saga / 工作流 做"未来可能用到"的扩展 | 仅当 **当前有 ≥2 个 consumer** 才引入 |
| 自定义 DSL / 自研框架 | 用业界标准（Spring / Vue） |
| 配置文件 200 行只为了"灵活" | 90% 场景用默认值，10% 才配置 |

### 13.2 Modularity（模块化）

| 反模式 | 正例 |
|--------|------|
| 一个 `common` 模块塞 80% 业务 | common 只放基础类，业务按域拆 |
| 跨服务直接调 Mapper（绕过 service 层） | 必须经 OpenFeign / MQ |
| 两个 service 互相 import 对方 entity | 共享 model 放到独立的 contract 模块 |
| 包名 `com.xingyunliushui.business.order.OrderService` 全平铺 | 按 feature 切片：`order/api`、`order/service`、`order/domain` |

### 13.3 Resilience（韧性）

| 反模式 | 正例 |
|--------|------|
| Feign 调用无 fallback → 一挂全挂 | 必填 fallback 或降级逻辑 |
| 单点 MQ → broker 挂全停 | 关键链路用至少 2 个 broker / 至少 1 个重试机制 |
| DB 单库单表无分区 | > 1 亿行必有分区 |
| 无幂等 → 重试产生脏数据 | 写操作必填 idempotency_key |
| 无超时 → 一个慢调用拖垮全链路 | Feign / HTTP / DB 全部显式超时 |

### 13.4 CI/CD Reliability（持续集成可靠性）

| 反模式 | 正例 |
|--------|------|
| `mvn deploy` 凭手感 | 必须 mvn verify → sonar → 安全扫描 → 灰度 |
| 跳过测试 commit | CI 必跑 unit + integration |
| 上线无回滚方案 | 每次发布必含 rollback.md |
| 无监控上线 | 必含 prometheus + logback + healthcheck |
| 无凭据管理 | 必填 vault / 环境变量，禁止 commit 明文 |

### 13.5 4 维评分卡

每个 PR 必须有 `docs/评审/l-gevity-scorecard.md`：

```markdown
# L-GEVITY Scorecard — M-XX

| 维度 | 1（差） | 3（中） | 5（优） | 得分 |
|------|---------|---------|---------|------|
| Minimalism | 严重过度设计 | 适度 | 极简 | __ |
| Modularity | 高耦合 | 适度 | 高内聚低耦合 | __ |
| Resilience | 无任何保护 | 部分覆盖 | 全链路保护 | __ |
| CI/CD | 手工 | 半自动 | 全自动 + 灰度 | __ |

**总分 ≥ 16/20 才 PASS**（< 16 必须修改或解释）
```

### 13.6 何时不评估

- 文档变更（仅 markdown）
- 单文件 bug 修复
- 测试用例本身
- L-GEVITY 4 维都不涉及的微调

---

---

## 14. S.U.P.E.R Architecture Health

> **借鉴 spec_driven_develop 的 S.U.P.E.R 哲学** —— "Like building with LEGO"，每个 brick 单职、标准接口、方向明确、可替换。

5 维架构健康评估，每维 1-5 分（5 = 优），总分 ≥ 20/25 才 PASS。

### 14.1 S — Single Purpose（单一职责）

| 反模式 | 正例 |
|--------|------|
| 一个脚本做"取数据 + 算指标 + 画图 + 通知" | 拆 4 个脚本，每个只做一件事 |
| 模块的职责无法用一句话说清 | 拆模块 |
| 一个 Service 既管缓存又管业务又管通知 | 切 3 个 Service |

**Litmus test**：能否用一句话描述模块职责？不能 → 拆。

### 14.2 U — Unidirectional Flow（单向数据流）

| 反模式 | 正例 |
|--------|------|
| 内层依赖外层（Controller 调 Service 反向） | 依赖永远向内 |
| 循环调用（A→B→A） | 所有调用形成 DAG |
| 核心业务层依赖具体数据库 | 抽象 Port，由 Adapter 实现 |

**Litmus test**：核心业务能否零外部服务跑单元测试？不能 → 依赖方向错了。

### 14.3 P — Ports over Implementation（接口优先）

| 反模式 | 正例 |
|--------|------|
| 模块边界传 Java 对象 / 业务实体 | 传 JSON / schema-defined 结构 |
| "看代码就知道格式" | 显式 schema（OpenAPI / JSON Schema / Protobuf） |
| 改一个模块牵动上游 | 改实现不改接口 |

**实践**：
- 每个模块的输入输出必须可序列化
- 跨模块接口必须 schema 化
- 显式合约，不靠"猜"

### 14.4 E — Environment-Agnostic（环境无关）

| 反模式 | 正例 |
|--------|------|
| 硬编码 `localhost:3306` | 走环境变量 |
| 依赖全局系统包 | `requirements.txt` / `pom.xml` 显式声明 |
| 写文件日志 | stdout 日志 |
| 状态存在进程内存 | 外部存储（DB / Redis） |

**配置优先级**（高到低）：
1. 命令行参数
2. 环境变量
3. 配置文件
4. 默认值（必须安全）

### 14.5 R — Replaceable Parts（可替换）

| 反模式 | 正例 |
|--------|------|
| 换数据库 → 改 50 个文件 | 换 Driver 即可 |
| 换前端框架 → 重写后端契约 | 同一 JSON 契约 |
| 换消息队列 → 改业务代码 | 换 Adapter |

**替换矩阵**：

| 替换项 | 影响范围 | 正确做法 |
|--------|---------|----------|
| 数据源 API | 仅 Adapter 层 | 写新 fetcher，输出同 JSON |
| 前端渲染器 | 仅 Render 层 | 读同 JSON，替换实现 |
| 通知渠道 | 仅 Notification 层 | 换 webhook Adapter |
| 部署平台 | 仅 deploy 配置 | 改 Dockerfile / wrangler.toml |
| 编程语言 | 实现层 | 合约不变，重写 |

### 14.6 评分卡（自动生成）

```bash
bash "$SKILL_ROOT/scripts/super-scorecard.sh" [module]
```

每维 1-5 分：
- **5 = 优**：完全符合，无任何问题
- **4 = 良**：偶有小气味，1-2 处可优化
- **3 = 中**：明显违反，需改进
- **2 = 差**：多处违反，应重构
- **1 = 差**：根本性问题，必须重写

**总分 ≥ 20/25** → PASS
**总分 15-19** → WARN，需修复后再标记
**总分 < 15** → FAIL，阻塞 phase 切换

### 14.7 强制代码审查清单（10 项）

| # | 检查项 | 维度 |
|---|--------|------|
| 1 | 每个新模块 / 文件有且仅有一个职责 | S |
| 2 | 没有函数做超过 1 件事 | S |
| 3 | 数据流 input → processing → output，无反向依赖 | U |
| 4 | 没有引入循环 import | U |
| 5 | 跨模块接口是 schema 化的 | P |
| 6 | 模块 I/O 可序列化 | P |
| 7 | 没有硬编码路径 / URL / 密钥 / 配置 | E |
| 8 | 所有新依赖显式声明 | E |
| 9 | 新模块可独立替换不影响其他模块 | R |
| 10 | 所有测试通过 | — |

**评分规则**：全过 = 推进；1-2 失败 = 修复后再标记完成；3+ 失败 = 停止并重构。

### 14.8 L-GEVITY vs S.U.P.E.R

| 维度 | L-GEVITY（§13） | S.U.P.E.R（§14） |
|------|----------------|------------------|
| 视角 | 架构治理（4 维） | 代码质量（5 维） |
| 触发 | Phase 切换 | 每次 PR |
| 度量 | 1-5 分，≥16/20 PASS | 1-5 分，≥20/25 PASS |
| 目标 | 4 个反模式（过度/欠设计/无韧性/无 CI） | 5 个原则（单职/单向/接口/环境/可替换） |

**两者互补**：L-GEVITY 回答"架构是否合理"，S.U.P.E.R 回答"代码是否符合原则"。

---
