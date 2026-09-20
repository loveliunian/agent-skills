#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""SDD 共享工具(两个校验脚本的公共底座)。

v2 sdd skill 自包含底座,由同目录 sdd.py / sdd_state.py 导入。

职责只收"两个脚本原本各抄一遍"的东西:错误收集、JSON 读取、
编号正则、spec 目录定位、状态回写、汇总输出。领域校验逻辑
(台账对账、DDL 比对等)不进本模块,仍留在各自脚本里。
"""
import json
import re
import sys
from datetime import date
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

F_ID = re.compile(r"^F\d{3}$")
Q_ID = re.compile(r"^Q\d{3}$")
# 文本中的 Q 占位:统一三位 [Qnnn],与 open-questions 的 id schema 同一口径。
# 禁止放宽:2/4 位编号登记不进登记簿,会造成"扫得到、登不进"的永久红。
Q_IN_TEXT = re.compile(r"\[(Q\d{3})\]")

ERRORS = []
WARNS = []


def err(msg):
    ERRORS.append(msg)


def warn(msg):
    WARNS.append(msg)


def rel(path):
    try:
        return path.resolve().relative_to(Path.cwd())
    except Exception:
        return path


def load_json(path, required=False):
    """读取 JSON;required=True 时缺失记 ERROR,否则静默返回 None。解析失败一律记 ERROR。"""
    if not Path(path).exists():
        if required:
            err(f"缺少文件: {rel(path)}")
        return None
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        err(f"JSON 解析失败: {rel(path)}: {e}")
        return None


def find_spec_dir(specs, fid):
    """按 F 编号定位 spec 目录(如 F008-element-recycle);找不到返回 None。"""
    matches = sorted(Path(specs).glob(f"{fid}-*"))
    return matches[0] if matches else None


def summarize(header, strict=False, pre_lines=None):
    """统一汇总输出。返回进程退出码:1=有 ERROR(--strict 下含 WARN)。"""
    print(header)
    for line in pre_lines or []:
        print(line)
    for w in WARNS:
        print(f"[WARN] {w}")
    for e in ERRORS:
        print(f"[ERROR] {e}")
    if not ERRORS and not WARNS:
        print("全部通过,0 错误 0 警告")
    failed = bool(ERRORS) or (strict and bool(WARNS))
    print(f"结果: {'FAIL' if failed else 'PASS'} ({len(ERRORS)} 错误 / {len(WARNS)} 警告"
          f"{' / strict' if strict else ''})")
    return 1 if failed else 0


def set_spec_status(specs, fid, status, by="user"):
    """回写 spec 状态:json 的 status/approvedBy/approvedAt + md「| 状态 |」行同步。

    这是原先靠 LLM 手工编辑两个文件维护的状态,现收敛为一条命令,消灭双源漂移。
    返回 True=成功。失败已记 ERROR。
    """
    spec_dir = find_spec_dir(specs, fid)
    if spec_dir is None:
        err(f"找不到 spec 目录: {fid}-*")
        return False
    today = date.today().isoformat()
    # 1) json
    jp = spec_dir / "spec.json"
    data = load_json(jp, required=True)
    if data is None:
        return False
    old = data.get("status")
    data["status"] = status
    data["approvedBy"] = by
    data["approvedAt"] = today
    jp.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    # 2) md 状态行
    md = spec_dir / "spec.md"
    done_md = False
    if md.exists():
        lines = md.read_text(encoding="utf-8", errors="ignore").splitlines()
        for i, ln in enumerate(lines):
            if ln.lstrip().startswith("| 状态 |"):
                lines[i] = f"| 状态 | {status}({by},{today}) |"
                done_md = True
                break
        md.write_text("\n".join(lines) + "\n", encoding="utf-8")
    if not done_md:
        warn(f"{md.name} 无「| 状态 |」行,md 未同步(仅 json 已回写)")
    print(f"[状态回写] {fid}: {old!r} -> {status!r} (by={by}, at={today}; md{'已' if done_md else '未'}同步)")
    return True
