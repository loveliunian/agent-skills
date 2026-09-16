# agent-skills

自己做的 skill。

## Skills

| Skill | 版本 | 说明 |
|-------|------|------|
| [devflow](./devflow/) | 3.22.0 | PRD 到生产的阶段门禁交付流程：需求澄清、技术选型、详细设计、规范实现、测试、部署、监控、文档、复盘，支持 checkpoint 恢复。适用于 Java/Spring/Flyway 后端、PC Web、微信小程序和移动端。 |
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

```bash
# Claude Code / Codex 等，将 skill 复制到对应 skills 目录即可
git clone https://github.com/loveliunian/agent-skills.git
cp -r agent-skills/devflow ~/.claude/skills/devflow   # 或 ~/.codex/skills/devflow
```

## License

MIT
