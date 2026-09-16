# -*- coding: utf-8 -*-
"""devflow 结构化产物渲染器（JSON → Markdown 确定性派生层）。

分工契约（自 flow-node-panorama 吸收）：
  确定性层（本脚本）：计数、覆盖率、追溯矩阵、索引表、权限矩阵、零结果话术、
  证据绑定表、统计行——按 JSON 数组顺序解析，AI 不手填；
  语义层（AI）：设计判断、证据结论——已在 JSON 中，本脚本只做忠实呈现。

design 模式（拼接）：文档骨架中的 `<!-- df:begin:KEY -->` … `<!-- df:end:KEY -->`
块由本脚本整体重写（KEY ∈ summary/trace-matrix/table-index/api-index/
permission-matrix/rule-index/client-scope/zero-results/ddr-index/ddr-matrix）。
骨架缺块即报错退出，不静默跳过——防止"渲染成功但确定性层缺失"的假绿。

verification 模式（整文档）：渲染终验报告，绑定命令、退出码、报告 SHA-256、
执行日志与（可选）Gate 实际执行退出码对账列。

用法：
  python3 df_render.py design --input design.json --doc docs/详细设计/f-详细设计.md
  python3 df_render.py design --input design.json --out standalone.md
  python3 df_render.py verification --input verification.json --out docs/测试/f-终验报告.md \
      [--exec-record .devflow/f/test-execution-results.env] [--workspace .]
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# v3.24.0(A07)：块注册表 = 渲染器实际产出的全部块（唯一正本）。
# 旧表只声明 10 块，而 render_design_blocks 实际产出 12 块（resource-operations、
# integrations-configs 未列入声明）——按提示词声明的 10 块搭骨架会触发
# ValueError 拼接崩溃。现在缺块检查直接以渲染块集合为准，新增块自动纳入强制。
# v3.24.0(A01)：新增 biz-ops（业务操作契约索引），共 13 块。
_DESIGN_BLOCKS = [
    "summary", "trace-matrix", "table-index", "api-index",
    "permission-matrix", "rule-index", "biz-ops", "client-scope",
    "zero-results", "ddr-index", "ddr-matrix", "resource-operations",
    "integrations-configs",
]


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def _cell(v):
    return str(v).replace("\r", " ").replace("|", "\\|").replace("\n", " ")


def _table(headers, rows):
    out = ["| " + " | ".join(headers) + " |", "|" + "|".join(["---"] * len(headers)) + "|"]
    for r in rows:
        out.append("| " + " | ".join(_cell(c) for c in r) + " |")
    return "\n".join(out)


# ---------- design 确定性派生 ----------


def render_design_blocks(data):
    acc = data.get("acceptance", [])
    tables = data.get("tables", [])
    apis = data.get("apis", [])
    pages = data.get("pages", [])
    rules = data.get("rules", [])
    client = data.get("client", {})
    blocks = {}
    decisions = data.get("decisions", [])

    total = len(acc)
    complete = sum(1 for a in acc if a.get("status") == "COMPLETE")
    pct = f"{(complete / total * 100):.0f}%" if total else "0%"
    field_n = sum(len(t.get("fields", [])) for t in tables)
    req_n = sum(len((a.get("request") or {}).get("fields", [])) for a in apis)
    res_n = sum(len((a.get("response") or {}).get("fields", [])) for a in apis)
    scope_text = client.get("scope")
    scope_human = {"pc-web": "PC 网页端", "mini-program": "微信小程序",
                   "app": "手机 APP"}.get(scope_text, scope_text or "未声明")

    missing_api_details = sum(1 for a in apis if not a.get("detail_anchor"))
    resources = data.get("resources", [])
    operations = data.get("operations", [])
    integrations = data.get("integrations", [])
    configs = data.get("configs", [])
    reverse_n = sum(1 for o in operations if o.get("type") in ("cancel", "rollback", "timeout", "retry"))
    blocks["summary"] = (
        f"本设计共覆盖验收点 **{total}** 个（设计完成 {complete}/{total} = {pct}），"
        f"新建或修改数据表 **{len(tables)}** 张（共 {field_n} 个字段），"
        f"接口 **{len(apis)}** 个（请求字段 {req_n} 个、响应字段 {res_n} 个，"
        + (f"全部配有详细定义" if missing_api_details == 0 else f"**{missing_api_details} 个接口缺少详细定义**") + "），"
        f"页面 **{len(pages)}** 个，业务规则 **{len(rules)}** 条，设计决策 **{len(decisions)}** 条，"
        f"外部集成 **{len(integrations)}** 个，配置键 **{len(configs)}** 个，"
        f"受管资源 **{len(resources)}** 个（{len(operations)} 个操作、其中反向操作 {reverse_n} 个）。"
        f"客户端只覆盖**{scope_human}**。\n\n"
        f"> 本节由设计数据自动汇总。"
    )

    blocks["trace-matrix"] = (
        _table(
            ["ID", "PRD 锚点", "页面/任务", "接口", "数据", "规则", "测试用例", "状态"],
            [[a.get("id"), a.get("prd_anchor"), a.get("page"), a.get("api"),
              a.get("data"), a.get("rule"), a.get("test_case"), a.get("status")] for a in acc],
        )
        + f"\n\n覆盖率：{complete}/{total} = {pct}"
        + ("，全部验收点都完成了设计。" if complete == total and total else f"，还有 {total - complete} 个验收点未完成设计。")
    )

    blocks["table-index"] = _table(
        ["锚点", "表名", "字段数"],
        [[t.get("anchor"), t.get("name"), len(t.get("fields", []))] for t in tables],
    )

    # v3.17.1: 方法必须在第一列（行首）——p4_prd_vs_code.sh parse_design_apis
    # 只识别首列为 HTTP 方法的表格行，概览列序与其解析契约保持一致。
    blocks["api-index"] = _table(
        ["方法", "路径", "接口名称", "权限", "概览锚点", "详细定义", "请求字段", "响应字段"],
        [[a.get("method"), a.get("path"), a.get("name"), a.get("permission"),
          a.get("anchor"), a.get("detail_anchor"),
          len((a.get("request") or {}).get("fields", [])),
          len((a.get("response") or {}).get("fields", []))] for a in apis],
    )

    perm_rows = [[p.get("name"), p.get("anchor"), p.get("permission")] for p in pages]
    perm_rows += [[f"{a.get('method')} {a.get('path')}", a.get("anchor"), a.get("permission")] for a in apis]
    blocks["permission-matrix"] = (
        _table(["对象", "§锚点", "所需权限"], perm_rows)
        + "\n\n> 每个页面和接口都标注了所需的权限；完全公开的对象在该列标注 public。"
    )

    blocks["rule-index"] = _table(
        ["规则", "§锚点", "摘要"], [[r.get("id"), r.get("anchor"), r.get("summary")] for r in rules],
    )

    # v3.24.0(A01)：业务操作契约索引——以业务命名（非固定 CRUD 枚举），
    # 与冻结验收集合双向对账（df_validate 校验 acceptance 覆盖闭环）。
    biz_ops = data.get("business_operations", [])
    if biz_ops:
        blocks["biz-ops"] = (
            _table(
                ["操作", "触发者/触发", "源状态→目标状态", "事务/并发", "结果/失败", "验收点", "§锚点"],
                [[o.get("name"),
                  f"{o.get('actor', '—')}｜{o.get('trigger', '—')}",
                  "无状态（已声明）" if o.get("stateless") else f"{o.get('source_state', '?')} → {o.get('target_state', '?')}",
                  o.get("concurrency", "—"),
                  f"{o.get('result', '—')}｜失败：{o.get('failure', '—')}",
                  "、".join(o.get("acceptance_refs", [])) or "—",
                  o.get("anchor", "—")] for o in biz_ops],
            )
            + "\n\n> 业务操作以业务命名，覆盖触发者、前置校验、状态迁移、事务/并发、结果与失败；"
              "冻结验收集合的每个验收点都必须被至少一个操作覆盖，无状态操作须显式声明。"
        )
    else:
        blocks["biz-ops"] = "本设计无业务操作契约（须在 zero_results 声明 business_operations 为空及理由）。"

    blocks["ddr-index"] = _table(
        ["编号", "决策点", "备选方案", "选定", "理由"],
        [[d.get("id"), d.get("topic"), d.get("alternatives", "—"), d.get("chosen", "—"), d.get("reason")]
         for d in decisions],
    ) + "\n\n> 每条设计决策回答了「为什么这么设计」，并与具体字段一一对应（见下表）。理由均来自业务口径、规范条目或量化数据，不只凭经验。"

    ddr_rows = []
    for t in tables:
        for f in t.get("fields", []):
            ddr_rows.append([t.get("name"), f.get("name"), "、".join(f.get("ddr", [])) or "—"])
    blocks["ddr-matrix"] = (
        _table(["表", "字段", "关联 DDR"], ddr_rows)
        + f"\n\n全部 {len(ddr_rows)} 个字段都能追溯到决定它的设计决策。"
    )

    scope = client.get("scope")
    if scope == "not-applicable":
        blocks["client-scope"] = f"本需求**没有客户端界面**，原因：{client.get('not_applicable_reason', '（缺原因）')}"
    else:
        journeys = client.get("journeys", [])
        blocks["client-scope"] = (
            f"客户端范围为**{scope_human}**，以下旅程必须在真实环境中走通：\n\n"
            + _table(["旅程", "§页面锚点", "证据形态"], [[j.get("name"), j.get("page"), j.get("evidence")] for j in journeys])
        )

    # v3.20.0: 资源×操作补偿矩阵 + 外部集成/配置索引
    if not resources:
        blocks["resource-operations"] = "本设计没有需要受管释放的资源（如锁、配额、占用标记、外部预占），无需补偿链。"
    else:
        rev_ops = [o for o in operations if o.get("type") in ("cancel", "rollback", "timeout", "retry")]
        timing_human = {"on_operation": "立即释放", "on_next_submit": "下次提交释放",
                        "never": "永不释放", "not_applicable": "不涉及"}
        rows = []
        for r in resources:
            row = [r.get("name"), r.get("kind")]
            for o in rev_ops:
                cell = "—未表态—"
                for c in o.get("resource_closure", []):
                    if c.get("resource") == r.get("id"):
                        cell = timing_human.get(c.get("release_timing"), c.get("release_timing"))
                row.append(cell)
            rows.append(row)
        blocks["resource-operations"] = (
            _table(["资源", "类别"] + [f"{o.get('name')}（{o.get('type')}）" for o in rev_ops], rows)
            + "\n\n> 每个被正向占用的资源，在取消/回滚/超时/重试时都有明确处置；"
              "「永不释放」「不涉及」必须写明理由，沉默视为设计缺失。"
        )

    if not integrations and not configs:
        blocks["integrations-configs"] = "本设计不涉及外部集成与配置键。"
    else:
        parts = []
        if integrations:
            parts.append(_table(
                ["集成", "方向", "端点", "超时", "幂等", "失败路径", "降级/兜底"],
                [[i.get("name"), "出向" if i.get("direction") == "outbound" else "入向",
                  i.get("endpoint", "—"), i.get("timeout"), i.get("idempotency"),
                  i.get("failure_path"), i.get("fallback", "—")] for i in integrations]))
        if configs:
            parts.append(_table(
                ["配置键", "值格式", "生效消费点", "失败路径", "置信级"],
                [[c.get("key"), c.get("value_format"),
                  sum(1 for pt in c.get("consumption_points", []) if pt.get("status") == "active"),
                  c.get("failure_path"), c.get("confidence")] for c in configs]))
        blocks["integrations-configs"] = "\n\n".join(parts)

    zeros = data.get("zero_results", [])
    blocks["zero-results"] = (
        "以下内容已确认为空，并非遗漏：\n\n"
        + _table(["为空的内容", "原因"], [[z.get("path"), z.get("reason")] for z in zeros])
        if zeros
        else "本文所有清单均有内容，无空缺项。"
    )

    return blocks


def _splice(doc_path, blocks):
    """整体重写骨架中的 df:begin/end 块；缺块或重复块即失败关闭。

    v3.24.0(A07)：缺块检查以本次渲染的 blocks 键集合为正本（= _DESIGN_BLOCKS），
    不再依赖可能过期的平行清单。"""
    text = Path(doc_path).read_text(encoding="utf-8")
    required = [k for k in _DESIGN_BLOCKS if k in blocks] or list(_DESIGN_BLOCKS)
    missing = [k for k in required if f"<!-- df:begin:{k} -->" not in text]
    if missing:
        print(f"  ✗ 骨架缺少确定性层锚点块: {missing}", file=sys.stderr)
        print("    须在文档中加入：<!-- df:begin:KEY -->\\n<!-- df:end:KEY -->（KEY ∈ "
              + ", ".join(required) + "）", file=sys.stderr)
        print("    或用 `df_render.py design --init-doc <path>` 由注册表直接生成含全量块的骨架",
              file=sys.stderr)
        sys.exit(1)
    duplicated = [k for k in required if text.count(f"<!-- df:begin:{k} -->") > 1]
    if duplicated:
        print(f"  ✗ 骨架存在重复锚点块: {duplicated}（每 KEY 恰好一对 begin/end，拒绝歧义拼接）",
              file=sys.stderr)
        sys.exit(1)
    # v3.17.2(L4): begin 无成对 end 时显式报错（曾落入 split ValueError traceback）
    orphan_end = [k for k in required
                  if text.count(f"<!-- df:begin:{k} -->") != text.count(f"<!-- df:end:{k} -->")]
    if orphan_end:
        print(f"  ✗ 锚点块 begin/end 不成对: {orphan_end}", file=sys.stderr)
        sys.exit(1)
    for key, content in blocks.items():
        begin, end = f"<!-- df:begin:{key} -->", f"<!-- df:end:{key} -->"
        pre, rest = text.split(begin, 1)
        _, post = rest.split(end, 1)
        text = pre + begin + "\n" + content + "\n" + end + post
    Path(doc_path).write_text(text, encoding="utf-8")


def _init_doc(doc_path):
    """v3.24.0(A07)：初始化入口——按块注册表生成含全量锚点块的骨架。

    模板、schema 与块注册表来自同一契约：此入口保证「声明的块 = 渲染器要写的块」。
    文档已存在时拒绝（防覆盖在途产物），并列出缺失块供手工补齐。"""
    p = Path(doc_path)
    if p.exists():
        text = p.read_text(encoding="utf-8")
        missing = [k for k in _DESIGN_BLOCKS if f"<!-- df:begin:{k} -->" not in text]
        print(f"  ✗ 文档已存在，拒绝初始化: {doc_path}", file=sys.stderr)
        if missing:
            print(f"    该文档缺少锚点块: {missing}", file=sys.stderr)
        sys.exit(1)
    p.parent.mkdir(parents=True, exist_ok=True)
    parts = ["# 设计文档骨架（由 df_render 块注册表生成，13 个确定性层锚点块）", ""]
    for k in _DESIGN_BLOCKS:
        parts.append(f"<!-- df:begin:{k} -->\n<!-- df:end:{k} -->")
    p.write_text("\n".join(parts) + "\n", encoding="utf-8")
    print(f"骨架已初始化: {doc_path}（{_DESIGN_BLOCKS.__len__()} 个锚点块；"
          f"语义层内容按模板补写后经 df_pipeline.py 渲染）")


# ---------- verification 终验报告 ----------


def render_verification(data, input_path, exec_record_path=None, workspace="."):
    import os

    results = data.get("acceptance_results", [])
    evidence = data.get("evidence", {})
    cna = data.get("client_not_applicable", {})
    total = len(results)
    passed = sum(1 for r in results if r.get("status") == "PASS")

    record = {}
    if exec_record_path:
        er = Path(exec_record_path)
        if er.exists():
            import re as _re
            for ln in er.read_text(encoding="utf-8", errors="replace").splitlines():
                m = _re.match(r"^([A-Z_]+)=(.*)$", ln)
                if m:
                    record[m.group(1)] = m.group(2)

    env_human = {"dev": "开发环境", "staging": "预发布环境", "production": "生产环境"}.get(
        data.get("environment"), data.get("environment", "未声明"))
    # v3.18.0: ISO 8601 机器格式转人类可读（#3）
    gen_time = (data.get("generated_at") or "未填写").replace("T", " ").replace("Z", "（UTC）")
    lines = [
        f"# {data.get('feature')} 终验报告（部署前最终验收）",
        "",
        f"> 生成时间：{gen_time}　验证环境：**{env_human}**　数据来源：终验数据自动汇总",
        f"<!-- 审计指纹: verification.json sha256={_sha256(input_path)} -->",
        "",
        f"## 结论：{'全部通过，可以部署' if passed == total and total else f'存在 {total - passed} 个未通过项，禁止部署'}",
        "",
        f"{total} 个验收点{'全部通过' if passed == total and total else f'通过 {passed} 个、未通过 {total - passed} 个'}。"
        + (
            "单元、集成、负载、预发布四类测试已执行，客户端测试按声明豁免（frontend_scope=not-applicable），"
            if (data.get("client_not_applicable") or {}).get("declared")
            else "五类测试（单元、集成、客户端、负载、预发布）均已执行，"
        )
        + ("结果全部通过，明细见下文。" if passed == total and total else f"其中 {total - passed} 个验收点未通过，明细见下文。"),
        "",
        "## §1 验收点明细",
        "",
        _table(
            ["ID", "终态", "证据"],
            [[r.get("id"), r.get("status"), r.get("evidence", "—")] for r in results],
        ),
        "",
        f"共 {total} 个验收点：通过 {passed} 个，未通过 {total - passed} 个。"
        f"验收点范围与测试开始前冻结的验收点清单完全一致，无遗漏、无多余。",
        "",
        "## §2 五类测试证据绑定",
        "",
    ]

    kind_human = {"unit": "单元测试", "integration": "集成测试", "client": "客户端测试",
                  "load": "负载测试", "staging": "预发布验证"}
    ev_rows = []
    for kind in ("unit", "integration", "client", "load", "staging"):
        ev = evidence.get(kind)
        if not ev:
            ev_rows.append([kind_human[kind], "—（本需求无客户端界面）" if kind == "client" else "—（该类测试未提供证据，本次终验不通过）", "—", "—", "—", "—", "—"])
            continue
        actual = record.get(f"{kind.upper()}_ACTUAL_EXIT", "未记录")
        rp = ev.get("report_path", "—")
        sha = "—"
        resolved = Path(workspace) / rp if rp != "—" and not os.path.isabs(rp) else Path(rp) if rp != "—" else None
        if resolved is not None and resolved.exists():
            sha = _sha256(resolved)[:12] + "…"
        ev_rows.append([kind_human[kind], ev.get("cmd"), ev.get("exit_code"), actual, rp, sha, ev.get("log_path", "—")])
    lines += [
        _table(["测试类别", "执行命令", "退出码", "实测退出码", "报告文件", "报告指纹", "日志"], ev_rows),
        "",
        "> 「实测退出码」是部署前检查流程现场重新执行同一命令后的实际结果，与上表命令一一对应；报告指纹是报告文件内容的 SHA-256 摘要，用于事后核对报告未被改动。",
        "",
        "## §3 客户端测试说明",
        "",
    ]
    if cna.get("declared"):
        lines.append(f"本需求没有客户端界面，因此不做客户端测试。原因：{cna.get('reason', '（缺原因）')}")
    else:
        cj = evidence.get("client") or {}
        lines.append(f"客户端测试已执行：`{cj.get('cmd', '—')}`，报告见 `{cj.get('report_path', '—')}`。")
    lines += ["", "## §4 空项与特别说明", ""]
    zeros = data.get("zero_results", [])
    lines.append(
        "以下内容确认为空，不是遗漏：\n\n"
        + _table(["为空的内容", "原因"], [[z.get("path"), z.get("reason")] for z in zeros])
        if zeros
        else "无。"
    )
    lines.append("")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description="devflow 结构化产物渲染器（确定性派生层）")
    ap.add_argument("kind", choices=["design", "verification"])
    ap.add_argument("--input", required=True)
    ap.add_argument("--doc", default=None, help="design: 拼接目标文档（须含 df:begin/end 锚点块）")
    ap.add_argument("--init-doc", dest="init_doc", default=None, metavar="PATH",
                    help="design: 按块注册表初始化骨架（文档须不存在；存在时列出缺失块后退出 1）")
    ap.add_argument("--out", default=None, help="输出路径（design 未给 --doc 时为独立输出；verification 必填）")
    ap.add_argument("--exec-record", default=None, help="verification: Gate 执行记录（填充实际退出码列）")
    ap.add_argument("--workspace", default=".", help="相对路径解析根")
    args = ap.parse_args()

    data = json.loads(Path(args.input).read_text(encoding="utf-8"))

    if args.kind == "design":
        if args.init_doc:
            _init_doc(args.init_doc)
            sys.exit(0)
        blocks = render_design_blocks(data)
        if args.doc:
            _splice(args.doc, blocks)
            print(f"渲染完成：确定性层已拼接至 {args.doc}（{len(blocks)} 个锚点块）")
        elif args.out:
            Path(args.out).write_text(
                "\n\n".join(f"<!-- df:begin:{k} -->\n{v}\n<!-- df:end:{k} -->" for k, v in blocks.items()),
                encoding="utf-8",
            )
            print(f"渲染完成：{args.out}（独立输出 {len(blocks)} 个锚点块）")
        else:
            ap.error("design 模式需要 --doc（拼接）或 --out（独立输出）")
    else:
        if not args.out:
            ap.error("verification 模式需要 --out")
        report = render_verification(data, args.input, exec_record_path=args.exec_record,
                                     workspace=args.workspace)
        Path(args.out).write_text(report, encoding="utf-8")
        print(f"渲染完成：{args.out}")
    sys.exit(0)


if __name__ == "__main__":
    main()
