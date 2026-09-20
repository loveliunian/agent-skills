#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""测试锚点守卫(L1):详设 testId ↔ 前端源码 data-testid 机器对账。

用法(guard-tests.md §3.0,G2 随其他守卫一起跑):

    python scripts/check_testids.py --design specs/_work/detail_design.json --src frontend/src
    python scripts/check_testids.py --design a.json --design b.json --src frontend/src   # part 分片可多个
    python scripts/check_testids.py --design x.json --src frontend/src --scan "vue,ts,tsx"

判据:
- 详设登记(frontend.interactions[].formFields[].testId + controls[].testId)而源码找不到 → ERROR,退出码 1
- 源码里有 data-testid 但详设没登记 → WARN(防实现期自由发挥;退出码不受影响)
- 详设无 frontend.interactions 或一个 testId 都没有 → 直接通过(纯后端模块/老详设降级,不误伤)

命中口径:字面 `data-testid="xxx"` 命中;或 xxx 以绑定形式出现
(`:data-testid="'xxx-' + ..."`、`data-testid: 'xxx'` 等)时按字面串出现即命中——
静态分析只对账"锚点存在",精确 DOM 归属归 L5 运行时验证。
"""
import argparse
import json
import re
import sys
from pathlib import Path

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

# data-testid 的三种常见形态:静态、动态绑定、对象/配置字面量。
DID_STATIC = re.compile(r"""data-testid=["']([^"']+)["']""")
DID_BOUND = re.compile(r""":?data-testid=["'`]?([^"'`>\s]+)""")  # 宽口径,仅用于"出现即命中"


def collect_testids(designs):
    """从一份或多份详设 JSON 收集 (testId, 溯源) 列表。"""
    got = {}
    for dpath in designs:
        data = json.loads(Path(dpath).read_text(encoding="utf-8"))
        for it in ((data.get("frontend") or {}).get("interactions") or []):
            page = it.get("page", "?")
            for f in it.get("formFields") or []:
                tid = f.get("testId")
                if tid:
                    got.setdefault(tid, f"{dpath} 页[{page}] 表单控件[{f.get('field', '?')}]")
            for c in it.get("controls") or []:
                tid = c.get("testId")
                if tid:
                    got.setdefault(tid, f"{dpath} 页[{page}] 控件[{c.get('name', '?')}]")
    return got


def scan_sources(src, exts):
    """返回 (所有 data-testid 静态值集合, 全部文件文本)。"""
    static_ids = set()
    texts = {}
    for p in sorted(Path(src).rglob("*")):
        if not p.is_file() or p.suffix.lstrip(".").lower() not in exts:
            continue
        try:
            text = p.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        texts[p] = text
        static_ids.update(DID_STATIC.findall(text))
    return static_ids, texts


def main():
    ap = argparse.ArgumentParser(description="测试锚点守卫:详设 testId ↔ 源码 data-testid 对账")
    ap.add_argument("--design", action="append", required=True, help="详设 JSON(detail_design.json 或 part 分片),可多次")
    ap.add_argument("--src", required=True, help="前端源码目录(递归扫描)")
    ap.add_argument("--scan", default="vue,js,ts,tsx,jsx", help="扫描的扩展名,逗号分隔(默认 vue,js,ts,tsx,jsx)")
    args = ap.parse_args()

    registry = collect_testids(args.design)
    if not registry:
        print("[SKIP] 详设未登记任何 testId(纯后端模块/老详设),锚点守卫不适用")
        return 0

    exts = {e.strip().lower() for e in args.scan.split(",") if e.strip()}
    static_ids, texts = scan_sources(args.src, exts)

    errors, warns = [], []
    for tid, origin in sorted(registry.items()):
        hits = [str(p) for p, t in texts.items() if tid in t]  # 宽口径:字面或绑定中出现即命中
        if hits:
            print(f"[OK]   {tid}  <- {origin}")
        else:
            errors.append(f"{tid}  <- {origin}")
    for sid in sorted(static_ids - set(registry)):
        warns.append(f"源码 data-testid=\"{sid}\" 未在详设登记(实现期自由发挥?)")

    for e in errors:
        print(f"[MISS] {e}")
    for w in warns:
        print(f"[WARN] {w}")
    print(f"\n共 {len(registry)} 个锚点:命中 {len(registry) - len(errors)},缺失 {len(errors)};未登记 {len(warns)}")
    if errors:
        print("RED:登记未落地,禁止过闸(漏加/改名的,对照详设补 data-testid)")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
