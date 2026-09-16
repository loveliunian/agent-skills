# -*- coding: utf-8 -*-
"""devflow 结构化产物管线（单一失败关闭入口）。

固定顺序：validate → render → gate。校验失败（退出码非 0）即中止，不渲染、
不进 Gate——把「校验通过才产出」从文字规范变成流程硬门（自 flow-node-panorama
的 run_analysis.py 吸收；渲染器遇缺字段会静默降级，必须在渲染前拦截）。

Gate 仍是阶段权威（如 P6 的 s6_final_verification_gate.sh 会实际执行五类测试
命令并写收据）；本管线保证进入 Gate 的文档/报告由已校验的 JSON 确定性生成。

用法：
  # P2：design.json → 校验 → 拼接详设确定性层 →（可选）跑 P2 Gate
  python3 df_pipeline.py design --input .devflow/f/design.json \
      --doc docs/detailed-design/f-design.md \
      --criteria docs/requirements/f-acceptance-criteria.md \
      --gate bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/detailed-design/f-design.md docs/requirements/f-acceptance-criteria.md

  # P6：verification.json → 校验（对账 baseline + Gate 执行记录）→ 渲染终验报告
  python3 df_pipeline.py verification --input .devflow/f/verification.json \
      --out docs/test/f-final-verification-report.md \
      --baseline .devflow/f/first-pass-baseline.tsv \
      --exec-record .devflow/f/test-execution-results.env
"""
import argparse
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = Path(__file__).resolve().parent


def _run(cmd):
    print(f"[pipeline] $ {' '.join(str(c) for c in cmd)}")
    return subprocess.run([str(c) for c in cmd]).returncode


def main():
    ap = argparse.ArgumentParser(description="validate → render → gate（失败关闭）")
    ap.add_argument("kind", choices=["design", "verification"])
    ap.add_argument("--input", required=True, help="结构化 JSON 路径")
    ap.add_argument("--schema", default=None, help="schema.json 路径（缺省用 skill 内置）")
    ap.add_argument("--doc", default=None, help="design: 拼接目标详设文档")
    ap.add_argument("--out", default=None, help="输出 Markdown（verification 必填；design 独立输出时必填）")
    ap.add_argument("--criteria", default=None, help="design: P0 验收点文件（冻结分母对账）")
    ap.add_argument("--baseline", default=None, help="verification: first-pass-baseline.tsv（P6 必填）")
    ap.add_argument("--exec-record", default=None, help="verification: test-execution-results.env（P6 必填）")
    ap.add_argument("--workspace", default=".", help="报告相对路径解析根")
    ap.add_argument("--max-errors", type=int, default=100)
    ap.add_argument("--gate", nargs=argparse.REMAINDER, default=None,
                    help="渲染成功后执行的 Gate 命令（如 s2/s6 gate；收据由 Gate 自产）")
    args = ap.parse_args()

    # v3.17.2(L5): `--gate` 后为空曾静默视为未指定并 exit 0——显式报用法错误
    # v3.17.3(B-7): 以解析结果判定而非 sys.argv 字符串匹配（避免其他选项值恰为字面量 --gate 误触发）
    if args.gate is not None and len(args.gate) == 0:
        ap.error("--gate 需要至少一个命令参数（如 --gate bash s2_design_coverage_gate.sh ...）")

    if args.kind == "verification" and not args.out:
        ap.error("verification 需要 --out")
    if args.kind == "verification" and (not args.baseline or not args.exec_record):
        # v3.19.0(P0-2): P6 的真实证据只能来自已执行的 Gate（EXEC_RECORD 由 s6 生成）。
        # 缺 baseline/exec-record 时管线曾以"未对账"状态渲染出「可以部署」——false 收尾。
        # 正确因果序：execute gate → validate evidence → render；无执行记录即拒绝。
        ap.error(
            "verification 必须提供 --baseline 与 --exec-record"
            "（先跑 s6_final_verification_gate.sh 生成真实执行记录，再校验/渲染；"
            "Gate 通过后会自行渲染正式终验报告并绑定收据）"
        )
    if args.kind == "design" and not args.doc and not args.out:
        ap.error("design 需要 --doc 或 --out")

    validate_cmd = [sys.executable, _HERE / "df_validate.py", "--kind", args.kind,
                    "--input", args.input, "--workspace", args.workspace,
                    "--max-errors", str(args.max_errors)]
    if args.schema:
        validate_cmd += ["--schema", args.schema]
    if args.kind == "design":
        if args.criteria:
            validate_cmd += ["--criteria", args.criteria]
        if args.doc:
            validate_cmd += ["--doc", args.doc]
    if args.kind == "verification":
        if args.baseline:
            validate_cmd += ["--baseline", args.baseline]
        if args.exec_record:
            validate_cmd += ["--exec-record", args.exec_record]

    print("[pipeline] Step 1/2 校验结构化 JSON …")
    rc = _run(validate_cmd)
    if rc != 0:
        print("[pipeline] 校验未通过，已中止：不渲染、不进 Gate。", file=sys.stderr)
        sys.exit(rc)

    print("[pipeline] Step 2/2 渲染确定性层 …")
    render_cmd = [sys.executable, _HERE / "df_render.py", args.kind, "--input", args.input,
                  "--workspace", args.workspace]
    if args.kind == "design":
        render_cmd += (["--doc", args.doc] if args.doc else ["--out", args.out])
    else:
        render_cmd += ["--out", args.out]
        if args.exec_record:
            render_cmd += ["--exec-record", args.exec_record]
    rc = _run(render_cmd)
    if rc != 0:
        print("[pipeline] 渲染失败，不进 Gate。", file=sys.stderr)
        sys.exit(rc)

    if args.gate:
        print("[pipeline] Step 3/3 执行 Gate（收据由 Gate 自产）…")
        sys.exit(_run(args.gate))

    print("[pipeline] 完成（未指定 --gate，Gate 请按阶段矩阵另行执行）。")
    sys.exit(0)


if __name__ == "__main__":
    main()
