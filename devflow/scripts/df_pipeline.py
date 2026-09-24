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
      --doc docs/详细设计/f-详细设计.md \
      --criteria docs/需求/f-验收点.md \
      --gate bash "$SKILL_ROOT/scripts/s2_design_coverage_gate.sh" docs/详细设计/f-详细设计.md docs/需求/f-验收点.md

  # P6：verification.json → 校验（对账 baseline + Gate 执行记录）→ 渲染终验报告
  python3 df_pipeline.py verification --input .devflow/f/verification.json \
      --out docs/测试/f-终验报告.md \
      --baseline .devflow/f/first-pass-baseline.tsv \
      --exec-record .devflow/f/test-execution-results.env

  # v3.25.0 全阶段产物（每环节 md 产物都有 JSON 契约，失败关闭）：
  #   clarification acceptance constraints prd-review tech-selection design-review
  #   self-check code-review prd-validation test-cases deployment monitoring
  #   docs-index retrospective small-change
  python3 df_pipeline.py acceptance --input .devflow/f/acceptance.json \
      --out docs/需求/f-验收点.md --criteria docs/PRD/f.md
  python3 df_pipeline.py small-change --input .devflow/c1/small-change.json \
      --out docs/小需求变更/c1-小需求变更.md \
      --out-env .devflow/c1/small-change.env --out-scan .devflow/c1/project-scan.txt
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

_HERE = Path(__file__).resolve().parent


def _design_doc_mode(input_path, doc_path):
    """v3.27.10：总分模式从设计包清单解析当前文档角色（无清单/未登记返回 None）。

    总文档（mode=total）校验时不做模块级锚点与正文明细对账（见 df_validate
    --doc-mode）——模块级对象由分文档承担；此前总文档会被模块级锚点误拦。"""
    pkg = Path(input_path).resolve().parent / "design-package.json"
    if not pkg.is_file():
        return None
    try:
        data = json.loads(pkg.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    doc = str(doc_path).replace("\\", "/").lstrip("./")
    for d in data.get("docs", []) or []:
        cand = str(d.get("path") or "").replace("\\", "/").lstrip("./")
        if cand and (cand == doc or Path(cand).name == Path(doc).name):
            mode = (d.get("mode") or "").strip()
            return mode if mode in ("total", "sub") else None
    return None


def _run(cmd, timeout=None):
    """统一 ProcessRunner（v3.31.0：审查报告-0924 短期项）——全子进程带超时。

    超时杀进程组（start_new_session），rc=124（对齐 run-tests 惯例）；无超时的
    卡死 build/test 可无限占用 Agent 会话——默认 DF_PIPELINE_TIMEOUT_SECONDS=3600。"""
    import os as _os, signal as _signal
    default_to = int(_os.environ.get("DF_PIPELINE_TIMEOUT_SECONDS", "3600"))
    timeout = timeout or default_to
    print(f"[pipeline] $ {' '.join(str(c) for c in cmd)} (timeout={timeout}s)")
    import time as _time
    _t0 = _time.monotonic()
    try:
        proc = subprocess.Popen(
            [str(c) for c in cmd],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
            start_new_session=True,
        )
    except FileNotFoundError:
        print(f"[pipeline] command not found: {cmd[0]}", file=sys.stderr)
        return 127
    try:
        out, _ = proc.communicate(timeout=timeout)
        if out:
            sys.stdout.write(out)
        return proc.returncode
    except subprocess.TimeoutExpired:
        try:
            _os.killpg(_os.getpgid(proc.pid), _signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            proc.kill()
        try:
            proc.communicate(timeout=10)
        except Exception:
            pass
        print(f"[pipeline] TIMEOUT after {timeout}s: {cmd[0]}（rc=124）", file=sys.stderr)
        return 124


def main():
    # v3.25.0：kind 注册表 = df_validate._DEFAULT_SCHEMAS（design/verification 之外的
    # 全阶段产物共用整文档渲染路径，extra outputs 支持 small-change 三件套）
    import df_validate as _dv  # 同目录脚本，注册表单源
    _PHASE_KINDS = sorted(set(_dv._DEFAULT_SCHEMAS) - {"design", "verification"})

    ap = argparse.ArgumentParser(description="validate → render → gate（失败关闭）")
    ap.add_argument("kind", choices=["design", "verification"] + _PHASE_KINDS)
    ap.add_argument("--input", required=True, help="结构化 JSON 路径")
    ap.add_argument("--schema", default=None, help="schema.json 路径（缺省用 skill 内置）")
    ap.add_argument("--doc", default=None, help="design: 拼接目标详设文档")
    ap.add_argument("--db-doc", dest="db_doc", default=None, metavar="PATH",
                    help="design: 数据库设计决策文档（DDR/迁移移出详设后的渲染目标，v3.28.1；须含 ddr-index/ddr-matrix 锚点块）")
    ap.add_argument("--trace-doc", dest="trace_doc", default=None, metavar="PATH",
                    help="design: 需求追溯文档（追溯矩阵移出详设后的渲染目标，v3.28.1；须含 trace-matrix 锚点块）")
    ap.add_argument("--out", default=None, help="输出 Markdown（verification/各阶段报告必填）")
    ap.add_argument("--out-env", default=None, help="small-change: small-change.env 输出路径")
    ap.add_argument("--out-scan", default=None, help="small-change: project-scan.txt 输出路径")
    ap.add_argument("--out-feedback", default=None, help="retrospective: feedback.md 输出路径")
    ap.add_argument("--criteria", default=None, help="design/test-cases: P0 验收点文件（集合/覆盖对账）")
    ap.add_argument("--constraints", default=None, help="tech-selection: P0 技术约束契约文件（绑定对账）")
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
    if args.kind in _PHASE_KINDS and not args.out:
        ap.error(f"{args.kind} 需要 --out（渲染目标 Markdown）")

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
            doc_mode = _design_doc_mode(args.input, args.doc)
            if doc_mode:
                validate_cmd += ["--doc-mode", doc_mode]
    if args.kind == "verification":
        if args.baseline:
            validate_cmd += ["--baseline", args.baseline]
        if args.exec_record:
            validate_cmd += ["--exec-record", args.exec_record]
    if args.kind == "test-cases" and args.criteria:
        validate_cmd += ["--criteria", args.criteria]
    if args.kind == "tech-selection" and args.constraints:
        validate_cmd += ["--constraints", args.constraints]

    print("[pipeline] Step 1/2 校验结构化 JSON …")
    rc = _run(validate_cmd)
    if rc != 0:
        print("[pipeline] 校验未通过，已中止：不渲染、不进 Gate。", file=sys.stderr)
        # v3.28.10 (FB-20260921-002): 失败即附契约卡入口——字段级契约（枚举/正则/
        # 列序）应在【写之前】读，而不是靠试错反推（m01-base 实测：契约对齐占全程 ~25%）。
        _gc = Path(__file__).resolve().parent / "gate-contract.sh"
        print(f"[pipeline] 字段级契约速查：bash '{_gc}' all "
              f"｜或按阶段：gate-contract.sh P0|P0b|P1|P2|...（写产物【前】必读）",
              file=sys.stderr)
        sys.exit(rc)

    print("[pipeline] Step 2/2 渲染确定性层 …")
    render_cmd = [sys.executable, _HERE / "df_render.py", args.kind, "--input", args.input,
                  "--workspace", args.workspace]
    if args.kind == "design":
        render_cmd += (["--doc", args.doc] if args.doc else ["--out", args.out])
        if args.db_doc:
            if not args.doc:
                ap.error("--db-doc 需要同时提供 --doc（详设正文）")
            render_cmd += ["--db-doc", args.db_doc]
        if args.trace_doc:
            if not args.doc:
                ap.error("--trace-doc 需要同时提供 --doc（详设正文）")
            render_cmd += ["--trace-doc", args.trace_doc]
    else:
        render_cmd += ["--out", args.out]
        if args.kind == "small-change":
            if args.out_env:
                render_cmd += ["--out-env", args.out_env]
            if args.out_scan:
                render_cmd += ["--out-scan", args.out_scan]
        if args.kind == "retrospective" and args.out_feedback:
            render_cmd += ["--out-feedback", args.out_feedback]
        if args.kind == "verification" and args.exec_record:
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
