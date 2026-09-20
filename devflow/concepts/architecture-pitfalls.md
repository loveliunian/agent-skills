---
name: architecture-pitfalls
version: "3.29.0"
description: |
  从 `docs/架构升级改造计划.md` 54 项 D-XX 偏差、21 项 G 守卫、44 项 B 改进中归纳的
  通用化"架构陷阱"清单。**任何项目在任何 Phase 切换前都应自检**。
  配套自动检查脚本：checks/check-arch-pitfalls.sh
  配套人工 review checklist：checks/check-arch-pitfalls.sh（生成）
license: MIT
metadata:
  author: "xingyunliushui"
  tags: "architecture,pitfalls,anti-patterns,phase-gate"
---

# Architecture Pitfalls（架构陷阱清单 · v3.4）

> **目的**：把"踩过的坑"沉淀为"机器可检查 + 人工可对照"的规则，避免后续项目重蹈覆辙。
>
> **来源**：从 `docs/架构升级改造计划.md` 54 项 D-XX 偏差、21 项 G 守卫、44 项 B 改进中归纳。
>
> **适用**：devflow 任意 Phase 切换前必跑（`/audit-completeness` 自动调用）。

## 1. 分类索引

| 类别 | 机器可检查 | 人工需 review | 详见 § |
|------|-----------|---------------|--------|
| 配置分散 | ✅ 6 项 | 2 项 | §2 |
| API/接口契约 | ✅ 4 项 | 1 项 | §3 |
| 安全/密钥 | ✅ 5 项 | 1 项 | §4 |
| 依赖/版本 | ✅ 3 项 | 1 项 | §5 |
| 代码规范 | ✅ 4 项 | 1 项 | §6 |
| 文档同步 | ✅ 2 项 | 2 项 | §7 |
| 性能/缓存 | ✅ 3 项 | 2 项 | §8 |
| 可观测性 | ✅ 3 项 | 1 项 | §9 |
| 运维/部署 | ✅ 4 项 | 2 项 | §10 |
| 测试 | ✅ 2 项 | 2 项 | §11 |

---

## 2. 配置分散（Anti-Pattern: Configuration Fragmentation）

### ❌ Anti-Pattern 2.1：环境变量命名分裂

**问题**：同一类配置有 2+ 套命名（如 `POSTGRES_*` vs `SPRING_DATASOURCE_*`）。

**规则**：
- 统一采用 Spring 官方命名 `SPRING_DATASOURCE_*`、`SPRING_FLYWAY_*`、`SPRING_REDIS_*`
- 自定义服务调用统一 `<SERVICE>_SERVICE_URI`（如 `GOVERNANCE_SERVICE_URI`）
- 任何 yml 引用方式必须使用 `${VAR}` 不允许硬编码

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" config-env-vars
# 扫描 application*.yml，检测重复的环境变量前缀
```

### ❌ Anti-Pattern 2.2：配置类重复定义

**问题**：每个服务都定义自己的 `MyBatisPlusConfig` / `RedisConfig` / `JacksonConfig`。

**规则**：
- 公共配置必须放 `common` 模块 + `@AutoConfiguration` 注解
- 业务服务只保留服务特有差异（如 schema、type-aliases）
- 注册到 `AutoConfiguration.imports`

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" config-duplicate
# 扫描各服务是否存在已被 common 抽象的 @Configuration
```

### ❌ Anti-Pattern 2.3：profile 文件缺失

**问题**：所有环境用同一份 `application.yml`，`prod`/`test` 差异靠手工切换。

**规则**：
- 必须有 `application-prod.yml`（生产环境）
- 必须有 `application-test.yml`（测试环境）
- 必须有 `application-local.yml`（本地开发）

### ❌ Anti-Pattern 2.4：默认配置值硬编码 IP

**问题**：`spring.datasource.url: jdbc:postgresql://127.0.0.1:5432/xyls`

**规则**：
- 所有中间件 URL 必须经 `${VAR:default}` 引用环境变量
- 默认值**只允许** `localhost` / `127.0.0.1`
- 生产值**禁止**在 yml 中写死

### ❌ Anti-Pattern 2.5：application.yml 密钥残留

**问题**：`JWT_SECRET: please-change-me-in-production` 这种弱默认值。

**规则**：
- 任何密钥类变量必须 `${VAR:?msg}` 强制注入（无 env 启动即失败）
- 禁止 `${VAR:default}` 形式（含默认值）

### ❌ Anti-Pattern 2.6：MyBatis-Plus/Redis/Jackson 等三花八门

**问题**：governance 用 `redisson-spring-boot-starter`，org-service 用手动 `RedissonLockConfig`，form-engine 引入依赖但零使用。

**规则**：
- 公共框架统一由 `common` starter 提供
- 业务服务禁止直接依赖 `redisson` / `mybatis-plus` / `jackson` 等基础库（应透过 common）

---

## 3. API/接口契约（Anti-Pattern: API Contract Fragility）

### ❌ Anti-Pattern 3.1：跨服务调用散落

**问题**：服务 A 直接调用服务 B 的 RestTemplate / WebClient / RestClient，绕过声明式接口。

```java
// ❌ 错误
restTemplate.getForObject("http://governance-service/api/elements/" + id, ElementDTO.class);

// ✅ 正确
@HttpExchange("/api/elements")
public interface ElementExchange {
    @GetExchange("/{id}")
    ElementDTO getById(@PathVariable Long id);
}
```

**规则**：
- 所有跨服务调用必须通过 `@HttpExchange` / `@FeignClient` 声明式接口
- 禁止在 Service 层直接调用 `RestTemplate` / `WebClient` / `RestClient.builder()`

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" api-declarative
# 扫描 Service 代码，检测 RestTemplate/WebClient 直接调用
```

### ❌ Anti-Pattern 3.2：接口契约无验证

**问题**：Consumer 改了 path / header / Content-Type，Provider 不会知道。

**规则**：
- 关键 `@HttpExchange` 必须有 contract 测试
- 路径/方法/头部/媒体类型/响应包装**任一项**变更必须双侧同步

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
# contract 检查项由本脚本 api 类目覆盖（URL ↔ Controller 对应校验）
```

### ❌ Anti-Pattern 3.3：OpenAPI 文档缺失

**问题**：API 文档方案完全缺失（SpringDoc / Swagger / OpenAPI 都没声明）。

**规则**：
- 每个有 Controller 的服务必须集成 `springdoc-openapi`
- 网关聚合 OpenAPI（`RewritePath` 路由）

### ❌ Anti-Pattern 3.4：文档与代码口径冲突

**问题**：技术选型 v5.0 声称"OpenFeign + Resilience4j"，实际用的是 RestClient。

**规则**：
- 文档每写一个"现状"，必须有 grep/mvn 命令验证
- 每次代码变更必须 grep 文档关键字，输出差异（由 `p4_prd_vs_code.sh` 把关）

### ❌ Anti-Pattern 3.5：消费者-Provider 兼容门禁缺失

**问题**：Pact / WireMock 装 0，没有契约测试。

**规则**：
- 至少关键链路（登录、流程发起、任务办理）有 Provider 验证
- HTTP 路径/方法/头部/媒体类型变更必须破坏本地构建

---

## 4. 安全/密钥（Anti-Pattern: Security Baseline Missing）

### ❌ Anti-Pattern 4.1：JWT_SECRET 默认弱口令

**问题**：`${JWT_SECRET:please-change-me-in-production-at-least-32-bytes}`

**规则**：
- 任何密钥类变量禁止默认值
- 用 `${JWT_SECRET:?msg}` 强制注入

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" security-defaults
# 扫描 :${VAR:default} 模式中的密钥类变量
```

### ❌ Anti-Pattern 4.2：部署脚本硬编码密码

**问题**：`deploy/start.sh` 中 `:-` 默认值含 `Liucl157` / `password` 等明文。

**规则**：
- 密钥类变量必须 `${VAR:?msg}` 强制注入
- 默认值章节必须为 `:-` 形式**且不出现** `password` / `secret` / `key` 字样

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" security-hardcoded
# 扫描 deploy/*.sh 的硬编码密码
```

### ❌ Anti-Pattern 4.3：CSRF 策略不一致

**问题**：8 个服务 `csrf.disable()`，1 个服务 `ignoringRequestMatchers`。

**规则**：
- 统一 `csrf.disable()`（StateLess JWT REST API 豁免）
- 或统一开启但白名单 `/api/internal/**`

### ❌ Anti-Pattern 4.4：CORS 策略缺失

**问题**：两份主文档均未声明 CORS 允许的 origin 与处理位置。

**规则**：
- CORS 必须由**网关统一处理**
- 各服务 `SecurityConfig` 不单独配置 CORS

### ❌ Anti-Pattern 4.5：内部接口鉴权 fail-open

**问题**：`InternalServiceAuthenticationFilter` 仅在 header 存在时校验，缺失则放行。

**规则**：
- 必须 `fail-closed` —— 缺失内部 token 头直接拒绝
- 必须有专门的 `X-Internal-Token` 等头部携带

### ❌ Anti-Pattern 4.6：幂等键丢失

**问题**：跨服务调用丢失 `Idempotency-Key` header，导致下游无法去重。

**规则**：
- 关键写操作（发布、流程发起、Action 触发）必须带 `Idempotency-Key`
- 由 `ExchangeFactory` 自动透传

---

## 5. 依赖/版本（Anti-Pattern: Dependency Version Drift）

### ❌ Anti-Pattern 5.1：版本号两文档不一致

**问题**：技术选型 §2.3 = `23.6.0.24.10`，系统详设 = `23.6.0.0.1`。

**规则**：
- pom 唯一事实源
- 文档版本号必须能从 `mvn dependency:tree` 反向推导

### ❌ Anti-Pattern 5.2：前端双锁文件

**问题**：同时存在 `package-lock.json` 和 `pnpm-lock.yaml`。

**规则**：
- **只保留一种包管理器**
- CI/远程构建使用 `npm ci` 或 `pnpm --frozen-lockfile`

### ❌ Anti-Pattern 5.3：SBOM / 镜像 digest 缺失

**问题**：生产 Compose 用 `:latest`，回滚依赖本机 `:prev`。

**规则**：
- 服务镜像必须以 **版本+commit** 或 **digest** 部署
- Compose 禁止 `:latest`
- 回滚必须引用已验证 digest

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" deploy-image-tag
# 扫描 docker-compose*.yml 是否有 :latest
```

### ❌ Anti-Pattern 5.4：时间语义未统一

**问题**：455 处直接调用 `LocalDateTime.now()`，Outbox 租约、幂等超时、缓存 TTL 依赖节点本地时间。

**规则**：
- 统一 UTC 存储、显示时区（按用户）
- 业务关键路径必须可注入 `Clock`
- 多副本/跨时区部署时必须有 `ClockSkewMonitor`

---

## 6. 代码规范（Anti-Pattern: Code Quality Baseline Missing）

### ❌ Anti-Pattern 6.1：巨型 Service（>1000 行）

**问题**：`ElementServiceImpl` 5384 行、`ReferenceServiceImpl` 1834 行。

**规则**：
- 单个 `ServiceImpl` 文件**≤500 行**（warn），**≤800 行**（fail）
- 超过必须按业务域拆分（Facade + 多个内部 Service）

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" code-huge-service
# 扫描 ServiceImpl 行数
```

### ❌ Anti-Pattern 6.2：DTO 重复定义

**问题**：`ApiResponse` / `PageRequest` / `PageResponse` 在 common 已有，governance 又定义。

**规则**：
- 通用响应/分页类**只能在 common**
- 业务服务 `*.vo` / `*.api.dto` 禁止重新定义

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" code-dto-duplicate
# 扫描重复的 ApiResponse/PageRequest/PageResponse
```

### ❌ Anti-Pattern 6.3：业务代码 `new ObjectMapper()`

**问题**：业务代码自己 `new ObjectMapper()`，绕过 Spring 注入。

**规则**：
- 业务代码禁止 `new ObjectMapper()`
- 必须通过 `@Autowired` 注入或构造器注入

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" code-objectmapper
# 业务代码（含 service/handler）扫描
```

### ❌ Anti-Pattern 6.4：RestTemplate / WebClient / RestClient.builder 绕过

**问题**：service 层直接 `new RestTemplate()` / `RestClient.builder()`。

**规则**：
- 跨服务调用必须经声明式接口
- 禁止运行时构造客户端

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" api-declarative
# 扫描 Service 层
```

### ❌ Anti-Pattern 6.5：未命名 / 缓存线程池

**问题**：未指定 `@Async("xxx")` 使用默认 SimpleAsyncTaskExecutor；手动 `newCachedThreadPool` 无上限。

**规则**：
- 所有 `@Async` 必须显式指定执行器
- 禁止 `newCachedThreadPool`（无界）
- 每个执行器必须有命名、active/queue/rejected 指标

---

## 7. 文档同步（Anti-Pattern: Documentation Drift）

### ❌ Anti-Pattern 7.1：测试策略完全缺失

**问题**：两份文档均未声明单元/集成/E2E 覆盖目标、测试目录结构、TestContainers 容器组合。

**规则**：
- 技术选型必须声明：
  - 单测覆盖率目标（≥70%）
  - TestContainers 容器组合（PostgreSQL/Oracle/Redis/MinIO）
  - Playwright e2e 范围
  - 契约测试与性能测试登记

### ❌ Anti-Pattern 7.2：Maven 依赖分裂

**问题**：MyBatis-Plus 3.5.15 / MyBatis 3.5.16 / Flyway 11.8.2 写在两文档，pom 实际是另两个版本。

**规则**：
- pom 是唯一事实源
- 文档版本号必须能从 `mvn dependency:tree` 推导

### ❌ Anti-Pattern 7.3：日志规范声明与实现不符

**问题**：系统详设声明"结构化日志：JSON 格式"，实际是纯文本。

**规则**：
- 文档声明与实现**必须一致**
- 任何不一致由 `p4_prd_vs_code.sh` 把关

### ❌ Anti-Pattern 7.4：方案多处表述不一

**问题**：技术选型 §11.1 "OpenFeign 已实现"，§11.2 "OpenFeign 待实现"。

**规则**：
- 同一方案在某文档中只有**一种**结论
- "目标方案" / "现状" / "已实现"三种状态**清晰标记**

---

## 8. 性能/缓存（Anti-Pattern: Performance Anti-Patterns）

### ❌ Anti-Pattern 8.1：N+1 查询

**问题**：for 循环里逐条调用 `selectById`。

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" perf-n-plus-one
# 已有 checks/detect-n-plus-one.sh
```

### ❌ Anti-Pattern 8.2：本地无界缓存

**问题**：`new ConcurrentHashMap<>()` 充当缓存，无容量无清理。

**规则**：
- 业务层禁止新增无上限 Map 缓存
- 必须用有界 Caffeine / Redis Cache / 持久化表

### ❌ Anti-Pattern 8.3：幂等键散落

**问题**：workflow 有 `StdIdempotencyLog`，operations 拼接 key，governance 拼路径 hash。

**规则**：
- common 定义 `Idempotency-Key` 协议
- 各服务本地表但实现同一协议
- 关键写操作必须经 `IdempotencyKeyFilter`

### ❌ Anti-Pattern 8.4：Outbox 模式散落

**问题**：workflow 有 `wf_outbox_event`，operations 自己造 Outbox。

**规则**：
- common 提供 `PublishOutboxDispatcher` 抽象
- 业务事件统一进 Outbox → 异步投递

### ❌ Anti-Pattern 8.5：异步执行器未统一

**问题**：10 个 `@Async` 方法，使用不同命名池（`audit-pool` / `configUpdateTaskExecutor`）。

**规则**：
- 三类执行器：业务关键 / 审计尽力而为 / IO 并发
- 所有 `@Async` 必须显式指定

---

## 9. 可观测性（Anti-Pattern: Observability Theater）

### ❌ Anti-Pattern 9.1：Actuator 端点不一致

**问题**：4 种变体（`health` / `health,info` / `health,info,metrics` / 全开）。

**规则**：
- 业务服务统一 `health,info,metrics,prometheus`
- `health.show-details: when-authorized`

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" obs-actuator
# 扫描 application*.yml 的 management.endpoints.web.exposure.include
```

### ❌ Anti-Pattern 9.2：日志格式分裂

**问题**：9 个服务 logback-spring.xml，prod profile 输出 JSON 覆盖率参差。

**规则**：
- common `logback-base.xml` 提供基础
- 各服务 `logback-spring.xml` 包含
- prod profile 必须 LogstashEncoder JSON

### ❌ Anti-Pattern 9.3：可观测性停留在端点暴露

**问题**：10 服务暴露 Prometheus，但生产代码只有 3 个自定义指标。

**规则**：
- 关键入口（HTTP、Outbox、调度、异步）必须有 Micrometer Observation
- 必须有 RED/USE 指标（Rate/Error/Duration + Utilization/Saturation/Errors）

### ❌ Anti-Pattern 9.4：监控接收端点缺失

**问题**：前端 `web-vitals` 监控无接收端点。

**规则**：
- monitoring-service 必须有 `MonitoringController` 接收前端上报
- 前端 `.env.*` 必须预置 `VITE_MONITORING_ENDPOINT`

---

## 10. 运维/部署（Anti-Pattern: Deployment Theater）

### ❌ Anti-Pattern 10.1：部署回滚仅覆盖镜像

**问题**：镜像回滚不能恢复误迁移、数据损坏、对象丢失。

**规则**：
- 必须有 database/MinIO/Redis 备份清单
- 必须有 RPO/RTO 声明
- 必须有恢复演练记录

### ❌ Anti-Pattern 10.2：容量治理未落地

**问题**：生产 Compose 未定义 CPU/内存资源、JVM 堆、连接/线程预算。

**规则**：
- 每个服务必须有 `resources.requests/limits`
- 关键参数（Hikari、Redis、线程池）必须在 yml 显式声明

**机器检查**：
```bash
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" deploy-resources
# 扫描 docker-compose*.yml 的 deploy.resources
```

### ❌ Anti-Pattern 10.3：供应链不可追溯

**问题**：`:latest` 镜像、缺失 SBOM、依赖漏洞扫描。

**规则**：
- 镜像必须版本+commit 或 digest
- 必须有 SBOM（CycloneDX 或等价）
- 必须有依赖漏洞扫描

### ❌ Anti-Pattern 10.4：空壳服务遗漏

**问题**：monitoring/validation 是空壳，但 Gateway 仍路由 `/api/monitoring/**`、`/api/validation/**`。

**规则**：
- 空壳服务必须有 `fallback` 过滤器返回 503
- 路由必须有 `circuit breaker` 或启动开关

### ❌ Anti-Pattern 10.5：Spring Cloud LoadBalancer 未声明

**问题**：跨服务调用硬编码 `http.service.<name>` 单地址，多实例部署会失败。

**规则**：
- 多实例部署必须用客户端负载均衡（Spring Cloud LoadBalancer / LB）
- 文档必须声明当前 LB 方案

---

## 11. 测试（Anti-Pattern: Test Coverage Theater）

### ❌ Anti-Pattern 11.1：单元测试覆盖率 < 70%

**问题**：巨型组件几乎无单测。

**规则**：
- 后端覆盖率 ≥70%（fail），< 80% warn
- 前端关键 composable/store/api 必须有单测

### ❌ Anti-Pattern 11.2：契约测试缺失

**问题**：Pact/WireMock 装 0。

**规则**：
- 关键链路（登录、流程发起、任务办理）必须有 Provider 验证
- 至少覆盖 25 个 `@HttpExchange` 中的 80%

### ❌ Anti-Pattern 11.3：e2e 覆盖漏前端巨型组件

**问题**：5 个 400+ 行的 `.vue` 组件没有 e2e。

**规则**：
- 巨型组件（>400 行）必须有对应 e2e spec
- 拆分后必须跑对应 e2e 验证

### ❌ Anti-Pattern 11.4：PLAYWRIGHT 全量 SKIP

**问题**：48/48 用例 SKIP。

**规则**：
- **禁止**全量 SKIP
- 至少 80% PASS

---

## 12. 完整机器检查清单（用于 `/audit-completeness`）

```bash
# 一键运行所有架构陷阱检查
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --all

# 或分类运行
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category config
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category api
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category security
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category code
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category perf
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category obs
bash "$SKILL_ROOT/checks/check-arch-pitfalls.sh" --category deploy
```

**输出格式**：
```
[CRITICAL] D-17 ❌ JWT_SECRET 默认弱口令
  位置: backend/gateway/application.yml:232
  现状: ${JWT_SECRET:please-change-me-in-production-...}
  规则: 必须 ${JWT_SECRET:?msg} 强制注入
  修复: 见 docs/架构升级改造计划.md B9

[WARN] D-35 ⚠️ 巨型 Service 2544 行
  位置: governance-service/element/service/impl/ElementServiceImpl.java
  现状: 2544 行（阈值 500）
  规则: 单 ServiceImpl ≤500 行
  修复: 拆分 ElementImportService / ElementExportService 等
```

## 13. 完整人工 review checklist

| 类别 | 检查项 | 状态 |
|------|--------|------|
| 配置 | 2.1 环境变量命名分裂 | □ |
| 配置 | 2.2 配置类重复定义 | □ |
| 配置 | 2.3 profile 文件缺失 | □ |
| 配置 | 2.4 硬编码 IP/URL | □ |
| 配置 | 2.5 密钥默认值 | □ |
| 配置 | 2.6 框架三花八门 | □ |
| API | 3.1 跨服务调用散落 | □ |
| API | 3.2 接口契约无验证 | □ |
| API | 3.3 OpenAPI 缺失 | □ |
| API | 3.4 文档口径冲突 | □ |
| API | 3.5 兼容门禁缺失 | □ |
| 安全 | 4.1 JWT 默认弱口令 | □ |
| 安全 | 4.2 部署密码硬编码 | □ |
| 安全 | 4.3 CSRF 策略不一致 | □ |
| 安全 | 4.4 CORS 缺失 | □ |
| 安全 | 4.5 内部接口 fail-open | □ |
| 安全 | 4.6 幂等键丢失 | □ |
| 依赖 | 5.1 版本号不一致 | □ |
| 依赖 | 5.2 前端双锁文件 | □ |
| 依赖 | 5.3 SBOM/digest 缺失 | □ |
| 依赖 | 5.4 时间语义未统一 | □ |
| 代码 | 6.1 巨型 Service | □ |
| 代码 | 6.2 DTO 重复定义 | □ |
| 代码 | 6.3 new ObjectMapper | □ |
| 代码 | 6.4 客户端绕过 | □ |
| 代码 | 6.5 未命名/无界线程池 | □ |
| 文档 | 7.1 测试策略缺失 | □ |
| 文档 | 7.2 Maven 依赖分裂 | □ |
| 文档 | 7.3 日志规范不符 | □ |
| 文档 | 7.4 方案表述不一 | □ |
| 性能 | 8.1 N+1 查询 | □ |
| 性能 | 8.2 本地无界缓存 | □ |
| 性能 | 8.3 幂等键散落 | □ |
| 性能 | 8.4 Outbox 散落 | □ |
| 性能 | 8.5 异步执行器分裂 | □ |
| 观测 | 9.1 Actuator 不一致 | □ |
| 观测 | 9.2 日志格式分裂 | □ |
| 观测 | 9.3 端点暴露 ≠ 真实指标 | □ |
| 观测 | 9.4 监控端点缺失 | □ |
| 部署 | 10.1 备份缺失 | □ |
| 部署 | 10.2 容量未落地 | □ |
| 部署 | 10.3 供应链不可追溯 | □ |
| 部署 | 10.4 空壳服务路由 | □ |
| 部署 | 10.5 LB 未声明 | □ |
| 测试 | 11.1 覆盖率 < 70% | □ |
| 测试 | 11.2 契约测试缺失 | □ |
| 测试 | 11.3 巨型组件无 e2e | □ |
| 测试 | 11.4 全量 SKIP | □ |

---

## 14. 与 devflow 阶段对应

| Phase | 必跑检查 | 关键陷阱 |
|-------|---------|---------|
| P0 需求澄清 | §7 文档同步 | 7.1 测试策略缺失 |
| P1 技术选型 | §5 依赖/版本 | 5.1 版本号、5.2 双锁文件 |
| P2 详细设计 | §2 配置、§3 API | 2.1 环境变量、3.1 跨服务调用 |
| P3 编码 | §6 代码、§8 性能 | 6.1 巨型 Service、8.1 N+1 |
| P3b Review | §6.5 线程池、§9 观测 | 9.1 Actuator |
| P3c Security | §4 安全 | 4.1-4.5 全部 |
| P3d Performance | §8 性能 | 8.1-8.5 全部 |
| P4 验证 | §3.4 文档-代码 | 7.1-7.4 全部 |
| P5-P6 测试 | §11 测试 | 11.1-11.4 全部 |
| P7 部署 | §10 部署 | 10.1-10.5 全部 |
| P8 监控 | §9 观测 | 9.1-9.4 全部 |
| P9 文档 | §7 文档 | 7.1-7.4 全部 |
| P10 复盘 | §7.4 方案一致性 | 全清单 |
| P11 Postmortem | §6 全部 + 新坑登记 | 触发新 Pitfall 登记 |

---

## 15. 演进机制

### 15.1 新坑登记

每次 P11 Postmortem 发现新坑时，按以下流程登记：

1. 写一份 "XXX 事故与对应架构陷阱" 文档
2. 在本文件 §2-§11 新增一条 Anti-Pattern
3. 若机器可检查：在 `checks/check-arch-pitfalls.sh` 中新增
4. 更新 `/audit-completeness` 阶段门控

### 15.2 旧坑归档

当某 Anti-Pattern 已经在所有项目消除后：
1. 标记为 `archived: true`
2. 保留在文档中（提供历史参考）
3. 自动检查脚本中保留为 commented out

### 15.3 跨项目同步

每个项目都应该有自己的 `architecture-pitfalls.md`（基于本模板），但**最终必须回流入公共 skill**：
- 提交至 `docs/architecture-pitfalls.md`（项目特定）
- 通用化后写入本 skill `concepts/architecture-pitfalls.md`

---

## 16. 一句话原则

> **架构不是一次性设计，而是与坑的持续对抗。把每次踩过的坑变成不可绕过的规则。**

---

## 附录：M-01 实战新增坑（v3.27.5，2026-09-18）

### PITFALL-M01-01：ORM 全局逻辑删除 × 显式生命周期字段（P0）

- **模式**：服务用回收站/生命周期唯一键模式（deleted 参与业务状态机 + recycle_ref 显式置位），同时继承脚手架的 `logic-delete-field` 全局配置。
- **后果**：MP 从一切 UPDATE SET 过滤该字段——删除进站/恢复/置空全链路静默失效；P3 返工 3 轮。
- **检查**：凡服务启用回收站模式，application.yml 禁用 `logic-delete-field`，deleted 过滤下沉服务层。
- **已在 check-arch-pitfalls 覆盖**：否（正则难以静态判定，依赖规约 + 回环测试）。

### PITFALL-M01-02：实体 FQCN 类型名破坏文档↔代码字段对账

- **模式**：实体字段写 `private java.time.LocalDateTime x;`。
- **后果**：P4b 实体字段抽取正则（短类型名）失配，datetime 字段集体报"Field missing"（假阴性对账失败）。
- **规约**：实体一律短类型名 + import。

### PITFALL-M01-03：updateById 置空语义静默失效

- **模式**：用 updateById/entity 或普通 set 置 null（lock_until=NULL 解锁、recycle_ref=NULL 复位）。
- **后果**：空值被跳过，状态永不复位（解锁失败/恢复失败）。
- **规约**：置空一律 LambdaUpdateWrapper.set(field, null) + "置空后回读断言"测试。

### PITFALL-M01-04：渲染器整篇重建 × 手写章节共存

- **模式**：确定性渲染器对已含手写增强章节的文档执行骨架级重建。
- **后果**：手写内容（表格/流程/约束表）全部丢失；本文档类事故在 M-01 造成 2h 返工。
- **规约**：渲染器对既有文档只做锚点块拼接（df_render v3.27.5 守卫已实现）；手写增强一律写在锚点块外。
