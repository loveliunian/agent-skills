# 小需求变更 - c-sort-default

> 生成时间：2026-09-16 11:10:00（UTC）　数据来源：small-change.json 结构化产物自动汇总


<!-- 审计指纹: small-change.json sha256=53ab8769e23863c0eccba53608a1771efa0a083c40abb262e2aaa9ed5be5e965（由 df_render 自动生成，人工勿改） -->

## 自然语言需求

把列表默认排序改成按更新时间倒序，用户想最快看到刚改过的记录

## 变更摘要

| 项 | 内容 |
|---|---|
| 主题 | `列表默认排序改为更新时间倒序` |
| 旧行为 | 列表默认按创建时间倒序 |
| 新行为 | 列表默认按更新时间倒序 |
| 类型 | ui-behavior |
| 目标 | `merge-ready` |
| 影响路径 | `frontend/src/views/pay/List.vue` |

## 项目影响扫描（十项 HIT|MISS|NA）

| 扫描面 | 结果 |
|---|---|
| DB | MISS |
| DOMAIN | MISS |
| API | MISS |
| CLIENT | MISS |
| CONFIG | MISS |
| TEST | HIT |
| PERMISSION | NA |
| WORKFLOW | NA |
| CROSS_SERVICE | NA |
| HISTORY_DATA | NA |

风险面命中：无。

## 机器契约（写入 .devflow/c-sort-default/small-change.env，由管线自动产出）

```text
CHANGE_KIND=ui-behavior
CHANGE_SUBJECT=列表默认排序改为更新时间倒序
LOGICAL_CHANGE_COUNT=1
TARGET=merge-ready
DIALECTS=
VERIFY_CMD=npm run test:unit -- List
MIGRATION_VERIFY_CMD=
DEPLOY_RECEIPT_PATH=
MONITOR_RECEIPT_PATH=
DECISION=MICRO
DECISION_REASON=仅前端默认排序参数变化：扫描十维仅 test 命中，无权限/流程/跨服务/历史数据风险，逻辑变更数 1
```

## 验收条件

- 正向：打开列表默认按更新时间倒序，刚编辑的记录在首行
- 边界：更新时间为空的存量记录排在末尾且不报错
- 失败：排序参数异常时回退默认排序并记录 WARN 日志

## 实际验证

| 项 | 内容 |
|---|---|
| 验证命令 | `npm run test:unit -- List` |
| 真实退出码 | 0 |
| 执行日志 | `.devflow/c-sort-default/verify.log` |
| 环境边界 | 本地开发环境（node 20 / vitest） |
| 结论 | `MERGE_READY` |

`MERGE_READY` 为默认终点；明确要求上线才绑定 P7+P8 收据并声明 `RELEASED`。
