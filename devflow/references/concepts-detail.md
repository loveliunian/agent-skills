## POSIX（§7 细则）

**必须使用**：
- `grep -E`（POSIX ERE，macOS 支持）
- `find ... -name "*.java" | xargs grep`（不用 globstar `**/*.java`）
- `sed -E`（不用 `-r`，不用 PCRE `-P`）

**禁止**：
- `grep -P`（PCRE，macOS BSD 不支持）
- `find -path "*/X/*"`（GNU 扩展）
- `**/*.java` glob（bash 3.2 不支持 globstar；`GROUPS` 等是 bash 内建特殊数组名，禁止作变量名）
- zsh glob 模式（`?` 作为单字符通配符需 `set +o noglob` 保护）

---

## Fact-Sources（§11 细则）

### 清单（7 份手维护 + 5 份 auto）

| 文件 | 类型 | 维护方 | 触发时机 |
|------|------|--------|----------|
| `_commons.md` | 手维护 | 主 Agent | P2 详细设计冻结时 |
| `_权限矩阵.md` | auto + 手维护 | `scripts/generate-permission-matrix.sh` + 主 Agent | 每次新增 Controller 后 |
| `_环境与账号.md` | 手维护 | 主 Agent | 每次新环境时 |
| `_菜单Seed索引.md` | 手维护 | 主 Agent | 每次新增菜单时 |
| `INDEX-章节锚点.md` | 手维护 | 主 Agent | 详设模板冻结时 |
| `INDEX-表.md` | 手维护 | 主 Agent | 详设 §3 冻结时 |
| `INDEX-接口.md` | 手维护 | 主 Agent | 详设 §6 冻结时 |
| `_ER图索引.md` | auto | `scripts/generate-er-index.sh` | 每次 Flyway 变更后 |
| `_Schema变更日志.md` | auto | `scripts/generate-schema-changelog.sh` | 每次 Flyway 变更后 |
| `INDEX-表-auto.md` | auto | `scripts/generate-table-index.sh` | 每次 DDL 变更后 |
| `INDEX-接口-auto.md` | auto | `scripts/generate-interface-index.sh` | 每次 Controller 变更后 |

### 初始化命令

```bash
/init-fact-sources            # 首次创建（不会覆盖已有文件）
/init-fact-sources --force    # 强制覆盖（慎用）
```

**禁止**：跳过事实源直接编码 — `s1_fact_sources_gate.sh` 必须先 PASS。

### auto 索引的差异审查

```bash
bash "$SKILL_ROOT/scripts/generate-table-index.sh" --diff
bash "$SKILL_ROOT/scripts/generate-interface-index.sh" --diff
```

若 `人工有但 DB 无` 或 `DB 有但人工无` 任意一栏 > 0 → 必须 review 是否漏建/漏写。

### 跨项目复用原则

- 任何脚本不得硬编码项目路径（必须用 `DOC_DIR` / `OUTPUT_FILE` / `CONTROLLER_GLOB` 环境变量）
- 任何模板不得绑定项目名（用 `{DATE}` / `{FEATURE}` 占位符）
- 任何规则不得绑定单一客户端框架；服务端与 PC Web、小程序、APP 的项目级约定必须由事实源和适配器声明

**禁止**：把当前项目的脚本"复制粘贴"到 skill 后还在文件名带项目前缀。

---


## Skill Universalization（skill 通用化）

**铁律**：本 skill 必须支持从零构建、存量新增和需求修改。内置服务端 Gate 适用于 Java/Spring/Flyway；客户端覆盖 PC Web、微信小程序、APP 或无前端交付。其他后端栈必须先补充项目级 adapter 与等价 Gate，不能假装已被内置 Gate 覆盖。

### 12.1 三层解耦

| 层 | 内容 | 必须可替换 |
|---|------|-----------|
| **skill 层** | SKILL.md / phases/* / commands/* / subagents/* | 否 |
| **项目层** | scripts/*.sh（项目内副本） | 是 |
| **数据层** | docs/detailed-design/_*.md / INDEX-*.md | 是 |

### 12.2 参数化路径

生成类脚本支持 `DOC_DIR`、`OUTPUT_FILE`；分析和 Gate 脚本通过 `<service>`、`<feature>`、`DESIGN_FILE`、`MIGRATION_ROOT` 等显式参数定位目标。不得宣称所有脚本支持同一组环境变量。

### 12.3 平台无关

- 不得硬编码 `/Users/huymac/...`
- 不得假设绝对路径
- 不得要求特定 IDE / 终端

---


## 跨项目初始化（§11.5）

新项目接入本 skill 时：

```bash
# 1. 复制 skill 脚本到项目
mkdir -p scripts
cp <skill-root>/scripts/*.sh scripts/

# 2. 初始化事实源
bash "$SKILL_ROOT/scripts/init-fact-sources.sh"

# 3. 验证
bash "$SKILL_ROOT/scripts/s1_fact_sources_gate.sh" docs/detailed-design
```

---

