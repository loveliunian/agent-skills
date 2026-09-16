# flow-test-contract

> 老/新双系统流程迁移的**契约化对比测试** skill——把「新系统跟老系统跑得一样吗」这件事，
> 从人工点点看看，变成一条可审计、可复现、伪造不了的证据链。
>
> 当前版本 **v1.7.5**｜负向回归全绿（数量以 `selftest.py --full` 实跑为准）｜quick **11/11**｜发布门禁（各工具副本字节一致）退出码 0

## 这个 skill 解决什么问题

业务流程从老系统迁到新系统，验收要回答的是一个很硬的问题：**同一笔业务、同一个人、走同一条流程，两边的字段、按钮、路由、资源是否语义一致？**

手工验收的通病，这个 skill 逐条封死：

| 手工验收的坑 | 本 skill 的做法 |
|---|---|
| 「我看着差不多」 | 字段级语义对拍，差异必须有 field_mappings 合同背书 |
| 截图当证据、结论靠记忆 | 三态结论只认 `summary.json`，绑定 run-id，账本防误覆盖/单文件篡改（威胁模型边界见 SKILL.md） |
| 跑挂了就说「环境问题」 | 老/新任一不可达 → 诚实 **BLOCKED**，绝不出 PASS |
| 事后补个豁免把差异吞掉 | 豁免必须绑定真实 run 的账本+sha+审批工单，手写 JSON 一律拒绝 |
| 「这次好了」但换台机器又不一样 | 账本记录 skill 版本/脚本哈希/依赖/浏览器 CLI 版本；正式跑禁用未锁版工具 |

核心信条：**fail-closed**。任何"证据不足"的情形一律 BLOCKED，绝不向 PASS 让步。

## 生命周期（不可越级）

```
取证三源不完整（Excel / 老库 / 流程逻辑）
        ↓ 只能 DRAFT：可取证立契、生成、演练（--drill），禁止正式运行
validate-contract --level test_ready 全过
        ↓ TEST_READY：才允许生成正式件与真实执行
pipeline 真实 run（三态结论 + run-manifest 落账）
        ↓ EXECUTED：PASS / FAIL / BLOCKED，绑定 run-id
```

## 五分钟上手

```bash
SKILL=~/.agents/skills/flow-test-contract
FTC_PY=python3; python3 -c "import yaml, jsonschema" 2>/dev/null || FTC_PY="uv run --with pyyaml,jsonschema python3"

# 0) 前置检查（新会话必跑，任何 ✗ 即停）——见 SKILL.md「前置检查」代码块

# 1) 立契：从空白模板起，按 references/contract-howto.md 填取证结果
cp "$SKILL/templates/test-contract.template.yaml" docs/<流程>/自动化测试/test-contract.yaml

# 2) 校验（fail-closed）
$FTC_PY "$SKILL/templates/validate-contract.py" \
  --contract docs/<流程>/自动化测试/test-contract.yaml --level test_ready

# 3) 同源生成（场景 + 对拍规则，产物受保护）
$FTC_PY "$SKILL/templates/gen_from_contract.py" \
  --contract docs/<流程>/自动化测试/test-contract.yaml --outdir docs/<流程>/自动化测试/生成件

# 4) 演练（零副作用）→ 真实执行
bash "$SKILL/scripts/pipeline.sh" --contract <契约> \
  --scenario-dir docs/<流程>/自动化测试/生成件/flowtrace-scenarios \
  --rules docs/<流程>/自动化测试/生成件/compare-rules.json --dry-run
bash "$SKILL/scripts/pipeline.sh" ... （去掉 --dry-run；凭据自动从 $RUNTIME_DIR/env 加载）

# 5) 结论：docs/<流程>/自动化测试/对比测试/<run-id>/对比测试报告.md
```

## 产物放哪儿（三层，口径固定）

**① 交付物 —— 项目 docs（唯一对用户可见）**

```
<项目>/docs/<流程名>/自动化测试/
├── test-contract.yaml          # 契约：唯一人工编辑源
├── 生成件/                      # 同源生成（重生成整体覆盖，勿手改）
│   ├── flowtrace-scenarios/    #   场景 YAML
│   └── compare-rules.json      #   对拍规则（同源复算逐字节校验）
└── 对比测试/<run-id>/           # 执行产物：单 run 单目录，扁平同放
    ├── summary.json            #   ★ 三态结论（唯一采信）
    ├── run-manifest.json       #   防误覆盖账本（sha 复算；含工具链指纹）
    ├── field-compare.json/.md  #   语义对拍
    ├── gates.json / gate-evidence.json / health-results.json
    ├── field-captures/ · screenshots/
    ├── 对比测试报告.md          #   ★ 最终机器交付物（生成前证据链核验）
    └── 人工发现.md              #   人工产品级发现（机器永不覆盖）
```

**② 私有运行态 —— `$SKILL/runtime/<项目键>/`**（通道配置与 gate 证据库，非交付物、不同步副本）

**③ skill 自身 —— `~/.agents/skills/flow-test-contract`**（唯一事实源，14 个工具副本由 `sync-to-tools.sh` 单向同步）

> `.flowtrace/` 不属于本 skill——那是旧 FlowTrace 流水线的资产。

## 两条采集通道

| 通道 | 场景 | 说明 |
|---|---|---|
| **api**（默认） | 表单字段/路由/办理人语义对拍 | 内置纯 HTTP 采集器，五原语（login/todo/launch/form/submit）全配置化，不依赖外部工具 |
| **browser** | 按钮流、UI 行为差异、老系统无 API 处 | playwright-cli 驱动，逐环节截图；正式运行**必须** `PLAYWRIGHT_CLI` 指向锁定版本（禁 npx latest） |

## 不可突破的门禁

1. **凭据零明文**——只写 `env: CURRENT_<账号>_PWD`，值统一放 `$RUNTIME_DIR/env`（权限 0600；统一默认密码需显式 `FLOWTEST_ALLOW_DEFAULT_PWD=1`），轮换只改该处；采集器全链脱敏
2. **账本与结论防误覆盖**——无 `--force`，同 run-id 已存在即拒绝，重跑必须新 run-id；证据 sha 复算+结论复算防单文件篡改（不防御拥有目录写权限的本地攻击者）
3. **PASS 三前提**——有字段合同 + fixture 双端配对 + 采集齐全，否则 OBSERVE/BLOCKED
4. **同源复算**——执行件必须是契约的确定性重生成物，逐字节一致，手改规则塞豁免在入口即拦
5. **gate 证据须能证明该 gate**——契约声明 `evidence_schema`，通用 file/url 与自由文本一律拒
6. **路由矛盾默认拒绝**——用例路由 ∉ nodes.next 即 TEST_READY 拒绝，探索性路径仅 DRAFT/`--drill`
7. **豁免须绑定真实 run**——核验账本三件齐全、run-id 一致、fc 与账本 sha 一致、结论 ∈ PASS/FAIL、含工具链指纹
8. **可复现性**——账本落 skill 版本 + MANIFEST SHA256 + 脚本哈希 + Python/依赖/CLI 版本

这些规则不是文档约定，而是 **300+ 条负向回归**（数量以 selftest 实跑输出为准）逐条锁定的行为：改动任何脚本后必须
`python3 templates/selftest.py` 全绿。

## 目录导航

| 路径 | 内容 |
|---|---|
| `SKILL.md` | **主入口**：前置检查、工作流、守护规则（agent 读这个） |
| `references/contract-howto.md` | 立契指南与 15 条取证坑 |
| `references/execution-gate.md` | 执行/账本/三态结论的全部硬校验规则 |
| `references/capture-channels.md` | api 通道契约、五原语配置、选人与提交载体实战 |
| `references/browser-channel.md` | 浏览器通道 schema、实战 SOP、UI 录制手册 |
| `references/f12-record.md` | 老系统 F12 录端点手册 |
| `references/adversarial-regression.md` | 「攻击向量 → 此前漏洞 → 现口径」总表 |
| `references/lessons-learned.md` | 三流程实战经验（速查 27 条 / 全文 54 条）**先读** |
| `references/flow-tables.md` | 流程环节表生成（DB 直取 / 快照回退） |
| `references/changelog.md` | 演进史与版本规则 |
| `MANIFEST.txt` | 分发清单（唯一事实源，install/同步/前置检查全依此） |

## 维护约定

- **唯一事实源 = 本目录**；改动后必须重跑 `bash sync-to-tools.sh`，发布门禁 `--check` 退出码 0
- **版本 x.y.z**：默认只升 `z`；重大能力变化才升 `y`；`x` 仅在使用者特殊指定时升
- 每次升版在 `references/changelog.md` 登记条目
- 可选：`bash install.sh <project-root>` 把副本部署进项目供 CI 使用（`--check` 零写入校验）
