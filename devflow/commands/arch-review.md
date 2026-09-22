---
name: arch-review
description: 代码架构审查命令
version: "3.29.6"
allowed-tools: [read, write, exec, glob, grep, task]
alwaysApply: true
---

# /arch-review — 架构审查

paths: ["backend/**", "frontend/**"]
> 使用 `architecture-reviewer` Agent 进行模块级架构审查

## 目标

在模块/功能开发完成后，审查代码架构：
- **代码重复检测**：发现可提取为公共方法/类的重复代码
- **公共组件识别**：发现可抽取为公共工具类的代码
- **配置归一化**：发现可统一管理的配置
- **分层合理性**：检查是否遵循分层架构

## 执行时机

| 场景 | 说明 |
|------|------|
| `/build` 完成后 | 模块代码写完后立即执行 |
| `/review` 完成后 | Code Review 通过后可补充执行 |
| 功能迭代稳定后 | 在代码稳定后执行 |

## 使用方式

```
/arch-review M-04
/arch-review <feature-name>
```

## 执行流程

```
┌─────────────────────────────────────────────────────────────┐
│                   /arch-review 执行流程                      │
├─────────────────────────────────────────────────────────────┤
│  1. 代码结构扫描                                            │
│     ├── 文件数量统计                                         │
│     ├── 代码行数统计                                         │
│     └── 分层结构检查                                         │
│         ↓                                                   │
│  2. 代码重复检测                                            │
│     ├── Magic Number/String                                 │
│     ├── 相似 SQL 片段                                       │
│     └── 相似方法模式                                         │
│         ↓                                                   │
│  3. 公共组件识别                                            │
│     ├── 工具方法重复                                         │
│     ├── DTO 转换模式                                        │
│     └── 日期/字符串处理                                       │
│         ↓                                                   │
│  4. 配置归一化检测                                          │
│     ├── 硬编码配置                                          │
│     ├── 分散枚举/常量                                        │
│     └── 配置类数量                                           │
│         ↓                                                   │
│  5. 分层合理性检查                                          │
│     ├── 跨层依赖                                            │
│     ├── 大型 Controller/Service                             │
│     └── 上帝类检测                                          │
│         ↓                                                   │
│  6. 架构报告输出                                            │
│     └── docs/评审/<feature>-架构评审报告.md        │
└─────────────────────────────────────────────────────────────┘
```

## 报告输出

报告将写入：`docs/评审/<feature>-架构评审报告.md`

### 报告结构

```markdown
# <feature> 架构审查报告

## 1. 代码重复分析
## 2. 公共组件建议
## 3. 配置归一化建议
## 4. 分层架构问题
## 5. 依赖分析
## 6. 优化建议汇总
## 7. 统计数据
```

## Agent 角色

| 角色 | 职责 | Agent 类型 |
|------|------|-----------|
| `architecture-reviewer` | 架构审查（独立 session） | `generalPurpose` |

> **铁律**：`architecture-reviewer` 专门用于架构审查，禁止用于开发任务

## 铁律

1. **独立 session**：必须在独立 session 中执行
2. **有证据**：每个优化点必须有具体代码位置
3. **可执行**：优化建议必须可操作，不能是空话

## 与 /devflow 的关系

| 命令 | 范围 | 说明 |
|------|------|------|
| `/devflow` | 完整流程 | 包含 /arch-review 可选执行 |
| `/review` | Code Review | 侧重代码正确性 |
| `/arch-review` | 架构审查 | 侧重架构优化（新增） |

## 输出文件

```
docs/评审/<feature>-架构评审报告.md
```

---

## 常用检测命令

### 代码重复检测

```bash
# Magic Number/String
find backend -name "*.java" | xargs grep -nE '"[^"]{4,}"' | grep -v "log\|import"

# 重复 SQL 片段
find backend -name "*.xml" -path "*/mapper/*" | xargs grep -nE "<sql id="

# 大方法（> 50 行）
find backend -name "*ServiceImpl.java" | xargs awk '/^[[:space:]]*(public|private).*\{$/ {count=0} /^[[:space:]]*\}.*$/ {count++} NR>1000 {if(count>50) print FILENAME":"NR" ("count" lines)"}'
```

### 公共组件检测

```bash
# 工具方法重复
find backend -name "*.java" | xargs grep -nE "public static.*\(" | head -30

# 转换逻辑重复
find backend -name "*.java" | xargs grep -cE "\.copyProperties|\.map\(" | awk -F: '$2>5 {print}'
```

### 配置归一化检测

```bash
# 硬编码配置
find backend -name "*.java" | xargs grep -nE "http://|localhost|:8080" | grep -v "@Value"

# 枚举分散
find backend -name "*.java" | xargs grep -l "enum" | head -20
```

### 分层检测

```bash
# Controller 直接依赖 Repository
find backend -name "*Controller.java" | xargs grep -l "Repository\|Mapper"

# 大型类
find backend -name "*.java" -exec wc -l {} + | sort -rn | head -10
```
