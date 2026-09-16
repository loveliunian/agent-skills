# capture-channels —— 采集通道契约与 FlowTrace 理念内化（v1，2026-09-07 第十二轮·通道自持）

> 读者：需要理解"双端采集怎么产生、为什么可信、怎么接新系统"的实现者/审计者。
> 本文件是通道层（run-contract-scenarios.py / api-capture.py / systems api 配置）的完整契约。

## 1. 演进：为什么不再依赖 FlowTrace CLI

| 阶段 | 执行方式 | 问题 |
|---|---|---|
| 旧 | 外部 FlowTrace CLI（`~/项目/FlowTrace`，浏览器自动化），`$CLI run --scenario <f> --run-id <id>` | 外部项目依赖；CLI 未检出即全链 BLOCKED；接口"以实际 CLI 为准"不可控 |
| **现（第十二轮）** | **内置 api-capture.py 纯 HTTP 采集**（默认后端 `FLOWTRACE_RUNNER=api`） | 零外部依赖；端点全配置化（systems/api/*.yaml）；cli 仅作显式兼容后端（`FLOWTRACE_RUNNER=cli` + `FLOWTRACE_CLI`，已移除 PATH/默认路径盲探） |

从 FlowTrace 吸收并保留的**理念**（与工具解耦）：

1. **场景即数据**：场景是确定性 YAML（契约生成，勿手改），不是代码；
2. **双端同构采集**：legacy/current 各跑一遍同一场景，产同构 capture；
3. **capture 即证据**：结论只认采集文件，不认退出码；
4. **身份绑定**：capture 必须携带 `run_id`/`case_id`，与本次运行强绑定（防冒领）；
5. **凭据零明文**：actor → 环境变量名映射（actorMap），密码永不入场景/配置/日志。

## 2. 场景 YAML（gen_from_contract 产出，runner 消费）

```yaml
id: WFA_RY_HZ_0162-c-01        # <flow_code>-<case_id 小写>
case_id: C-01                   # 契约用例号（conclude 与契约 cases 对账的键）
name/flowDef/process/severity/tags/required: …
steps:
  - {seq: 1, node: "00", taskName: …, actorAccount: <actor>, expectNext: …, expectAssignee: …, capture: form-fields}
  - …
fixturePairs: [FP-…]            # 可选：双端选数配对声明
```

runner 对 step 的解释：`node`=待办节点编码（与 systems api `todo.nodePath` 对齐）、
`actorAccount`=办理人（经 actorMap 解析凭据）、`expectAssignee`=流转选人（提交时 nextAssigneeId）、
`button`=按钮编码（缺省用 submit.defaultButton）。

## 3. capture JSON 契约（下游 field-level-compare 的输入；三通道同构）

```json
{
  "run_id": "run-20260907…",      // 身份三要素——runner 采信校验的硬条件
  "case_id": "C-01",
  "flow_code": "WFA_RY_HZ_0162",  // 须与 compare-rules meta.flow_code 一致
  "side": "legacy | current",
  "fixture_pairs": ["FP-…"],
  "steps": { "s1": { "fields": { "<字段>": 值 } }, "s2": … },   // 逐 step 采集，绝不折叠
  "instance_no": "…", "task_ids": {"s1": "…"},                   // 追溯元数据
  "channel": "api"                  // 产生通道（追溯）
}
```

- 双端配对：`field-captures/{legacy,current}/<case_id>.json` **同名文件**，`case_id`/`flow_code` 必须一致；
- 六维扩展位：steps 条目除 `fields` 外可携带 `buttons`/`routing`/`resources`/`post_flow`/`formulas`
  （对拍器按 compare-rules 声明的维度消费；api 通道当前产出 fields，其余维度按需扩展配置）。

## 4. runner 采信铁律（v1.2 起，与通道无关）

PASS = 后端全部成功退出 **且** 双端 capture 满足：

1. **清残留**：执行前清空 exec-dir 的 `field-captures/`（本 run 采集区只允许本 run 产物）；
2. **时间窗**：capture mtime ≥ 本 run 执行开始时刻（-5s 时钟容忍）；
3. **身份绑定**：JSON 对象且 `run_id`==本 run-id、`case_id`==本用例（缺/错=BLOCKED）；
4. **实例/流程绑定**（第十三轮·api 通道）：capture 含 `instance_no`==本 run 发起实例；
   执行期任务查找强制绑定实例号 + todo.flowCodePath 服务端流程编码==场景 flow_code。

## 5. api 通道五原语（api-capture.py v2 消费 systems/api/<side>.yaml）

| 原语 | 配置块 | 作用 |
|---|---|---|
| login | `login{path, body, tokenPath, tokenHeader, tokenScheme}` | 按步 actor 换 token（缓存复用） |
| todo | `todo{path, params, listPath, taskIdPath, nodePath, instancePath, flowCodePath?}` | 按 token 用户查待办；flowCodePath（配了必验）== 场景 flow_code |
| launch | `launch{path, body, instancePath, taskIdPath, elementIdEnv}`（**必填**） | 每 run 发起本流程新实例（launch-first） |
| form | `form{path(${TASK_ID}), fieldsPath}` | 采集该步表单字段 → steps.sN.fields |
| submit | `submit{path(${TASK_ID}), body, defaultButton, successStatus[]}` | 按钮执行办理（含 nextAssigneeId 流转选人） |
| operations | `operations{<BUTTON>: {method, path, body, successStatus[], backTarget?, ledger?, refetch?}}`（可选，第三十五轮 v1.3.5；v1.3.6 加固） | **按钮语义原语**：step.button 命中键时改发该按钮专属端点——老系统退回（backWorkflow）/作废（cancelWorkflow）是独立端点与载荷，编码成 next_step 走提交会被拒「所选环节并不可用范围」（2026-09-10 铁路实测根因）。backTarget=退回目标步实例解析器（恰一命中，多候选诚实失败）；ledger: finish（作废终态）\| refetch（按 todo 列表重登记退回后新任务，空 owner 条目对任意 actor 可见、实例+环节绑定保隔离，可配 pollSeconds 有限轮询）。载荷占位 ${INSTANCE_NO}/${TASK_ID}/${BACK_NODE}（expectNext 去括号）/${BACK_TARGET}。**v1.3.6**：整套 schema 在任何登录/发起/提交前经 `scripts/ftc_ops_config.py` 校验（api-capture 启动 + legacy-config-check 共用），命中键但非法即拒绝且不回退统一 submit；解析出的 BACK_NODE/BACK_TARGET/taskId 必须为非空有效标量。已实证形态见 assets/systems-api/legacy.yaml 注释与 lessons L41 |

**实例策略（第十三轮·实例隔离）**：默认 `launch`——每 run 首步先发起本流程新实例
（元素 ID 解析：env `LAUNCH_ELEMENT_ID_<FLOW_CODE>` → launch.elementIdEnv，缺即拒不猜测），
此后每步待办查找**强制绑定 instance_no**——本采集器只可能拿到自己发起的实例，他流程同 node
真实任务绝不触碰（BB1 decoy 回归）。复用既有待办须契约 `meta.instance_policy: reuse`
（gen 生成场景 `instancePolicy`）显式声明，且 systems todo 必配 `flowCodePath` 验流程身份。
**v1.3.6**：复用首步同流程同节点**必须恰一命中**（多候选=BLOCKED，绝不任取第一个真实生产
单据）；场景可声明 instanceNo/businessKey/fixtureSelector 消歧，后二者的待办字段路径由
systems `todo.selectorPaths` 指认（缺失 fail-closed）。（BB7/BB7b 回归 + v1.3.6 reuse 消歧回归。）

配置要点：

- **占位符** `${VAR}`：USERNAME/PASSWORD（actorMap env 解析）、TASK_ID/INSTANCE_NO/NODE/BUTTON/NEXT_ASSIGNEE/ELEMENT_ID；解析为空串的键自动剔除；
- **JSONPath** 用点号+数组下标（`data.content[0].taskId`）；路径取值失败=诚实 BLOCKED，绝不猜；
- **taskWaitSeconds**：提交后等待下一节点任务可见的轮询窗口（异步流转）；
- **凭据**：actorMap 只写环境变量名；缺 env 即拒（BB3 回归）；
- **日志零请求体**：错误只报 HTTP status + path（防凭据回显泄漏）；
- **通道适配性警示**（三流程实战）：含**客户端公式字段（只读+必填）**的表单 api 通道结构性走不通
  （铁路 D-19：服务端不执行前端公式 → 带值=只读禁改 / 缺值=必填拒）——该类流程用
  `FLOWTEST_RUNNER=browser`；老系统阵发超时调 `FLOWTEST_HTTP_TIMEOUT`（实测 60s）；
- 新系统（current）端点已按 frontend/src/api 实测预填（todo.flowCodePath=flowCode 已配）；
  老系统（legacy）配置为 schema 占位，填法见文件头注释（F12 Network 录一次"登录→发起→待办→表单→提交"）。

**选人与提交载体实战规则**（第三十三轮·港口煤全链贯通实证，机制详见 lessons L33~L35）：

- **同名多候选**：老系统人名库存在同名多 user_id（3 个「侯丽娟」实锤）——systems
  `assignee.prefer_ids: {归一化姓名: 实值ID}` 指认（ID 从被测系统 whoami 探针取，零猜测）；
  无指认 resolve_assignee **fail-closed 返回 None**（原值透传由被测系统判定），绝不盲取首个；
  姓名比对前归一化剥全部内部空白（候选「高 鹏」vs 场景「高鹏」）；
- **编码空间不对称**（DMN 路由流程）：submit.nextStep 只认 routeCode（环节码），
  next-assignees.nodeCode 只认 taskElementId——resolve_assignee 候选空时用 workbench
  `nextNodes`（routeCode→taskElementId）回退翻译；此类流程 **不配 route_map**；
- **SUBMIT 不落业务表单**：execute-button SUBMIT 按已保存 revision+本次 formPatch 合并做必填
  校验，patch 空=恒拒。三层配置：填单步 `submit.save_with_form_data: SAVE_FORM`（先落
  revision）、无填单步 `submit.echo_form_patch: true`（workbench 当前表单整体回显）、
  载体=formData(Map)（勿发明 formPatch 顶层键——DTO 无此字段静默丢弃）；
- **新流程接入 todo.map**：stepCode 映射从引擎库部署 BPMN 实查
  （`xyls_engine.act_ge_bytearray` join `act_re_procdef` 取最新 version 的 XML 解析 userTask id），
  **勿用项目内 BPMN 文件**（与运行时 elementId 不一致，港口煤实锤：本地 task_218 系 vs 运行时 task_3117 系）。

## 6. 通道选择与布局

**执行产物布局**（第三十轮）：单 run 单目录，多轮同放——

```
<项目>/docs/<流程名>/自动化测试/对比测试/
└── run-<ts>/                       # exec=report 合一（RUN_EXEC_DIR==RUN_REPORT_DIR）
    ├── 对比测试报告.md              # 机器最终交付（gen-final-report.py 自动汇总 9 节；1.3.4 起生成前证据链核验）
    └── 人工发现.md                  # 人工产品级发现（首次自动建模板，机器永不覆盖）
    ├── screenshots/{legacy,current}/s<seq>_<node>_{form,submitted}.png   # browser 通道逐环节截图
    ├── field-captures/{legacy,current}/<case>.json
    ├── case-results.json / field-compare*.json / gates.json
    └── run-manifest.json / summary.json / summary.md
```

流程名取契约路径 `docs/` 下首段；无契约（legacy 兼容模式）回退 `$RUNTIME_DIR/reports/`。


```bash
FLOWTRACE_RUNNER=api   # 默认：内置 api 采集（systems api 配置 + 可达服务）
FLOWTRACE_RUNNER=cli   # 兼容：显式 FLOWTRACE_CLI=<path>，接口以该 CLI 为准（采集仍过三重校验）
FLOWTRACE_RUNNER=none  # 无后端 → 全部 BLOCKED（诚实阻断）
```

同一套脚本支持两种部署布局（pipeline.sh 自动探测；env 可覆盖）：

| 布局 | scripts 位置 | templates 位置 | 项目根解析 |
|---|---|---|---|
| 项目部署（install.sh 后） | `<root>/.flow-test-contract/scripts/` | `<root>/docs/自动化测试模板/` | 脚本位置推导 |
| skill 自持 | `<skill>/scripts/` | `<skill>/templates/` | `FLOWTEST_PROJECT_ROOT` 或 cwd git 根 |

## 7. DB 通道（规划中，未实现）

对已迁移实例对（write-manifest `--instance-pairs`）直接从老库（qianyi）与新引擎库抽字段产同构
capture——覆盖"存量迁移语义一致"，零执行依赖；须保持本文件 §3 契约与 §4 采信铁律不变。

## 8. 健康检查（health-check.py，第十三轮·P1）

- 门禁端点**由契约声明**（environments.health_checks，curl 描述串：url + `# expect N`），
  不再硬编码——环境可移植；
- 只采信 url/expect，固定 curl 参数重发，**不 eval 契约字符串**（任意命令串 → exit 2）；
- 契约缺 health_checks → exit 2（fail-closed）；产物并入 gate-evidence-check 的自动 gate 集。

## 9. 回归锚点（selftest BB1-BB8 + CC1-CC5）

- BB1 launch-first 全链 → PASS 且他流程 decoy（同 node 同办理人）未被采/提交；BB1b 缺元素 ID → BLOCKED；
- BB2 服务不可达 → BLOCKED；BB3 凭据 env 缺失 → BLOCKED；BB4 systems 配置缺失 → BLOCKED；
- BB5 `FLOWTRACE_RUNNER=cli` 无显式 CLI → BLOCKED（不再盲探）；
- BB6 api capture 直供 field-level-compare → OK（同构性）；
- BB7 reuse（显式 instancePolicy）只采本流程待办不碰 decoy；BB7b reuse 缺 flowCodePath → BLOCKED；
- BB8 health-check 契约驱动正负（可达/不可达/非 curl 串/缺 health_checks）；
- **CC1-CC4 补齐占位防御**（[references/f12-record.md](f12-record.md) 老系统 F12 录端点）：
  CC1 残留 `__F12_RECORD__` → legacy-config-check exit 1 + 清单；CC2 全清 → exit 0；
  CC3 任意一侧含占位 → runner 立即 BLOCKED（绝不假跑）；CC4 全填 + mock legacy → 端到端 PASS；
- **CC5 目标缺失 fail-closed**（第二十三轮）：legacy-config-check 目标文件不存在 → exit 2
  （此前"跳过"仍 exit 0——路径打错得到假绿）。

## 10. 老系统端点补齐（[references/f12-record.md](f12-record.md)）

- legacy.yaml 用 `__F12_RECORD__` 显式占位（每个待录字段同行有 `TODO: __F12_RECORD__` 注释指引）；
- api-capture 启动时检测任一占位即拒（exit 2 → runner BLOCKED，绝不假跑）；
- `legacy-config-check.py` 扫描占位残留并输出**可粘贴到 issue 的待录清单**（path + 同行 TODO 注释）；
- 录完所有 5 个端点（login/todo/launch/form/submit）+ 写 `LAUNCH_ELEMENT_ID_<FLOW_CODE>` env → legacy 端到端可跑通。
