#!/usr/bin/env bash
# ============================================================
# init-fact-sources.sh (v3.1 - skill-grade)
# ------------------------------------------------------------
# 用途：在任意项目的 docs/<DOC_DIR>/ 下生成：
#   - 7 份事实源（手维护 + auto）
#   - 5 个 auto 索引
#   - MASTER.md 项目单一索引
#   - CLAUDE.md / AGENTS.md 跨平台入口
#
# 输出（默认）：
#   ${DOC_DIR}/_commons.md                       # 手维护公约
#   ${DOC_DIR}/_权限矩阵.md                      # 自动生成 + 手维护
#   ${DOC_DIR}/_环境与账号.md                    # 手维护环境
#   ${DOC_DIR}/_菜单Seed索引.md                  # 手维护 seed
#   ${DOC_DIR}/INDEX-章节锚点.md                 # skill 自动化用
#   ${DOC_DIR}/INDEX-表.md                       # 模板（人工可覆盖）
#   ${DOC_DIR}/INDEX-接口.md                     # 模板（人工可覆盖）
#   ${DOC_DIR}/_ER图索引.md                      # 自动生成（Flyway）
#   ${DOC_DIR}/_Schema变更日志.md                # 自动生成（Flyway）
#   MASTER.md                                    # 项目单一索引
#   CLAUDE.md / AGENTS.md                        # 跨平台入口
#
# 用法：
#   bash "$SKILL_ROOT/scripts/init-fact-sources.sh"                      # 默认
#   bash "$SKILL_ROOT/scripts/init-fact-sources.sh" --force              # 强制覆盖
#   SKILL_DIR=/path/to/skill bash "$SKILL_ROOT/scripts/init-fact-sources.sh"
#   DOC_DIR=docs/design bash "$SKILL_ROOT/scripts/init-fact-sources.sh"
# ============================================================

# 不加 set -u，避免 bash 5 在数组展开时的兼容问题
set -o pipefail

# v3.22.0: 默认事实源目录中文化；历史英文目录已存在且未显式指定 DOC_DIR 时沿用，避免重复初始化两套
if [ -n "${DOC_DIR:-}" ]; then
  :
elif [ -d "docs/detailed-design" ] && [ ! -d "docs/详细设计" ]; then
  DOC_DIR="docs/detailed-design"
else
  DOC_DIR="docs/详细设计"
fi
OUTPUT_DIR="$DOC_DIR"
FORCE=0

# ---------- 自动检测 SKILL_DIR ----------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
SKILL_DIR="${SKILL_DIR:-$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)}"
TEMPLATES_DIR="$SKILL_DIR/templates"

# v3.14.6: 通用探测——按常见工具目录顺序回退，不再硬编码单一工具
if [ ! -d "$TEMPLATES_DIR" ]; then
  for d in .claude .codex .cursor .trae-cn .agents; do
    if [ -d "$(pwd)/$d/skills/devflow/templates" ]; then
      SKILL_DIR="$(pwd)/$d/skills/devflow"
      TEMPLATES_DIR="$SKILL_DIR/templates"
      break
    fi
  done
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "[ERR] unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

echo "============================================="
echo "  初始化事实源"
echo "============================================="
echo "Skill templates : $TEMPLATES_DIR"
echo "项目文档目录    : $OUTPUT_DIR"
echo "强制覆盖        : $FORCE"
echo

if [ ! -d "$TEMPLATES_DIR" ]; then
  echo "[ERR] templates 目录未找到：$TEMPLATES_DIR"
  echo "      请设置 SKILL_DIR 环境变量指向 skill 根"
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

# ---------- 复制模板（7 份） ----------
COPIED=0
SKIPPED=0
TEMPLATES_LIST=$(cat <<'TPL_LIST'
_commons.md
_权限矩阵.md
_环境与账号.md
_菜单Seed索引.md
INDEX-章节锚点.md
INDEX-表.md
INDEX-接口.md
TPL_LIST
)

DATE=$(date +%Y-%m-%d)
while IFS= read -r tpl; do
  [ -z "$tpl" ] && continue
  src="$TEMPLATES_DIR/$tpl"
  dst="$OUTPUT_DIR/$tpl"
  if [ ! -f "$src" ]; then
    echo "[WARN] 模板不存在：$src"
    continue
  fi
  if [ -f "$dst" ] && [ "$FORCE" -eq 0 ]; then
    echo "  [SKIP] ${tpl}（已存在）"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi
  sed "s/{DATE}/$DATE/g" "$src" > "$dst"
  echo "  [OK]   $tpl"
  COPIED=$((COPIED + 1))
done <<< "$TEMPLATES_LIST"

echo
echo "模板复制完成：$COPIED 新建，$SKIPPED 跳过"

# ---------- 自动生成 ----------
echo
echo "============================================="
echo "  生成自动产物"
echo "============================================="

run_or_skip() {
  local script="$1"; local label="$2"; local output="$3"
  if [ ! -f "$SKILL_DIR/scripts/$script" ]; then
    echo "[SKIP] ${label}（脚本不存在：${script}）"
    return
  fi
  echo
  echo ">>> $label"
  DOC_DIR="$DOC_DIR" \
  OUTPUT_FILE="$OUTPUT_DIR/$output" \
  CONTROLLER_GLOB="${CONTROLLER_GLOB:-backend/*/src/main/java/**/*.java}" \
    bash "$SKILL_DIR/scripts/$script" 2>&1 | tail -3
  # v3.15.16: 生成器失败判定显式化——原 || echo 依赖 L32 set -o pipefail 隐式生效
  #（实测 pipefail 下 || 可触发，第 15 轮"死分支"判断不成立；但隐式依赖脆弱——
  #  pipefail 一旦被移除即变真死分支）。改 PIPESTATUS 显式捕获 + WARN 带 rc。
  GEN_RC="${PIPESTATUS[0]}"
  if [ "$GEN_RC" -ne 0 ]; then
    echo "[WARN] ${label} 生成失败（rc=${GEN_RC}）——详情见上方输出"
  fi
}

run_or_skip "generate-permission-matrix.sh" "权限矩阵" "_权限矩阵.md"
run_or_skip "generate-er-index.sh" "ER图索引" "_ER图索引.md"
run_or_skip "generate-schema-changelog.sh" "Schema变更日志" "_Schema变更日志.md"
run_or_skip "generate-table-index.sh" "表索引" "INDEX-表-auto.md"
run_or_skip "generate-interface-index.sh" "接口索引" "INDEX-接口-auto.md"
run_or_skip "generate-master-index.sh" "MASTER索引" "MASTER.md"

# ---------- 生成 CLAUDE.md / AGENTS.md ----------
echo
echo "============================================="
echo "  生成跨平台入口文件"
echo "============================================="

gen_cross_platform() {
  local target="$1"
  local platform_label="$2"
  # v3.14.1: 已存在的用户文件永不整体覆盖——只更新受控标记块；无标记块时生成候选文件
  if [ -f "$target" ] && [ "$FORCE" -eq 1 ]; then
    if ! grep -q "BEGIN:DEVFLOW-AUTO" "$target" 2>/dev/null; then
      local candidate="${target}.devflow-candidate"
      cat > "$candidate" <<CROSS_EOF
# $target — 项目入口（由 devflow 自动生成 v3.14）

> [!WARNING] 检测到已有 ${target} 但不含 DEVFLOW 自动块。
> 本内容写入候选文件，请人工核对后合并（自动块以 BEGIN/END:DEVFLOW-AUTO 标记）。

## 快速开始

\`\`\`bash
/devflow docs/PRD/<feature>.md       # 完整开发流程
/spec <feature>                      # PRD + 详设
/build docs/详细设计/<feature>-详细设计.md  # 全栈编码
/review                              # Adversarial 3 评审
/init-fact-sources                   # 初始化事实源
\`\`\`

## 阶段

P0 → P0b → P1 → P2 → P2a → P2b → P3 → P3b → P3c/P3d → P4 → P4b → P5 → P6 → P7 → P8 → P9 → P10

## Skill 路径

- 概念铁律：$SKILL_DIR/concepts/core.md
- 命令入口：$SKILL_DIR/commands/
CROSS_EOF
      echo "  [CANDIDATE] 已存在无标记的 ${target}，候选写入 ${candidate}"
      return
    fi
  fi
  if [ ! -f "$target" ] || { [ "$FORCE" -eq 1 ] && grep -q "BEGIN:DEVFLOW-AUTO" "$target" 2>/dev/null; }; then
    # v3.14.1: 幂等——已有自动块时先删除旧块再追加，重复 --force 不再累积
    if grep -q "BEGIN:DEVFLOW-AUTO" "$target" 2>/dev/null; then
      sed -i.bak-devflow '/<!-- BEGIN:DEVFLOW-AUTO/,/<!-- END:DEVFLOW-AUTO -->/d' "$target" && rm -f "$target.bak-devflow"
    fi
    {
    echo "<!-- BEGIN:DEVFLOW-AUTO（此块由 init-fact-sources 维护，手工修改请放在块外） -->"
    cat <<CROSS_EOF
# $target — devflow 项目入口（自动块 v3.14）

本项目使用 devflow skill 进行开发。

## 快速开始

\`\`\`bash
/devflow docs/PRD/<feature>.md       # 完整开发流程
/spec <feature>                      # PRD + 详设
/build docs/详细设计/<feature>-详细设计.md  # 全栈编码
/init-fact-sources                   # 初始化事实源
\`\`\`

## 阶段

P0 → P0b → P1 → P2 → P2a → P2b → P3 → P3b → P3c/P3d → P4 → P4b → P5 → P6 → P7 → P8 → P9 → P10

## Skill 路径

- 概念铁律：$SKILL_DIR/concepts/core.md
- Phase 流程：$SKILL_DIR/phases/
- 命令入口：$SKILL_DIR/commands/
- 当前平台：**$platform_label**
CROSS_EOF
    echo "<!-- END:DEVFLOW-AUTO -->"
    } >> "$target"
    echo "  [OK]   ${target}（受控自动块已写入/刷新，幂等）"
    return
  fi
  echo "  [SKIP] ${target}（已存在且非 --force 或无标记块）"
}


gen_cross_platform "CLAUDE.md" "Claude Code"
gen_cross_platform "AGENTS.md" "Codex / Trae"

echo
echo "============================================="
echo "  初始化完成"
echo "============================================="
echo "输出目录：$OUTPUT_DIR"
ls "$OUTPUT_DIR" 2>/dev/null | sort
