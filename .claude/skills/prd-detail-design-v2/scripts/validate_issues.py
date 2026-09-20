# -*- coding: utf-8 -*-
"""PRD 问题清单校验器：用 issues.schema.json 校验 prd_issues.json。

检查：
  I1 编号        issueId 必须 PI-01..PN 按数组顺序连续、不重复
  I2 blocking 裁决门  blocking=true 且 status=open 的问题存在时，详设（受影响范围）禁止生成
                 ——加 --gate 参数时以非 0 退出码表达（run_design 硬门用）；默认仅报告
  I3 裁决完整性  status=resolved ⇒ resolution 非空；status=wontfix ⇒ resolution 写理由；
                 resolution 非空但 status=open ⇒ 状态与内容矛盾
  I4 冲突双口径  kind=conflict ⇒ text 中须能检出两处口径线索（「 vs 」/「；另有」/两个章节号），
                 缺线索提示补全（矛盾必须可回溯到两处出处）
  I5 blocking 凭据（硬）  blocking=true 且 kind=unresolved ⇒ candidates 必须 ≥2
                 ——blocking 的判据是"有分叉影响设计"，写不出两个候选就不是分叉，
                 判定方向有误须打回；kind=conflict 双口径已是凭据、免检；
                 kind=gap（零方案型）允许为空，仅提示确认
  I6 非阻塞自说明（软）  blocking=false 且未 resolved 时建议填 nonBlockingReason/confirmPoint，
                 两者皆空仅警告不拦截（说明性字段，非闭环锚点）

用法：
  python validate_issues.py --input prd_issues.json
  python validate_issues.py --input prd_issues.json --gate   （blocking 未裁决 → 退出码 1）
"""
import argparse
import json
import re
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = Path(__file__).resolve().parent


def _load(path):
    sys.path.insert(0, str(_HERE))
    from validate_design import validate
    schema = json.loads((_HERE.parent / "issues.schema.json").read_text(encoding="utf-8"))
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    return data, validate(data, schema, schema)


def main():
    ap = argparse.ArgumentParser(description="校验 PRD 问题清单")
    ap.add_argument("--input", required=True)
    ap.add_argument("--gate", action="store_true",
                    help="裁决门：存在 blocking 且未裁决的问题时退出码 1（详设生成前的前置条件）")
    args = ap.parse_args()

    data, schema_errors = _load(args.input)
    errors = list(schema_errors)
    warns = []
    issues = data.get("issues", [])

    # I1 编号
    for i, p in enumerate(issues, start=1):
        expect = f"PI-{i:02d}"
        if p.get("issueId") != expect:
            errors.append(f"issues[{i - 1}].issueId 应为 {expect}，实际 {p.get('issueId')!r}")

    # I3 裁决完整性
    for p in issues:
        pid = p.get("issueId")
        res = (p.get("resolution") or "").strip()
        if p.get("status") == "resolved" and not res:
            errors.append(f"{pid}: status=resolved 但 resolution 为空（裁决必须写明口径）")
        if p.get("status") == "wontfix" and not res:
            errors.append(f"{pid}: status=wontfix 但 resolution 为空（须写明不处理理由）")
        if p.get("status") == "open" and res:
            errors.append(f"{pid}: status=open 但已填 resolution（状态与内容矛盾，应为 resolved）")

    # I4 冲突双口径线索
    for p in issues:
        if p.get("kind") != "conflict":
            continue
        text = p.get("text", "")
        # 直接数 sourceSection 里的章节号 token（§7.1;§7.2 紧凑分隔也能数出两个）
        secs = re.findall(r"\d+(?:\.\d+)*", p.get("sourceSection", ""))
        has_two = (" vs " in text) or ("；另有" in text) or ("两处" in text) or len(secs) >= 2
        if not has_two:
            errors.append(
                f"{p.get('issueId')}: kind=conflict 但 text/sourceSection 检不出两处口径线索"
                f"（须并列两种表述及各自出处，矛盾必须可回溯）"
            )

    # I5 blocking 凭据（硬）：unresolved 且 blocking ⇒ 必须出示 ≥2 个候选（分叉检测器）
    for p in issues:
        pid = p.get("issueId")
        kind, blocking = p.get("kind"), p.get("blocking")
        cands = p.get("candidates") or []
        if blocking and kind == "unresolved" and len(cands) < 2:
            errors.append(
                f"{pid}: blocking=true 且 kind=unresolved 但 candidates 不足 2 个（实际 {len(cands)}）"
                f"——blocking 的判据是存在影响设计的分叉，须把候选方案及各自影响列进 candidates；"
                f"列不出来说明这里没有分叉，应改为 blocking=false 并填 nonBlockingReason"
            )
        if blocking and kind == "gap" and not cands:
            warns.append(
                f"{pid}: blocking=true 且 kind=gap 且无候选（零方案型，合法；请确认确实无候选可列而非漏登）"
            )

    # I6 非阻塞自说明（软）：说明性字段缺失只警告
    for p in issues:
        if p.get("blocking") or p.get("status") == "resolved":
            continue
        if not (p.get("nonBlockingReason") or "").strip() and not (p.get("confirmPoint") or "").strip():
            warns.append(
                f"{p.get('issueId')}: blocking=false 但未填 nonBlockingReason/confirmPoint"
                f"（建议写明为什么不阻塞、读者只需确认什么，裁决评审更省事）"
            )

    # I2 blocking 裁决门
    unresolved_blocking = [p["issueId"] for p in issues if p.get("blocking") and p.get("status") == "open"]

    for w in warns:
        print("  ⚠", w)
    for e in errors:
        print("  ✗", e)
    if errors:
        print(f"\n问题清单校验失败：共 {len(errors)} 处不合规。")
        sys.exit(1)

    print(f"问题清单校验通过：{len(issues)} 条问题，"
          f"blocking 未裁决 {len(unresolved_blocking)} 条"
          f"（{'、'.join(unresolved_blocking) or '无'}）。")
    if args.gate and unresolved_blocking:
        print(f"\n裁决门未通过：blocking 问题 {'、'.join(unresolved_blocking)} 仍为 open——"
              f"受影响范围的详设禁止生成，须先裁决回填（status=resolved + resolution）。")
        sys.exit(1)
    if args.gate:
        print("裁决门通过：全部 blocking 问题已裁决，可生成详设。")
    sys.exit(0)


if __name__ == "__main__":
    main()
