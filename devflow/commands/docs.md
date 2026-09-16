---
name: docs
version: "3.25.0"
description: >-
  Use when updating project documentation after a feature is delivered, mentions
  "/docs", "更新文档", "文档", "文档更新", "api docs", "readme", "changelog", or "doc update".
  Must list actual file paths for every deliverable — never just "已完成". Each file must exist on disk.
paths:
  - "docs/**"
  - "README.md"
  - "**/*.md"
disable-model-invocation: false
allowed-tools:
  - read
  - write
  - exec
  - glob
  - grep
---

# /docs - 文档更新（P9）

> **核心约束**：**禁止"文档已完成"文字**，必须列 5+ 份实际产出文件路径。

## 使用方式

```
/docs <feature>
/docs <feature> --checklist=api,ops,runbook,faq
```

## 示例

```
/docs m-03-basic-library
/docs payment-system --checklist=api,ops
```

## 命名约定

`<feature>` = kebab-case 全小写 → 输出在 `docs/api/` `docs/ops/` `docs/复盘/` 等。

| 文档 | 路径 |
|------|------|
| API 文档 | `docs/api/<feature>-api.md` |
| 运维文档 | `docs/ops/<feature>-ops.md` |
| Runbook | `docs/runbook/<feature>-runbook.md`（可选） |
| FAQ | `docs/faq/<feature>-faq.md`（可选） |
| 数据字典 | `docs/data/<feature>-data-dictionary.md`（可选） |
| 复盘 | `docs/复盘/<feature>-复盘.md` |

## 执行步骤

### 1. 检查现有文档清单

```bash
# 列出所有 <feature>-* 文档
find docs/ -name "<feature>-*.md" -type f
```

### 2. API 文档（强制）

`docs/api/<feature>-api.md` 必须含：
- 接口列表（与详设 §6 一致）
- 每个接口的请求/响应示例
- 错误码表
- 鉴权说明

### 3. 运维文档（强制）

`docs/ops/<feature>-ops.md` 必须含：
- 部署步骤
- 健康检查
- 监控指标列表
- 常见问题（启动失败 / 健康检查失败 / 慢响应）

### 4. 复盘 markdown

`docs/复盘/<feature>-复盘.md` 必须含：
- "上次遗漏了什么"段
- "本次新发现的坑"段
- 修复策略
- 复盘总结

### 5. 输出文档路径清单与 P9 索引

写到 `docs/复盘/<feature>-audit-P9.md` 或直接 stdout：

```markdown
# <feature> 文档清单

## 实际产出文件路径

1. `docs/api/<feature>-api.md` ✅ (文件大小: 12KB, 行数: 280)
2. `docs/ops/<feature>-ops.md` ✅ (文件大小: 8KB, 行数: 195)
3. `docs/复盘/<feature>-复盘.md` ✅ (文件大小: 5KB, 行数: 120)
4. `docs/测试/<feature>-PRD验证报告.md` ✅ (文件大小: 15KB, 行数: 360)
5. `docs/评审/<feature>-代码审查报告.md` ✅ (文件大小: 18KB, 行数: 425)
6. `docs/评审/<feature>-安全审计报告.md` ✅ (文件大小: 10KB, 行数: 240)
7. `docs/评审/<feature>-性能审计报告.md` ✅ (文件大小: 9KB, 行数: 210)
8. `docs/发布/<feature>-部署记录.md` ✅ (文件大小: 6KB, 行数: 150)
9. `docs/发布/<feature>-监控配置.md` ✅ (文件大小: 5KB, 行数: 120)
10. `docs/测试用例/<feature>-测试用例.md` ✅ (文件大小: 25KB, 行数: 580)

**总计：10 份文档 ✅（≥ 5 份）**
```

并创建 `docs/<feature>-文档索引.md`（使用 `templates/文档索引-模板.md`），填写并验证：

```text
USER_DOC=docs/...
USER_DOC_SHA256=<64-hex>
DEVELOPER_DOC=docs/...
DEVELOPER_DOC_SHA256=<64-hex>
API_DOC=docs/...
API_DOC_SHA256=<64-hex>
OPERATIONS_DOC=docs/...
OPERATIONS_DOC_SHA256=<64-hex>
RELEASE_NOTES=docs/...
RELEASE_NOTES_SHA256=<64-hex>
```

Gate（强制）

| 项 | 强制条件 |
|----|----------|
| 文档数量 | **≥ 5 份实际产出文件**（五类各一） |
| 路径真实性 | 每个文件 `test -f` 验证 + `_SHA256` 固化与实测一致 |
| 文档实质 | 每份 ≥10 行、≥2 标题、≥5 正文行（占位文档不通过） |
| 语义章节 | 用户指南含"使用/指南"、开发指南含"开发/构建"、API 含"接口/API"、运维含"运维/部署/监控"、发布说明含"变更/版本/发布" |
| API 文档 | 与详设 §6 接口清单 100% 对应 |
| 运维文档 | 含部署 / 监控 / 排错 |
| 复盘 markdown | 含"上次遗漏了什么"段 |

## 输出

- `docs/api/<feature>-api.md`
- `docs/ops/<feature>-ops.md`
- `docs/复盘/<feature>-复盘.md`
- 其他辅助文档

## 自检命令

```bash
# P9 自检：≥ 5 份实际文档存在
COUNT=$(find docs/ -name "<feature>-*.md" -type f | wc -l)
echo "文档数量: $COUNT"
test "$COUNT" -ge 5  # 必须 ≥ 5

# 关键文档存在性
for f in docs/api/<feature>-api.md \
         docs/ops/<feature>-ops.md \
         docs/复盘/<feature>-复盘.md \
         docs/测试/<feature>-PRD验证报告.md \
         docs/评审/<feature>-代码审查报告.md; do
  test -f "$f" && echo "$f OK" || echo "$f MISSING"
done
```

## 角色约束

- 主 Agent 执行
- 可调用技术写作子 Agent 协助
- 不允许"已完成"无证据，必须附 `ls -la` 或 `wc -l` 输出

## 与其他命令关系

- 前置：P3b/P3c/P3d/P4/P6/P7/P8 全部 PASS
- 完成后：**强制**运行 `/audit-completeness P9 <feature>`
- P9 PASS 后才能进 `/retro` (P10)

---

## 验收（真实命令）

```bash
# 运行真实 Gate，以退出码为准；禁止 echo 自报 PASS
bash "$SKILL_ROOT/scripts/artifact_gate.sh" P9 <feature>
# 期望：exit 0 = 文档清单检查通过
```
