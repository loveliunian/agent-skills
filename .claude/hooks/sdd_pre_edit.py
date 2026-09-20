#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PreToolUse hook(Write|Edit):拦截对 spec 状态字段的手工编辑。
状态回写必须走命令(sdd.py --stage set-status / sdd_state.py approve-list),
机器强制,不再靠文档求模型别手改。非状态类编辑放行。"""
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

SPECS_DIRS = {"specs", "design"}  # v2 约定 specs/;design/ 兼容历史路径


def is_managed(fp: Path):
    parts = [p.lower() for p in fp.parts]
    if not (SPECS_DIRS & set(parts)):
        return None
    if fp.name in ("spec.json", "feature-list.json"):
        return fp
    return None


def deny(msg):
    print(msg, file=sys.stderr)
    sys.exit(2)  # Claude Code 约定:exit 2 = 拦截该工具调用,stderr 反馈给模型


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        sys.exit(0)
    ti = payload.get("tool_input", {}) or {}
    raw = ti.get("file_path") or ti.get("path") or ""
    if not raw:
        sys.exit(0)
    fp = Path(raw)
    if fp.name != "spec.json" and fp.name != "feature-list.json":
        sys.exit(0)
    if not (SPECS_DIRS & {p.lower() for p in fp.parts}):
        sys.exit(0)

    if payload.get("tool_name") == "Edit":
        new = ti.get("new_string") or ""
        if re.search(r'"status"\s*:', new):
            deny("拦截:手工编辑状态字段会让 json/md 双源漂移。回写状态必须走命令:"
                 "python .claude/skills/sdd/scripts/sdd.py <specs目录> --stage set-status <F编号> "
                 "--status <s> --by <谁>(清单确认用 sdd_state.py approve-list)。非状态内容请缩小编辑范围。")
    elif payload.get("tool_name") == "Write":
        content = ti.get("content") or ""
        try:
            new_status = json.loads(content).get("status")
        except ValueError:
            sys.exit(0)
        if new_status is not None and fp.exists():
            try:
                old_status = json.loads(fp.read_text(encoding="utf-8")).get("status")
            except (ValueError, OSError):
                old_status = None
            if new_status != old_status:
                deny(f"拦截:status {old_status!r}->{new_status!r} 属状态回写,必须走命令:"
                     "python .claude/skills/sdd/scripts/sdd.py <specs目录> --stage set-status <F编号> "
                     f"--status {new_status} --by <谁>。")
    sys.exit(0)


if __name__ == "__main__":
    main()
