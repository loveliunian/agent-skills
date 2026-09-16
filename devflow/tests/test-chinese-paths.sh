#!/usr/bin/env bash
# test-chinese-paths.sh · v3.22.0 文档层中文化回归
# 钉住三件事：
#   1) 全新中文布局（docs/需求、docs/详细设计、docs/评审…中文文件名）各 gate 能解析并通过；
#   2) 历史英文布局继续通过（向后兼容，在途项目零迁移）；
#   3) 解析优先级：中英文同时存在时中文优先。
TEST_DIR="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(cd "$TEST_DIR/.." && pwd -P)"
source "$TEST_DIR/testlib.sh"

S="$ROOT/scripts"
TMP="$(mktemp -d -t df-zh.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# ---------- 1. 路径库单元行为（纯函数，三态，独立工作区） ----------
WU="$TMP/unit"; mkdir -p "$WU"
(
  cd "$WU" || exit 1
  source "$S/devflow_paths.sh"
  out="$(df_default_doc foo clarification .md requirements)"
  [ "$out" = "docs/需求/foo-需求澄清.md" ] && ok "默认写路径为中文: $out" || bad "默认写路径错误: $out"
  mkdir -p docs/requirements
  echo x > docs/requirements/foo-clarification.md
  out="$(df_resolve_doc foo clarification .md requirements)"
  [ "$out" = "docs/requirements/foo-clarification.md" ] && ok "仅英文存在时回退英文" || bad "英文回退失败: $out"
  mkdir -p docs/需求
  echo y > docs/需求/foo-需求澄清.md
  out="$(df_resolve_doc foo clarification .md requirements)"
  [ "$out" = "docs/需求/foo-需求澄清.md" ] && ok "中英并存时中文优先" || bad "中文优先失败: $out"
)

# 构造一套合格澄清/验收点文档的辅助函数（$1=目录 $2=feature，内容对齐 test-phase-gates 已验证夹具）
make_s0_docs() {
  local dir="$1" f="$2"
  cat > "$dir/$f-需求澄清.md" <<EOF
# $f 需求澄清
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | $f |
| 验收点来源 | $f-验收点.md |
| 备注 | 冻结时点为评审完成时；权限矩阵=not-applicable（纯后端夹具） |
## 模糊点清单
| 编号 | 模糊点 | 澄清结论 | 状态 |
|---|---|---|---|
| Q1 | 查询口径 | 以 PRD 为准 | 已闭环 |
## 澄清结论汇总
全部闭环，无未决项。
## 遗留项（需后续跟进）
无。
## 签字确认
甲方：fixture 甲方 2026-08-24
乙方：fixture 乙方 2026-08-24
EOF
  cat > "$dir/$f-验收点.md" <<EOF
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | $f |
| 状态 | FROZEN |
## 验收清单
| acceptance_id | requirement | status |
|---|---|---|
| M-01-F01-A01 | 查询真实数据 | FROZEN |
| 总计 | 1 | FROZEN |
EOF
  cat > "$dir/$f-技术约束.md" <<EOF
# $f 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
}

# ---------- 2. 全中文布局：s0 gate 端到端 ----------
WZ="$TMP/zh"; mkdir -p "$WZ/docs/需求"
( cd "$WZ" && WORKSPACE="$WZ" bash "$S/devflow-state.sh" init zh --frontend=not-applicable >/dev/null 2>&1 )
make_s0_docs "$WZ/docs/需求" zh
S0_OUT=$(cd "$WZ" && WORKSPACE="$WZ" bash "$S/s0_acceptance_gate.sh" zh 2>&1)
if echo "$S0_OUT" | grep -q "P0 GATE: PASS"; then ok "全中文布局 s0 gate 通过"; else
  bad "全中文布局 s0 gate 失败"; echo "$S0_OUT" | grep -E "^\[P0\]|RESULT"; fi
if echo "$S0_OUT" | grep -q "clarification exists: docs/需求/zh-需求澄清.md"; then ok "s0 解析并绑定中文澄清文档"; else bad "s0 未绑定中文文档"; fi

# ---------- 3. 全英文布局：s0 继续通过（历史兼容） ----------
WE="$TMP/en"; mkdir -p "$WE/docs/requirements"
( cd "$WE" && WORKSPACE="$WE" bash "$S/devflow-state.sh" init en --frontend=not-applicable >/dev/null 2>&1 )
# 英文布局手工建英文名文件（内容同合格夹具）
cat > "$WE/docs/requirements/en-clarification.md" <<'EOF'
# en 需求澄清
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | en |
| 验收点来源 | en-acceptance-criteria.md |
| 备注 | 权限矩阵=not-applicable（纯后端夹具） |
## 模糊点清单
| 编号 | 模糊点 | 澄清结论 | 状态 |
|---|---|---|---|
| Q1 | 查询口径 | 以 PRD 为准 | 已闭环 |
## 澄清结论汇总
全部闭环，无未决项。
## 遗留项（需后续跟进）
无。
## 签字确认
甲方：fixture 甲方 2026-08-24
乙方：fixture 乙方 2026-08-24
EOF
cat > "$WE/docs/requirements/en-acceptance-criteria.md" <<'EOF'
## 基本信息
| 字段 | 内容 |
|---|---|
| 功能模块 | en |
| 状态 | FROZEN |
## 验收清单
| acceptance_id | requirement | status |
|---|---|---|
| M-01-F01-A01 | 查询真实数据 | FROZEN |
| 总计 | 1 | FROZEN |
EOF
cat > "$WE/docs/requirements/en-technology-constraints.md" <<'EOF'
# en 技术约束
<!-- DEVFLOW:CONSTRAINTS
constraint_set=NONE
confirmed=true
DEVFLOW:END -->
EOF
S0_EN=$(cd "$WE" && WORKSPACE="$WE" bash "$S/s0_acceptance_gate.sh" en 2>&1)
if echo "$S0_EN" | grep -q "P0 GATE: PASS"; then ok "历史英文布局 s0 gate 仍通过（向后兼容）"; else
  bad "历史英文布局 s0 gate 失败（回归）"; echo "$S0_EN" | grep -E "^\[P0\]|RESULT"; fi

# ---------- 4. 全中文布局：p5 测试用例 gate 认中文目录/文件名 ----------
W5="$TMP/zh5"; mkdir -p "$W5/docs/测试用例" "$W5/.devflow"
( cd "$W5" && WORKSPACE="$W5" bash "$S/devflow-state.sh" init zh5 --frontend=not-applicable >/dev/null 2>&1 )
cat > "$W5/docs/测试用例/zh5-测试用例.md" <<'EOF'
# zh5 测试用例
- TC-zh5-001：验证某行为，步骤一。
EOF
P5_OUT=$(cd "$W5" && WORKSPACE="$W5" bash "$S/p5_test_cases_gate.sh" zh5 2>&1)
echo "$P5_OUT" | grep -q "test-case evidence exists: docs/测试用例/zh5-测试用例.md" \
  && ok "p5 识别中文目录中文测试用例" || { bad "p5 未识别中文测试用例"; echo "$P5_OUT"|head -8; }

# ---------- 5. gen-domain-checklist 生成中文名 ----------
WG="$TMP/dc"; mkdir -p "$WG/docs/需求"
( cd "$WG" && WORKSPACE="$WG" bash "$S/devflow-state.sh" init gdc --frontend=not-applicable >/dev/null 2>&1 )
cat > "$WG/docs/需求/gdc-需求澄清.md" <<'EOF'
# gdc
无外部系统对接，纯内部计算。
EOF
( cd "$WG" && WORKSPACE="$WG" bash "$S/gen-domain-checklist.sh" gdc --stage prd >/dev/null 2>&1 )
[ -f "$WG/docs/需求/gdc-PRD领域清单.md" ] && ok "PRD 领域清单生成中文名" || bad "PRD 领域清单中文名缺失"
( cd "$WG" && WORKSPACE="$WG" bash "$S/gen-domain-checklist.sh" gdc --stage design >/dev/null 2>&1 )
[ -f "$WG/docs/评审/gdc-设计领域清单.md" ] && ok "设计领域清单生成到中文评审目录" || bad "设计领域清单中文名缺失"

# ---------- 6. init-fact-sources 默认中文目录，且英文旧项目沿用不重建 ----------
WI="$TMP/fs"; mkdir -p "$WI"
( cd "$WI" && SKILL_DIR="$ROOT" WORKSPACE="$WI" bash "$S/init-fact-sources.sh" >/dev/null 2>&1 )
[ -f "$WI/docs/详细设计/_权限矩阵.md" ] && ok "事实源初始化到中文目录 docs/详细设计" || bad "事实源中文目录缺失"
WI2="$TMP/fs2"; mkdir -p "$WI2/docs/detailed-design"
( cd "$WI2" && SKILL_DIR="$ROOT" WORKSPACE="$WI2" bash "$S/init-fact-sources.sh" >/dev/null 2>&1 )
if [ -f "$WI2/docs/detailed-design/_权限矩阵.md" ] && [ ! -d "$WI2/docs/详细设计" ]; then
  ok "已有英文事实源目录时沿用，不重复建中文目录"
else bad "英文旧项目事实源目录沿用逻辑失败"; fi

finish "CHINESE_PATHS"
