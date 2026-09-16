# agent-skills

自己做的 skill。

## Skills

| Skill | 版本 | 说明 |
|-------|------|------|
| [devflow](./devflow/) | 3.23.1 | PRD 到生产的阶段门禁交付流程：需求澄清、技术选型、详细设计、规范实现、测试、部署、监控、文档、复盘，支持 checkpoint 恢复。核心流程与技术栈解耦（Runtime Profile），内置 Java/Spring/Flyway 参考 Profile；客户端覆盖 PC Web、微信小程序和移动端。 |
| [flow-test-contract](./flow-test-contract/) | 1.7.5 | 契约化流程迁移测试：双端对拍、覆盖账本、发布门禁与断点复跑。 |

## 同步（唯一入口）

编辑任何 skill 后跑这一条命令，完成全部同步（软链自愈 + flow-test-contract 分发到各工具 + git 提交推送）：

```bash
bash ~/dev/agent-skills/sync.sh "提交信息"
bash ~/dev/agent-skills/sync.sh --local    # 只做本地同步，不提交推送
```

- 各工具 skills 目录里的 devflow 与 flow-test-contract(.agents/opencode) 均为**直连本仓库的软链**；
- flow-test-contract 在其余工具目录由 `flow-test-contract/sync-to-tools.sh` 维护实体副本（`runtime/` 本机运行态不入库）。

## 安装

推荐软链安装（`git pull` 即更新）：

```bash
git clone https://github.com/loveliunian/agent-skills.git "$HOME/.local/share/agent-skills"

# Claude Code
mkdir -p "$HOME/.claude/skills"
ln -sfn "$HOME/.local/share/agent-skills/devflow" "$HOME/.claude/skills/devflow"

# Codex（当前官方 user scope；旧的 ~/.codex/skills 已过时）
mkdir -p "$HOME/.agents/skills"
ln -sfn "$HOME/.local/share/agent-skills/devflow" "$HOME/.agents/skills/devflow"
```

或使用 devflow 自带安装器（同样为软链、幂等、不覆盖实体目录）：

```bash
bash "$HOME/.local/share/agent-skills/devflow/scripts/install.sh" --platform all
bash "$HOME/.local/share/agent-skills/devflow/scripts/doctor.sh"
```

也可以在仓库内直接同步到本机所有工具目录：`bash sync.sh --local`。

## License

MIT
