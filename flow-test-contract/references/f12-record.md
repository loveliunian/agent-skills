# F12 录老系统端点 · 操作手册（让 api-capture 跑通的最后一步）

> 目的：把 `systems/api/legacy.yaml` 里所有 `__F12_RECORD__` 占位符替换为真实端点 + JSONPath，
> 让 api-capture 走完 launch-first + 实例隔离 + 流程身份绑定的全链。
>
> 路径约定（双布局）：下文 `<scripts>` 默认指 skill 自持脚本目录
> `~/.agents/skills/flow-test-contract/scripts`（项目部署布局为 `.flow-test-contract/scripts`）；
> `systems/api/legacy.yaml` 属运行态：skill 布局在 `$SKILL/runtime/<项目键>/systems/api/`（项目部署布局在 `<项目>/.flow-test-contract/runtime/systems/api/`）。
>
> 全程 0 编造：所有值都从老系统浏览器 F12 Network 抓，不带任何"推测"成分。
>
> 用时预估：首次 20–30 分钟（含登录→待办→发起→表单→提交 5 个端点 + 6 处 JSONPath），
> 后续系统迭代只改 path/field 名，<5 分钟。

## 0. 准备

- 浏览器：Chrome / Edge / Firefox 任一（Chrome 推荐——Network 面板最详细）
- 老系统可访问：`http://<legacy-prod-host>`（若非此地址，先确认 `<runtime>/systems/api/legacy.yaml` 的 `api.baseUrl`）
- 一份可访问老系统的账号（`$RUNTIME_DIR/env` 中 `LEGACY_<账号大写>_USER` / `LEGACY_<账号大写>_PWD`）
- 检查占位清单：`python3 $SKILL/scripts/legacy-config-check.py --systems <runtime>/systems/api/legacy.yaml`
  → 打印 `__F12_RECORD__` 残留字段与所在路径（每次改完重跑确认）
- playwright-cli 命令参考（CLI 实测口径，2026-09-08）：`requests` 列请求、`request <n>` 详情、
  `request-body/response-body <n>` 取载荷/响应、`eval` 页面上下文取数。
  （旧手册写的 `network` 命令在当前 CLI 版本不存在——以 `requests` 为准。）

## 0.1 复杂登录形态 → 原生 login.chain（第二十一轮，免适配器）

若老系统登录是**多步链/加密密码/302 带 token**（如李雅庄老系统：MD5(password)大写 → RSA/PKCS1v1.5
→ POST auth/accessCode → GET sso/login 302 Location 携带 token），不再需要手写适配器——
用 `login.chain` 配置直接表达（完整实录实例见运行态 `<runtime>/systems/api/legacy.yaml`（自项目 .flowtrace 迁入 skill runtime）——
李雅庄项目运行态；skill 自带 `assets/systems-api/legacy.yaml` 为简单登录的占位形态示例，
chain/ledger 字段按本节样例与 api-capture 头注释补）：

```yaml
api:
  rsaPubB64: "MIGf..."                 # 前端 JS 内嵌公钥（SPKI base64）
  whoami: {path: /api/.../getUserInfo, namePath: data.name}   # 显示名（账本 owner 匹配用）
  login:
    tokenHeader: authorization         # 实测鉴权头（裸 JWT 无 Bearer 前缀时 tokenScheme: ""）
    tokenScheme: ""
    chain:
      - method: POST
        path: /api/.../auth/accessCode
        body: {account: "${USERNAME}", password: "${PASSWORD|md5_upper|rsa_pkcs1|uri}"}
        saveAs: CODE
        savePath: data.code
      - method: GET
        path: "/api/.../sso/login?clientId=10001&code=${CODE}"
        noFollow: true
        tokenFromRedirectQuery: token
```

可用变换：`md5_upper / md5 / sha256 / b64 / uri / upper / lower / rsa_pkcs1`（管道可串联）。
配 `todo.mode: ledger`（待办账本：launch/submit 响应组装——适合"待办列表不暴露未保存实例"的系统）。

## 1. 录 login（登录态获取）

**F12 操作**
1. 打开 DevTools（F12 或 Cmd+Opt+I）→ 切到 **Network** 面板 → 勾 **Preserve log** 与 **Disable cache**
2. 在老系统登录页 `http://<legacy-prod-host>/#/login` 输入账号密码 → 点登录
3. Network 列表里找**第一个状态码 2xx 的请求**（通常是 `/api/auth/login` 或 `/api/login`）：
   - 双击打开 → 右侧 **Headers** 标签
     - **Request URL**（只看 path 部分）→ `login.path`
     - **Request Method** → `login.method`
     - **Form Data** 或 **Request Payload**（看是表单还是 JSON）→ 映射到 `login.body`
       （通常含 `username` / `password`；字段名不一致就改 key）
   - 切到 **Response** 标签
     - 复制整个响应 JSON → 在编辑器里格式化（`jq .` 或在线工具）
     - 找到 token 字符串的**完整点路径**（鼠标点响应字段会高亮→看左侧 Path）：
       - 例：`data.accessToken` / `data.token` / `result.token` / `token`（裸）
     - 写进 `login.tokenPath`

**填进 yaml**（示例值；以实际为准）

```yaml
login:
  method: POST
  path: /api/auth/login                # ← 真实 path
  body: {username: "${USERNAME}", password: "${PASSWORD}"}   # ← 按 Form Data 调整 key
  tokenPath: data.accessToken          # ← 真实 token JSONPath
  tokenHeader: Authorization           # 一般 Bearer；若老系统用 cookie/X-Auth-Token 改这里
  tokenScheme: "Bearer "               # 前缀（裸 token 则设为 ""）
```

## 2. 录 todo（按用户查待办）

**F12 操作**
1. 登录成功后 Network 仍在记录 → 进入主页/工作台（任何含"待办/任务/Todo"列表的页面）
2. 列表渲染时 Network 会发**一个 GET 请求**返回任务列表（通常 QueryString 有 `page`/`size`/`assignee`/`userId`）：
   - **Request URL** → `todo.path`（含路径前缀，去掉域名）
   - **Query String Parameters** → 映射到 `todo.params`（最常见 `{page: 0, size: 50}`）
3. 切 **Response** 标签 → 复制整个 JSON → 找到"任务数组"的 JSONPath：
   - 常见形态：`data.content` / `data.list` / `data.records` / `data.items` → `todo.listPath`
4. 展开数组里**第一项**的 JSON（点开列表项）→ 找到**这 4 个字段**的 key：
   - 任务 id（全局唯一）→ `todo.taskIdPath`（如 `taskId` / `id` / `bizId`）
   - 节点编码（与契约 `nodes[].code` 对齐）→ `todo.nodePath`（如 `stepCode` / `nodeCode` / `activityId`）
   - 流程实例号 → `todo.instancePath`（如 `flowInstanceNo` / `instanceNo` / `procInstId`）
   - 流程编码 → `todo.flowCodePath`（如 `flowCode` / `procDefKey` / `processKey`）
     > **必填**——`flowCodePath` 不配则 api-capture 在 reuse 模式或防御性流程身份校验时会拒

**填进 yaml**

```yaml
todo:
  method: GET
  path: /api/tasks/todo                # ← 真实 path
  params: {page: 0, size: 50}          # ← 按实际 QueryString
  listPath: data.content               # ← 真实列表 JSONPath
  taskIdPath: taskId                   # ← 实际 key
  nodePath: stepCode                   # ← 实际 key
  instancePath: flowInstanceNo         # ← 实际 key
  flowCodePath: flowCode               # ← 实际 key（必填）
```

## 3. 录 launch（发起新流程）

**F12 操作**
1. Network 仍在记录 → 找老系统的"发起新流程"按钮（一般在工作台顶部 / 左侧菜单）
2. 点开发起表单 → 选你的目标流程 → 点提交（实际录端点时挑任意一个流程——launch 端点对流程编码不敏感）
3. Network 找那个**带 `start` / `launch` / `process/start`** 路径的 POST 请求：
   - **Request URL** → `launch.path`
   - **Request Payload** → 映射到 `launch.body`（通常含 `flowCode` / `templateId` / `processKey` —— 哪个是流程标识改 body key）
4. **Response** 标签 → 找两个字段：
   - 流程实例号 → `launch.instancePath`（如 `data.instanceNo` / `data.procInstId`）
   - 首任务 id（可能为 `null`——老系统可能要先 todo 才能查到任务）→ `launch.taskIdPath`

**元素 ID（必填，独立于 F12）**
- launch 端点通常要一个**流程模板/要素 ID**（数字），它**不会出现在 F12 Network 列表**（是页面里下拉框的 value）
- 录法：F12 → Elements 面板 → 找到"流程模板"下拉/选项 → 看 `<option value="...">` 的 value → 复制
- 写入 `$RUNTIME_DIR/env`（按流程命名，**必填**）：
  ```bash
  # $RUNTIME_DIR/env 追加（注意 flow_code 大写+下划线）
  LAUNCH_ELEMENT_ID_<FLOW_CODE>=123   # 例：LAUNCH_ELEMENT_ID_WFA_RY_HZ_0162=42
  ```
- `api-capture` 启动时**自动**按 `flow_code` 选这条 env；缺即拒绝

**填进 yaml**

```yaml
launch:
  method: POST
  path: /api/flow/start                # ← 真实 path
  body: {flowCode: "${FLOW_CODE}"}     # ← 按 payload 调整
  instancePath: data.instanceNo        # ← 实际 JSONPath
  taskIdPath: data.taskId              # ← 实际 JSONPath（可能为 null）
  elementIdEnv: LEGACY_LAUNCH_ELEMENT_ID  # 回退 env（按需改）
```

## 4. 录 form（表单字段采集）

**F12 操作**
1. 回到待办列表（todo 录过的那个页面）→ 点开**任意一个任务**进入办理页
2. Network 找那个返回"表单字段"的 GET（通常 path 含 taskId 或 instanceNo）：
   - **Request URL** → `form.path`（保留 `${TASK_ID}` 占位）
   - 样例：`/api/task/12345/form` → 写成 `/api/task/${TASK_ID}/form`
3. **Response** → 找到"字段字典"（一个 `{字段名: 值}` 的对象）的 JSONPath：
   - 常见：`data.formData` / `data.fields` / `data.form.fields` / `result.fields`
   - **必须是一个 dict**（不是 list）——api-capture 会逐项作为 fields 喂给对拍器

**填进 yaml**

```yaml
form:
  method: GET
  path: /api/task/${TASK_ID}/form      # ← 真实 path（${TASK_ID} 保留）
  fieldsPath: data.formData            # ← 真实字段字典 JSONPath
```

## 5. 录 submit（办理提交）

**F12 操作**
1. 在同一个任务办理页 → 修改一两个字段 → 点提交按钮（一般叫"提交"/"保存"/"下一步"）
2. Network 找那个 POST 请求（path 含 taskId 或 instanceNo）：
   - **Request URL** → `submit.path`（保留 `${TASK_ID}` 占位）
   - **Request Payload** → 映射到 `submit.body`：
     - 按钮编码字段（通常 `buttonCode` / `action` / `btnKey`）→ body 对应 key（固定 `buttonCode: "${BUTTON}"`）
       实际按钮值看 button 控件的 value：Elements 面板找 `<button value="submit">` 或 onClick → JS 里的 magic string
     - 流转选人字段（若老系统支持，常见 `nextAssigneeId` / `nextUserId` / `toUser`）→ key `nextAssigneeId`
3. **Response** 标签 → 看状态码（一般 200 / 201）→ 加进 `submit.successStatus`
4. **defaultButton**：从 Request Payload 的 `buttonCode` 字段值复制，作为缺省按钮编码

**填进 yaml**

```yaml
submit:
  method: POST
  path: /api/task/${TASK_ID}/submit    # ← 真实 path
  defaultButton: 提交                  # ← 默认按钮编码（按 F12 实际值）
  body:
    buttonCode: "${BUTTON}"            # ← 按 payload 调整 key
    nextAssigneeId: "${NEXT_ASSIGNEE}" # ← 按 payload 调整
  successStatus: [200, 201]            # ← 实际成功状态码
```

## 6. 录 actorMap（actor → 环境变量名）

这一节**不需 F12**——按契约 `accounts[]` 逐条加：

```yaml
actorMap:
  renna1: {username: LEGACY_RENNA1_USER, password: LEGACY_RENNA1_PWD}
  # 一条 actor 一行；缺哪条补哪条
```

⚠️ env 名规范：`LEGACY_<账号大写>_USER` / `LEGACY_<账号大写>_PWD`；`$RUNTIME_DIR/env` 中须有真值（密码键缺失时仅在 `FLOWTEST_ALLOW_DEFAULT_PWD=1` 下可用 `FLOWTEST_DEFAULT_PWD` 兜底）。

## 7. 验证清单

跑完上面 5 步，再做：

```bash
# 1) 占位应全部清空
python3 $SKILL/scripts/legacy-config-check.py --systems <runtime>/systems/api/legacy.yaml
#   期望：✅ 无残留占位（__F12_RECORD__），可启动 api-capture

# 2) 端到端 dry-run（不真发请求；pipeline 会跑 legacy-config-check 校验配置/占位/结构）
bash $SKILL/scripts/pipeline.sh --contract <your-test-contract> \
  --scenario-dir <生成件/flowtrace-scenarios> \
  --rules <生成件/compare-rules.json> --dry-run

# 3) 真实执行（先确保 $RUNTIME_DIR/env 含 LEGACY_* 与 LAUNCH_ELEMENT_ID_<FLOW_CODE>；
#    pipeline 自动加载，无需 source）
bash $SKILL/scripts/pipeline.sh --contract ... --scenario-dir ... --rules ...
# 期望：docs/<流程>/自动化测试/对比测试/<run-id>/summary.json PASS / FAIL / BLOCKED——三态都诚实
```

## 8. 常见卡点速查

| 现象 | 排查 |
|---|---|
| api-capture 启动拒 "含 F12 录端点占位符" | `legacy-config-check.py` 查占位清单 |
| login 返回的不是 token 而是 cookie | `login.tokenHeader: Cookie` + `login.tokenScheme: ""`（cookie 不用 Bearer 前缀） |
| 找不到 todo GET 请求 | 主页可能用单个 Vue 组件渲染不出独立 API；试 Network 过滤 `XHR` 或翻页/切 tab |
| todo 列表为空 | 登录账号没在老系统里有待办；换个账号重试 |
| launch 端点 POST 后 redirect 302 | 老系统可能用 redirect 模式——F12 Network 选"Preserve log"会保留那条 302 → 找其 Location 头对应的真正端点 |
| form 返回的不是 dict 而是 list | `fieldsPath` 调对 list→{field: value} 的 JSONPath（老系统可能 `data.fields[*].value`） |
| 提交后无明显响应（200 但 body 空） | 正常——`successStatus: [200, 201]` 覆盖；如 204 也加上 |
| launch 元素 ID 不知道值 | DevTools → Elements → 找发起表单里的"流程模板"下拉 → 复制 `<option value="...">` 的 value |

## 9. 录完后

- 在 `$RUNTIME_DIR/env` 顶部加一行注释（哪天 dev 接手时知道这文件怎么来的）
  ```bash
  # 老系统 API 端点配置：<runtime>/systems/api/legacy.yaml（按 references/f12-record.md 录）
  LAUNCH_ELEMENT_ID_<FLOW_CODE>=<number>
  LEGACY_<ACCOUNT>_USER=<account>
  LEGACY_<ACCOUNT>_PWD=<password>     # 凭据只放 runtime env（绝不入库/同步；只在此处可读）
  ```
- 把 `legacy.yaml` + actorMap 增补的 actor + `$RUNTIME_DIR/env` 凭据键**作为一份 atomic 变更同步落地**
  （runtime 属私有运行态，绝不入库——atomic 指三处同一次录制会话内一致）
- `references/adversarial-regression.md` 无需改（第十三轮审计行已涵盖）
- 出错回看：跑 `legacy-config-check.py` 看清单 + 跑 `selftest.py` 验证负向回归全绿

## 10. 按钮语义原语 operations（第三十五轮 v1.3.5 补录；李雅庄老系统已实证）

五原语之外，退回/作废类按钮在本类老系统（霍州结算）是**独立端点与载荷**——
把退回编码成 commitWorkflow 的 next_step 会被服务端拒「所选环节并不可用范围」
（2026-09-10 铁路 C-03/04/06/07 实测根因）。取证方式=前端 JS 包全量扫描
（`chunk.app.*.js` 1757 个端点字面量）+ 调用点上下文 + 真实探针，双源互证：

| 按钮（UI 词表） | 端点 | 载荷 |
| --- | --- | --- |
| 退回流程（G5） | `POST /api/swan-cloud-settlement/workflowManage/backWorkflow` | `{WorkflowFlag{FlowInsCode,StepInsCode}, backStepInstanceId, backDesc}` |
| ↳ 目标列表 | `POST …/getWorkflowInstanceRecordsBack2` `{WorkflowFlag}` | → `data.stepInfo[]`：`{stepCode, stepInstCode, stepName, operUser, instCode, beforeStepCode…}`（**列表非按时间序**——按 stepCode 字段匹配，恰一命中） |
| 作废流程（G6） | `POST …/workflowManage/cancelWorkflow` | `{WorkflowFlag, reason}`（弹窗强制 reason） |
| 退回至矿点（G5b） | `POST …/workflowManage/backWorkflowMine` | `{WorkflowFlag, back_step_instance_ids(逗号串), reason(逗号串), back_descs(逗号串)}`；⚠️「退回至矿点此流程将会作废」——矿点从待启动重新发起，**跨实例语义**，operations v1 不覆盖 |
| 退回至待启动 | `POST …/workflowManage/backWorkflowStart` | `{WorkflowFlag, reason:""}`（同样作废本实例） |
| 撤回流程 | `POST …/workflowManage/withdrawWorkflow` | `{WorkflowFlag}` |
| 作废申请/审批 | `applyCancelFlow {instCode, cancelReason}` / `approvalCancelFlow` | 两步审批链（v1 不覆盖） |
| 退回后新任务重定位 | `POST …/workflowManage/getCurrentUserProcessList` | 全 30 键参数形态见 assets/systems-api/legacy.yaml 注释；响应行 122 字段，关键=`instCode`(FI 实例码)/`instanceNo`(单据号)/`stepInstCode`(SI 任务)/`flowInstCurrStep`(当前环节)——**无办理人姓名字段**（账本空 owner 通配的设计依据） |

配套实录（探针 2026-09-10）：
- `WorkflowFlag = {FlowInsCode, StepInsCode}`，FlowInsCode=**FI 风格实例码**（待办行的
  `instCode` 字段），非单据号 `instanceNo`（JMHZLY 风格）——拿单据号查 RecordsBack2 会报
  「未查询到当前流程实例信息」；
- 老系统实例状态词表：进行中=1、已完成=2、已结束=3、**已退回=4**、已挂起=5、**已作废=9**；
- 中间环节（如 13 质量单负责人）无 CANCEL 按钮（按钮=服务端按环节配置
  `flowCollectManage/buttonAndDataConfigInfo` + 前端 viewModel 过滤）——作废只能回到
  配有该按钮的节点（00）或管理端通道。

operations 块的完整配置形状见 `assets/systems-api/legacy.yaml` 注释（含
backTarget/refetch 解析器三态负向回归：selftest G7a~G7f）。
