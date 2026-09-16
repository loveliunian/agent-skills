# Security Policy

## 支持范围

本仓库是 Agent Skill（提示与脚本集合），不含常驻服务。安全问题主要指：

- 脚本在用户仓库执行时引入的破坏性行为（覆盖文件、绕过 Gate）；
- 诱导提交秘密（secret）或隐私数据；
- 发布流程（`release.sh`）被绕过或伪造。

## 禁止提交的数据

以下内容**一律不得**进入提交、示例、receipts、测试报告或文档：

- API Key、Token、Session、私钥（`*.pem` / `*.key` / `*.p12` / `*.jks`）；
- 数据库密码、真实账号密码；
- 真实服务器 IP / 域名、客户名、公司内部 Git 地址；
- 真实用户数据与生产数据、内部 PRD 原文（脱敏后才可作为示例）。

`devflow/scripts/secret-scan.sh` 作为发布硬门禁执行高置信度扫描；`.gitignore`
覆盖常见秘密文件形态。发现误报可用 `secret-scan: allow` 标注并说明理由。

## 报告漏洞

请通过 GitHub Security Advisories（私有报告）或直接联系仓库维护者。
请勿在公开 Issue 中粘贴任何真实凭据或生产数据。我们会尽快确认并修复。
