---
name: windows-compatibility
version: "3.23.0"
description: 跨平台兼容性事实清单（v3.15.x 实测口径）。
paths: []
disable-model-invocation: false
---

# 跨平台兼容性（v3.16.0 重写）

> 旧版以 v2.2/v2.3 为主体且错误声称 Bash 3.2 不支持 process substitution——
> 与脚本现状矛盾（全树大量使用 `< <(...)`）。本文件重写为当前事实。

## 已验证平台矩阵

| 平台 | Bash | 状态 | 证据 |
|---|---|---|---|
| macOS（本机） | 3.2.57 | ✅ 全量回归通过（run-tests.sh 全绿） | 本仓库测试收据 |
| Ubuntu Linux | 5.x | ⏳ 待 CI 收据 | 未验证——CI 接入后补 |
| Windows Git Bash / MSYS2 | 4.4+/5.x | ⏳ 待 CI 收据 | 未验证——CI 接入后补 |

## 事实清单（macOS Bash 3.2 实测）

- **Process substitution `< <(...)` / `>(...)`：支持**。旧文档"不支持"的说法错误，
  全树 scripts/ 大量使用且 3.2.57 全量回归通过。
- **`local -a arr=()` 数组、`[[ ]]`、`printf %q`、`mapfile`（3.2 不支持，未使用）**：
  代码遵循"3.2 兼容子集"——不使用 mapfile/关联数组/`${var,,}` 等 4.x 特性。
- **多字节邻接陷阱**：`$var` 紧邻全角字符必须 `${var}`（bash 变量名解析吞字节），
  由 test-v3140 静态扫描强制（scripts + tests + commands/*.md）。
- **`grep -E` 词边界**：`\b` 在 BSD grep 不可靠，统一 `[^A-Za-z]` 口径。
- **`date -r`/`stat -f`**：为 macOS 语法；Linux 对应 `date -d @`/`stat -c`——
  当前仅测试与诊断脚本使用，跨平台执行前需适配。
- **rsync 2.6.9（macOS 自带）**：check 阶段已改用纯 SHA 集合对账（portable_diff），
  rsync 仅用于 apply 且 `--checksum` 选项在 2.6.9 可用。
- **python3/jq/shasum 依赖**：sha256sum 或 shasum 二选一；双缺失时相关审计 fail-closed 拒绝运行（不产生空哈希相等假绿）。

## Windows 专项注意

- 路径分隔符：副本目标列表（DEVFLOW_COPY_TARGETS）用换行分隔（盘符冒号不参与切分，check-copies 已兼容 CRLF）。
- Git Bash 下 `mktemp`/`find -print0` 行为一致；PowerShell/CMD 不受支持。
- CI 收据（Ubuntu/Git Bash）为待办：接入后在本表补退出码与日志路径。
