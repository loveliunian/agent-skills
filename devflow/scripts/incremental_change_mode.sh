#!/usr/bin/env bash
# 增量变更模式 v3.31.3
# 用途：支持最小化变更路径（只改一个字段、只加一个 API）

set -euo pipefail

# 颜色定义
# v3.28.7 Windows Git Bash 兼容：统一 Python 解释器解析（python3→python→py -3）
source "$(dirname "${BASH_SOURCE[0]}")/py_runtime.sh"
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

FEATURE="${1:-}"
CHANGE_TYPE="${2:-}"
CHANGE_SCOPE="${3:-}"

echo "════════════════════════════════════════════════════════════════"
echo "  增量变更模式 v3.28.7"
echo "════════════════════════════════════════════════════════════════"
echo ""

# 检查参数
if [ -z "$FEATURE" ] || [ -z "$CHANGE_TYPE" ]; then
  echo -e "${RED}❌ 缺少必需参数${NC}"
  echo ""
  echo "用法: bash $0 <feature-name> <change-type> [scope]"
  echo ""
  echo "变更类型："
  echo "  add-field        - 添加一个数据库字段"
  echo "  modify-field     - 修改一个数据库字段"
  echo "  add-api          - 添加一个 API 接口"
  echo "  modify-api       - 修改一个 API 接口"
  echo "  add-rule         - 添加一个业务规则"
  echo "  modify-rule      - 修改一个业务规则"
  echo "  add-validation   - 添加一个参数校验"
  echo "  fix-bug          - 修复一个 bug"
  echo ""
  echo "示例："
  echo "  bash $0 user-management add-field user.phone"
  echo "  bash $0 user-management modify-api POST:/api/users"
  echo "  bash $0 user-management fix-bug issue-123"
  exit 1
fi

echo -e "${BLUE}Feature:${NC} $FEATURE"
echo -e "${BLUE}变更类型:${NC} $CHANGE_TYPE"
echo -e "${BLUE}变更范围:${NC} ${CHANGE_SCOPE:-全部}"
echo ""

# 创建增量变更状态文件
INCREMENTAL_STATE=".devflow/$FEATURE/incremental.json"
mkdir -p ".devflow/$FEATURE"

# 初始化状态文件（如果不存在）
if [ ! -f "$INCREMENTAL_STATE" ]; then
  cat > "$INCREMENTAL_STATE" << JSON_END
{
  "feature": "$FEATURE",
  "mode": "incremental",
  "changes": [],
  "base_commit": "$(git rev-parse HEAD 2>/dev/null || echo 'none')",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
JSON_END
fi


# 增量变更：添加字段
incremental_add_field() {
  local feature="$1"
  local field_path="$2"  # 格式：table.field_name
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  增量变更：添加字段"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  # 解析字段路径
  local table_name="${field_path%%.*}"
  local field_name="${field_path##*.}"
  
  echo -e "${CYAN}[步骤 1/5]${NC} 检查现有设计..."
  
  DESIGN_FILE="docs/detailed-design/${feature}-design.md"
  if [ ! -f "$DESIGN_FILE" ]; then
    echo -e "${RED}❌ 设计文档不存在: $DESIGN_FILE${NC}"
    exit 1
  fi
  
  echo -e "${GREEN}✓${NC} 设计文档存在"
  echo ""
  
  echo -e "${CYAN}[步骤 2/5]${NC} 生成字段变更建议..."
  echo ""
  echo "请在设计文档中添加以下内容："
  echo ""
  echo "────────────────────────────────────────────────────────────────"
  cat << FIELD_TEMPLATE
### 数据表字段（新增）

#### 表名：$table_name

| 字段名 | 类型 | 长度 | 是否必填 | 默认值 | 说明 |
|--------|------|------|----------|--------|------|
| $field_name | VARCHAR | 50 | 是 | NULL | TODO: 补充字段说明 |

**变更原因**：TODO: 补充变更原因
**影响范围**：仅新增字段，不影响现有数据

#### 对应的 Flyway 迁移脚本

\`\`\`sql
-- V<version>__add_${field_name}_to_${table_name}.sql

ALTER TABLE $table_name
ADD COLUMN $field_name VARCHAR(50) NULL COMMENT 'TODO: 补充字段说明';
\`\`\`
FIELD_TEMPLATE
  echo "────────────────────────────────────────────────────────────────"
  echo ""
  
  echo -e "${CYAN}[步骤 3/5]${NC} 识别需要修改的文件..."
  echo ""
  echo "受影响的文件（最小化变更）："
  echo "  1. docs/detailed-design/${feature}-design.md（添加字段定义）"
  echo "  2. backend/src/main/resources/db/migration/h2/${feature}/V*__add_${field_name}.sql"
  echo "  3. backend/src/main/java/entity/${table_name^}DO.java（添加字段属性）"
  echo "  4. backend/src/main/java/dto/${table_name^}VO.java（添加字段属性）"
  echo ""
  
  echo -e "${CYAN}[步骤 4/5]${NC} 生成增量测试..."
  echo ""
  echo "需要补充的测试："
  echo "  1. 测试新字段的插入"
  echo "  2. 测试新字段的查询"
  echo "  3. 测试新字段的校验（如果有）"
  echo ""
  
  echo -e "${CYAN}[步骤 5/5]${NC} 记录变更..."
  
  # 记录到增量状态文件
  "${DEVFLOW_PY[@]}" << PYTHON_END
import json
from datetime import datetime

with open("$INCREMENTAL_STATE", "r") as f:
    state = json.load(f)

state["changes"].append({
    "type": "add-field",
    "scope": "$field_path",
    "table": "$table_name",
    "field": "$field_name",
    "timestamp": datetime.utcnow().isoformat() + "Z",
    "status": "pending"
})

with open("$INCREMENTAL_STATE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_END
  
  echo -e "${GREEN}✓${NC} 变更已记录"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo -e "${GREEN}✅ 增量变更计划已生成${NC}"
  echo ""
  echo "下一步："
  echo "  1. 按照上述建议修改设计文档"
  echo "  2. 重新渲染 design.json："
  echo "     python3 scripts/df_pipeline.py design $feature"
  echo "  3. 生成 Flyway 迁移脚本和实体类"
  echo "  4. 补充测试"
  echo "  5. 运行增量验证："
  echo "     bash scripts/incremental_verify.sh $feature"
  echo "════════════════════════════════════════════════════════════════"
}

# 增量变更：修改字段
incremental_modify_field() {
  local feature="$1"
  local field_path="$2"
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  增量变更：修改字段"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  local table_name="${field_path%%.*}"
  local field_name="${field_path##*.}"
  
  echo -e "${CYAN}[步骤 1/4]${NC} 检查现有字段定义..."
  
  DESIGN_JSON=".devflow/$feature/design.json"
  if [ ! -f "$DESIGN_JSON" ]; then
    echo -e "${RED}❌ design.json 不存在，请先运行 P2 阶段${NC}"
    exit 1
  fi
  
  # 提取现有字段定义
  echo -e "${GREEN}✓${NC} 找到现有字段定义"
  echo ""
  
  echo -e "${CYAN}[步骤 2/4]${NC} 生成修改建议..."
  echo ""
  echo "请明确以下变更内容："
  echo ""
  echo "  • 字段名是否修改？"
  echo "  • 字段类型是否修改？（VARCHAR → TEXT）"
  echo "  • 字段长度是否修改？（50 → 100）"
  echo "  • 是否必填是否修改？（可空 → 非空）"
  echo "  • 默认值是否修改？"
  echo ""
  
  echo -e "${CYAN}[步骤 3/4]${NC} 影响分析..."
  echo ""
  echo "⚠️  修改字段可能影响："
  echo "  • 现有数据（需要数据迁移）"
  echo "  • 现有代码（需要更新引用）"
  echo "  • 现有测试（需要更新断言）"
  echo ""
  echo "建议："
  echo "  1. 如果修改类型/长度，使用 ALTER TABLE 语句"
  echo "  2. 如果修改为非空，先填充默认值再修改约束"
  echo "  3. 如果重命名字段，分两步：添加新字段 → 迁移数据 → 删除旧字段"
  echo ""
  
  echo -e "${CYAN}[步骤 4/4]${NC} 记录变更..."
  
  "${DEVFLOW_PY[@]}" << PYTHON_END
import json
from datetime import datetime

with open("$INCREMENTAL_STATE", "r") as f:
    state = json.load(f)

state["changes"].append({
    "type": "modify-field",
    "scope": "$field_path",
    "table": "$table_name",
    "field": "$field_name",
    "timestamp": datetime.utcnow().isoformat() + "Z",
    "status": "pending",
    "warning": "需要数据迁移计划"
})

with open("$INCREMENTAL_STATE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_END
  
  echo -e "${GREEN}✓${NC} 变更已记录"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo -e "${YELLOW}⚠️  修改字段是高风险操作${NC}"
  echo ""
  echo "建议先执行："
  echo "  bash scripts/analyze_field_impact.sh $feature $field_path"
  echo "════════════════════════════════════════════════════════════════"
}

# 增量变更：添加 API
incremental_add_api() {
  local feature="$1"
  local api_path="$2"  # 格式：POST:/api/users
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  增量变更：添加 API"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  local method="${api_path%%:*}"
  local path="${api_path##*:}"
  
  echo -e "${CYAN}[步骤 1/5]${NC} 检查 API 冲突..."
  
  DESIGN_JSON=".devflow/$feature/design.json"
  if [ -f "$DESIGN_JSON" ]; then
    # 检查是否已存在相同路径的 API
    if grep -q "\"path\": \"$path\"" "$DESIGN_JSON" 2>/dev/null; then
      echo -e "${YELLOW}⚠️  警告：已存在相同路径的 API${NC}"
    else
      echo -e "${GREEN}✓${NC} 无冲突"
    fi
  fi
  echo ""
  
  echo -e "${CYAN}[步骤 2/5]${NC} 生成 API 定义模板..."
  echo ""
  echo "请在设计文档中添加以下内容："
  echo ""
  echo "────────────────────────────────────────────────────────────────"
  cat << API_TEMPLATE
### API 接口（新增）

#### $method $path

**功能描述**：TODO: 补充 API 功能描述

**请求参数**：

| 参数名 | 类型 | 是否必填 | 说明 |
|--------|------|----------|------|
| TODO | String | 是 | TODO |

**响应格式**：

\`\`\`json
{
  "code": 200,
  "message": "成功",
  "data": {
    // TODO: 补充响应字段
  }
}
\`\`\`

**权限要求**：TODO: 补充权限编码

**业务规则**：

- TODO: 补充业务规则

**异常处理**：

| 错误码 | 说明 | 处理方式 |
|--------|------|----------|
| 400 | 参数校验失败 | 返回具体校验错误 |
| 401 | 未授权 | 返回登录提示 |
| 403 | 权限不足 | 返回权限提示 |
API_TEMPLATE
  echo "────────────────────────────────────────────────────────────────"
  echo ""
  
  echo -e "${CYAN}[步骤 3/5]${NC} 识别需要修改的文件..."
  echo ""
  echo "受影响的文件（最小化变更）："
  echo "  1. docs/detailed-design/${feature}-design.md（添加 API 定义）"
  echo "  2. backend/src/main/java/controller/*Controller.java（添加方法）"
  echo "  3. backend/src/main/java/service/*Service.java（添加业务逻辑）"
  echo "  4. backend/src/test/java/controller/*ControllerTest.java（添加测试）"
  echo ""
  
  echo -e "${CYAN}[步骤 4/5]${NC} 生成测试用例..."
  echo ""
  echo "需要补充的测试："
  echo "  1. 200 Success - 正常请求"
  echo "  2. 400 Bad Request - 参数校验失败"
  echo "  3. 401 Unauthorized - 未授权"
  echo "  4. 403 Forbidden - 权限不足"
  echo ""
  
  echo -e "${CYAN}[步骤 5/5]${NC} 记录变更..."
  
  "${DEVFLOW_PY[@]}" << PYTHON_END
import json
from datetime import datetime

with open("$INCREMENTAL_STATE", "r") as f:
    state = json.load(f)

state["changes"].append({
    "type": "add-api",
    "scope": "$api_path",
    "method": "$method",
    "path": "$path",
    "timestamp": datetime.utcnow().isoformat() + "Z",
    "status": "pending"
})

with open("$INCREMENTAL_STATE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_END
  
  echo -e "${GREEN}✓${NC} 变更已记录"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo -e "${GREEN}✅ 增量变更计划已生成${NC}"
  echo ""
  echo "下一步："
  echo "  1. 按照上述建议修改设计文档"
  echo "  2. 重新渲染 design.json"
  echo "  3. 生成 Controller 方法和 Service 方法"
  echo "  4. 运行 P3 编译验证"
  echo "  5. 生成并补充测试"
  echo "════════════════════════════════════════════════════════════════"
}

# 增量变更：修改 API
incremental_modify_api() {
  local feature="$1"
  local api_path="$2"
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  增量变更：修改 API"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  echo -e "${YELLOW}⚠️  修改 API 是破坏性变更${NC}"
  echo ""
  echo "建议策略："
  echo "  1. 保持向后兼容：添加新参数设为可选"
  echo "  2. 版本化：创建 /api/v2/... 新版本"
  echo "  3. 废弃标记：标记旧 API 为 @Deprecated"
  echo ""
  echo "如果必须修改，请明确："
  echo "  • 修改了哪些参数？（新增/删除/重命名/类型变更）"
  echo "  • 修改了响应格式吗？"
  echo "  • 影响哪些客户端？"
  echo ""
}

# 增量变更：修复 bug
incremental_fix_bug() {
  local feature="$1"
  local bug_id="$2"
  
  echo "════════════════════════════════════════════════════════════════"
  echo "  增量变更：修复 Bug"
  echo "════════════════════════════════════════════════════════════════"
  echo ""
  
  echo -e "${CYAN}[步骤 1/4]${NC} Bug 信息..."
  echo ""
  echo "Bug ID: $bug_id"
  echo ""
  echo "请提供以下信息："
  echo "  1. Bug 描述"
  echo "  2. 复现步骤"
  echo "  3. 根本原因"
  echo "  4. 修复方案"
  echo ""
  
  echo -e "${CYAN}[步骤 2/4]${NC} 影响范围分析..."
  echo ""
  echo "Bug 修复通常只需修改："
  echo "  • 1-2 个文件"
  echo "  • 1-10 行代码"
  echo ""
  echo "如果影响范围超出，建议拆分为独立需求"
  echo ""
  
  echo -e "${CYAN}[步骤 3/4]${NC} 测试策略..."
  echo ""
  echo "必须添加："
  echo "  1. 回归测试（复现 bug 的测试）"
  echo "  2. 边界测试（防止类似 bug）"
  echo ""
  
  echo -e "${CYAN}[步骤 4/4]${NC} 记录变更..."
  
  "${DEVFLOW_PY[@]}" << PYTHON_END
import json
from datetime import datetime

with open("$INCREMENTAL_STATE", "r") as f:
    state = json.load(f)

state["changes"].append({
    "type": "fix-bug",
    "scope": "$bug_id",
    "bug_id": "$bug_id",
    "timestamp": datetime.utcnow().isoformat() + "Z",
    "status": "pending"
})

with open("$INCREMENTAL_STATE", "w") as f:
    json.dump(state, f, indent=2)
PYTHON_END
  
  echo -e "${GREEN}✓${NC} 变更已记录"
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo -e "${GREEN}✅ Bug 修复计划已生成${NC}"
  echo "════════════════════════════════════════════════════════════════"
}

# 其他增量变更函数（占位）
incremental_add_rule() { echo "TODO: 实现添加业务规则"; }
incremental_modify_rule() { echo "TODO: 实现修改业务规则"; }
incremental_add_validation() { echo "TODO: 实现添加参数校验"; }

# 根据变更类型执行增量变更
case "$CHANGE_TYPE" in
  "add-field")
    incremental_add_field "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "modify-field")
    incremental_modify_field "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "add-api")
    incremental_add_api "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "modify-api")
    incremental_modify_api "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "add-rule")
    incremental_add_rule "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "modify-rule")
    incremental_modify_rule "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "add-validation")
    incremental_add_validation "$FEATURE" "$CHANGE_SCOPE"
    ;;
  "fix-bug")
    incremental_fix_bug "$FEATURE" "$CHANGE_SCOPE"
    ;;
  *)
    echo -e "${RED}❌ 未知的变更类型: $CHANGE_TYPE${NC}"
    exit 1
    ;;
esac

# 如果直接运行，显示用法
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  echo "增量变更模式已启动"
fi
