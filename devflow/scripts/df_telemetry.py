#!/usr/bin/env python3
"""df_telemetry.py · devflow 结构化遥测（JSONL，审查报告-0924 P1 项）

契约：
  - 事件追加分 .devflow/telemetry.jsonl（项目侧；不进收据树，audit 不消费）
  - 每行一个 JSON 对象：ts / run_id / phase / gate / event / exit_code /
    duration_ms / detail（detail 值经脱敏——长值截断、敏感键打码）
  - run_id：同 feature 一次编排会话的稳定标识（DF_RUN_ID 环境变量或生成）

用法（shell）:
  "${DEVFLOW_PY[@]}" df_telemetry.py emit --feature fx --phase P3 --gate build \\
      --event gate-exit --exit-code 0 --duration-ms 1234 [--detail k=v ...]
  "${DEVFLOW_PY[@]}" df_telemetry.py summary --feature fx    # 汇总（每 phase 通过率/耗时）
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import sys
import uuid
from pathlib import Path

MAX_DETAIL_LEN = 200
SENSITIVE_KEY_RE = re.compile(r"(secret|token|password|passwd|api[_-]?key|credential)", re.I)


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def _redact_detail(k: str, v: str) -> str:
    if SENSITIVE_KEY_RE.search(k):
        return "<redacted>"
    v = str(v)
    return v if len(v) <= MAX_DETAIL_LEN else v[: MAX_DETAIL_LEN - 3] + "..."


def telemetry_path(feature: str, state_dir: str = ".devflow") -> Path:
    return Path(state_dir) / "telemetry.jsonl"


def emit(feature: str, phase: str, gate: str, event: str,
         exit_code=None, duration_ms=None, detail=None,
         state_dir: str = ".devflow", run_id: str | None = None) -> dict:
    rec = {
        "ts": _now_iso(),
        "run_id": run_id or os.environ.get("DF_RUN_ID") or str(uuid.uuid4())[:12],
        "feature": feature,
        "phase": phase,
        "gate": gate,
        "event": event,
    }
    if exit_code is not None:
        rec["exit_code"] = int(exit_code)
    if duration_ms is not None:
        rec["duration_ms"] = int(duration_ms)
    if detail:
        rec["detail"] = {str(k): _redact_detail(str(k), str(v)) for k, v in detail.items()}
    p = telemetry_path(feature, state_dir)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")
    return rec


def summary(feature: str, state_dir: str = ".devflow") -> dict:
    p = telemetry_path(feature, state_dir)
    if not p.is_file():
        return {"feature": feature, "events": 0}
    phases: dict = {}
    n = 0
    for line in p.read_text(encoding="utf-8").splitlines():
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        n += 1
        ph = rec.get("phase") or "?"
        st = phases.setdefault(ph, {"gate_exits": 0, "pass": 0, "fail": 0,
                                    "total_duration_ms": 0, "last_exit": None})
        if rec.get("event") == "gate-exit":
            st["gate_exits"] += 1
            rc = rec.get("exit_code")
            st["last_exit"] = rc
            if rc == 0:
                st["pass"] += 1
            else:
                st["fail"] += 1
            st["total_duration_ms"] += rec.get("duration_ms") or 0
    return {"feature": feature, "events": n, "phases": phases}


def main():
    ap = argparse.ArgumentParser(description="devflow 结构化遥测（JSONL）")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("emit")
    e.add_argument("--feature", required=True)
    e.add_argument("--phase", default="")
    e.add_argument("--gate", default="")
    e.add_argument("--event", default="gate-exit")
    e.add_argument("--exit-code", type=int)
    e.add_argument("--duration-ms", type=int)
    e.add_argument("--detail", action="append", default=[],
                   help="k=v 键值对（敏感键自动打码）")
    e.add_argument("--state-dir", default=".devflow")
    s = sub.add_parser("summary")
    s.add_argument("--feature", required=True)
    s.add_argument("--state-dir", default=".devflow")
    a = ap.parse_args()
    if a.cmd == "emit":
        detail = {}
        for kv in a.detail:
            if "=" in kv:
                k, v = kv.split("=", 1)
                detail[k] = v
        rec = emit(a.feature, a.phase, a.gate, a.event, a.exit_code,
                   a.duration_ms, detail, a.state_dir)
        print(json.dumps(rec, ensure_ascii=False))
    else:
        print(json.dumps(summary(a.feature, a.state_dir), ensure_ascii=False, indent=1))


if __name__ == "__main__":
    sys.exit(main() or 0)
