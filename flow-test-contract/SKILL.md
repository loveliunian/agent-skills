---
name: flow-test-contract
version: 1.7.5
description: Use when：老/新双系统流程迁移需要对比测试并出正式 PASS/FAIL/BLOCKED 结论、生成测试契约/场景/环节表、api 或浏览器通道双端执行对拍、流程测试结果审计或断点复跑时。触发词：流程测试/契约测试/双端对比/flow-test-contract。
---

# Flow Test Contract（契约化流程迁移测试）· v1.7.5

> **v1.5.0 任务完成门（六门）+ v1.6.0 门槛收紧**：①**覆盖账本** coverage-manifest.yaml
>   （来源→契约 ref→维度→通道→状态；**深度校验**：covered 的 contract_ref 解析为 case/step
>   结构化引用并核对节点/维度/evidence 凭据——不能挂在任意合法 case 上；**两类 PASS 语义**：
>   未声明账本 = contract_scope_only（已声明契约范围），声明且全闭环 = full（全流程）；
>   新契约立契口径 validate --require-coverage 强制；相对路径按契约目录解析；
>   **v1.7.0 covered 深度绑定契约对象**（field→field_mappings / formula→公式 id /
>   button→buttons[node] / branch→routing / resource→resources——无对应合同维度不构成覆盖，
>   且 covered 必填 evidence）+ **来源库存**（source-inventory + source_hash 指纹挂靠，
>   import-inventory reconcile——"人工列出的集合已闭环"升级为"真实流程集合已闭环"）；
>   **promote 全链核验**（中性化重算 PASS + 契约哈希一致 + coverage full/partial 声明 +
>   case PASS + capture 通道一致——任意"PASS 目录"不再能关闭缺口）；手册
>   [references/coverage.md](references/coverage.md)）；
>   ②**浏览器只读探索** `explore-channel.py explore-browser`（截图+可见按钮/输入/候选 ref，
>   零点击零填写，产出 __UI_RECORD__ 候选 + 覆盖要素草稿——按钮流从"已知 BLOCKED"变显式
>   完成队列）；③**live readiness** `scripts/readiness.py`（两级判定 static_ready/task_ready：
>   按用例只读体检 + 覆盖账本闭环 + gate 证据需求 + 浏览器承载 + `--live-readonly` 登录/待办
>   活体检查——精确 BLOCKED 预估 + 责任域）；
>   ④**测试数据账本** `scripts/test-data-ledger.py`（pipeline 自动 init/record/close：
>   fixtures/resources **租约** claim→双端实例号→released/residual/**unknown** 三态——
>   released 须 --verify 确认资源真实释放（**结构化 check 白名单适配器** sql/http——
>   契约自由文本命令已移除，绝不执行任意 shell）；**跨 run 租约 registry**（claim 独占/
>   冲突拒绝/release 回收，readiness 探针同步）；账本 sha 经 write-manifest --extra-file
>   入证据链）；
>   ⑤**DRAFT 骨架** `scripts/draft-contract.py`（experience.yaml → 受控 DRAFT 契约 +
>   覆盖账本骨架，未覆盖项全 TODO，永不越权 TEST_READY）；
>   ⑥**重跑计划** `scripts/rerun-plan.py`（BLOCKED/FAIL → 责任域→动作→验证命令→新 run-id，
>   rerun_of 绑定源 run；只读预检可复用，绝不拼接历史 PASS）。
>
> **v1.4.0 双能力**：
> ① **对比结果人话化**——最终报告新增「一句话结论」、差异按用例分组、维度中文化 +
>   原因人话翻译（共享 `scripts/fc_readability.py` 唯一实现）；机器证据字段（json）零改动，
>   结论仍以 conclude_core 重算为准。
> ② **首次对比自由探索**——新流程冷启动先探索后立契：`scripts/explore-channel.py`
>   双端采集**点击（按钮）/选择（路由+办理人候选）/填写（表单字段与值）/公式计算（探针法）**
>   四类过程经验 → merge 产出经验库 `experience.yaml` + 人读 `立契建议.md`（同名/归一化同名
>   字段映射自动纳为建议、其余列待人工）。探索默认只读，写探索须显式 `--apply`
>   （launch-first 实例隔离）；**经验库是第四取证源（参考物），不是契约更不是结论**——
>   正式对比仍走既有立契→校验→生成→pipeline 链路。手册见
>   [references/exploration.md](references/exploration.md)。
>
> **既有能力**：场景 `step.button` 命中 systems `api.operations[<BUTTON>]` 时改发该按钮的
> **专属端点与载荷**（老系统退回=`backWorkflow`、作废=`cancelWorkflow`，独立于统一
> `commitWorkflow`），不再把退回/作废编码成 next_step 走提交（会被老系统拒「所选环节并不可用
> 范围」）。`backTarget` 解析器按 stepCode **恰一命中**退回目标（列表非时间序，多候选=诚实
> 失败）；`ledger: finish|refetch` 决定账本处置，`refetch` 按实例+环节重登记退回后新任务并支持
> 有限轮询。默认 `FLOWTRACE_RUNNER=api`（内置纯 HTTP 采集，双端执行不依赖外部工具）。
>
> **v1.3.6~v1.4.5 加固（fail-closed，细则见 [references/execution-gate.md](references/execution-gate.md)
> 与 [references/changelog.md](references/changelog.md)）**：operations schema 在任何登录/发起/
> 提交之前校验（键须字符串、refetch 定位键写前验证、严格业务成功谓词——success:0/"false" 即
> 失败，`submit.successValues` 可配置；retryOn 前置按钮失败禁止重试 SUBMIT）；reuse 待办必须
> 恰一命中（消歧选择器 instanceNo/businessKey/fixtureSelector 已入契约 schema 并由 gen 确定性
> 透传，支持 {legacy,current} 分侧）；表单预保存/retryOn 前置失败即拒；豁免强制八字段取证链 +
> 契约模式账本最小键；最终报告统计以 conclude_core 重算为准，`--allow-unverified` 只产草稿。
>
> **"不可篡改"的准确含义（威胁模型边界）**：防护对象是**工具误覆盖与单文件篡改**（同 run-id
> 拒绝重写、落账 sha 复算、结论复算、跨入口共享核验）；**不**防御对整个证据目录拥有写权限的
> 本地攻击者（其可同时改账本与证据并重算哈希）。若威胁模型包含本地写入者，需在 skill 之外叠加
> **只增账本/外部归档或签名**（如证据提交后推送只增存储/CI 副本校验）。
>
> **遗留边界（诚实保留）**：按钮流中 G5 退回/G6 作废已可经 `api.operations` 表达；其余——G5b
> 退回至矿点（跨实例语义）、选择合同/磅房/执行单、盖章链——的 API 自动化尚未实现，由浏览器通道
> 兜底（老系统四支全链办结实证）；但 browser 配置 `__UI_RECORD__` 尚未录制、凭据未实配——按钮流
> 相关用例在完成双端 UI 录制与真实验证前诚实 **BLOCKED**，不得产出该部分正式 PASS 结论；api
> 通道可覆盖的非按钮流全链不受影响（手册见 [references/browser-channel.md](references/browser-channel.md)）。
> 演练模式（--drill）产出仍不作为正式结论。

## 生命周期（勿越级）

```
取证三源（Excel / 老库 / 流程逻辑）不完整 → 只能 DRAFT（取证立契/生成/演练；禁止正式运行）
validate-contract --level test_ready 全过       → TEST_READY（才允许生成正式件与运行）
pipeline 真实 run（三态结论 + run-manifest 落账）→ EXECUTED（PASS/FAIL/BLOCKED，绑定 run-id）
```

## 自持与部署

- **唯一事实源 = 本 skill 目录**（标准安装 `~/.agents/skills/flow-test-contract`；其他 agent 的
  副本（codex/cursor/trae(-cn)/claude/hermes/cc-switch/continue/copilot/gemini/ghcp-appmod/
  qoder/roo/workbuddy）一律由 `sync-to-tools.sh` 同步，禁止单侧手改；opencode 为指向本源的
  符号链接，由 sync 脚本建链/校验）。**sync-to-tools.sh 不分发到任何副本——只能从源目录
  执行**（改副本无效且会被下次同步覆盖）。
  **改动本 skill 后必须重跑 `bash sync-to-tools.sh`；发布门禁 = `bash sync-to-tools.sh --check`
  退出码 0**（全部副本字节一致）。
- 全部资产以 [MANIFEST.txt](MANIFEST.txt) 为**唯一清单**（scripts+templates+assets 逐文件登记；
  install.sh 复制/校验与前置检查资产齐全校验均以其为准——勿在任何地方手写第二套文件列表）。
- **默认用法：直接运行 skill 内路径**（`$SKILL/scripts/pipeline.sh`…），项目内不留脚本副本。
  同一套脚本双布局可跑：skill 布局用 `FLOWTEST_PROJECT_ROOT`（或项目内 cwd git 根）定位项目根。
- 路径口径（**唯一面向用户的最终产物路径**）：
  - **执行产物**（截图/采集/账本/结论/最终 md 报告）→
    `<项目>/docs/<流程名>/自动化测试/对比测试/<run-id>/`（多轮对比同放一处；`FLOWTEST_OUTPUT_DIR` 可整体覆盖）
  - **通道配置与 gate 证据库**（systems api/browser）→ `$SKILL/runtime/<项目键>/`
    （`FLOWTEST_RUNTIME_DIR` 可覆盖；**私有配置目录，非交付物**），与旧 FlowTrace 流水线的
    `.flowtrace/` 彻底分离——.flowtrace 只属于旧流水线（flow-defs/scenarios/run-all-plants）。
- 可选：`bash "$HOME/.agents/skills/flow-test-contract/install.sh" [project-root]` 按 MANIFEST
  把副本部署进项目（`.flow-test-contract/scripts/` + `docs/自动化测试模板/`），供干净 clone 的
  CI 使用；`install.sh --check` 仅校验部署副本与源字节一致（零写入）。

## 前置检查（新会话先跑；任何 ✗ 即停，不继续）

```bash
PROJECT_ROOT="${PROJECT_ROOT:-${FLOWTEST_PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}}"
cd "$PROJECT_ROOT" || exit 1
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
ok=1
# 1) 依赖统一策略（第三十四轮 P1）：系统 python3 带 yaml+jsonschema 即用；缺则走 uv；
#    两者皆无 → 阻断（不再"uv 仅警告"，标准命令全部依赖其中一条路径）
FTC_PY=python3
if ! python3 -c "import yaml, jsonschema" 2>/dev/null; then
  if command -v uv >/dev/null 2>&1; then FTC_PY="uv run --with pyyaml,jsonschema python3"
  else echo "⛔ 缺 python3(yaml+jsonschema) 且无 uv——安装 uv 或 pip install pyyaml jsonschema"; ok=0; fi
fi
# 2) skill 资产齐全（以 MANIFEST.txt 唯一清单为准，含 assets；不手写文件列表）
#    清单本身缺失 → fail-closed（第三十五轮 P2：缺清单时 while 重定向静默零校验=假绿）
if [ -f "$SKILL/MANIFEST.txt" ]; then
  while IFS=$'\t' read -r f _; do
    case "$f" in ''|'#'*) continue ;; esac
    [ -f "$SKILL/$f" ] || { echo "⛔ skill 资产缺失：$SKILL/$f"; ok=0; }
  done < "$SKILL/MANIFEST.txt"
else
  echo "⛔ 缺分发清单：$SKILL/MANIFEST.txt（skill 不完整——重新同步/安装）"; ok=0
fi
# 3) 基础命令（node 仅浏览器通道需要，缺=警告不阻断）
for c in python3 curl git; do command -v $c >/dev/null || { echo "⛔ 缺 $c"; ok=0; }; done
command -v node >/dev/null 2>/dev/null || echo "⚠ 缺 node（仅浏览器通道 browser-capture 需要；api 契约模式不受影响）"
# 4) 项目根可定位（cwd git 根或 FLOWTEST_PROJECT_ROOT）
git rev-parse --show-toplevel >/dev/null 2>&1 || [ -n "${FLOWTEST_PROJECT_ROOT:-}" ] || { echo "⛔ 不在 git 项目内（设 FLOWTEST_PROJECT_ROOT 或进入项目目录）"; ok=0; }
# 5) 执行后端配置（api=默认自持通道；RUNTIME_DIR 本块自含解析——勿依赖其他块定义）
RUNTIME_DIR="$(bash "$SKILL/scripts/ftc-runtime.sh" resolve "$PROJECT_ROOT")"
if [ -f "$RUNTIME_DIR/systems/api/legacy.yaml" ] && [ -f "$RUNTIME_DIR/systems/api/current.yaml" ]; then
  if $FTC_PY "$SKILL/scripts/legacy-config-check.py" --systems-dir "$RUNTIME_DIR/systems/api" >/dev/null 2>&1; then
    echo "✓ api 通道配置就绪（端点可达性由运行时门禁/runner 诚实校验）"
  else
    echo "⚠ systems api 配置存在但占位/结构未过检查（F12 录端点未完成？）——契约模式执行将 BLOCKED"
    echo "  待录清单：$FTC_PY $SKILL/scripts/legacy-config-check.py --systems-dir $RUNTIME_DIR/systems/api"
    echo "  录端点手册：$SKILL/references/f12-record.md；示例起步：$SKILL/assets/systems-api/"
  fi
else
  echo "⚠ systems api 配置缺失（$RUNTIME_DIR/systems/api）——契约模式执行将 BLOCKED（从 $SKILL/assets/systems-api/ 起步拷贝，参考 $SKILL/references/capture-channels.md §5）"
fi
# 6) 负向回归快检（会话前置秒级；项数以 selftest 实际输出为准——完整"攻击向量→现口径"
#    总表见 references/adversarial-regression.md。版本发布/深度审计须跑全量：selftest.py --full）
$FTC_PY "$SKILL/templates/selftest.py" --quick || ok=0
[ $ok -eq 1 ] && echo "✅ 前置检查通过" || { echo "⛔ 前置检查失败——停止使用本 skill"; exit 1; }
```

## 工作流

> 下文 `$SKILL` = 本 skill 根目录。**每个命令块自含所需变量（SKILL/RUNTIME_DIR/FTC_PY），
> 可独立复制执行**；`$RUNTIME_DIR` 一律经 `ftc-runtime.sh resolve` 现算，勿依赖其他块的定义。

**0 流程环节表（可选；多分支总览/单分支明细，从老系统数据库直取）**：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
# 快照回退起草；正式以 DB 为准（--db legacy-oracle；结构不符/不可达 → BLOCKED，绝不猜测）
uv run --with oracledb python3 "$SKILL/templates/gen_flow_tables.py" \
  --flow <流程编码> --mode all --db snapshot \
  --snapshot <快照md路径> --outdir "docs/<流程名>/自动化测试/环节表"
```
两态产物/DB 表结构/列语义/主线规则见 [references/flow-tables.md](references/flow-tables.md)。

**0.5 首次对比先自由探索（v1.4.0；新流程冷启动强烈推荐）**：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml" 2>/dev/null || FTC_PY="uv run --with pyyaml python3"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME_DIR="$(bash "$SKILL/scripts/ftc-runtime.sh" resolve "$PROJECT_ROOT")"
EXP="docs/<流程名>/自动化测试/探索/explore-$(date +%Y%m%d%H%M%S)"
# 双端各探一次（默认只读；--apply 必须显式 --actor；--apply 默认 --advance none 不推进，
# 要推进显式 --advance first 且无候选办理人时须 --assignee——拒绝空办理人提交）
$FTC_PY "$SKILL/scripts/explore-channel.py" explore \
  --systems "$RUNTIME_DIR/systems/api/legacy.yaml"  --flow <流程编码> --outdir "$EXP" \
  --apply --actor <账号>
$FTC_PY "$SKILL/scripts/explore-channel.py" explore \
  --systems "$RUNTIME_DIR/systems/api/current.yaml" --flow <流程编码> --outdir "$EXP" \
  --apply --actor <账号> --fill
# 双端合并 → experience.yaml + 立契建议.md（人读；映射建议只作参考，契约仍须人工立契；
# 产物默认脱敏 #sha16:长度，--include-values 才保留原值且须放私有 runtime）
$FTC_PY "$SKILL/scripts/explore-channel.py" merge --explore-dir "$EXP"
```
采集**点击/选择/填写/公式计算**四类过程经验，产出字段映射建议（同名/归一化同名自动纳为建议、
同值巧合仅提示、其余列待人工）——**经验库是第四取证源（参考物），不是契约更不是结论**；
写影响与一次正式 run 同级（老系统为生产环境，`--apply` 前确认影响面）。完整动作序列、
参数与边界见 [references/exploration.md](references/exploration.md)。

**1 取证立契** → 按 [references/contract-howto.md](references/contract-howto.md) 的字段速查与
取证坑清单（STEP_USER 需 DISTINCT、SELECT_* 值域是 `'是'`、实例前缀须全量统计、资源释放语义
逐流程确认等）填 `docs/<流程>/自动化测试/test-contract.yaml`（从
`$SKILL/templates/test-contract.template.yaml` 空白模板起；勿复制实例
`$SKILL/templates/examples/liyazhuang-railway.yaml` 起稿——易遗留他流程编码/账号）。

**2 校验（fail-closed）**：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml, jsonschema" 2>/dev/null || FTC_PY="uv run --with pyyaml,jsonschema python3"
$FTC_PY "$SKILL/templates/validate-contract.py" \
  --contract docs/<流程>/自动化测试/test-contract.yaml --level test_ready
```
铁律：accounts 只写 `env: CURRENT_<账号大写>_PWD`（零明文）；每个被比较字段必须有
field_mappings 合同；fixture_pair_required 字段须有 fixtures 配对；≥1 required 用例；
`environments.health_checks` ≥1 条且覆盖 legacy/current 每侧 base_url 主机（pipeline 门禁按此执行）；
无自动检查器的 `gates[]` 必须带 `evidence_schema`；实例策略缺省 launch，需复用待办时
`meta.instance_policy: reuse`（v1.3.6：复用首步同流程同节点**必须恰一命中**，多候选=BLOCKED；
可用例声明 instanceNo/businessKey/fixtureSelector 消歧（标量或 {legacy,current} 分侧；
gen 确定性透传场景），businessKey/fixtureSelector 的待办字段
路径由 systems `todo.selectorPaths` 指认）；**用例路由与 nodes.next 矛盾默认拒绝**（确属退回/作废等特殊
按钮流转须在 cases[].notes 显式声明——探索性路径仅限 DRAFT 或 --drill）；
**豁免必须带完整取证链**（id/scope/match/reason/approved_by + approval_ref/source_run_id/
source_compare_sha256_16，1.3.0 起八字段）且源 run 账本经共享模块 `run_evidence.py` 全链核验
一致（1.3.4：五件齐全/run-id 三方一致/账本 config_snapshot 全部条目 sha 现算（含契约快照）/
toolchain 指纹/结论经 conclude_core 全量复算与 summary 一致/scope-match 绑定源 diffs；
1.3.6：账本须含 contract/rules/scenarios 最小键登记 + 非空 evidence_paths，manifest_sha256 须为
真实 64hex SHA；`--runs-dir` 缺省智能解析 契约同目录 → 上一级）——只可能由
exempt 子命令产出；历史手工五字段豁免须补链迁移或降 DRAFT。

**3 同源生成（产物=受保护文件，人工内容只写契约 meta.notes/risk_seeds/cases[].notes）**：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml, jsonschema" 2>/dev/null || FTC_PY="uv run --with pyyaml,jsonschema python3"
$FTC_PY "$SKILL/templates/gen_from_contract.py" \
  --contract docs/<流程>/自动化测试/test-contract.yaml --outdir docs/<流程>/自动化测试/生成件
```

**3.5 live readiness（v1.5.0 可选；跑前只读体检）**：
```bash
$FTC_PY "$SKILL/scripts/readiness.py" --contract docs/<流程>/自动化测试/test-contract.yaml \
  --systems-dir "$RUNTIME_DIR/systems/api" \
  [--gate-evidence <证据文件>] --out docs/<流程>/自动化测试/readiness/<run-id-预检>
```
按用例输出：双端 actor 凭据/发起要素/通道配置/reuse 选择器/按钮承载/gate 时效是否就绪，
未就绪给精确原因与责任域（env/config/contract/data/evidence）——不等跑完整条链才发现缺按钮/账号/数据。

**4 演练/执行**（在项目根执行）：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml, jsonschema" 2>/dev/null || FTC_PY="uv run --with pyyaml,jsonschema python3"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME_DIR="$(bash "$SKILL/scripts/ftc-runtime.sh" resolve "$PROJECT_ROOT")"
# 零副作用 dry-run（不建目录/不 curl/不写文件）：
bash "$SKILL/scripts/pipeline.sh" \
  --contract docs/<流程>/自动化测试/test-contract.yaml \
  --scenario-dir docs/<流程>/自动化测试/生成件/flowtrace-scenarios \
  --rules docs/<流程>/自动化测试/生成件/compare-rules.json --dry-run
# 真实执行（默认 api 通道：systems api 配置 + 可达服务 + 凭据（$RUNTIME_DIR/env 自动加载，
#           FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 统一默认密码兜底）；runtime env 必须为 0600 实体文件；不满足=诚实 BLOCKED）：
bash "$SKILL/scripts/pipeline.sh" \
  --contract docs/<流程>/自动化测试/test-contract.yaml \
  --scenario-dir docs/<流程>/自动化测试/生成件/flowtrace-scenarios \
  --rules docs/<流程>/自动化测试/生成件/compare-rules.json
# 可选参数：--cases C-01,C-02 场景子集过滤；--drill 演练（全账本但 conclusion=DRILL，不出正式
#           三态结论；--drill 下允许探索性路由=自动传 --allow-route-drift 给校验）；
#           --gate-evidence <file> 门禁证据预校验后原子拷入 run 目录
# 老系统 F12 端点检查：
$FTC_PY "$SKILL/scripts/legacy-config-check.py" --systems "$RUNTIME_DIR/systems/api/legacy.yaml"
# 浏览器通道（可见浏览器、UI 行为对比；实战 SOP 见 references/browser-channel.md）：
FLOWTRACE_RUNNER=browser bash "$SKILL/scripts/pipeline.sh" --contract <契约> --scenario-dir <场景目录> --dry-run
$FTC_PY "$SKILL/scripts/browser-capture.py" --check-config --systems "$RUNTIME_DIR/systems/browser/legacy.yaml"
$FTC_PY "$SKILL/scripts/browser-capture.py" --probe --systems "$RUNTIME_DIR/systems/browser/legacy.yaml" --headed  # 只读探针
```
通道与布局细节（api 五原语配置、FLOWTRACE_RUNNER 选择、skill 直跑、老系统 F12 录端点）见
[references/capture-channels.md](references/capture-channels.md) 与 [references/f12-record.md](references/f12-record.md)；
浏览器通道 schema/实战 SOP/UI 录制手册见 [references/browser-channel.md](references/browser-channel.md)
（配置范本 `assets/systems-browser/`）。**新流程首跑前过一遍六项预检**（runtime env 凭据键 /
双端 actorMap / LAUNCH_ELEMENT_ID_<FLOW_CODE> / 新系统 todo.map stepCode 映射【从引擎库部署
BPMN 实查】/ gate 证据 24h 时效 / 数据池未使用行）——清单见 contract-howto §取证坑 13；
**迁移环境追加第⑦项：迁移用户 API 权限点回填**（qianyi backfill_flow_participant.py --all，
L45）。

**4.5 多分支全量模式（可选；「全量」语义=当前流程取证源实查多少分支就生成多少，分支数永不写死）**：
```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml, jsonschema" 2>/dev/null || FTC_PY="uv run --with pyyaml,jsonschema python3"
# ① 全分支契约生成（数据驱动枚举；基准=已 PASS 契约；节点码补充映射=执行者实查后传入）
$FTC_PY "$SKILL/scripts/gen-multibranch-contract.py" gen \
  --branches-source docs/<流程>/自动化测试/pcm_run.py --branches-var branch_def \
  --template docs/<流程>/自动化测试/test-contract.yaml \
  --node-map-extra node-map-extra.json \
  --outdir docs/<流程>/自动化测试/生成件
# ② 校验 + 同源生成（cases=N 个分支 → N 个场景；--cases 子集执行）
# ③ 首跑对拍后批量豁免（强制绑定真实 run：核验账本/结论/对拍 sha/run-id/工具链指纹）：
$FTC_PY "$SKILL/scripts/gen-multibranch-contract.py" exempt \
  --run-dir docs/<流程>/自动化测试/对比测试/<run-id> \
  --approved-by "<审批人>" --approval-ref "<审批工单号>"
```
分支定义串（`launcher|KC|firstNext|user:环节,...`）用 ast 解析**零执行**，且**只解析
`--branches-var` 指定的受控变量/同名函数体内的分支 dict**（拒绝全文件扫描——样例/缓存 dict
会静默污染分支集合；零候选或多候选一律拒绝）；生成的契约在 `meta.sources.multibranch_generation`
登记每个取证源的路径 + SHA256 与分支计数（总数/正移/反向/跳过），正式契约据此自证"取证源全量"。
豁免**必须**以真实 run 为据（`--run-dir` 内部核验 run-manifest/summary/field-compare 三件齐全、
run-id 一致、fc 与账本登记 sha 一致、结论 ∈ PASS/FAIL、账本含 toolchain 指纹），每条豁免落
`source_run_id`/`source_compare_sha256_16`/`approval_ref`；1.3.0 起该取证链在**契约入口**
（validate-contract 八字段必填 + 账本现算复验）与**对拍入口**（field-level-compare 无链不生效）
双重强制——绕过 exempt 手写豁免不可采信。反向分支
（RETURN:/WITHDRAW:/VOID@）自动分流 explore 契约（守护规则 6，仅 --drill）；未知环节名分支
跳过进待核实清单（绝不猜码——先实查码后经 --node-map-extra 补入重生成）；nodes.next=全分支
并集拓扑（单分支实际路由由服务端 DMN 按发起人收窄）；`meta.branch_coverage` 双态完成度：
accounted_complete=分支全分类、formal_complete=反向也为 0（reverse_explore>0 的契约只覆盖
正向分支，conclude 据此拒绝全量 PASS——顶层 conclusion=BLOCKED + forward_conclusion=PASS）；
新账号 actorMap 增量与 runtime env 凭据键缺口
由生成器输出清单。实战实录（6 轮 run 修复链 + L41~L46）见 lessons-learned §6d；
必填三定律与扩量口径见 contract-howto §取证坑 14/15。

**5 结论与最终交付**：只认 `docs/<流程>/自动化测试/对比测试/<run-id>/summary.json`
（run 目录=单 run 单目录，截图/采集/账本/结论/报告同放一层；无契约 legacy 兼容模式回退
`$RUNTIME_DIR/reports/<run-id>/`。conclude.py 三态 PASS/FAIL/BLOCKED，fail-closed）；
结论仅绑定 run-id，不得沿用历史；像素 diff 永不进结论。
**结论范围限定（1.3.1）**：契约 branch_coverage.reverse_explore>0（反向分支仅 drill 探索）
时，即使正向全部通过也**不产出顶层 conclusion=PASS**——正式结论=BLOCKED，
summary.forward_conclusion=PASS 仅为信息性字段 + branch_scope.conclusion_scope=
forward_branches_only + 报告显著标注，只读顶层 conclusion 的 CI/报表/外部调用方
不会误判全量成功；反向要出正式结论须另立正式契约（cases[].notes 显式声明特殊流转）
并单独 run 绑定。
BLOCKED/FAIL 后的重跑计划：`$FTC_PY "$SKILL/scripts/rerun-plan.py" --run-dir <run目录>
--contract <契约>` → 重跑计划.md（阻塞项→责任域→动作→验证命令；rerun_of 绑定源 run；
必须新 run-id 全量重跑，绝不拼接历史 PASS）。数据残留见 run 目录 test-data-ledger.json
（close 段 safe_to_clean 清单，人工/管理员执行）。
PASS 采信链（launch-first 实例隔离 + 三重校验）、账本规则、gate 证据校验、以及**最终交付物
= 单一 md**（`对比测试报告.md`，pipeline 在 conclude 后自动经 gen-final-report.py 生成；
1.3.4 起生成前必须证据链核验通过：五件齐全 + 账本 sha 复算 + 结论复算与 summary 一致，
缺 summary.json 或核验失败 exit 2，--allow-unverified 只产出明确标注的草稿；
人工产品级发现记在独立的 `人工发现.md`，机器永不覆盖）的全部硬校验规则见
[references/execution-gate.md](references/execution-gate.md)
与 [references/adversarial-regression.md](references/adversarial-regression.md)。

## 守护规则

1. 凭据零落库；统一放 `$RUNTIME_DIR/env`（私有运行态、权限 0600，绝不入库/同步），或以显式授权的 `FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD` 统一默认密码兜底；轮换只改该处
2. 语义结论三前提：有合同 + fixture 双端配对 + 采集齐全；否则 OBSERVE/BLOCKED
3. 账本与结论**防误覆盖/防单文件篡改**（无 --force；同 run-id 目录已存在即拒绝——重跑必须新 run-id；落账证据 sha 复算 + 结论复算）。注意这不防御拥有整个证据目录写权限的本地攻击者——该威胁需外部只增账本/签名
4. 生成件受保护：重新生成整体覆盖，人工内容进契约或 run 目录独立的 `人工发现.md`（机器不覆盖）
5. **通道自持**：双端执行默认走内置 api 采集器；引入任何外部执行器（含 cli 兼容后端）都必须满足 capture 契约与三重采信校验
6. **路由矛盾默认拒绝**：用例路由 ∉ nodes.next → TEST_READY 拒绝（cases[].notes 显式声明特殊流转除外）；探索性路径仅限 DRAFT 或 --drill
7. **豁免取证链三重强制（1.3.0；1.3.1 共享模块化；1.3.4 结论复算）**：豁免只能由 exempt 子命令从真实 run 产出（八字段 + 源 run 全链核验）；生成器入口（--run-dir）、契约入口（validate-contract，经共享 `run_evidence.py`：五件齐全/run-id 三方一致/config_snapshot 全部条目（含契约）sha 现算/toolchain/结论全量复算与 summary 一致 + **scope/match 绑定源 diffs**）、对拍入口（比较器无链不生效）任一不过即拒绝/不生效——手写或半伪造豁免不可采信，且禁止在任何消费方另写简化版核验
8. **结论不得越界（1.3.1）**：reverse_explore>0 的 run 即使正向全 PASS，顶层 conclusion=BLOCKED（forward_conclusion=PASS 仅为信息性字段）——只读 conclusion 的下游不得据此报告全量成功；反向分支正式结论须另立正式契约单独 run 绑定

## 深入细节

[references/contract-howto.md](references/contract-howto.md)（立契指南与取证坑） ·
[references/coverage.md](references/coverage.md)（覆盖账本：任务完成门①+浏览器收敛路径） ·
[references/exploration.md](references/exploration.md)（自由探索：首次对比冷启动/经验库/立契建议） ·
[references/execution-gate.md](references/execution-gate.md)（执行/账本/三态） ·
[references/capture-channels.md](references/capture-channels.md)（采集通道契约；§5 含选人
prefer_ids/编码不对称/SUBMIT 载体实战规则） · [references/f12-record.md](references/f12-record.md)（老系统录端点手册） ·
[references/adversarial-regression.md](references/adversarial-regression.md)（负向回归规则总表） ·
[references/lessons-learned.md](references/lessons-learned.md)（三流程实战经验：速查 27 条/全文 54 条，港口煤/公路/铁路，先读） ·
[references/flow-tables.md](references/flow-tables.md)（环节表生成：DB/SQL/快照回退） ·
[references/changelog.md](references/changelog.md)（演进史） · 分发清单：[MANIFEST.txt](MANIFEST.txt) ·
多分支全量生成：`scripts/gen-multibranch-contract.py`（gen 全分支契约 / exempt 批量豁免；
数据驱动分支数，见工作流 4.5 与 contract-howto §取证坑 14/15）；
实例：`templates/examples/liyazhuang-railway.yaml`（skill 内完整契约实例）；
`docs/李雅庄铁路流程/自动化测试/`（项目内运行态数据）

---

Base directory for this skill: 本 SKILL.md 所在目录（标准安装为 `~/.agents/skills/flow-test-contract`；多工具同步副本为对应 skills 目录）。 Relative paths in this skill are relative to this base directory.
