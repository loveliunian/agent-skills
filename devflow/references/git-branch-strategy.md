---
name: git-branch-strategy
version: "3.27.4"
description: >-
  Git 分支策略与工作流规范。配合 /devflow 使用，确保多 Phase 并行开发时的分支管理。
  ：与 devflow-state.sh checkpoint 集成。
metadata:
  tags: "git,branch,workflow,devflow"
---

# Git 分支策略 

> **目的**：规范 devflow 工作流中的 Git 分支管理，确保代码质量和团队协作效率。

## 1. 分支模型

### 1.1 长期分支

| 分支 | 用途 | 保护级别 |
|------|------|----------|
| `main` | 生产环境代码 | 最高 |
| `develop` | 开发主分支 | 高 |

### 1.2 临时分支

| 前缀 | 示例 | 用途 |
|------|------|------|
| `feature/` | `feature/M-03-basic-library` | 功能开发 |
| `fix/` | `fix/M-03-auth-bug` | Bug 修复 |
| `refactor/` | `refactor/M-03-service-split` | 重构 |
| `docs/` | `docs/M-03-api-docs` | 文档更新 |

## 2. Phase 与分支映射

### 2.1 标准流程

```
feature/M-03 ──┬── P0-P2 (设计分支)
               ├── P3  (开发分支)
               ├── P3b (Review 分支)
               └── P4+ (修复分支)
```

### 2.2 分支命名规范

```
feature/<feature-id>           # 功能分支
feature/<feature-id>-p<phase> # Phase 分支（可选）

示例：
feature/M-03-basic-library
feature/M-03-basic-library-p3
feature/M-03-basic-library-p3b-review
```

### 2.3 命名规则

| 规则 | 说明 |
|------|------|
| 全部小写 | `feature/m-03` |
| 使用连字符 | `feature/m-03-basic` |
| 包含 feature ID | `M-03`, `M-04` |
| 可选 Phase 后缀 | `-p3`, `-p3b` |

## 3. 开发流程

### 3.1 从 develop 创建功能分支

```bash
# 1. 确保 develop 最新
git checkout develop
git pull origin develop

# 2. 创建功能分支
git checkout -b feature/M-03-basic-library

# 3. 初始化 devflow 状态
bash "$SKILL_ROOT/scripts/devflow-state.sh" init m-03-basic-library
```

### 3.2 Phase 完成时的操作

```bash
# P3 编码完成
git add .
git commit -m "feat(M-03): P3 编码完成

- 实现 Element CRUD API
- 添加 Flyway 迁移脚本
- 前端页面完成"

# 打标签（可选）
git tag -a v3.5-M-03-P3 -m "M-03 P3 编码完成"

# 保存检查点
bash "$SKILL_ROOT/scripts/devflow-state.sh" checkpoint m-03-basic-library "P3 编码完成"
```

### 3.3 Code Review 分支

```bash
# 1. 推送分支
git push -u origin feature/M-03-basic-library

# 2. 创建 PR 到 develop
# PR 标题格式：[M-03] 功能名称 - Phase X

# 3. Review 通过后合并
git checkout develop
git merge --no-ff feature/M-03-basic-library
git push origin develop
```

## 4. 分支保护规则

### 4.1 main 分支

- ❌ 禁止直接 push
- ❌ 禁止 force push
- ✅ 需要 PR + 2 人 approval
- ✅ 需要通过所有 CI 检查

### 4.2 develop 分支

- ❌ 禁止直接 push
- ✅ 需要 PR + 1 人 approval
- ✅ 需要通过 CI 检查

### 4.3 feature/* 分支

- ⚠️ 建议 PR review
- ⚠️ 建议定期 rebase develop

## 5. Commit 规范

### 5.1 Commit 类型

| 类型 | 说明 | 示例 |
|------|------|------|
| `feat` | 新功能 | `feat(M-03): 添加元素管理 API` |
| `fix` | Bug 修复 | `fix(M-03): 修复元素删除权限校验` |
| `refactor` | 重构 | `refactor(M-03): 拆分 ElementService` |
| `docs` | 文档 | `docs(M-03): 更新 API 文档` |
| `test` | 测试 | `test(M-03): 添加 E2E 测试` |
| `chore` | 杂项 | `chore: 更新依赖版本` |

### 5.2 Commit 模板

```bash
# .gitcommitmsg 模板
<type>(<scope>): <subject>

<body>

<footer>
```

### 5.3 Commit 示例

```bash
# 简单
git commit -m "feat(M-03): 添加元素管理 API"

# 详细
git commit -m "feat(M-03): 添加元素管理 API

- GET /api/elements/{id}
- POST /api/elements
- PUT /api/elements/{id}
- DELETE /api/elements/{id}

Closes #123"
```

## 6. 与 devflow-state.sh 集成

### 6.1 分支与状态同步

| devflow 状态 | Git 操作 |
|--------------|----------|
| 工作流初始化 | `git checkout -b feature/M-03` |
| Phase 完成 | `git commit` + `git tag` |
| 检查点保存 | 自动关联状态文件 |
| 工作流完成 | `git merge` 到 develop |

### 6.2 恢复场景

```bash
# 场景：工作流中断后恢复

# 1. 查看状态
bash "$SKILL_ROOT/scripts/devflow-state.sh" status m-03-basic-library

# 2. 找到对应的分支
git branch -a | grep m-03

# 3. 切换到分支
git checkout feature/m-03-basic-library

# 4. 继续开发
# ...
```

## 7. 常见问题

### 7.1 分支冲突

```bash
# 定期 rebase develop
git fetch origin
git rebase origin/develop
```

### 7.2 错误分支提交

```bash
# 撤销最后一个 commit（保留更改）
git reset --soft HEAD~1

# 切换到正确分支
git checkout feature/correct-branch

# 重新提交
git commit -m "..."
```

### 7.3 删除本地分支

```bash
# 删除已合并的分支
git branch -d feature/M-03

# 强制删除未合并的分支
git branch -D feature/M-03
```

## 8. CI/CD 集成

### 8.1 分支触发规则

| 分支 | 触发 CI |
|------|----------|
| `feature/*` | ✅ lint + unit test |
| `develop` | ✅ lint + test + build |
| `main` | ✅ lint + test + build + deploy |

### 8.2 CI 检查项

```yaml
# .gitlab-ci.yml 或 .github/workflows/ci.yml
stages:
  - lint
  - test
  - build

workflow-check:
  stage: lint
  script:
    - mvn checkstyle:check
    - npm run lint

unit-test:
  stage: test
  script:
    - mvn test
    - mvn jacoco:report

integration-test:
  stage: test
  script:
    - mvn verify -Pintegration
```

---

## Changelog

| 版本 | 日期 | 变更 |
|------|------|------|
| v3.5.0 | 2026-08-12 | 新增 devflow-state.sh 集成 |
| v3.0.0 | 2026-07-28 | 初始版本 |
