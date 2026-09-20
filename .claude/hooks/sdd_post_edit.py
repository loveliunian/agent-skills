#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""PostToolUse hook(Write|Edit):specs/ 下机器 twin(spec.json/feature-list.json/
open-questions.json)被改动后,立刻跑守门引擎快检,ERROR 当场喂回模型——
错误在写入时暴露,而不是攒到关口才炸(历史教训:R-L 存量 12 错攒了一堆才发现)。"""
import json
import subprocess
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent.parent
WATCH = {"spec.json", "feature-list.json", "open-questions.json"}
SPECS_DIRS = {"specs", "design"}


def main():
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except ValueError:
        sys.exit(0)
    fp = Path((payload.get("tool_input", {}) or {}).get("file_path") or "")
    if fp.name not in WATCH or not (SPECS_DIRS & {p.lower() for p in fp.parts}):
        sys.exit(0)
    # 从改动文件向上找 specs 根(含 feature-list.json 的目录)
    specs_root = fp.parent
    for cand in [fp.parent, *fp.parents]:
        if (cand / "feature-list.json").exists():
            specs_root = cand
            break
    engine = ROOT / ".claude" / "skills" / "sdd" / "scripts" / "sdd.py"
    if not engine.exists():
        sys.exit(0)
    try:
        r = subprocess.run([sys.executable, str(engine), str(specs_root)],
                           capture_output=True, text=True, timeout=120, encoding="utf-8")
    except Exception:
        sys.exit(0)
    errors = [ln for ln in (r.stdout or "").splitlines() if ln.startswith("[ERROR]")]
    if errors:
        print(f"[SDD 快检] 改动 {fp.name} 后引擎报 {len(errors)} 个错(改完就修,别攒到关口):")
        for e in errors[:10]:
            print(f"  {e}")
        if len(errors) > 10:
            print(f"  …其余 {len(errors) - 10} 个见 `python sdd.py {specs_root}` 完整输出")
    sys.exit(0)


if __name__ == "__main__":
    main()
