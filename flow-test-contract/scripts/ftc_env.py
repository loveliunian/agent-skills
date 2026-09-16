#!/usr/bin/env python3
"""ftc_env.py —— 凭据解析唯一实现（v1.3.3「去 .env 化」，api/browser 双通道共享）。

来源优先级（凭据零入库：契约/产物只允许 env 名引用，值运行时解析）：
  1. 进程环境变量（systems actorMap 指向的 <账号>_USER / <账号>_PWD）
  2. $RUNTIME_DIR/env（私有运行态凭据文件，与 systems/ 同级；绝不入库/绝不同步；
     必须为当前用户所有的 0600 非符号链接实体文件；格式 KEY=VALUE，容忍 export 前缀 /
     前后空白 / 成对单双引号 / # 注释行）
  3. 显式授权的统一默认密码兜底：FLOWTEST_ALLOW_DEFAULT_PWD=1 且存在
     FLOWTEST_DEFAULT_PWD；用户名 → actor 本名
  4. 仍不可得 → CredentialError（调用方诚实 BLOCKED，绝不伪造）

加载语义为 setdefault：进程已有值不被 env 文件覆盖（显式导出优先）；
同一路径幂等（首次访问读一次）。python 侧唯一实现——bash 侧 pipeline.sh 的
ftc_load_runtime_env 与其镜像同一规则，勿单侧改语义。
"""
from __future__ import annotations

import os
import re
from pathlib import Path

DEFAULT_PWD_ENV = "FLOWTEST_DEFAULT_PWD"
ALLOW_DEFAULT_PWD_ENV = "FLOWTEST_ALLOW_DEFAULT_PWD"
_KEY_VAL_RE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_loaded: set[str] = set()


class CredentialError(RuntimeError):
    """凭据不可得（env 未设置且无统一默认密码兜底）——调用方须诚实 BLOCKED。"""


def env_file_for(systems_path: str | os.PathLike | None) -> Path | None:
    """systems/<channel>/<file>.yaml → 运行态凭据文件 <runtime>/env；未知路径返回 None。

    层级：current.yaml → parent=systems/api → parent=systems → parent=<runtime>。
    """
    if not systems_path:
        return None
    return Path(systems_path).resolve().parent.parent.parent / "env"


def _check_env_file(p: Path) -> None:
    """Runtime credentials must be a private regular file owned by this user."""
    if p.is_symlink():
        raise CredentialError(f"runtime env 禁止符号链接: {p}")
    try:
        st = p.stat()
    except OSError as e:
        raise CredentialError(f"runtime env 无法读取: {p}: {e}") from e
    if st.st_mode & 0o077:
        raise CredentialError(f"runtime env 权限过宽: {p}（要求 0600）")
    getuid = getattr(os, "getuid", None)
    if getuid is not None and st.st_uid != getuid():
        raise CredentialError(f"runtime env 非当前用户所有: {p}")


def _strip_quotes(v: str) -> str:
    if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
        return v[1:-1]
    return v


def load_env_file(path: str | os.PathLike | None) -> int:
    """加载 runtime env 文件（setdefault、幂等）；返回本次实际注入的键数。"""
    if not path:
        return 0
    p = Path(path)
    if not p.exists():
        return 0
    if str(p) in _loaded:
        return 0
    if not p.is_file():
        raise CredentialError(f"runtime env 不是普通文件: {p}")
    _check_env_file(p)
    _loaded.add(str(p))
    n = 0
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _KEY_VAL_RE.match(line)
        if not m:
            continue
        k, v = m.group(1), _strip_quotes(m.group(2))
        # 与 Bash 侧同一语义：变量只要存在（含显式导出的空值）就不被文件值覆盖——
        # 用户显式 export K='' 是"禁止从保存凭据恢复该键"的意图，空串必须被尊重
        if k not in os.environ:
            os.environ[k] = v
            n += 1
    return n


def _lookup(name: str, systems_path) -> str:
    if not name:
        return ""
    load_env_file(env_file_for(systems_path))
    return os.environ.get(name, "")


def resolve_credentials(systems_path, actor: str, username_env: str = "",
                        password_env: str = "",
                        warn=lambda m: print(f"[ftc-env] ⚠ {m}")) -> tuple[str, str]:
    """解析 (username, password)；两级兜底后仍不可得 → CredentialError（fail-closed）。"""
    username = _lookup(str(username_env or ""), systems_path)
    password = _lookup(str(password_env or ""), systems_path)
    if not username:
        username = str(actor)
        warn(f"actor {actor!r} 用户名 env 未设置（{username_env or '未配置'}）——回退 actor 本名")
    if not password:
        load_env_file(env_file_for(systems_path))
        default_pwd = os.environ.get(DEFAULT_PWD_ENV, "")
        allow_default = os.environ.get(ALLOW_DEFAULT_PWD_ENV, "").strip().lower() in ("1", "true", "yes")
        password = default_pwd if allow_default else ""
        if default_pwd and allow_default:
            warn(f"actor {actor!r} 密码 env 未设置（{password_env or '未配置'}）"
                 f"——在 {ALLOW_DEFAULT_PWD_ENV}=1 显式授权下回退 {DEFAULT_PWD_ENV} 统一默认密码")
        elif default_pwd and not allow_default:
            warn(f"actor {actor!r} 检测到 {DEFAULT_PWD_ENV}，但缺少 {ALLOW_DEFAULT_PWD_ENV}=1——"
                 "为防止生产账号批量误登录，默认密码兜底未启用")
    if not username or not password:
        raise CredentialError(
            f"actor {actor!r} 凭据不可得：env 未设置且无 {DEFAULT_PWD_ENV} 兜底"
            f"——补 $RUNTIME_DIR/env（{username_env or '<用户名env>'} / "
            f"{password_env or '<密码env>'}，或显式设置 {ALLOW_DEFAULT_PWD_ENV}=1 + {DEFAULT_PWD_ENV}=<统一默认密码>）后重跑")
    return username, password
