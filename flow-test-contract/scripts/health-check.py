#!/usr/bin/env python3
"""health-check.py v1 —— 契约驱动的健康检查（P1 修复：不再硬编码三个 localhost 端点）。

消费契约 environments.health_checks（每项为一条 curl 描述串：
  "curl -m 3 -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/actuator/health  # expect 200"
），提取 url 与期望状态码后**用固定 curl 参数重新执行**（不 eval 契约字符串——防任意命令
注入；只采信 url 与 expect）。产出:
  [{"id": "health-<url>", "severity": "P0", "passed": true|false, "note": "HTTP <code> expect <n>"}]

用法:
  python3 health-check.py --contract <test-contract.yaml> --out <health-results.json>
退出码: 0=检查完成（含失败项——健康失败是 gate 结果不是工具崩溃）；
        2=契约/配置不可读或条目格式非法（fail-closed）。
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

# 只放行标准 curl 描述形态：... <url> [# expect <code> [# 任意备注]]（url 须 http/https 且不带引号变体）。
# 第二十轮：允许 expect 后再跟注释段（单条目多段 # 注释此前无法解析——实测反哺），仅采信 url 与 expect
HC_RE = re.compile(r".*\b(https?://\S+?)[\"']?(?:\s+#\s*expect\s*(\d+))?(?:\s+#.*)?\s*$")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--contract", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    try:
        import yaml
        c = yaml.safe_load(Path(args.contract).read_text(encoding="utf-8")) or {}
    except Exception as e:
        print(f"[health] ⛔ 契约不可读 {args.contract}: {e}", file=sys.stderr)
        raise SystemExit(2)
    hcs = ((c.get("environments") or {}).get("health_checks")) if isinstance(c.get("environments"), dict) else None
    if not isinstance(hcs, list) or not hcs:
        print("[health] ⛔ 契约未声明 environments.health_checks（≥1 条）——无健康门禁定义，拒绝放行", file=sys.stderr)
        raise SystemExit(2)
    # 解析全部条目为 (url, expect)；任一条格式非法 → exit 2（fail-closed，不 eval 契约串）
    targets = []
    for line in hcs:
        if not isinstance(line, str):
            print(f"[health] ⛔ health_checks 条目非字符串: {line!r}", file=sys.stderr)
            raise SystemExit(2)
        m = HC_RE.match(line.strip())
        if not m:
            print(f"[health] ⛔ health_checks 条目无法解析（须为 curl 描述串含 url 与可选 # expect N）: {line[:120]}",
                  file=sys.stderr)
            raise SystemExit(2)
        url, expect_s = m.group(1), m.group(2)
        targets.append((url, int(expect_s) if expect_s else 200))

    def _probe(url: str, expect: int) -> dict:
        # 固定参数执行——契约字符串只贡献 url/expect，其余参数不受信任
        p = subprocess.run(["curl", "-m", "3", "-s", "-o", "/dev/null", "-w", "%{http_code}", url],
                           capture_output=True, text=True)
        code = (p.stdout or "").strip() or "000"
        return {"id": f"health-{url}", "severity": "P0", "passed": code == str(expect),
                "note": f"HTTP {code} expect {expect}（契约 environments.health_checks）"}

    # 第十三轮·审计修复（P1-2）：并发探活——串行 20×3s 最坏 60s，并发降到 ~3s；
    # 用 ThreadPoolExecutor + 子进程 curl（保持既有"固定参数、零依赖库"策略）
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(targets)))) as ex:
        items = list(ex.map(lambda t: _probe(*t), targets))
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(items, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"[health] {len(items)} 项健康检查（并发） → {args.out}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[health] ⛔ 内部异常（fail-closed）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
