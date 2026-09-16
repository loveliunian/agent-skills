# Contributing

## 改动 devflow

1. 读 `devflow/SKILL.md`（唯一权威入口）与 `devflow/concepts/core.md`（不可违背的铁律）。
2. 任何修复/升级合入前必须递增 `SKILL.md` frontmatter 的 `version`（z 位），并同步所有带版本的文件
   （`bash devflow/scripts/check-skill-version.sh` 会列出漂移项）。
3. 在 `devflow/references/CHANGELOG.md` 顶部新增对应版本文档条目。

## 验证（必须全绿）

```bash
bash devflow/tests/run-tests.sh        # 完整测试套件
bash devflow/scripts/check-skill-version.sh
bash devflow/scripts/release-audit.sh
bash devflow/scripts/secret-scan.sh
```

发布自身必须走唯一入口（包含 ShellCheck、manifest 不可变链、副本直连校验）：

```bash
bash devflow/scripts/release.sh
```

## 约定

- 不引入真实秘密/生产数据（见 `SECURITY.md`）；
- 新增第三方内容须登记到 `THIRD_PARTY_NOTICES.md`；
- 新增 `phases/`、`subagents/`、`templates/` 资源须同步 `devflow/references/RESOURCE-REGISTRY.md`；
- 行为类改动请一并补测试（`devflow/tests/`）。

## PR

- 说明动机、改动面、验证命令与结果；
- 保持改动聚焦，不混入无关重构；
- CI（`.github/workflows/devflow-ci.yml`）必须通过。
