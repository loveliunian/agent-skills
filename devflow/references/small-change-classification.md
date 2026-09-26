# 小需求 / 小改动分类矩阵

## MICRO 候选

| 类型 | 前提 | 最低验证 |
|---|---|---|
| `ui-copy` / `ui-behavior` | 既有页面局部文案、展示或交互，不影响权限/流程 | 客户端构建与相关页面测试 |
| `bugfix` | 有界既有缺陷，不改变公开契约或状态机 | 可复现缺陷测试与回归测试 |
| `additive-api` | 可选字段或兼容接口扩展，旧消费者不受影响 | 后端单测、契约、客户端兼容测试 |
| `validation-default` | 局部默认值或校验，不改变历史数据解释 | 成功、边界、失败测试 |
| `config` | 既有项目局部配置调整，无跨服务协议变化 | 加载、缺省、错误输入测试 |
| `additive-persistence` | 可追加、兼容、无大回填的持久化改动 | 四方言 Flyway 与迁移验证 |

## 必须 FULL

- `breaking-api`、`schema-breaking`、权限、状态机、跨服务；
- 新模块/服务、大规模回填、多项逻辑改动；
- 扫描命中权限、流程、跨服务或历史数据；
- 扫描不完整、受影响面不明确、实现中范围扩大。

## 机器规则

`LOGICAL_CHANGE_COUNT` 必须为 1；大于 1 自动 FULL。风险字段任何一个为 1 也自动 FULL：`BREAKING_API`、`TYPE_OR_NULLABILITY_BREAKING`、`PERMISSION_CHANGE`、`STATE_MACHINE_CHANGE`、`CROSS_SERVICE_CHANGE`、`NEW_TABLE_OR_SERVICE`、`LARGE_BACKFILL`。

十个扫描表面都要有 `HIT|MISS|NA`。持久化 MICRO 的 `AFFECTED_PATHS` 必须包含 h2、postgresql、oracle、kingbase 四个方言目录下的实际迁移文件。

## 状态

- `MERGE_READY`：代码与聚焦验证完成，未声明上线。
- `RELEASED`：除 SMALL-CHANGE Gate 外，已绑定并重验成功的 P7 与 P8 收据。

## 用户约束与路由（User Constraints vs Routing）

- 路由决策只能**上调**（MICRO→FULL），不得下调用户显式要求的验证；机器规则（LOGICAL_CHANGE_COUNT、风险字段）同理只升不降。
- 用户显式约束（"不要跑全量测试""先不部署""只改这一处"）写入分类合同 `USER_CONSTRAINTS` 行；被约束收缩的验证项**逐条**写入完成声明 `unverified[]`（契约同 `commands/devflow.md` §Result Contract）——不允许静默少跑。
- 约束不得放宽硬安全不变量：权限/破坏性/跨服务/历史数据命中仍强制 FULL，`RELEASED` 仍需授权收据（优先级链见 `concepts/core.md` §21）。
- 实现中范围扩大或合同矛盾：升级 FULL 或 `BLOCKED`，不得在 MICRO 内"顺带做掉"。
