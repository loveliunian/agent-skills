# 守卫测试搭建方案

> 使用说明(生成时删除本块):本文件由守卫方案环节按 `references/guard-tests.md` 生成,是唯一落地进源码树相关信息的产物(落地源码树仍需用户同意,见 R-B)。
> 章节标题与编号不得增删改(脚本按本模板逐节比对)。仓库已有守卫时,"规则↔守卫对照"填现状,"守卫清单"只写增量;确实不适用的节写"本节不适用:<原因>",不得整节删除。
> "验证记录"必须写实测结果(正向全绿 / 反向变红 / 未实跑三选一),禁止用"应该可行""已验证"含糊带过。

架构形态:<单体 或 微服务——与 feature-list.json 的 architecture 一致,只留一项>

## 1. 元信息与架构形态

| 项 | 值 |
|---|---|
| 架构形态判定依据 | 详设 §x /parse-report.architecture.evidence |
| 被测范围 | <单体:各业务模块包根;微服务:各服务包根> |
| 守卫代码落点 | <模块>/src/test/java/<rootPackage>/architecture/ |
| 是否已落地源码树 | 否(默认)/ 是(用户 <日期> 同意) |

## 2. 依赖与位置

<从 references/guard-tests.md §1 粘贴实际使用的依赖坐标与版本、放置模块,并说明为何覆盖全部被测代码>

## 3. 守卫清单

<按 references/guard-tests.md §2 生成,逐条列出;每条给出测试类名、规则要点、对应形态>

| 守卫类 | 作用 | 适用形态 | 状态 |
|---|---|---|---|
| LayeredArchitectureGuardTest | 分层方向 + 禁跨层 + 包级判环 | 通用 | 启用 |
| ModuleIsolationGuardTest | 模块隔离:跨业务模块禁止直引 internal/repository/mapper | 仅单体 | 启用 |
| ServiceIsolationGuardTest | 服务隔离:跨服务禁止直引 internal/entity/mapper | 仅微服务 | 启用 |
| CommonModuleGuardTest | common/shared 只允许依赖白名单基础库 | 通用 | 启用 |
| ContractBindingGuardTest | 契约绑定:OpenAPI path 集合 ↔ Controller path 集合一致 | 通用 | <启用/暂缓> |

## 4. 规则↔守卫对照

<constitution 中标 [测试] 的每条规则,必须在此表找到落点;找不到落点的 [测试] 规则要么补守卫要么降级为 [评审]>

| constitution [测试] 规则 | 落在哪个守卫/门禁 | 说明 |
|---|---|---|
| <规则要点> | <测试类.规则名 / JaCoCo check / ESLint 规则> | <覆盖方式> |

## 5. 前端守卫

<从 references/guard-tests.md §3 生成 ESLint 配置片段(追加到项目现有配置),列出禁跨层引用、组件命名等规则;无前端时写"本节不适用:本设计不含前端">

## 6. 命令落点

<实现阶段与 CI 唯一依据的命令清单;constitution §7 指向本表>

| 用途 | 命令 | 失败含义 |
|---|---|---|
| 后端守卫测试 | `mvn test -Dtest=*GuardTest` | 架构规则被破坏 |
| 单测+覆盖率门禁 | `mvn -q verify` | 覆盖率低于 constitution §7 分层阈值 |
| L3 接口全量测试 | `bash specs/_work/api-tests/<F编号>/run.sh`(逐 F) | 接口行为/错误码与契约不符 |
| L4 场景链路回归 | `bash specs/_work/local-tests/<F编号>/*.sh`(收尾全量) | 业务链路断裂 |
| 前端静态守卫 | `npm run lint && npm run typecheck` | 前端依赖/命名/类型约定被破坏 |
| L5 浏览器冒烟 | `npx playwright test`(登记目录) | 首屏/入口链路断裂 |
| 契约校验(可选) | `npx @redocly/cli lint specs/*/openapi.yaml` | 契约格式非法 |

## 7. 验证记录

<两步都跑完再填;环境缺构建工具时"结果"列写"未实跑",并写一句原因>

| 步骤 | 命令 | 执行时间 | 结果 |
|---|---|---|---|
| 正向(应全绿) | <命令> | <日期时间> | 全绿 / 未实跑(<原因>) |
| 反向(应变红) | <临时造一条违规,如 Controller 直连 Repository> | <日期时间> | 变红后已删除并复跑恢复 / 未实跑(<原因>) |

## 8. CI 接线

<按 references/guard-tests.md §5 写明流水线步骤与合并前置条件;无 CI 时写"本节不适用:仓库暂无流水线,本地以 <命令> 为准">

## 9. 白名单变更记录

<common/shared 守卫依赖白名单、生成代码排除清单的每次扩充必须在此留痕;无变更写"暂无">

| 日期 | 变更 | 理由 |
|---|---|---|
| <日期> | <新增包前缀 / 排除生成包> | <为什么必须放> |

## 10. 补测清单

<对照后发现的缺口:哪些 [测试] 规则当前无守卫覆盖,后续由哪个 feature 补;无缺口写"暂无">

| 缺口 | 涉及规则 | 计划由谁在何时补 |
|---|---|---|
| <缺口描述> | <R编号 / constitution 条目> | <F编号 / 待排期> |
