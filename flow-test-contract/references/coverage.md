# 覆盖账本（coverage manifest）· v1.5.0 任务完成门①

> 工具：`$SKILL/scripts/coverage_manifest.py`（scaffold/check，唯一实现）；
> 结论门禁：`conclude_core`（契约声明 `meta.coverage_manifest` 时自动启用）。

## 1. 解决什么问题

validator 只能验证"已声明的 required case 有 assertions"，不能证明 Excel/流程逻辑/老系统
取证中**所有环节、按钮、字段、公式、分支**都进了契约——契约遗漏会被当成"全流程双端 PASS"。
覆盖账本把"来源要素 → 契约位置 → 比较维度 → 通道 → 状态"逐项登记成机器可判定门禁：

> 只有全部 **must-cover** 要素 status=covered（或显式 not_applicable），run 才允许
> "全流程双端 PASS"；否则 conclude 把 PASS 降级 **BLOCKED**（coverage_scope=partial）。

**两类 PASS 语义（v1.6.0）**：
- **未声明账本** → PASS 合法，但 conclude 输出 `coverage_scope=contract_scope_only`，
  报告显式标注"已声明契约范围，不构成全流程双端 PASS"（向后兼容，存量契约不受阻）；
- **声明且全部 must-cover 闭环** → `coverage_scope=full`，才是"全流程双端 PASS"。
- 新契约立契口径：`validate-contract --level test_ready --require-coverage` 强制要求声明；
  存量契约迁移期默认仅告警。

## 2. 账本 schema

> **v1.6.0**：①相对路径按**契约所在目录**解析（validator/conclude/readiness/draft 统一）；
> ②covered 深度校验：contract_ref=`case[/s<序号>]`（case/step/node/维度逐项核对）+ 必填
> `evidence`（run-id/探索 id）；not_applicable 必填 reason+evidence；③`--require-coverage`
> 强制口径与两类 PASS 语义（见 §1.1）；④`import-browser-explore`/`promote` 子命令（§4）。

```yaml
meta: {generator: ..., generated_at: ..., note: ...}
elements:                      # 逐条取证要素
  - id: button-35              # 唯一 id（必填）
    source: excel              # excel|legacy_db|flow_logic|exploration|browser_explore|manual
    kind: button               # node|button|field|formula|branch|resource|post_flow|case|page|other
    name: 环节 35 按钮可见集
    contract_ref: "C-01/s3"    # covered 时必填（case[/step] 承载证据）
    dimension: buttons         # field|formula|routing|buttons|resources|post_flow|""
    channel: browser           # api|browser|both|none
    status: covered            # covered|expected_gap|ready_for_browser_run|uncovered|not_applicable
    must_cover: true           # 布尔；true 的未闭环项阻断全量 PASS
    reason: ""                 # expected_gap/not_applicable 必填（可审计理由）
    followup: ""               # expected_gap 必填（完成队列下一步）
    evidence: ""               # 可选：探索 id / run-id
```

状态语义与门禁关系：

| 状态 | 含义 | 阻断全量 PASS？ |
|---|---|---|
| covered | 已进契约且有 case/step 承载 | 否 |
| not_applicable | 明确不适用（填 reason） | 否 |
| expected_gap | 已声明的非自动化缺口（填 reason+followup） | **是**（已声明 ≠ 已验证） |
| ready_for_browser_run | UI 已录制/探索，待浏览器正式 run | **是** |
| uncovered | 未覆盖、未声明理由 | **是**（最危险态） |

## 3. 标准用法

```bash
SKILL="${SKILL:-$HOME/.agents/skills/flow-test-contract}"
FTC_PY=python3; python3 -c "import yaml" 2>/dev/null || FTC_PY="uv run --with pyyaml python3"

# ① 从契约生成骨架（全部 uncovered/must_cover——宁可从零核实，不允许默认 covered）
$FTC_PY "$SKILL/scripts/coverage_manifest.py" scaffold \
  --contract docs/<流程>/自动化测试/test-contract.yaml \
  --out docs/<流程>/自动化测试/coverage-manifest.yaml

# ② 人工逐项核实：covered 填 contract_ref；expected_gap 填 reason+followup；
#    not_applicable 填 reason；浏览器缺口走 §4 完成队列

# ③ 契约声明：meta.coverage_manifest: {path: coverage-manifest.yaml}（相对契约目录或绝对路径）

# ④ 校验（validate-contract 亦会联动深度校验；新契约建议 --require-coverage）
$FTC_PY "$SKILL/scripts/coverage_manifest.py" check --manifest docs/<流程>/自动化测试/coverage-manifest.yaml \
  --contract docs/<流程>/自动化测试/test-contract.yaml
```

之后照常 pipeline：conclude 会输出 `summary.coverage_scope`（total/must_cover/covered/...
conclusion_scope=full|partial），最终报告 §2 渲染覆盖摘要与未闭环清单。

## 4. 浏览器缺口的收敛路径（配合 explore-browser）

按钮流（选择合同/磅房/执行单、盖章、G5b）此前只是"已知 BLOCKED"；现在有显式完成队列：

```bash
# ① 只读探索（截图+可见按钮/输入/候选 ref；零点击零填写）
$FTC_PY "$SKILL/scripts/explore-channel.py" explore-browser \
  --systems "$RUNTIME_DIR/systems/browser/legacy.yaml" \
  --actor <账号> --goto <工作台URL> --label workbench \
  --outdir docs/<流程>/自动化测试/探索/<explore-id>/
# 产出：探索发现-browser-*.md、ui-record-candidates-*.yaml（__UI_RECORD__ 候选，人工核对后
# 填入正式 browser 配置）、browser-*.png 截图、coverage_elements 草稿

# ② 账本推进：expected_gap →（探索后 import）ready_for_browser_run →（浏览器正式 run PASS 后）covered
$FTC_PY "$SKILL/scripts/coverage_manifest.py" import-browser-explore \
  --manifest docs/<流程>/自动化测试/coverage-manifest.yaml --explore-dir <探索目录>   # 去重入队
# 浏览器正式 run 结论=PASS 后：
$FTC_PY "$SKILL/scripts/coverage_manifest.py" promote \
  --manifest docs/<流程>/自动化测试/coverage-manifest.yaml --contract docs/<流程>/自动化测试/test-contract.yaml \
  --set browser-workbench-button-0=C-01/s3 --run-id <run 目录>   # evidence=run-id 自动登记
```

## 4.5 v1.7.0：深度绑定 / 来源库存 / promote 全链核验

**covered 深度绑定契约对象**（validate/check --contract 时强制）：

| kind | 必填绑定 | 校验 |
|---|---|---|
| field | contract_key=legacy/target 字段 | ∈ 契约 field_mappings |
| formula | contract_key=公式 id | ∈ 契约 formulas |
| button | node | ∈ 契约 buttons 断言节点 |
| branch | node | ∈ 契约 routing 断言节点 |
| resource | contract_key=资源 id | ∈ 契约 resources |
| post_flow | — | 契约须声明 post_flow.code |

covered 另必填 `evidence`（run:<id>/browser-explore:<id>）；not_applicable 必填 reason+evidence。

**来源库存**（真实流程集合全量证明）：

```yaml
meta: {note: Excel+BPMN 导出}
items:
  - {id: INV-001, source: excel, kind: field, name: 毛重, source_hash: <指纹>}
```

```bash
$FTC_PY "$SKILL/scripts/coverage_manifest.py" import-inventory \
  --manifest docs/<流程>/自动化测试/coverage-manifest.yaml --inventory <库存.yaml>
# 缺项自动补 uncovered must-cover（含 source_ref/source_hash）；账本须声明
# meta.source_inventory: {path: ...} 后，全部 must-cover 逐条挂靠（check --inventory 校验）
```

**promote 全链核验**（v1.7.0）：中性化重算 PASS（执行面全绿，覆盖缺口除外）+ run 账本契约
哈希与本契约一致 + coverage_scope=declared partial/full + 目标 case 在 PASS 集合 + 双端
capture 存在且 channel 与要素一致（浏览器要素必须浏览器通道 run）。

## 5. 与其他门的关系

- **结论门禁**在 conclude_core（单一评估器）：uncovered/expected_gap/ready_for_browser_run
  的 must-cover 项存在 → PASS 降 BLOCKED + `coverage_scope.conclusion_scope=partial`；
  summary.coverage_scope 进防篡改面（gen-final-report 与重算比对）。
- **DRAFT 骨架**（draft-contract.py）自动生成账本骨架并把探索未覆盖字段一并列为 uncovered
  must-cover——骨架即诚实，不允许"默认 covered"。
- 账本是**契约的附属取证物**：随契约进 sha 账本（write-manifest config_snapshot），改动即断链。
