#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""UserPromptSubmit hook:每次用户发消息,注入一行 SDD 流水线状态。
确定性信息由脚本报数,模型不用每轮重新扫 specs 目录。specs/ 不存在则静默退出。"""
import json
import subprocess
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent.parent
SPECS = ROOT / "specs"
STATE = ROOT / ".claude" / "skills" / "sdd" / "scripts" / "sdd_state.py"

if not SPECS.is_dir() or not STATE.exists():
    sys.exit(0)

try:
    r = subprocess.run([sys.executable, str(STATE), str(SPECS), "state"],
                       capture_output=True, text=True, timeout=30, encoding="utf-8")
    data = json.loads(r.stdout or "{}")
except Exception:
    sys.exit(0)

counts = data.get("counts", {})
total = sum(counts.values())
detail = "、".join(f"{k}={v}" for k, v in sorted(counts.items()))
high = data.get("openHighBlockQs") or []
if len(high) > 5:
    high_s = f"{','.join(high[:5])} 等{len(high)}个"
else:
    high_s = ",".join(high) if high else "无"
nxt = data.get("pipelineNext", "")
line = f"[SDD 状态机] feature {total} 个({detail});高阻塞未关 Q:{high_s};下一步:{nxt}"
print(line)
sys.exit(0)
