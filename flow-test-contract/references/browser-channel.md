# browser-channel —— 浏览器通道契约（browser-capture.py，双系统同构）

> 读者：需要用真实浏览器跑契约场景（可见过程/复核 UI 行为）的实现者与审计者。
> 本通道把「老系统浏览器对比测试」数十轮实战 SOP 固化为配置驱动脚本；与 api 通道
> （api-capture.py）完全同构——同场景输入、同 capture 契约、同采信铁律。

## 1. 什么时候用浏览器通道

| 通道 | 适用 | 不适用 |
|---|---|---|
| api（默认） | 常规双端对拍、CI、批量回归 | 老系统接口未实录 / 需人工目击 UI 行为 |
| api（禁用场景） | — | **含客户端公式字段（只读+必填）的表单结构性走不通**（铁路 D-19：服务端不执行前端公式，带值=只读禁改 / 缺值=必填拒，建议服务端回填修复） |
| **browser** | UI 行为对比（弹窗/选人/日期面板）、演示可见过程、api 打不通的按钮流（盖章/弹窗选数）、**含客户端公式字段的表单** | 大规模批量（浏览器慢） |

## 2. 快速上手

```bash
SKILL=~/.agents/skills/flow-test-contract
# 0) 前置：node（playwright-cli）；凭据经 $RUNTIME_DIR/env（自动加载）或显式授权
#    FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 兜底
#    正式运行（非 --drill/--dry-run）必须锁 CLI 版本——否则 fail-closed 拒跑：
#    export PLAYWRIGHT_CLI=/path/to/pinned/playwright-cli   # 已固定版本的本地工具
#    （未配置且无本地包装脚本时只有演练/探针可用 npx latest；npx 联网下载+版本漂移=正式 PASS 不可复现）
# 1) 配置落到项目运行态并录制（legacy 已实测可直接用；current 需 UI 录制）
RUNTIME=${FLOWTEST_RUNTIME_DIR:-$SKILL/runtime/$(basename "$PWD" | tr -c 'A-Za-z0-9._-' '-')-$(printf %s "$PWD" | md5 -q | cut -c1-8)}
mkdir -p $RUNTIME/systems/browser
cp $SKILL/assets/systems-browser/*.yaml $RUNTIME/systems/browser/
# 2) 配置校验（占位/凭据 env；零副作用）
python3 $SKILL/scripts/browser-capture.py --check-config --systems $RUNTIME/systems/browser/legacy.yaml
# 3) 只读探针（登录+导航，不触数据；headed 可见浏览器）
python3 $SKILL/scripts/browser-capture.py --probe --systems $RUNTIME/systems/browser/legacy.yaml --headed
# 4) 执行契约场景（双端 browser 采集）
FLOWTRACE_RUNNER=browser bash $SKILL/scripts/pipeline.sh --contract <契约> --skip-parse
# 或单独跑 runner：
FLOWTRACE_RUNNER=browser python3 $SKILL/scripts/run-contract-scenarios.py \
  --scenario-dir <生成件/flowtrace-scenarios> --exec-dir <exec> --run-id <id>
```

## 3. systems browser 配置 schema（assets/systems-browser/ 为范本）

```yaml
id: legacy                    # 侧名 → field-captures/<id>/ 子目录
channel: browser              # 必填，非 browser 拒跑
browser:
  baseUrl / session / profile / headed / loginWaitSeconds / cliTimeoutSeconds
  taskWaitSeconds             # 提交后下一节点待办轮询窗口
  switchAccount: close-reopen # 铁律：JWT 切号=整浏览器关开（同 profile）
  whoamiContains              # 登录成功标识（页面标题）
  instancePattern             # 实例号正则（从页面文本提取，绑定后续步骤）
  login: {userRef, passRef, submitRef}   # 静态 ref 可写死；删掉则探针兜底（前2 textbox+末按钮）
nav: {flowMenu, launchItem, todoItem, handleButton, launchButton, fallbackMenu{parent,item}}
form: {saveButton, nextNodeLabel, submitButton, confirmButton, autoConfirmPopups,
       datePanelTrigger, forms: {<节点码>: {popupSelect|datePanel|textboxes|popupSop}}}
popups: {<sop名>: {openButtonContains, resetButton, queryButton, waitSeconds, usedMarker}}
handlerPick: {enabled, mode: textbox|button, triggerLabel, handlerLabel}   # G3.3（mode 缺省 textbox；button 模式 handlerLabel 检测已预选处理人）
nodeNames: {<环节码>: 环节显示名}         # 选环节匹配
actorMap: {<actor>: {username: ENV, password: ENV}}   # 凭据零明文
```

- 探针纪律：任何解析值含 `__UI_RECORD__` → 拒跑（与 api 通道 `__F12_RECORD__` 同纪律）；
- 探针匹配 = a11y 快照行正则（`menuitem "…名"`、`button "…名"`、`textbox "请输入"` 序号等），
  **动作前一律重新快照解析 ref**（ref 随快照失效）。

## 4. 实战 SOP（已编码进脚本，配置化触发）

| SOP | 触发 | 行为 |
|---|---|---|
| **G3.1 数据弹窗** | `forms.<node>.popupSop: s95306` | 打开→重置→清日期→查询→等 waitSeconds(8~10s)→跳过含 usedMarker 行选第一个未使用→确定 |
| **G3.3 处理人补选** | `handlerPick.enabled` | 选环节后若处理人下拉为空→点开选第一候选（否则提交静默失败）；`mode: button`（李雅庄公路 WFA_HY_HZ_0150 实测）处理人为工具栏按钮「选择处理人」→点击弹组织/角色/用户三面板（默认预选首候选）→点面板「确定」；`mode: textbox`（缺省）为原下拉文本框型 |
| **G3.4 无菜单账号** | `nav.fallbackMenu` | 待办导航走「结算处理→港口待处理结算」；发起无 fallback（必须菜单） |
| **G3.5 老系统对话框选数（Vue 组件注入）** | 老系统选择合同/磅房/执行单弹窗 | 合成事件勾选不可靠（lessons L27）——从 `wrap.__vue__.$parent` 链找业务组件（contractDialog/customDialog/sheetDialog），把 `.el-table.__vue__.data` 的行对象直接赋 `_data.multipleTableVal`（合同类补 `_data.clickVal=[]`），调 `sure()`。**行对象必须带 sure() 过滤器字段**：磅房 `STATUS==='未使用'`（无此字段被静默过滤）、合同 `qzzt`（双签态）、执行单 `id`（写 DATA_CN_IDS），否则过滤后 0 行=「请选择一条数据！」或「缺少必要参数」 |
| **G3.6 老系统发起与提交流程** | 老系统 nav/form 配置 | 发起列表**点行/点流程名不触发**——勾选行复选框后点页面级「启动流程」按钮；提交三件套：①先工具栏「选择处理人」（getUserByOrgRole → 请选择用户对话框选人），否则 toast「请选择处理人」；②「保存单据」成功后调 `identification()`（updateStepHtwjSaveResult 注册合同文件，跳过=提交报「合同文件未保存成功」）；③「未生成文件，确定要提交流程?」确认框的确定按钮**在容器内查找**（先按特征文本定位 dialog：`[...document.querySelectorAll('.el-dialog')].find(d => d.textContent.includes('未生成文件'))` 再取其中确定）——僵尸弹窗堆积时全局找"确定"会点错 |
| **00 日期陷阱** | `forms."00".datePanel` | 日历面板点选（键入不进模型→FYRQ undefined→提交恒置灰） |
| **老系统表单日期=Vue 模型直写** | 老系统有服务端日期窗校验的表单 | el-datepicker 键入/合成事件都不进模型（`form_data.TBRQ/KSFYSJ/JSFYSJ` 仍旧值，服务端按旧值校验「拉运日期不在合同有效日期」）——可靠修法=找 `pendingSettlementHandle` 实例直接写 `_data.form_data.<FIELD>`；日期窗口必须落在已选合同的签约期内（老系统强校验，见 lessons L27/L28） |
| **老系统一气呵成纪律** | 老系统全程 | 保存未提交的发起句柄 **reload 即永久丢失**（暂存孤儿：发起列表/草稿箱/进行中/待办均不可见）——中途刷新=丢弃重来；每步前清 `.el-message` 防旧 toast 混淆判断 |
| **同人自动流转** | `autoConfirmPopups` | 提交确定后追加弹窗自动确认 N 次 |
| **JWT 切号** | `switchAccount: close-reopen` | 账号变化即整浏览器关开（同 profile），免登出不可靠问题 |
| **默认处理人陷阱** | 提交前回读 | 选人弹窗按首组织首用户预选，**可落别家人员**（水峪默认=沙曲张冲实锤）；多候选默认空→静默失败 |
| **老系统=生产环境** | 执行纪律 | <legacy-prod-host> 是生产库——最小占用、用后释放、残留登记；只读探针优先 |
| **宿主守卫（并行会话串扰）** | 多 agent 共用一台机器 | 另一会话可能把你的 tab 导航走（G3.1 同款事故三连：老系统页两次被导航到新系统）；每个 eval 块首行内嵌 `if (location.host !== '期望host') return 'WRONG_HOST'`，操作打包成单块 mega-eval 压缩抢屏窗口；被抢后按已验证路径重新导航即可（登录态在 localStorage 存活）；发现 parallel 会话的 sock（`~/.agent-browser/*.sock` 多个）即启用守卫；**实测两轮并行各自零实例互染** |
| **老系统提交被合同文件注册阻断 = 治理侧缺口** | G3.6 ②被拒 | 「提交失败，合同文件未保存成功」且 `identification()` 静默成功后仍拒 → 该合同的电子文件在服务端从未注册（生产数据缺口，前端不可解）——**判 BLOCKED 归因治理侧**，勿再反复重试选择/保存；备用合同（如 2026 年稀疏行）缺 id 字段会触发「缺少必要参数」且清空 DATA_CN_IDS，反而更糟。转投：业务补合同文件，或要求提供带电子文件的测试合同 |
| **G3.7 提交确认弹窗时序与告警中止** | 老系统「未生成文件，确定要提交流程?」 | 确认弹窗渲染慢 **2~5s**——提交后循环检测须「点到弹窗→确定→**连续 3 轮无可见确认按钮才收尾**」（单次 sleep 后查一次=弹窗未起误判成功）；循环内**先检测业务告警**（「请选择一条数据！/此记录已被使用/请选择一行数据！」的「是的」按钮）→ **立即中止自动化**（乱点确定会数十次循环污染页面状态，弹窗组件进坏态）；每步提交后回读「当前环节」文本验证流转——无弹窗无 toast 且环节不变=**静默失败**（多候选未选处理人/数据被占用的典型表现）。参考实现：项目内 `pcm_legacy.py`（港口煤 23 分支逐支跑链 CLI，login/launch/fill00/picknext/save/submit/todo/opentodo） |
| **G3.7a 95306/磅房弹窗勾选可靠路径（agent-browser eval）** | 老系统数据选择弹窗勾行 | DOM 合成点击（checkbox inner/label/input）**不回写 Vue 选中模型**（`is-checked` 翻转但 selection-change 不触发）；可靠解法=调表格 Vue 实例：可见弹窗作用域（wrapper 是 position:fixed，**offsetParent 恒 null——用 `style.display!=='none'` 过滤**，否则勾到隐藏模板表格）内取 `.el-table` 的 `__vue__`，`toggleRowSelection(vu.data[0], true)` 后点确定（港口煤 B-02/B-03/B-05 三支实证，与 G3.5 的 multipleTableVal 注入同源同理，element-ui Table 自带该 API）；数据行先按「95306状态=未使用」过滤——历史轮次的"未使用"已被消费，不过滤=服务端拒「存在已经被其他流程使用的95306数据」 |
| **G3.7b 显示名≠账号；页内导航纪律** | 多办理人链路切号 | 选人面板抓到的处理人是**显示名**（张冲），与分支表账号（张泽 hmzhangze）可能不同人——切号前按显示名核对实际账号（老系统 sys_user.display_name ≠ account）；agent-browser `open()` 是真导航会**杀 SPA 登录态**（白屏），页内切换一律 `location.hash='#/...'`，真导航后必须重登；agent-browser daemon 偶发 EAGAIN（`Resource temporarily unavailable`）——sleep 自愈或 `close` 重开会话 |

## 5. capture 契约（与 api 通道 §3 同构）

```json
{ "run_id": "…", "case_id": "C-01", "flow_code": "WFA_RY_JM_126001",
  "side": "legacy", "instance_no": "JMFXZXK001884", "fixture_pairs": [],
  "steps": { "s1": { "fields": {"t3": "古交"}, "routing": {"selected_next": "01", "submitted": true},
                     "buttons": ["保存单据", "提交流程"] } },
  "channel": "browser" }
```

- **逐环节截图**（第三十轮）：browser 通道每步自动存 `screenshots/<side>/s<seq>_<node>_form.png`
  （填单后）与 `_submitted.png`（提交后），随 run 目录落 `docs/<流程>/自动化测试/对比测试/`；
  `browser.screenshots: false` 可关；
- fields 键为位置序（`t1..tn` 有值 textbox）+ 配置读回；api 通道字段名对拍需 compare-rules
  按 fixtures/routing 维度消费（fields 名映射见 compare-rules `exemptions` 或后续 readbacks 扩展）；
- instance_no 全程强制：launch 后首个待办行文本提取，s≥2 任务查找绑定该实例（防误触他流程）；
- 采信铁律同 §4（capture-channels）：清残留 / mtime 时间窗 / 身份三要素 / 实例绑定。

## 6. fail-closed 行为清单

| 情形 | 行为 |
|---|---|
| 配置缺失 / channel≠browser / 占位残留 | exit 2，不开浏览器 |
| 凭据 env 缺失 | exit 2（BB3 同纪律），不开浏览器 |
| 元素探针未命中 / 无未使用行可选 | exit 2 不落 capture（半执行绝不误判 PASS） |
| 全程未取得 instance_no | exit 2 不落 capture |
| systems/browser 目录缺配置 | runner 全场景 BLOCKED（不伪造执行） |
| 正式运行（FLOWTEST_FORMAL_RUN=1）未配 PLAYWRIGHT_CLI 且无本地包装脚本 | exit 2/BLOCKED——禁用 npx latest 回退（未锁版本=不可复现，1.1.0）；演练/探针不受限 |

## 7. UI 录制手册（新系统 / 老系统 UI 改版后）

1. `--probe` 起 headed 浏览器登录，观察失败点；
2. 用 playwright-cli `snapshot` 看目标元素的 a11y 行（`menuitem/button/textbox "名" [ref=…]`）；
3. 把实测**名称文案**（不是 ref——ref 每次快照都变）填进 systems browser yaml 对应探针；
4. `--check-config` → `--probe` 回归直至全绿；老系统 login 静态 ref（e11/e17/e31）若失效，删
   `browser.login` 块走探针兜底。

## 8. 已知边界（诚实声明）

- 弹窗行选择按「跳过 usedMarker」启发式；复杂配对（fixture_pairs 指定行）尚未支持；
- fields 采集为有值 textbox 位置序，字段级语义映射待 readbacks 扩展；
- 新系统（current.yaml）为 UI 录制骨架，录制完成前 browser 后端对 current 侧诚实 BLOCKED；
- selftest（BB9）只覆盖结构/负向路径；真实浏览器 E2E 用 `--probe` + 单用例 `--cases C-01` 验证；
- **老系统配置化范围外**：G3.5/G3.6 的 Vue 组件注入路径当前是 agent-browser eval 手工 SOP
  （李雅庄 09-09 实证可用），尚未编码进 browser-capture.py 的配置驱动——老系统新流程执行按
  §4 对应 SOP 手工套用；编码化列入待办；
- 老系统公式写入顺序分叉（A.1 首笔煤种 vs A.5 归类值谁覆盖谁）：同输入双端 PZ 不同值，
  属行为差异非缺陷——对拍时按"可归因差异"表述并提请产品确认口径（lessons L30）。
