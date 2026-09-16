# 流程环节表生成（gen_flow_tables.py）

> 环节结构表（多分支总览 / 单分支明细）从**老系统数据库（Oracle 源库）直取**，Excel/快照仅作起草回退。
> 本能力是 flow-test-contract 的**结构取证前置件**：环节/办理人/候选集是「哪个分支能到哪个环节」的权威锚，
> 后续双端采集只填「新可达/老可达」证据列。

## 1. 两种产物与列语义

| 产物 | 内容 | 列 |
|---|---|---|
| `multi` 多分支总览 | 每矿厂分支一行 | 分支｜矿厂/T_GK｜发起人(00)｜实际首跳｜节点数｜主线路径｜分支路由来源 |
| `single` 单分支明细 | 该分支 DB 配置的每一环节一行 | 环节｜环节名称｜办理人｜下一环节候选｜办理人候选 |

- **环节行 = 分支配置**：某环节不在该分支 → 老/新均不可达（对照报告里体现为「老可达 ✗」）。
- **主线规则**：从 00 起，沿每环节**第一个**下一候选行进（老系统 nextSteps 数组顺序，序=WORKFLOW_SUB_ID 升序）；
  41~47 运费环节（跳转结束型 APPROVE_TYPE=2）提交即办结、自动启动后置流程 WFA_RY_JM_165002，无下一环节选择。
- **新可达/老可达** 为测试证据列，由 flow-test-contract 双端采集对拍后填入（生成器只产结构侧，不产证据）。

## 2. DB 后端（legacy-oracle，正式）

连接约定与 qianyi/migrator 同源（只读）：

```
SOURCE_ORACLE_HOST / SOURCE_ORACLE_PORT / SOURCE_ORACLE_SERVICE
SOURCE_ORACLE_USERNAME / SOURCE_ORACLE_PASSWORD
```

核心 SQL（列名以实际结构为准，脚本先 `user_tab_columns` 探列、缺列即 BLOCKED）：

```sql
-- 分支路由边（每行 = 分支条件 → 下一环节）
SELECT STEP_ID, FIELD, VALUE, NEXT_STEP_ID
FROM   SETTLE_WORKFLOW_SUB
WHERE  FLOW_CODE = :flow
ORDER  BY STEP_ID, WORKFLOW_SUB_ID;      -- 分支键=(FIELD,VALUE)；VALUE=矿厂条件值(T_GK)

-- 环节定义（名称/顺序；无名称时用内置编号名兜底）
SELECT STEP_ID, STEP_NAME FROM SETTLE_WORKFLOW_STEP WHERE FLOW_CODE = :flow;
```

- 同 (STEP_ID, VALUE) 多行 = 该环节多个下一候选（候选集）；排序决定主线「首选」。
- 老系统按**登录人**过滤 00 候选（gov_formula 983 / F1，9 组白名单+默认组）——该收窄属运行侧 DMN 语义，
  结构表 `single` 的 00 行列出配置全集并可由 `--notes` 标注组规则（B-05 默认组=全集等）。
- 办理人/候选办理人：配置在 SUB/STEP_USER 等关联；快照端已在《23分支节点对应信息.md》分支 sheet 汇总，
  DB 端按探列结果映射（当前脚本 DB 后端输出办理人列留空待补——实施时按 SETTLE_WORKFLOW_STEP_USER 补
  STEP_ID→USER 映射，USER→姓名(账号) 用 sys_user）。

## 3. 快照回退（snapshot，起草用）

`--db snapshot --snapshot <《23分支节点对应信息.md>同构路径>`：解析 `## B-XX …` 分支 sheet 表 +
总览表（矿厂列/节点数）。与 DB 产同构表格；**差异仲裁以 DB 为准**（快照是 Excel 转档，可能滞后）。

## 4. 验收

- `python3 templates/gen_flow_tables.py --selftest` 绿（快照解析/主线推导/候选办理人解析）；
- 用真实快照跑 `--mode all`：23 分支主线须与《23分支节点对应信息.md》总览一致（B-01..B-23 逐行核对）；
- DB 模式：不可达/缺列 → 打印 BLOCKED 并退出码 2，绝不静默回退。

## 5. 与对比报告的衔接

`docs/港口煤发运流程/自动化测试/测试用例/对比报告/老系统浏览器对比测试用例-对比测试用例.md` §3 的
「环节｜环节名称｜办理人｜下一环节候选｜办理人候选｜新可达｜老可达｜备注」即此两产物 + 执行证据合并版：
生成器产前 5 列 + 表注；flow-test-contract 执行后回填新/老可达与备注（历史多轮实测已在报告内固化）。
