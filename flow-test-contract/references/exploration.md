# 自由探索（首次对比的冷启动）· v1.4.0

> 工具：`$SKILL/scripts/explore-channel.py`（唯一实现；复用 api-capture 的 Api——
> launch-first/实例隔离/选人解析/账本，禁止另写一套 HTTP 逻辑）。

## 1. 解决什么问题

正式对比的前置是**立契**（field_mappings/formulas/routing/buttons 全要字段级合同），
而新流程初次对比时这些合同只能靠人工盲录（F12/翻页面/翻库）——慢且易错。

自由探索把冷启动变成**先探索后立契**：

1. 双端各跑一次探索器 → 采集四类过程经验：
   - **点击**：每节点已知按钮面（默认提交/预保存/operations 按钮语义/retryOn 前置按钮）
   - **选择**：每节点路由候选（workbench nextNodes + form.nextStepPath 声明）+ 候选办理人名单
   - **填写**：每节点表单全部字段与当前值（字段名→字段名映射的原始证据）
   - **公式计算**：探针法——向最多 2 个数值字段填探针值 → 预保存 → 读回表单 →
     记录发生变化的字段（=公式输出候选）（保存动作本身更新的
     更新时间/修改人类系统维护字段单列 `system_field_changes`，不算公式候选）
2. merge 双端实录 → `experience.yaml`（经验库）+ `立契建议.md`（人读）：
   同名/归一化同名的字段映射候选自动纳为建议；同值巧合只提示；其余列待人工。
3. 人工核对建议 + 取证三源（Excel/老库/流程逻辑）→ 正式立契 → 走既有 validate → gen → pipeline。

## 2. 定位铁律（读一遍再用）

- **经验库是第四取证源（参考物），不是契约、更不是结论**——探索永不产出 PASS/FAIL；
  契约仍须人工立契并过 `validate-contract --level test_ready`（生命周期门控不变）。
- **写操作显式门槛**：默认只读；`--apply` 才发起实例+逐环节提交（写影响=与一次正式 run
  同级，launch-first 实例隔离，只碰自己发起的实例；**必须显式 `--actor`**——写操作可追溯）；
  `--fill` 公式探针再显式开启。`--apply` 默认 `--advance none`（只采集不推进，防非预期流转）；
  要自主推进显式 `--advance first`，且**拒绝空办理人提交**——无候选办理人须显式 `--assignee`，
  `--route` 只接受系统实时候选内的值，任何缺失都在 api.submit 前中断。
  **老系统是生产环境**——`--apply` 前按 lessons-learned L15/L16 确认影响面。
- **探索可中断、如实记录**：无路由/无候选办理人/下一任务在他人名下/提交失败 →
  记录中断原因后正常退出（exit 0）——"哪里走不通"本身就是经验（按钮流未支持等）。
  只有配置/凭据/launch 失败才 exit 2（零产物）。
  用户 Ctrl+C 中断 → 已采集经验照常落盘后 exit 130。
- 探索实录含 `instance_no`（可追溯/可清理）；产物落 `docs/<流程>/自动化测试/探索/<explore-id>/`。

## 3. 标准动作序列

```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml" 2>/dev/null || FTC_PY="uv run --with pyyaml python3"
PROJECT_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
RUNTIME_DIR="$(bash "$SKILL/scripts/ftc-runtime.sh" resolve "$PROJECT_ROOT")"
EXP="docs/<流程名>/自动化测试/探索/explore-$(date +%Y%m%d%H%M%S)"

# 0) 只读观察（可选，安全热身）：待办结构/流程匹配计数，零写操作
$FTC_PY "$SKILL/scripts/explore-channel.py" explore \
  --systems "$RUNTIME_DIR/systems/api/legacy.yaml"  --flow <流程编码> --outdir "$EXP" --observe-only

# 1) 老系统写探索（生产环境！--apply 前确认影响面；--actor 必填；默认不推进）
$FTC_PY "$SKILL/scripts/explore-channel.py" explore \
  --systems "$RUNTIME_DIR/systems/api/legacy.yaml"  --flow <流程编码> --outdir "$EXP" \
  --apply --actor <账号>

# 2) 新系统写探索（+公式探针；确认推进链路后可加 --advance first [--assignee <办理人>]）
$FTC_PY "$SKILL/scripts/explore-channel.py" explore \
  --systems "$RUNTIME_DIR/systems/api/current.yaml" --flow <流程编码> --outdir "$EXP" \
  --apply --actor <账号> --fill

# 3) 双端合并 → experience.yaml + 立契建议.md
$FTC_PY "$SKILL/scripts/explore-channel.py" merge --explore-dir "$EXP"
```

常用参数：`--actor <账号>`（--apply 必填；下一环节在别人名下会中断——换账号续探）、
`--advance first|none`（默认 none=只探当前节点不提交）、`--route <节点>`（显式路由，须在实时候选内）、
`--assignee <姓名或ID>`（显式办理人；无候选且未指定=拒绝空办理人提交并在 submit 前中断）、
`--max-steps N`（默认 12）、`--form-data '{"字段":"值"}'`（每步随提交的业务表单数据）、
`--include-values`（产物保留表单原值——默认脱敏 `#sha16:长度`；开启后产物含敏感值，
须放私有 runtime 勿提交/勿同步）、`--overwrite`（覆盖已有产物——默认拒绝，防丢实例号）、
`--explore-id <id>`（缺省取 outdir 目录名）。

## 4. 产物与消费方式

| 文件 | 谁读 | 内容 |
|---|---|---|
| `explore-<side>.json` | 机器/agent | 单端实录：每步字段/按钮/路由候选/办理人候选/公式探针/推进结果 + instance_no |
| `探索发现-<side>.md` | 人 | 同上的人读版（按步骤分节） |
| `experience.yaml` | 机器+人 | 双端按 step 对齐：`field_mapping_candidates`（basis=same_name/same_name_normalized/same_value）+ `needs_human`（legacy_only/current_only）+ 路由/按钮/公式探针对照 + `contract_suggestions` |
| `立契建议.md` | 人 | 每节点映射建议表（✅ 可自动纳入 / ⚠ 同值巧合 / ❓ 待人工）+ 总览 |

**消费方式**：从 `experience.yaml` 的 `contract_suggestions.field_mappings` 复制进契约草稿
（建议条目带 `note` 标注来源与判定依据，核对后可删）；`needs_human` 两列就是立契人
要补的映射清单；路由候选对照可填 `routing.candidates_legacy`。**绝不让 agent 跳过人工
确认直接改契约**——契约是受保护生成件的唯一事实源。

## 5. 与正式对比的关系（边界）

- 探索通过 ≠ 对比通过：探索只证明"能走通、看得到"，对比结论只能出自
  契约 → gen → pipeline 的正式 run（三态 + 账本 + run-id 绑定）。
- 探索发现的"提交失败/中断"是**立契素材**（该环节可能需要按钮语义 operations、
  选人 resolver、save_with_form_data 等配置——对照 references/capture-channels.md §5 配齐后重探）。
- 公式探针的 `outputs_candidates` 只是"变化字段"，是否真公式、双端是否同律，
  由契约 `formulas`（expr + expected_legacy + tolerance）在正式 run 中判定。
