#!/usr/bin/env python3
"""df_executor.py · devflow Capability Executor（统一安全子进程运行时）

来源：外部深度审查报告-0924「推荐的首个补丁方向」——所有 Profile 只输出 CommandSpec，
Gate 不再知道 Maven/pytest/Prisma/Flyway。兑现 Runtime Profile 架构原则。

契约（references/runtime-profile.md §capability）：
  - executable + args + cwd + timeout_seconds + env_allowlist（结构化 argv）
  - cwd 物理归一后必须在 workspace 内（防越界）
  - 环境变量白名单（默认 PATH/HOME/LANG/LC_* TZ CI DEVFLOW_*）
  - timeout（默认 900s；超时杀进程树，rc=124 语义对齐 run-tests 惯例）
  - 退出码 + duration_ms 回执（供收据/结构化日志消费）

用法（shell）:
  bash -c '. py_runtime.sh && "${DEVFLOW_PY[@]}" df_executor.py --exec mvn --arg -q --arg test \
    --cwd backend --json'          # 输出 JSON 回执
  "${DEVFLOW_PY[@]}" df_executor.py --profile-verify python-fastapi-sqlalchemy \
    --capability test --workspace .   # 从 runtime-profiles 读结构化 argv 执行

用法（python）:
  from df_executor import CommandSpec, run_capability
  spec = CommandSpec(executable="mvn", args=("-q","test"), cwd=Path("backend"))
  rc, ms = run_capability(spec, workspace=Path("."))
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_TIMEOUT_SECONDS = 900
DEFAULT_ENV_ALLOWLIST = ("PATH", "HOME", "LANG", "LC_ALL", "LC_CTYPE", "TZ", "CI", "TERM")
ENV_PREFIX_ALLOW = ("DEVFLOW_",)

# 可执行文件名白名单（首词）——拒绝 shell 元字符与绝对路径执行任意二进制
EXECUTABLE_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._+-]*$"


def _resolve_json_path(data, path: str):
    """按 'backend.build_adapter' 点路径取嵌套节点；{service}/{scope} 模板变量由
    profile 自身的 context 节点替换（无 context 时保留字面）。"""
    if not path or not isinstance(path, str):
        return None
    import re as _re
    ctx = data.get("context") or {}
    path = path.replace("{service}", str(ctx.get("service") or "{service}"))
    path = path.replace("{scope}", str(ctx.get("scope") or "{scope}"))
    node = data
    for part in path.split("."):
        if not isinstance(node, dict) or part not in node:
            return None
        node = node[part]
    return node if isinstance(node, dict) else None


@dataclass(frozen=True)
class CommandSpec:
    executable: str
    args: tuple = ()
    cwd: str = "."
    timeout_seconds: int = DEFAULT_TIMEOUT_SECONDS
    env_allowlist: tuple = DEFAULT_ENV_ALLOWLIST

    def to_json(self) -> dict:
        return {
            "executable": self.executable,
            "args": list(self.args),
            "cwd": self.cwd,
            "timeout_seconds": self.timeout_seconds,
            "env_allowlist": list(self.env_allowlist),
        }

    @classmethod
    def from_json(cls, d: dict) -> "CommandSpec":
        import re
        exe = str(d.get("executable") or "")
        if not re.match(EXECUTABLE_PATTERN, exe):
            raise ValueError(f"executable 非法（须匹配 {EXECUTABLE_PATTERN}）: {exe!r}")
        args = tuple(str(a) for a in (d.get("args") or []))
        for a in args:
            if "\x00" in a:
                raise ValueError("args 含 NUL")
        return cls(
            executable=exe,
            args=args,
            cwd=str(d.get("cwd") or "."),
            timeout_seconds=int(d.get("timeout_seconds") or DEFAULT_TIMEOUT_SECONDS),
            env_allowlist=tuple(d.get("env_allowlist") or DEFAULT_ENV_ALLOWLIST),
        )

    @classmethod
    def from_profile(cls, profile: dict, capability: str) -> "CommandSpec":
        """从 runtime-profile JSON 解析（v3.31.1 两路）：
        ① gate_bindings 键（如 P3-build）→ 路径值（backend.build_adapter）→ 按 JSON 路径取节点
        ② 直接 adapter 名（build/test/...）→ 各 section 下 {name}_adapter
        优先结构化 executable/args；legacy command 字符串 shlex 拆词兼容（首词元字符拒）"""
        node = None
        # 路径①：gate_bindings（支持列表取首项）
        gb = (profile.get("gate_bindings") or {}).get(capability)
        if gb:
            path = gb[0] if isinstance(gb, list) else gb
            node = _resolve_json_path(profile, path)
        # 路径②：adapter 名（严格匹配 {capability}_adapter 或同名键——裸 "adapter"
        # 回退过宽：任意 capability 名都会误中 security.adapter/performance.adapter）
        if node is None:
            for section in ("backend", "frontend", "database", "quality", "security", "performance", "deployment"):
                sec = profile.get(section) or {}
                for key in (f"{capability}_adapter", capability):
                    if isinstance(sec.get(key), dict):
                        node = sec[key]
                        break
                if node:
                    break
        if node is None:
            raise ValueError(f"MISSING_CAPABILITY={capability}（profile 无该 adapter/gate_binding）")
        if node.get("executable"):
            return cls.from_json(node)
        legacy = str(node.get("command") or "")
        if not legacy:
            raise ValueError(f"adapter 既无 executable 也无 command: {capability}")
        import shlex
        try:
            words = shlex.split(legacy)
        except ValueError as e:
            raise ValueError(f"legacy command 解析失败（引号不平衡）: {legacy!r}") from e
        if not words:
            raise ValueError("legacy command 为空")
        if len(words) > 1 and any(c in words[0] for c in "|&;<>()$`\\\"'"):
            raise ValueError(f"legacy command 首词含 shell 元字符（拒绝）: {words[0]!r}")
        cwd = str(node.get("working_dir") or ".")
        return cls(executable=words[0], args=tuple(words[1:]), cwd=cwd)


class ExecutorError(RuntimeError):
    pass


def _filtered_env(allowlist: tuple) -> dict:
    env = {}
    for k, v in os.environ.items():
        if k in allowlist or k.startswith(ENV_PREFIX_ALLOW):
            env[k] = v
    return env


def run_capability(spec: CommandSpec, workspace: Path, extra_env: dict | None = None) -> tuple:
    """执行并返回 (returncode, duration_ms)。cwd 越界/超时/信号有明确 rc 语义。"""
    root = workspace.resolve()
    cwd = (workspace / spec.cwd).resolve() if not Path(spec.cwd).is_absolute() else Path(spec.cwd).resolve()
    if root != cwd and root not in cwd.parents:
        raise ExecutorError(f"cwd escapes workspace: {cwd}（root={root}）")

    env = _filtered_env(spec.env_allowlist)
    if extra_env:
        env.update(extra_env)

    argv = [spec.executable, *spec.args]
    start = time.monotonic()
    try:
        proc = subprocess.Popen(
            argv, cwd=str(cwd), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,  # 进程组——超时可杀整树（POSIX）
        )
    except FileNotFoundError:
        return 127, 0
    except PermissionError:
        return 126, 0

    try:
        out, _ = proc.communicate(timeout=spec.timeout_seconds)
        rc = proc.returncode
    except subprocess.TimeoutExpired:
        try:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            proc.kill()
        try:
            proc.communicate(timeout=10)
        except Exception:
            pass
        return 124, int((time.monotonic() - start) * 1000)

    duration_ms = int((time.monotonic() - start) * 1000)
    if out:
        sys.stdout.write(out)
    # v3.31.3: 结构化遥测（DF_TELEMETRY=1 时追加 JSONL——审查报告-0924 P1）
    if os.environ.get("DF_TELEMETRY") == "1":
        try:
            from df_telemetry import emit as _tlm_emit
            _tlm_emit(
                feature=os.environ.get("DF_FEATURE", "-"),
                phase=os.environ.get("DF_PHASE", ""),
                gate=spec.executable,
                event="capability-exit",
                exit_code=rc,
                duration_ms=duration_ms,
                state_dir=os.environ.get("DF_STATE_DIR", ".devflow"),
            )
        except Exception:
            pass  # 遥测失败不影响执行
    return rc, duration_ms


def load_profile(profile_id: str, profiles_dir: Path | None = None) -> dict:
    d = profiles_dir or (Path(__file__).resolve().parent.parent / "runtime-profiles")
    p = d / f"{profile_id}.json"
    if not p.is_file():
        known = sorted(x.stem for x in d.glob("*.json"))
        raise ExecutorError(f"unknown profile: {profile_id}（已知: {', '.join(known)}）")
    return json.loads(p.read_text(encoding="utf-8"))


def main():
    ap = argparse.ArgumentParser(description="devflow Capability Executor（结构化 argv 安全运行时）")
    ap.add_argument("--exec", dest="executable", help="可执行文件名（白名单 pattern）")
    ap.add_argument("--arg", action="append", default=[], help="参数（可多次）")
    ap.add_argument("--cwd", default=".", help="工作目录（相对 workspace；越界即拒）")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_SECONDS)
    ap.add_argument("--json", action="store_true", help="输出 JSON 回执（rc/duration_ms/spec）")
    ap.add_argument("--profile-verify", metavar="PROFILE_ID", help="从 runtime-profiles 读 adapter 执行")
    ap.add_argument("--capability", help="profile-verify 的能力位（build/test/...）")
    ap.add_argument("--workspace", default=".", help="workspace 根（边界锚）")
    ap.add_argument("--dry-run", action="store_true", help="只解析输出 spec 不执行")
    a = ap.parse_args()

    try:
        if a.profile_verify:
            if not a.capability:
                print("[executor] --profile-verify 须配 --capability", file=sys.stderr)
                return 2
            profile = load_profile(a.profile_verify)
            spec = CommandSpec.from_profile(profile, a.capability)
        elif a.executable:
            spec = CommandSpec.from_json({
                "executable": a.executable, "args": a.arg,
                "cwd": a.cwd, "timeout_seconds": a.timeout,
            })
        else:
            ap.error("须提供 --exec 或 --profile-verify")
    except ValueError as e:
        print(f"[executor] {e}", file=sys.stderr)
        return 2

    if a.dry_run:
        print(json.dumps(spec.to_json(), ensure_ascii=False))
        return 0

    try:
        rc, ms = run_capability(spec, Path(a.workspace).resolve())
    except ExecutorError as e:
        print(f"[executor] {e}", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps({"rc": rc, "duration_ms": ms, "spec": spec.to_json()}, ensure_ascii=False))
    return rc


if __name__ == "__main__":
    sys.exit(main())
