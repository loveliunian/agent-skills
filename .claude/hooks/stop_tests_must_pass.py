#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Stop 钩子——收工前,被改动的代码必须先过编译/检查。

移植自 coleam00/skills(MIT 许可)的 hooks/stop_tests_must_pass.py,按本项目改造:

  1. 检查命令不再是一个固定测试命令,而是按 git 改动现场算出来:
     - backend/<模块>/ 下有改动 → mvn -q -pl <模块列表> -am -DskipTests compile(cwd=backend)
     - backend/ 根文件(如 backend/pom.xml)有改动 → 全量 mvn -q -DskipTests compile
     - frontend/ 下有改动 → npm run lint(cwd=frontend)
     - 两处都没改动(纯文档/分析会话)→ 直接放行,不付编译代价
     这只是收工底线,SDD 流程的完整关口(守卫测试/validate_impl.py/T1)不由此替代。
  2. 保留上游防篡改守卫(GUARD_TEST_EDITS):第一次阻断时对测试文件做快照,
     之后变绿时若快照里的测试文件被改过,仍然阻断——防止"改测试让检查变绿"。
     全新增的测试文件不算改动(那是补覆盖,要鼓励)。
  3. 保留上游环路保险丝:payload 里 stop_hook_active 为真直接放行,
     否则"阻止→干活→再停→再阻止"会打转(硬顶 8 次后强制结束,白烧 8 个回合)。

    exit 0 → 放行      exit 2 → 阻止收工,stderr 原文回传给代理

    任何意外一律放行(fail-open):坏掉的保证好过卡死的会话。
"""

import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Optional

# Windows 控制台/管道默认 GBK 编码;钩子输出统一强制 UTF-8,避免中文说明变乱码。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:  # noqa: BLE001
        pass

# ============================ 配置(按需改这里) ============================

BACKEND_DIR = "backend"
FRONTEND_DIR = "frontend"

# 改动波及 backend 根文件时的全量兜底命令(cwd=backend)
BACKEND_FULL_CMD = "mvn -q -DskipTests compile"
# 模块级命令模板;<MODULES> 替换为逗号分隔的模块名列表
BACKEND_MODULES_CMD = "mvn -q -pl <MODULES> -am -DskipTests compile"
# frontend 有改动时加跑的命令(cwd=frontend)
FRONTEND_CMD = "npm run lint"

# 单条命令超时秒数;超时放行。卡死的钩子比漏检的钩子更糟。
TIMEOUT_SECONDS = 240

# 失败输出回传多少字符。够动手定位,不至于撑爆上下文。保尾不保头(摘要在底部)。
MAX_OUTPUT_CHARS = 3000

# 防篡改守卫。见文件头第 2 点。合法地补测试的会话不受影响。
GUARD_TEST_EDITS = True

# 哪些文件算"测试文件"(项目相对 glob)。覆盖后端 Java 与前端 TS/Vue 惯用后缀。
TEST_GLOBS = (
    "**/src/test/**/*.java",
    "**/*.test.*",
    "**/*.spec.*",
    "**/test_*.py",
    "**/*_test.py",
)

# ===========================================================================


def _repo_root(project_root: Path) -> Optional[Path]:
    """git 仓库根;不在仓库里返回 None(无基线,防篡改守卫自动失效)。"""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(project_root), timeout=10,
        )
        if result.returncode != 0:
            return None
        return Path(result.stdout.strip())
    except Exception:  # noqa: BLE001
        return None


_ASSERTION = re.compile(
    r"expect\(|assert|Assert|toBe\(|toEqual\(|assertTrue|assertFalse|assertEquals"
    r"|andExpect\(|jsonPath",
    re.IGNORECASE,
)


def _tampered_tests(project_root: Path) -> list:
    """git diff 语义判定(2026-09-18 改造,替代会话快照):

    基线 = 上一次 commit(已验收代码),而非某个偶然瞬间。
    对改动/删除的测试文件逐个看 diff:
      - 断言行「净删除」(删的断言多于新增的) → 判定削弱测试,返回该文件
      - 纯新增用例、import/签名适配 → 放行
      - 未跟踪的新测试文件 → 放行(补覆盖)
    不在 git 仓库里 → 返回空(无基线,守卫失效即放行,fail-open)。
    """
    repo = _repo_root(project_root)
    if repo is None:
        return []
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "--diff-filter=MDR", "HEAD", "--",
             "*.java", "*.ts", "*.py"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(project_root), timeout=10,
        )
        if result.returncode != 0:
            return []
        files = [f.strip() for f in result.stdout.splitlines() if f.strip()]
    except Exception:  # noqa: BLE001
        return []

    def is_test(rel: str) -> bool:
        return rel.endswith(("Test.java", "Tests.java", ".test.ts", ".test.tsx",
                             ".spec.ts", ".spec.tsx")) or "_test.py" in rel or "test_" in rel

    tampered = []
    for rel in files:
        if not is_test(rel.replace("\\", "/")):
            continue
        try:
            diff = subprocess.run(
                ["git", "diff", "HEAD", "--", rel],
                capture_output=True, text=True, encoding="utf-8", errors="replace",
                cwd=str(project_root), timeout=10,
            ).stdout
        except Exception:  # noqa: BLE001
            continue
        removed = sum(1 for line in diff.splitlines()
                      if line.startswith("-") and _ASSERTION.search(line))
        added = sum(1 for line in diff.splitlines()
                    if line.startswith("+") and _ASSERTION.search(line))
        if removed > added:
            tampered.append(rel)
    return tampered


def _project_env(run_dir: Path) -> dict:
    """继承环境;若项目自带 venv 则把它放到 PATH 最前(上游原样保留,对 mvn/npm 无害)。"""
    env = os.environ.copy()
    ephemeral = env.pop("VIRTUAL_ENV", None)
    path_parts = env.get("PATH", "").split(os.pathsep)
    if ephemeral:
        drop = {os.path.join(ephemeral, "Scripts"), os.path.join(ephemeral, "bin")}
        path_parts = [p for p in path_parts if p not in drop]
    for candidate in (".venv", "venv"):
        for bindir in ("Scripts", "bin"):
            venv_bin = run_dir / candidate / bindir
            if venv_bin.is_dir():
                env["VIRTUAL_ENV"] = str(run_dir / candidate)
                path_parts.insert(0, str(venv_bin))
                env["PATH"] = os.pathsep.join(path_parts)
                return env
    env["PATH"] = os.pathsep.join(path_parts)
    return env


def _clip(text: str) -> str:
    text = text.strip()
    if len(text) <= MAX_OUTPUT_CHARS:
        return text
    # 保尾。构建工具的报错摘要通常在底部。
    return "... [输出已截断] ...\n" + text[-MAX_OUTPUT_CHARS:]


def _changed_paths(project_root: Path):
    """git status --porcelain -z 的改动路径列表;git 不可用返回 None。"""
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain", "-z"],
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            cwd=str(project_root), timeout=10,
        )
        if result.returncode != 0:
            return None
        # -z 输出以 NUL 分隔;重命名记录会多出一段"新路径\0旧路径",只认带状态前缀的记录
        paths = []
        for entry in result.stdout.split("\0"):
            if re.match(r"^[MADRCUTX?! ]{2} ", entry) and not entry.startswith("  "):
                paths.append(entry[3:])
        return paths
    except Exception:  # noqa: BLE001
        return None


def _plan_commands(project_root: Path):
    """按改动算出要跑的检查命令,返回 [(命令, cwd)];空列表=快速放行。"""
    paths = _changed_paths(project_root)
    if paths is None:
        # git 不可用:退回全量,保守检查
        return [(BACKEND_FULL_CMD, project_root / BACKEND_DIR)]

    backend_mods = set()
    backend_root_file = False
    frontend_changed = False
    for raw in paths:
        p = raw.replace("\\", "/").lstrip("/")
        if p.startswith(BACKEND_DIR + "/"):
            rest = p[len(BACKEND_DIR) + 1:]
            if "/" in rest:
                mod = rest.split("/", 1)[0]
                if (project_root / BACKEND_DIR / mod / "pom.xml").is_file():
                    backend_mods.add(mod)
                else:
                    backend_root_file = True  # backend/ 下的非模块目录,按根改动处理
            else:
                backend_root_file = True
        elif p.startswith(FRONTEND_DIR + "/"):
            frontend_changed = True

    commands = []
    if backend_root_file:
        commands.append((BACKEND_FULL_CMD, project_root / BACKEND_DIR))
    elif backend_mods:
        commands.append((
            BACKEND_MODULES_CMD.replace("<MODULES>", ",".join(sorted(backend_mods))),
            project_root / BACKEND_DIR,
        ))
    if frontend_changed:
        commands.append((FRONTEND_CMD, project_root / FRONTEND_DIR))
    return commands


def main() -> None:
    try:
        data = json.load(sys.stdin)

        # 环路保险丝。没有它:阻止收工→代理干活→再停→再阻止,打转烧回合。
        if data.get("stop_hook_active"):
            sys.exit(0)

        project_root = Path(data.get("cwd") or ".")
        commands = _plan_commands(project_root)

        # 快速通道:backend/frontend 都没动(纯文档/分析会话),不付编译代价。
        if not commands:
            sys.exit(0)

        session_id = str(data.get("session_id", ""))
        failures = []
        for cmd, cwd in commands:
            try:
                result = subprocess.run(
                    cmd,
                    shell=True,  # 命令逐字执行;Windows 上经 cmd.exe,mvn/npm 均可解析
                    capture_output=True,
                    text=True,
                    cwd=str(cwd),
                    env=_project_env(cwd),
                    timeout=TIMEOUT_SECONDS,
                )
            except subprocess.TimeoutExpired:
                print(f"检查命令超过 {TIMEOUT_SECONDS}s,本条放行:{cmd}", file=sys.stderr)
                continue
            if result.returncode != 0:
                output = _clip((result.stdout or "") + "\n" + (result.stderr or ""))
                failures.append((cmd, result.returncode, output))

        if not failures:
            # 全绿。但绿是因为代码修好了,还是测试被改了?只在本会话曾阻断时才追问。
            tampered = _tampered_tests(project_root) if GUARD_TEST_EDITS else []
            if tampered:
                print(
                    "BLOCKED:检查绿了,但绿是因为测试文件本身被改了。\n\n"
                    "本钩子首次阻断之后被改动的测试文件:\n  "
                    + "\n  ".join(tampered)
                    + "\n\n恢复这些文件,去修被测的代码。如果你确认某个测试本身写错了,"
                    "不要动手改它:说明是哪个测试、为什么,然后停下来。"
                    "这个判断归人,不归代理。",
                    file=sys.stderr,
                )
                sys.exit(2)
            sys.exit(0)  # 诚实绿,放行

        msg = "BLOCKED:被改动的代码没有过编译/检查,这一轮不算完成。\n"
        for cmd, code, output in failures:
            msg += f"\n命令:{cmd}\n(cwd={BACKEND_DIR if 'mvn' in cmd else FRONTEND_DIR}) 退出码:{code}\n{output}\n"
        msg += (
            "\n修好上面的代码再收工。不要改测试来让检查变绿;如果你确认某条检查本身错了,"
            "不要动手改它:说明是哪条、为什么,然后停下来。这个判断归人,不归代理。"
        )
        print(msg, file=sys.stderr)
        sys.exit(2)

    except Exception:
        # fail-open。坏掉的保证好过被卡死的会话。
        sys.exit(0)


if __name__ == "__main__":
    main()
