# -*- coding: utf-8 -*-
"""design-package 清单校验（v3.24.0 · 体检报告 A05）。

总分模式一份 feature 级 design.json 对应多份总/分文档。设计包清单
（.devflow/<feature>/design-package.json）声明每份文档及其验收子集：

  {
    "feature": "<feature>",
    "docs": [
      {"path": "docs/详细设计/m-01-结算-详细设计.md", "mode": "sub",
       "acceptance_ids": ["M-01-F01-A01", "M-01-F01-A02"]},
      {"path": "docs/详细设计/系统详细设计.md", "mode": "total",
       "acceptance_ids": ["M-02-F01-A01"]}
    ]
  }

机器契约（缺一即 FAIL）：
  1. 总分模式（--mode=total|sub）清单必须存在；
  2. 每份登记文档必须真实存在（缺文档即失败——跨模块引用可解析的前提）；
  3. 子集并集必须与冻结分母（criteria）全等——不多、不少；
  4. 每个子集内的 ID 必须属于冻结分母（不得私造验收点）；
  5. 当前被 Gate 的文档必须登记在清单中（path 精确匹配）。

成功时向 stdout 打印 `SCOPE=<id,id,…>`（当前文档的验收子集；total 文档
通常为全量），供 s2 传给 df_validate --scope-ids 做范围过滤的文档对账。
"""
import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_M_ID_RE = re.compile(r"^M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}$")


def main():
    ap = argparse.ArgumentParser(description="校验 design-package 设计包清单")
    ap.add_argument("--package", required=True, help="design-package.json 路径")
    ap.add_argument("--criteria", required=True, help="P0 冻结验收点文件")
    ap.add_argument("--doc", required=True, help="当前被 Gate 的文档路径")
    args = ap.parse_args()

    errors = []
    pkg_path = Path(args.package)
    if not pkg_path.is_file():
        print(f"清单文件不存在: {args.package}")
        sys.exit(1)
    try:
        pkg = json.loads(pkg_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"清单 JSON 解析失败: {e}")
        sys.exit(1)

    docs = pkg.get("docs")
    if not isinstance(docs, list) or not docs:
        print("清单缺 docs[] 或为空——设计包必须至少登记一份文档")
        sys.exit(1)

    criteria_text = ""
    cp = Path(args.criteria)
    if cp.is_file():
        criteria_text = cp.read_text(encoding="utf-8", errors="replace")
    frozen = set(re.findall(r"M-?[0-9]{2}-F[0-9]{2}-A[0-9]{2}", criteria_text))
    if not frozen:
        print(f"criteria 无冻结验收点: {args.criteria}")

    seen_paths = set()
    union = set()
    total_entries = 0
    current_scope = []
    registered = False
    doc_real = str(Path(args.doc).resolve())
    for i, d in enumerate(docs):
        where = f"docs[{i}]"
        path = (d.get("path") or "").strip()
        mode = (d.get("mode") or "").strip()
        ids = d.get("acceptance_ids")
        if not path:
            errors.append(f"{where}: 缺 path")
            continue
        if path in seen_paths:
            errors.append(f"{where}: 文档重复登记: {path}")
        seen_paths.add(path)
        if mode not in ("total", "sub"):
            errors.append(f"{where}: mode 必须为 total|sub（得到 {mode!r}）")
        if mode == "total":
            total_entries += 1
        if not isinstance(ids, list) or not ids:
            errors.append(f"{where}({path}): 缺 acceptance_ids 子集")
            continue
        bad_ids = [x for x in ids if not _M_ID_RE.match(str(x))]
        if bad_ids:
            errors.append(f"{where}({path}): 非法验收 ID: {bad_ids[:3]}")
        unknown = [x for x in ids if str(x) not in frozen]
        if unknown:
            errors.append(f"{where}({path}): 子集含冻结分母之外的 ID: {sorted(unknown)[:3]}（不得私造验收点）")
        union.update(str(x) for x in ids)
        try:
            if str(Path(path).resolve()) == doc_real:
                registered = True
                current_scope = [str(x) for x in ids]
        except OSError:
            pass
        if not Path(path).is_file():
            errors.append(f"{where}({path}): 文档不存在（缺文档即失败——先补文档或修正清单）")

    if total_entries > 1:
        errors.append(f"total 文档最多一份（实际 {total_entries}）")
    if frozen:
        missing = frozen - union
        extra = union - frozen
        if missing:
            errors.append(f"子集并集缺冻结验收点 {len(missing)} 个: {sorted(missing)[:5]}（并集必须与冻结分母全等）")
        if extra:
            errors.append(f"子集并集含冻结分母之外的 ID: {sorted(extra)[:5]}")

    if errors:
        for e in errors:
            print(f"  ✗ {e}")
        print(f"\n设计包清单校验失败：共 {len(errors)} 处。")
        sys.exit(1)

    if not registered:
        print(f"当前文档未登记进设计包清单: {args.doc}")
        sys.exit(1)

    print(f"SCOPE={','.join(current_scope)}")
    sys.exit(0)


if __name__ == "__main__":
    main()
