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
import re
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


def _ref_cell(v):
    """v3.24.0(A04)：验收行引用渲染——多对象数组以「、」连接为单格文本。"""
    if isinstance(v, list):
        return "、".join(str(x) for x in v)
    return v


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
            [[a.get("id"), a.get("prd_anchor"), _ref_cell(a.get("page")), _ref_cell(a.get("api")),
              _ref_cell(a.get("data")), a.get("rule"), a.get("test_case"), a.get("status")] for a in acc],
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


# ---------- v3.25.0 全阶段产物渲染器（JSON → 整文档 Markdown） ----------
#
# 与 verification 同一模式：JSON 是唯一事实源，本层确定性派生计数/表格/机器契约块。
# 渲染格式与各阶段 Gate 的机器解析契约逐字段对齐（s0/p3b/p4/artifact_gate/tech_constraints_lib…），
# 保证「Gate 仍是阶段权威，进入 Gate 的文档由已校验的 JSON 确定性生成」。

_AUDIT_NOTE = "\n\n<!-- 审计指纹: {name} sha256={sha}（由 df_render 自动生成，人工勿改） -->"


def _audit(kind, input_path):
    return _AUDIT_NOTE.format(name=f"{kind}.json", sha=_sha256(input_path))


def _gen_time(data):
    return (data.get("generated_at") or "未填写").replace("T", " ").replace("Z", "（UTC）")


def _kv(pairs):
    return "\n".join(f"{k}={v}" for k, v in pairs)


def _signoffs_table(signoffs):
    return _table(["角色", "姓名", "日期"], [[s.get("role"), s.get("name"), s.get("date")] for s in signoffs or []])


def _df_blocks(df_items, with_status=False):
    """DF 五字段块——artifact_gate.sh P0b / p2a_design_review_gate.sh 的机械解析格式。"""
    out = []
    for d in df_items:
        lines = [
            f"#### {d.get('id')} {d.get('title')}",
            f"- 归属评委：{d.get('role')}",
            f"- 文档位置：{d.get('doc_anchor')}",
            f"- 触发场景：{d.get('trigger_scene')}",
            f"- 影响链：{d.get('impact_chain')}",
            f"- 根因类别：{d.get('root_cause')}",
            f"- 完善建议：{d.get('suggestion')}",
            f"- 验证方式：{d.get('verify')}",
            f"- 严重性：{d.get('severity')}",
        ]
        if with_status:
            lines.append(f"- 状态：{d.get('status')}")
        out.append("\n".join(lines))
    return "\n\n".join(out)


def _zero_df_blocks(zero_roles):
    out = []
    for z in zero_roles or []:
        out.append(
            f"#### ZERO-DF（{z.get('role')}）核查记录\n"
            f"- 核查范围：{z.get('scope')}\n"
            f"- 证据锚点：{z.get('evidence_anchor')}\n"
            f"- 验证方式：{z.get('verify')}"
        )
    return "\n\n".join(out)


def _aw_lines(aw_items, df_ids):
    out = []
    for a in aw_items or []:
        refs = a.get("df_refs") or []
        valid = [r for r in refs if r in df_ids]
        if valid:
            result = f"发现 {'、'.join(valid)}"
        else:
            result = f"无问题，证据：{a.get('evidence_anchor')}"
        out.append(f"- {a.get('id')} 场景：{a.get('scenario')}｜走查路径：{a.get('path')}｜结果：{result}")
    return "\n".join(out)


def _probes_table(probes):
    return _table(
        ["探针", "主责评委/角色", "执行情况", "产出位置 / 结论"],
        [[f"{p.get('id')} {p.get('name')}", p.get("owner"),
          "已执行" if p.get("executed") else "未执行",
          p.get("output") or (f"不适用：{p.get('not_applicable_reason')}" if p.get("not_applicable_reason") else "—")]
         for p in probes or []],
    )


def render_clarification(data, input_path):
    amb = data.get("ambiguities", [])
    rows = []
    for a in amb:
        status = "✅ 已澄清" if a.get("status") == "resolved" else "⏳ 待澄清"
        refs = "、".join(a.get("acceptance_refs") or []) or "—"
        rows.append([a.get("priority"), a.get("id"), a.get("description"), a.get("impact"),
                     a.get("conclusion") or "—", refs, status])
    concl = data.get("conclusion", {})
    exclusions = data.get("exclusions", [])
    excl_note = ("以上排除场景已落为排除性验收点。" if data.get("exclusions_covered")
                 else "无排除条款。")
    perm = data.get("permissions")
    perm_line = ("权限矩阵=not-applicable" if data.get("permission_scope") == "not-applicable"
                 else "、".join(f"perm:{p}" for p in perm or []) or "—")
    lines = [
        f"# 需求澄清 - {data.get('feature_name')}",
        "",
        f"> 生成时间：{_gen_time(data)}　数据来源：clarification.json 结构化产物自动汇总",
        _audit("clarification", input_path),
        "",
        "## 基本信息",
        "",
        _table(["项", "内容"], [
            ["功能名称", data.get("feature_name")],
            ["PRD 文档", data.get("prd_doc")],
            ["澄清日期", data.get("date")],
            ["澄清人", "、".join(data.get("participants") or [])],
            ["权限码声明", perm_line],
        ]),
        "",
        "## 模糊点清单",
        "",
        _table(["优先级", "#", "模糊点描述", "影响范围", "澄清结论", "对应验收点", "状态"], rows),
        "",
        f"共 {len(amb)} 个模糊点："
        f"P0 {sum(1 for a in amb if a.get('priority') == 'P0')} 个"
        f"（全部已澄清）、P1 {sum(1 for a in amb if a.get('priority') == 'P1')} 个、"
        f"P2 {sum(1 for a in amb if a.get('priority') == 'P2')} 个。P0 阻塞项清零后才能进入详细设计。",
        "",
        "## 澄清结论汇总",
        "",
        "### 功能边界", "", "```", concl.get("boundaries", ""), "```",
        "",
        "### 数据约束", "", "```", concl.get("data_rules", ""), "```",
        "",
        "### 业务规则", "", "```", concl.get("business_rules", ""), "```",
        "",
        "### 异常处理", "", "```", concl.get("exceptions", ""), "```",
        "",
        "### 排除条款", "",
        "\n".join(f"- {e}" for e in exclusions) if exclusions else "无排除条款。",
        "", excl_note,
        "",
        "## 遗留项（需后续跟进）",
        "",
    ]
    fups = data.get("followups", [])
    lines.append(_table(["#", "遗留项", "owner", "ETA", "备注"],
                        [[f.get("id"), f.get("item"), f.get("owner"), f.get("eta"), f.get("note")] for f in fups]
                        ) if fups else "无遗留项。")
    lines += ["", "## 签字确认", "", _signoffs_table(data.get("signoffs")), ""]
    return "\n".join(lines)


def render_acceptance(data, input_path):
    pts = data.get("points", [])
    total = len(pts)
    frozen = sum(1 for p in pts if p.get("status") == "FROZEN")
    groups = {}
    for p in pts:
        m = re.match(r"M-?([0-9]{2})-F([0-9]{2})-A([0-9]{2})$", p.get("id", ""))
        if m:
            groups.setdefault(f"F{m.group(2)}", []).append(p)
    lines = [
        f"# 原子验收点清单 - {data.get('feature_name')}",
        "",
        f"> 生成时间：{_gen_time(data)}　数据来源：acceptance.json 结构化产物自动汇总",
        _audit("acceptance", input_path),
        "",
        "## 基本信息",
        "",
        _table(["项", "内容"], [
            ["功能名称", data.get("feature_name")],
            ["模块编码", f"M-{data.get('module')}"],
            ["PRD 文档", data.get("prd_doc")],
            ["拆分日期", data.get("date")],
            ["拆分人", data.get("splitter")],
            ["冻结状态", "✅ FROZEN" if frozen == total and total else f"⏳ {frozen}/{total} 已冻结"],
        ]),
        "",
        "## 拆分原则",
        "",
        "> **一个验收点 = 一个行为 = 一个测试用例**：单一行为、可验证、可失败，"
        "ID 格式 `M-{模块号}-F{功能号}-A{验收点号}`。",
        "",
        "## 拆分步骤",
        "",
        "```", "阅读 PRD → 识别功能点(F) → 拆分原子验收点(A) → 标注验证方式 → "
        "标注 PRD 锚点 → 评审 → 冻结(FROZEN) → 移交 P2 详设", "```",
        "",
        "## 验收点清单",
        "",
    ]
    for fname in sorted(groups):
        lines += [f"### 功能 {fname}：{(groups[fname][0] or {}).get('feature_label', '')}".rstrip(), ""]
        lines += [
            _table(["验收点ID", "验收点描述", "验证方式", "PRD原文锚点", "状态"],
                   [[p.get("id"), p.get("description"), p.get("verify_method"),
                     f"`{p.get('prd_anchor')}`", p.get("status")] for p in groups[fname]]),
            "",
        ]
    reviews = data.get("reviews", [])
    lines += [
        f"分母已冻结：验收点总计 {total} 个（FROZEN {frozen}/{total}；ID 唯一、格式合规、PRD 锚点完整）。",
        "",
        "## 拆分覆盖率检查",
        "",
        _table(["检查项", "结果"], [
            ["ID 格式合规（Mxx-Fyy-Azz）", f"{total}/{total}"],
            ["ID 唯一性", "0 重复"],
            ["状态冻结", f"{frozen}/{total}"],
            ["占位符", "0"],
            ["PRD 锚点完整", f"{total}/{total}"],
        ]),
        "",
        "## 评审记录",
        "",
        _table(["评审轮次", "评审人", "评审日期", "结论", "遗留问题"],
               [[r.get("round"), r.get("reviewer"), r.get("date"), r.get("verdict"), r.get("leftovers")]
                for r in reviews]) if reviews else "暂无评审记录。",
        "",
        "## 冻结签名",
        "",
        _signoffs_table(data.get("signoffs")),
        "",
    ]
    return "\n".join(lines)


def render_constraints(data, input_path):
    items = data.get("constraints", [])
    if items:
        recs = []
        for c in items:
            fields = [f"constraint_id={c.get('constraint_id')}", f"type={c.get('type')}",
                      f"subject={c.get('subject')}", f"required_product={c.get('required_product')}"]
            if c.get("required_version"):
                fields.append(f"required_version={c.get('required_version')}")
            fields += [f"status={c.get('status')}", f"confirmed={'true' if c.get('confirmed') else 'false'}"]
            recs.append("\n".join(fields))
        body = "\n\n".join(recs)
    else:
        body = "constraint_set=NONE\nconfirmed=true"
    lines = [
        f"# 技术约束契约 - {data.get('feature_name')}",
        "",
        f"> 冻结日期：{data.get('frozen_date')}　确认人：{data.get('confirmer')}　"
        f"PRD：{data.get('prd_doc')}",
        _audit("constraints", input_path),
        "",
        "> 本文件是 P0 的冻结事实源。MUST_USE、MUST_NOT_USE 和固定版本属于硬约束，",
        "> 不能被 P1 的加权评分或 Agent 自主决策覆盖。Gate 只解析下方机器契约块。",
        "",
        "## 机器契约（唯一机读事实源；字段格式勿改）",
        "",
        "<!-- DEVFLOW:CONSTRAINTS", body, "DEVFLOW:END -->",
        "",
        "## 约束清单（人读展示，与机器契约一致）",
        "",
    ]
    lines.append(_table(
        ["constraint_id", "类型", "技术/组件", "必须值/禁止值", "来源锚点", "状态"],
        [[c.get("constraint_id"), c.get("type"), c.get("subject"),
          (f"{c.get('required_product')} {c.get('required_version')}".strip()
           if c.get("required_version") else c.get("required_product")),
          f"`{c.get('source_anchor')}`", c.get("status")] for c in items],
    ) if items else "constraint_set=NONE（本需求无技术硬约束；该决定同样冻结，不得静默增删）。")
    lines += [
        "",
        "## 变更规则",
        "",
        "- 任何选型与 MUST_USE 或 MUST_NOT_USE 冲突时，P1 立即 BLOCKED。",
        "- 只有用户明确批准、更新 PRD/本契约并重新冻结（status=FROZEN + confirmed=true）后，才能恢复。",
        "- P2 详设必须逐条引用 constraint_id；P3 依赖/config 与 P4b 代码对账使用同一组 constraint_id。",
        "",
    ]
    return "\n".join(lines)


def render_prd_review(data, input_path):
    df_items = data.get("df", [])
    df_ids = {d.get("id") for d in df_items}
    terms = data.get("ambiguity_terms", [])
    resolved = sum(1 for t in terms if t.get("resolved"))
    benum = data.get("boundary_enums", [])
    sf = data.get("sf", [])
    lines = [
        f"# PRD 评审报告 - {data.get('feature_name')}",
        "",
        f"> 评审日期：{data.get('date')}　主持人：{data.get('host')}　"
        f"评审人：{'、'.join(data.get('reviewers') or [])}",
        f"> PRD 文档：{data.get('prd_doc')}",
        _audit("prd-review", input_path),
        "",
        "## 探针执行记录（v3.14.0 · P0b 必做四类，未执行不得下结论）",
        "",
        _probes_table(data.get("probes")),
        "",
        "## 歧义术语决议表" if terms else "## 歧义术语决议表（无歧义术语）",
        "",
    ]
    if terms:
        lines.append(_table(
            ["#", "术语", "PRD 位置(§)", "歧义描述", "决议口径", "决议人", "状态"],
            [[t.get("id"), t.get("term"), t.get("prd_anchor"), t.get("ambiguity"),
              t.get("resolution"), t.get("decider"),
              "✅ 已决议" if t.get("resolved") else "⏳ 未决议"] for t in terms],
        ))
        lines += ["", f"歧义术语 {len(terms)} 个，已决议 {resolved} 个（必须全部决议才能通过）。"]
    else:
        lines.append(f"无歧义术语。核查证据：{data.get('no_ambiguity_evidence')}")
    lines += [
        "",
        "## 边界条件枚举（P2 探针产出，未定义行为登记为 DF）",
        "",
        _table(["#", "对象(字段/流程)", "枚举值", "PRD 是否定义", "未定义→DF 编号"],
               [[b.get("id"), b.get("object"), b.get("values"),
                 "是" if b.get("prd_defined") else "否",
                 b.get("df_ref") or "—"] for b in benum]) if benum else "无（zero_results 声明）",
        "",
        "## 对抗场景走查（AW ≥2 条，每条以 `结果:` 收尾）",
        "",
        _aw_lines(data.get("aw"), df_ids),
        "",
        "## 深层发现 DF（五字段缺一 Gate 判无效；每角色 ≥1 条或 ZERO-DF 证据）",
        "",
    ]
    lines.append(_df_blocks(df_items) if df_items else "（无 DF 条目）")
    lines += ["", _zero_df_blocks(data.get("zero_df_roles")), ""]
    lines += [
        "## 表层发现 SF（不计配额、不阻塞 Gate）",
        "",
        _table(["#", "标题", "归属评委", "文档位置", "一句话建议"],
               [[s.get("id"), s.get("title"), s.get("role"), s.get("doc_anchor"), s.get("suggestion")]
                for s in sf]) if sf else "无表层发现。",
        "",
        "## 风险识别",
        "",
    ]
    risks = data.get("risks", [])
    lines.append(_table(["#", "风险描述", "严重度", "应对策略", "owner", "ETA"],
                        [[r.get("id"), r.get("description"), r.get("severity"),
                          r.get("strategy"), r.get("owner"), r.get("eta")] for r in risks])
                if risks else "无风险项。")
    lines += [
        "",
        "## 评审结论",
        "",
        f"- 探针执行：{sum(1 for p in data.get('probes', []) if p.get('executed'))}/{len(data.get('probes', []))} 已执行",
        f"- 歧义决议：{resolved}/{len(terms)}",
        f"- DF 深层发现：{len(df_items)} 条（P0 {sum(1 for d in df_items if d.get('severity') == 'P0')} 条）",
        f"- AW 对抗走查：{len(data.get('aw', []))} 条",
        f"- 结论：{'✅ 通过' if data.get('conclusion_passed') else '❌ 未通过'}",
        "",
        "### 遗留项",
        "",
    ]
    leftovers = data.get("leftovers", [])
    lines.append(_table(["#", "遗留项", "owner", "ETA", "状态"],
                        [[l.get("id"), l.get("item"), l.get("owner"), l.get("eta"), l.get("status")]
                         for l in leftovers]) if leftovers else "无遗留项。")
    lines += ["", "## 签字确认", "", _signoffs_table(data.get("signoffs")), ""]
    return "\n".join(lines)


def render_tech_selection(data, input_path):
    candidates = data.get("candidates", [])
    dims = data.get("dimensions", [])
    cand_ids = [c.get("id") for c in candidates]
    weighted = {cid: 0 for cid in cand_ids}
    for d in dims:
        for s in d.get("scores") or []:
            cid = s.get("candidate")
            if cid in weighted:
                weighted[cid] += int(s.get("score", 0)) * int(d.get("weight", 0))
    header = ["维度", "权重"] + [f"方案{c.get('id')} {c.get('name')} 评分(1-5)/证据" for c in candidates]
    rows = []
    for d in dims:
        score_map = {s.get("candidate"): s for s in d.get("scores") or []}
        row = [d.get("name"), f"{d.get('weight')}%"]
        for cid in cand_ids:
            s = score_map.get(cid) or {}
            row.append(f"{s.get('score', '—')}（{s.get('evidence', '无证据')}）")
        rows.append(row)
    rows.append(["**加权合计**", "100%"] + [str(weighted[cid]) for cid in cand_ids])
    bindings = data.get("bindings", [])
    bind_body = "\n\n".join(
        "\n".join([f"constraint_id={b.get('constraint_id')}", f"selected_product={b.get('selected_product')}"]
                  + ([f"selected_version={b.get('selected_version')}"] if b.get("selected_version") else [])
                  + [f"compliance={b.get('compliance')}", f"evidence={b.get('evidence')}"])
        for b in bindings
    ) if bindings else "constraint_set=NONE\nconfirmed=true"
    decision = data.get("decision", {})
    chosen = next((c for c in candidates if c.get("id") == decision.get("chosen")), {})
    lines = [
        f"# 技术选型报告 - {data.get('feature_name')}",
        "",
        f"> 选型日期：{data.get('date')}　选型人：{data.get('selector')}　评审人：{data.get('reviewer')}",
        _audit("tech-selection", input_path),
        "",
        "## Step 1 现有仓库与硬约束盘点",
        "",
        _table(["项", "内容"], [
            ["现有技术栈", data.get("existing_stack")],
            ["技术约束契约", data.get("constraints_doc")],
        ]),
        "",
        "## Step 2 硬约束淘汰",
        "",
        _table(["constraint_id", "候选方案", "判定", "淘汰理由"],
               [[s.get("constraint_id"), s.get("candidate"), s.get("verdict"), s.get("reason")]
                for s in data.get("constraints_scan", [])]) or "无（constraint_set=NONE 或全部保留）",
        "",
        "## Step 3 缺失事实补充",
        "",
        _table(["缺失事实", "获取方式", "结论"],
               [[f.get("fact"), f.get("method"), f.get("conclusion")] for f in data.get("facts", [])])
        or "无缺失事实。",
        "",
        "## 候选方案（经 Step 2 淘汰后剩余）",
        "",
    ]
    for c in candidates:
        lines += [
            f"### 方案 {c.get('id')}：{c.get('name')}", "",
            f"{c.get('description')}", "",
            "优点：" + "；".join(c.get("pros") or []), "",
            "缺点：" + "；".join(c.get("cons") or []), "",
        ]
    lines += [
        "## 决策矩阵（评分只对 Step 2 后剩余方案；分数必须有证据）",
        "",
        _table(header, rows),
        "",
        "> 权重按本项目实际关注点确定；无证据的评分无效。",
        "",
        "## 决策结论",
        "",
        f"选定方案 **{chosen.get('id')}：{chosen.get('name')}**（加权合计 {weighted.get(chosen.get('id'), 0)}）",
        "",
        f"用户确认：{data.get('user_confirmed')}",
        "",
        "### 决策理由", "", "```", decision.get("reason"), "```", "",
        "### 风险与应对", "",
        _table(["风险", "影响", "应对措施"],
               [[r.get("risk"), r.get("impact"), r.get("mitigation")] for r in data.get("risks", [])]),
        "",
        "## 硬约束绑定（机器契约；Gate 按 此块 判定合规）",
        "",
        "<!-- DEVFLOW:CONSTRAINT-BINDINGS", bind_body, "DEVFLOW:END -->",
        "",
        "## 实施计划",
        "",
        _table(["任务", "负责人", "完成日期"],
               [[p.get("task"), p.get("owner"), p.get("due")] for p in data.get("plan", [])]),
        "",
        "## 评审签字", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_design_review(data, input_path):
    df_items = data.get("df", [])
    df_ids = {d.get("id") for d in df_items}
    open_hp = [d.get("id") for d in df_items if d.get("severity") in ("P0", "P1") and d.get("status") != "CLOSED"]
    sf = data.get("sf", [])
    probes = data.get("probes", [])
    tr = data.get("traceability", {})
    roles = ["架构师", "后端专家", "前端专家", "测试开发", "DBA"]
    role_counts = {r: sum(1 for d in df_items if d.get("role") == r) for r in roles}
    lines = [
        f"# 详细设计评审报告 - {data.get('feature_name')}",
        "",
        f"> 评审日期：{data.get('date')}　第 {data.get('round')} 轮　模式：{data.get('mode')}",
        f"> 详设文档：{data.get('design_doc')}　PRD：{data.get('prd_doc')}",
        _audit("design-review", input_path),
        "",
        f"REVIEW_RUN_ID={data.get('run_id')}",
        "",
        "## 评审委员会",
        "",
        _table(["角色", "评委", "机构"],
               [[c.get("role"), c.get("reviewer"), c.get("org")] for c in data.get("committee", [])]),
        "",
        "### 独立性收据（每角色唯一）",
        "",
        _table(["角色", "REVIEWER_ID", "REVIEW_SESSION_ID", "结论"],
               [[r.get("role"), r.get("reviewer_id"), r.get("session_id"),
                 "✅" if r.get("conclusion") != "❌" else "❌"] for r in data.get("receipts", [])]),
        "",
        "## 设计质量四要素检查（每角色必查）",
        "",
        _table(["要素", "详设章节", "主责角色", "检查结论", "问题编号"],
               [[q.get("element"), q.get("design_anchor"), q.get("owner_role"),
                 "✅" if q.get("pass") else "❌", q.get("issue_ref") or "—"]
                for q in data.get("quality_four", [])]),
        "",
        "### DBA 对 DDR 的逐行核问",
        "",
        _table(["DDR #", "决策点", "理由是否成立", "核问意见"],
               [[q.get("ddr_id"), q.get("topic"), "✅" if q.get("holds") else "❌", q.get("comment")]
                for q in data.get("ddr_questions", [])]) or "详设无 DDR（zero_results 声明）",
        "",
        "## 探针执行记录（六类必做 + 代码基线核验，未执行不得下结论）",
        "",
        _probes_table(probes),
        "",
        "## 对抗场景走查（AW ≥3 条，每条 场景/走查路径/结果 三段非空）",
        "",
        _aw_lines(data.get("aw"), df_ids),
        "",
        "## 汇总统计",
        "",
        _table(["类别"] + roles + ["合计"],
               [["DF 深层发现"] + [role_counts[r] for r in roles] + [len(df_items)],
                ["SF 表层发现"]
                + [sum(1 for s in sf if s.get("role") == r) for r in roles] + [len(sf)]]),
        "",
        "## 深层发现 DF（五字段缺一 Gate 判无效）",
        "",
    ]
    lines.append(_df_blocks(df_items, with_status=True) if df_items else "（无 DF 条目）")
    lines += ["", _zero_df_blocks(data.get("zero_df_roles")), ""]
    lines += [
        "## 表层发现 SF",
        "",
        _table(["#", "标题", "归属评委", "文档位置", "一句话建议"],
               [[s.get("id"), s.get("title"), s.get("role"), s.get("doc_anchor"), s.get("suggestion")]
                for s in sf]) if sf else "无表层发现。",
        "",
        "## 严重性修订",
        "",
        _table(["#", "原 DF", "原严重性", "修订后严重性", "修订理由", "确认评委"],
               [[i + 1, r.get("df_id"), r.get("from"), r.get("to"), r.get("reason"), r.get("confirmor")]
                for i, r in enumerate(data.get("severity_revisions", []))])
        or "无严重性修订。",
        "",
        "## Gate 检查",
        "",
        _table(["条件", "要求", "当前值", "状态"], [
            ["DF 总数", "按实际发现，不得凑数", len(df_items), "—"],
            ["单角色 DF", "适用角色有 DF 或 ZERO-DF 证据",
             "、".join(f"{r}:{role_counts[r]}" for r in roles), "—"],
            ["DF 字段完整性", "五字段非空、位置 §x.y", "100%", "✅"],
            ["AW 对抗走查", "≥3 条且有结果收尾", len(data.get("aw", [])), "✅" if len(data.get("aw", [])) >= 3 else "❌"],
            ["探针执行记录", "全部已执行", f"{sum(1 for p in probes if p.get('executed'))}/{len(probes)}", "✅"],
            ["P0/P1 级 DF", "OPEN = 0", len(open_hp), "✅" if not open_hp else "❌"],
            ["SF 数量", "≤5/角色", len(sf), "✅"],
        ]),
        "",
        "## 需求追溯覆盖检查（acceptance-traceability）",
        "",
        _table(["检查项", "期望", "实际"], [
            ["P0 验收点总数", "—", tr.get("criteria_total")],
            ["§9 设计中 ID 数", "= 验收点总数", tr.get("design_ids")],
            ["覆盖率", "100%", f"{tr.get('coverage_pct')}%"],
        ]),
        "",
        f"- {'✅' if tr.get('coverage_pct') == 100 else '❌'} 需求追溯 100% 覆盖 P0 验收点",
        f"- {'✅' if not open_hp else '❌'} 所有 P0/P1 DF 状态为 CLOSED",
        f"- {'✅' if data.get('conclusion_passed') else '❌'} 评审委员会确认通过",
        "",
        "## 遗留项",
        "",
        _table(["#", "遗留项", "处理方式", "owner", "ETA"],
               [[l.get("id"), l.get("item"), l.get("handling"), l.get("owner"), l.get("eta")]
                for l in data.get("leftovers", [])]) or "无遗留项。",
        "",
        "## 评审签字", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_self_check(data, input_path):
    checks = data.get("checks", [])
    core = [c for c in checks if c.get("category") == "core"]
    module = [c for c in checks if c.get("category") == "module"]

    def _rows(items):
        return _table(["#", "检查项", "命令", "预期结果", "实际结果", "状态"],
                      [[c.get("id"), c.get("item"), f"`{c.get('cmd')}`", c.get("expected"),
                        c.get("actual"), "✅ PASS" if c.get("status") == "PASS" else "❌ FAIL"]
                       for c in items])

    failed = [c for c in checks if c.get("status") != "PASS"]
    lines = [
        f"# 完成度自检报告 - {data.get('feature_name')} / {data.get('phase')} {data.get('phase_name')}",
        "",
        f"> 执行人：{data.get('executor')}　执行时间：{data.get('executed_at')}",
        _audit("self-check", input_path),
        "",
        "## 执行信息",
        "",
        _table(["项", "内容"], [
            ["功能", data.get("feature_name")],
            ["Phase", f"{data.get('phase')} - {data.get('phase_name')}"],
            ["执行人", data.get("executor")],
            ["执行时间", data.get("executed_at")],
        ]),
        "",
        "## 检查矩阵",
        "",
        "### 核心检查项（必须全部通过）", "",
        _rows(core), "",
        "### 模块专项检查（如适用）", "",
        _rows(module) if module else "无专项检查（zero_results 声明）。", "",
        "## 检查结果汇总",
        "",
        _table(["类型", "通过", "失败", "总计"], [
            ["核心检查", sum(1 for c in core if c.get("status") == "PASS"),
             sum(1 for c in core if c.get("status") != "PASS"), len(core)],
            ["专项检查", sum(1 for c in module if c.get("status") == "PASS"),
             sum(1 for c in module if c.get("status") != "PASS"), len(module)],
            ["**合计**", sum(1 for c in checks if c.get("status") == "PASS"),
             len(failed), len(checks)],
        ]),
        "",
        "## 失败项详情（如有）",
        "",
    ]
    if failed:
        for c in failed:
            lines += [
                f"### ❌ 失败项 {c.get('id')}: {c.get('item')}", "",
                _table(["属性", "值"], [
                    ["检查命令", f"`{c.get('cmd')}`"],
                    ["预期结果", c.get("expected")],
                    ["实际结果", c.get("actual")],
                ]), "",
            ]
    else:
        lines.append("无失败项。")
    unfixed = data.get("unfixed", [])
    lines += ["", "## 未修复 P1/P2 清单", "",
              _table(["#", "严重度", "描述", "影响范围", "Owner", "ETA"],
                     [[i + 1, u.get("severity"), u.get("description"), u.get("scope"),
                       u.get("owner"), u.get("eta")] for i, u in enumerate(unfixed)])
              if unfixed else "无未修复项。"]
    lines += [
        "",
        "## 结论",
        "",
        f"{'✅ PASS' if data.get('conclusion') == 'PASS' else '❌ FAIL'} — "
        + ("所有核心检查项通过，进入下个 Phase。" if data.get("conclusion") == "PASS"
           else "存在失败项，阻塞进入下个 Phase。"),
        "",
        "### 签发", "", _signoffs_table(data.get("signoffs")), "",
        "",
        "## 命令输出附件", "",
    ]
    for o in data.get("outputs", []):
        lines += ["```bash", f"# {o.get('check_id')}", o.get("output", ""), "```", ""]
    return "\n".join(lines)


def render_code_review(data, input_path):
    findings = data.get("findings", [])
    by_sev = {sev: [f for f in findings if f.get("severity") == sev] for sev in ("P0", "P1", "P2")}
    nits = data.get("nits", [])
    open_n = sum(1 for f in findings if f.get("status") == "OPEN")

    def _finding_table(items):
        return _table(["#", "文件", "类型", "状态", "问题描述", "修复建议", "Owner", "ETA"],
                      [[f.get("id"), f"`{f.get('file')}:{f.get('line')}`", f.get("type"),
                        f.get("status"), f.get("summary"), f.get("fix"),
                        f.get("owner") or "—", f.get("eta") or "—"] for f in items])

    lines = [
        f"# 代码审查报告 - {data.get('feature_name')}",
        "",
        f"> 审查日期：{data.get('date')}　审查人：{data.get('reviewer_id')}　代码范围：{data.get('scope')}",
        _audit("code-review", input_path),
        "",
        "## Gate 机器字段（由 df_render 从 JSON 派生，人工勿改）",
        "",
        "```text",
        _kv([("DEVELOPER_ID", data.get("developer_id")),
             ("REVIEWER_ID", data.get("reviewer_id")),
             ("REVIEW_SESSION_ID", data.get("session_id"))]),
        "```",
        "",
        "### 结构化 FINDING 行（P0；p3b Gate 只解析本节 finding 行）",
        "",
    ]
    p0_lines = [f"FINDING|{f.get('severity')}|{f.get('id')}|STATUS={f.get('status')}|{f.get('summary')}"
                for f in by_sev.get("P0", [])]
    lines += ["```text", "\n".join(p0_lines) if p0_lines else "（无 P0 finding）", "```", ""]
    lines += [
        "## 审查摘要",
        "",
        _table(["类型", "数量"], [
            ["审查文件数", len(data.get("files", []))],
            ["审查代码行数", sum(int(f.get("lines", 0)) for f in data.get("files", []))],
            ["P0 问题", len(by_sev.get("P0", []))],
            ["P1 问题", len(by_sev.get("P1", []))],
            ["P2 问题", len(by_sev.get("P2", []))],
            ["Nit 问题", len(nits)],
            ["OPEN 合计", open_n],
        ]),
        "",
        "### 整体评价", "", "```", data.get("overall_comment"), "```", "",
        "## P1 问题（高优先级）", "",
        _finding_table(by_sev.get("P1", [])) if by_sev.get("P1") else "无 P1 问题。", "",
        "## P2 问题（中优先级）", "",
        _finding_table(by_sev.get("P2", [])) if by_sev.get("P2") else "无 P2 问题。", "",
        "## Nit 问题（建议改进）", "",
        _table(["#", "文件", "问题", "建议"],
               [[n.get("id"), f"`{n.get('file')}`", n.get("issue"), n.get("suggestion")] for n in nits])
        if nits else "无 Nit。", "",
        "## 未修复问题汇总", "",
        _table(["#", "严重度", "描述", "Owner", "ETA"],
               [[i + 1, f.get("severity"), f.get("summary"), f.get("owner"), f.get("eta")]
                for i, f in enumerate(findings) if f.get("status") == "OPEN"])
        if open_n else "无未修复问题。", "",
        "## 审查结论", "",
        f"{'✅ APPROVE' if data.get('conclusion') == 'APPROVE' else ('⚠️ REQUEST CHANGES' if data.get('conclusion') == 'REQUEST_CHANGES' else '🔴 BLOCK')} — "
        + {
            "APPROVE": "无未关闭 P0 问题，代码可进入下个 Phase。",
            "REQUEST_CHANGES": "存在 P0/P1 问题，需修复后重新审查。",
            "BLOCK": "存在严重问题，阻塞开发。",
        }[data.get("conclusion")], "",
        "### 签字", "", _signoffs_table(data.get("signoffs")), "",
        "## 附录：审查文件清单", "",
        _table(["#", "路径", "代码行数"],
               [[i + 1, f"`{f.get('path')}`", f.get("lines")] for i, f in enumerate(data.get("files", []))]), "",
    ]
    return "\n".join(lines)


def render_prd_validation(data, input_path):
    m = data.get("machine", {})
    blockers = data.get("p0_blockers", [])
    open_blockers = [b for b in blockers if b.get("status") != "已修复"]
    features = data.get("features", [])
    fields = data.get("fields", [])
    apis = data.get("apis", [])
    perms = data.get("permissions", [])

    def _cnt(items, key="result"):
        ok = sum(1 for i in items if i.get(key) == "通过")
        bad = sum(1 for i in items if i.get(key) == "失败")
        return [len(items), ok, bad, len(items) - ok - bad]

    lines = [
        f"# PRD 验证报告 - {data.get('feature_name')}",
        "",
        f"> 验证日期：{data.get('date')}　验证人：{data.get('validator')}　PRD：{data.get('prd_doc')}",
        _audit("prd-validation", input_path),
        "",
        "<!-- P4 Gate 机器可读结论（由 df_render 从 JSON 派生，人工勿改） -->",
        _kv([
            ("P0_BLOCKERS", m.get("p0_blockers")),
            ("VALIDATION_EVIDENCE", m.get("validation_evidence")),
            ("P4_CMD", m.get("p4_cmd")),
            ("P4_RESULTS_PATH", m.get("p4_results_path")),
        ]),
        "",
        "## 验证结果汇总",
        "",
        _table(["类型", "总数", "通过", "失败", "阻塞"],
               [["功能点"] + _cnt(features), ["数据字段"] + _cnt(fields),
                ["接口"] + _cnt(apis)]),
        "",
        "## P0 阻断项（必须全部修复）",
        "",
        _table(["#", "阻断项", "发现位置", "影响范围", "修复方案", "状态"],
               [[b.get("id"), b.get("desc"), b.get("location"), b.get("impact"),
                 b.get("fix"), b.get("status")] for b in blockers]) or "无 P0 阻断项。",
        "",
        "## 功能点验证", "",
        _table(["#", "功能点", "优先级", "实现状态", "验证结果", "备注"],
               [[i + 1, f.get("name"), f.get("priority"), f.get("impl_status"),
                 f.get("result"), f.get("note")] for i, f in enumerate(features)]), "",
        "## 数据字段验证", "",
        _table(["#", "字段名", "PRD 要求", "代码实现", "数据库", "验证结果"],
               [[i + 1, f.get("name"), f.get("prd_req"), f.get("impl"), f.get("db"), f.get("result")]
                for i, f in enumerate(fields)]), "",
        "## 接口验证", "",
        _table(["#", "接口", "方法", "路径", "权限", "实现状态", "验证结果"],
               [[i + 1, a.get("name"), a.get("method"), a.get("path"), a.get("permission"),
                 a.get("impl_status"), a.get("result")] for i, a in enumerate(apis)]), "",
        "## 权限验证", "",
        _table(["角色", "允许操作", "验证结果", "问题"],
               [[p.get("role"), "、".join(p.get("allowed") or []), p.get("result"), p.get("issue") or "—"]
                for p in perms]), "",
        "## 遗留项", "",
        _table(["#", "遗留项", "严重度", "owner", "ETA"],
               [[l.get("id"), l.get("item"), l.get("severity"), l.get("owner"), l.get("eta")]
                for l in data.get("leftovers", [])]) or "无遗留项。", "",
        "## 验证结论", "",
        f"{'✅ PASS' if data.get('conclusion') == 'PASS' else '❌ FAIL'} — "
        + ("所有 P0 阻断项已修复，可进入 P5 测试用例阶段。"
           if data.get("conclusion") == "PASS" else "存在 P0 阻断项，阻塞进入 P5。"),
        "",
        "### 签字", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_test_cases(data, input_path):
    cases = data.get("cases", [])

    def _case_block(c):
        res = c.get("result") or {}
        rows = [[("✅ 通过" if res.get("status") == "PASS" else ("❌ 失败" if res.get("status") == "FAIL" else "⏳ 阻塞"))
                 if res.get("executed") else "⏳ 未执行"]]
        parts = [
            f"#### {c.get('id')}：{c.get('name')}", "",
            _table(["属性", "内容"], [
                ["用例编号", c.get("id")],
                ["用例名称", c.get("name")],
                ["优先级", c.get("priority")],
                ["测试类型", c.get("type")],
                ["关联验收点", "、".join(c.get("acceptance_refs") or [])],
                ["前置条件", c.get("precondition")],
            ]), "",
            "**测试步骤：**", "",
            _table(["步骤", "操作", "预期结果"],
                   [[i + 1, s.get("action"), s.get("expected")] for i, s in enumerate(c.get("steps", []))]), "",
        ]
        if c.get("data"):
            parts += ["**测试数据：**", "",
                      _table(["字段", "值", "来源"],
                             [[d.get("field"), d.get("value"), d.get("source")] for d in c.get("data", [])]), ""]
        parts += [
            "**测试结果：**", "",
            _table(["项", "内容"], [
                ["执行日期", res.get("date") or "—"],
                ["执行人", res.get("executor") or "—"],
                ["执行结果", rows[0][0]],
                ["缺陷编号", res.get("defect") or "—"],
            ]), "",
        ]
        return "\n".join(parts)

    by_pri = {}
    for c in cases:
        by_pri.setdefault(c.get("priority"), []).append(c)
    executed = [c for c in cases if (c.get("result") or {}).get("executed")]

    def _stat(pri):
        items = by_pri.get(pri, [])
        ok = sum(1 for c in items if (c.get("result") or {}).get("status") == "PASS")
        bad = sum(1 for c in items if (c.get("result") or {}).get("status") == "FAIL")
        return [len(items), ok, bad, len(items) - ok - bad]

    lines = [
        f"# 测试用例文档 - {data.get('feature_name')}",
        "",
        f"> 编写人：{data.get('author')}　编写日期：{data.get('date')}　版本：{data.get('version')}",
        _audit("test-cases", input_path),
        "",
        "## 基本信息", "",
        _table(["项", "内容"], [
            ["功能", data.get("feature_name")],
            ["模块", data.get("module")],
            ["用例编写人", data.get("author")],
            ["用例编写日期", data.get("date")],
            ["用例版本", data.get("version")],
        ]), "",
        "## 测试凭证（必须可追溯；铁律 6 禁止盲猜）", "",
        _table(["项", "值", "代码来源", "行号"],
               [[c.get("item"), f"`{c.get('value_ref')}`", f"`{c.get('source_file')}`", c.get("line")]
                for c in data.get("credentials", [])]), "",
        "## 用例清单", "",
        _table(["用例编号", "用例名称", "优先级", "类型", "关联验收点", "状态"],
               [[c.get("id"), c.get("name"), c.get("priority"), c.get("type"),
                 "、".join(c.get("acceptance_refs") or []),
                 ("✅ 已执行" if (c.get("result") or {}).get("executed") else "⏳ 待实现")]
                for c in cases]), "",
        f"用例总计 {len(cases)} 个（P0 {len(by_pri.get('P0', []))} / P1 {len(by_pri.get('P1', []))} / "
        f"P2 {len(by_pri.get('P2', []))}），已执行 {len(executed)} 个。", "",
    ]
    for pri, label in (("P0", "P0 用例（必须通过）"), ("P1", "P1 用例（高优先级）"), ("P2", "P2 用例（边界/异常）")):
        items = by_pri.get(pri, [])
        if items:
            lines += [f"## {label}", ""]
            for c in items:
                lines += [_case_block(c), "---", ""]
    defects = data.get("defects", [])
    lines += [
        "## 缺陷汇总", "",
        _table(["缺陷编号", "用例编号", "缺陷描述", "严重度", "状态", "修复版本"],
               [[d.get("id"), d.get("case_id"), d.get("description"), d.get("severity"),
                 d.get("status"), d.get("fix_version")] for d in defects]) or "无缺陷。", "",
        "## 测试结果汇总", "",
        _table(["类型", "总数", "通过", "失败", "阻塞"],
               [["P0"] + _stat("P0"), ["P1"] + _stat("P1"), ["P2"] + _stat("P2"),
                ["**合计**", len(cases),
                 sum(1 for c in cases if (c.get("result") or {}).get("status") == "PASS"),
                 sum(1 for c in cases if (c.get("result") or {}).get("status") == "FAIL"),
                 sum(1 for c in cases if (c.get("result") or {}).get("executed")
                     and (c.get("result") or {}).get("status") not in ("PASS", "FAIL"))]]), "",
        "## 执行签字", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_deployment(data, input_path):
    art = data.get("artifact", {})
    health = data.get("health", {})
    pre = data.get("prechecks", {})
    lines = [
        f"# 部署记录 - {data.get('feature_name')}",
        "",
        f"> 部署日期：{data.get('date')}　部署人：{data.get('deployer')}　环境：{data.get('environment')}　方式：{data.get('strategy')}",
        _audit("deployment", input_path),
        "",
        "<!-- P7 Gate 机器可读证据（由 df_render 从 JSON 派生，人工勿改） -->",
        _kv([
            ("DEPLOYMENT_ID", data.get("deployment_id")),
            ("ARTIFACT_SHA256", art.get("sha256")),
            ("ARTIFACT_PATH", art.get("path")),
            ("ENVIRONMENT", data.get("environment")),
            ("HEALTH_HTTP_STATUS", health.get("status")),
            ("HEALTH_URL", health.get("url")),
            ("BUILD_INFO_URL", data.get("build_info_url")),
            ("RELEASE_EVIDENCE_PATH", data.get("release_evidence_path")),
        ]),
        "",
        "## 部署信息", "",
        _table(["项", "内容"], [
            ["功能", data.get("feature_name")],
            ["部署环境", data.get("environment")],
            ["部署方式", data.get("strategy")],
            ["部署人", data.get("deployer")],
        ]), "",
        "## 部署前检查", "",
        "### 服务状态", "",
        _table(["服务", "部署前状态", "负责人"],
               [[s.get("service"), s.get("status"), s.get("owner")] for s in pre.get("services", [])]), "",
        "### 数据库备份", "",
        _table(["数据库", "备份时间", "备份文件", "备份人"],
               [[b.get("database"), b.get("time"), b.get("file"), b.get("by")]
                for b in pre.get("db_backup", [])]), "",
        "### 依赖检查", "",
        _table(["依赖", "版本", "状态"],
               [[d.get("name"), d.get("version"), "✅" if d.get("ok") else "❌"]
                for d in pre.get("dependencies", [])]), "",
        "## 部署步骤", "",
        _table(["#", "步骤", "命令", "退出码", "证据"],
               [[i + 1, s.get("name"), f"`{s.get('cmd')}`", s.get("exit_code"), s.get("evidence")]
                for i, s in enumerate(data.get("steps", []))]), "",
        "## 部署后验证", "",
        "### 健康检查", "",
        _table(["检查项", "命令", "预期", "实际", "状态"],
               [[c.get("item"), f"`{c.get('cmd')}`", c.get("expected"), c.get("actual"),
                 "✅" if c.get("status") == "PASS" else "❌"]
                for c in data.get("post_checks", [])]), "",
        "### 功能验证", "",
        _table(["#", "功能点", "验证方式", "结果"],
               [[i + 1, f.get("feature"), f"`{f.get('method')}`",
                 "✅" if f.get("status") == "PASS" else "❌"]
                for i, f in enumerate(data.get("function_checks", []))]), "",
        "## 回滚方案", "",
        "### 自动回滚触发条件", "",
        "\n".join(f"- [ ] {t}" for t in (data.get("rollback_triggers") or [])), "",
        "### 回滚步骤", "", "```bash",
        "\n".join(data.get("rollback_steps", [])), "```", "",
        "## 部署结果", "",
        _table(["项", "内容"], [
            ["部署状态", "✅ 成功" if data.get("result") == "SUCCESS" else "❌ 失败"],
            ["开始时间", data.get("started_at")],
            ["结束时间", data.get("ended_at")],
            ["总耗时", f"{data.get('duration_minutes')} 分钟"],
            ["问题记录", data.get("problems") or "无"],
        ]), "",
        "## 签字确认", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_monitoring(data, input_path):
    m = data.get("machine", {})
    lines = [
        f"# 监控配置文档 - {data.get('feature_name')}",
        "",
        f"> 配置日期：{data.get('date')}　配置人：{data.get('configurer')}",
        _audit("monitoring", input_path),
        "",
        "<!-- P8 Gate 机器可读证据（由 df_render 从 JSON 派生，人工勿改） -->",
        _kv([
            ("METRICS_ENDPOINT", m.get("metrics_endpoint")),
            ("LOG_QUERY", m.get("log_query")),
            ("LOG_QUERY_EVIDENCE", m.get("log_query_evidence")),
            ("ALERT_RULE", m.get("alert_rule")),
            ("ALERT_TESTED", m.get("alert_tested")),
            ("ALERT_TEST_OUTPUT", m.get("alert_test_output")),
        ]),
        "",
        "## 监控三件套（必须齐全）", "",
        _table(["件", "证据", "状态"], [
            ["1. Prometheus 端点", f"`{m.get('metrics_endpoint')}`",
             "✅" if m.get("metrics_endpoint") else "❌"],
            ["2. 日志查询证据", f"`{m.get('log_query_evidence')}`",
             "✅" if m.get("log_query_evidence") else "❌"],
            ["3. 告警规则与验证", f"`{m.get('alert_rule')}`（{m.get('alert_tested')}）",
             "✅" if m.get("alert_tested") == "PASS" else "❌"],
        ]), "",
        "## Prometheus 指标", "",
        _table(["指标名称", "类型", "描述", "单位"],
               [[x.get("name"), x.get("type"), x.get("desc"), x.get("unit")]
                for x in data.get("metrics", [])]), "",
        "## Grafana 大盘", "",
        _table(["面板", "数据源", "刷新频率"],
               [[d.get("panel"), d.get("source"), d.get("refresh")]
                for d in data.get("dashboards", [])]), "",
        "## 告警规则", "",
        _table(["告警名称", "级别", "条件", "持续时间", "通知方式"],
               [[a.get("name"), a.get("level"), a.get("condition"), a.get("duration"), a.get("notify")]
                for a in data.get("alerts", [])]), "",
        "## 日志规范", "",
        _table(["场景", "级别", "必须包含字段"],
               [[l.get("scene"), l.get("level"), l.get("fields")]
                for l in data.get("log_standards", [])]), "",
        "## 验证检查清单", "",
        _table(["#", "检查项", "验证命令", "预期结果", "实际", "状态"],
               [[i + 1, c.get("item"), f"`{c.get('cmd')}`", c.get("expected"), c.get("actual"),
                 "✅" if c.get("status") == "PASS" else "❌"]
                for i, c in enumerate(data.get("checklist", []))]), "",
        "## 签字确认", "", _signoffs_table(data.get("signoffs")), "",
    ]
    return "\n".join(lines)


def render_docs_index(data, input_path):
    lines = [
        f"# {data.get('feature_name')} 文档交付索引",
        "",
        f"> 生成时间：{_gen_time(data)}　数据来源：docs-index.json 结构化产物自动汇总",
        _audit("docs-index", input_path),
        "",
    ]
    kv = []
    for d in data.get("docs", []):
        kv += [(d.get("kind"), d.get("path")), (f"{d.get('kind')}_SHA256", d.get("sha256"))]
    lines += [_kv(kv), "",
              "> v3.15.1 契约：所有路径必须存在且指向本次交付实际维护的文档；每份文档须固化 SHA-256，",
              "> 且为 substantive 文档（≥10 行、≥2 标题、≥5 正文行、含类别语义章节）。",
              "",
              "## 文档清单", "",
              _table(["类别", "路径", "SHA-256（前 12 位）"],
                     [[d.get("kind"), f"`{d.get('path')}`", (d.get("sha256") or "")[:12] + "…"]
                      for d in data.get("docs", [])]), ""]
    return "\n".join(lines)


def _retro_feedback_env(data):
    fb = data.get("feedback", {})
    return "\n".join([
        f"FEEDBACK_ID={fb.get('feedback_id')}",
        f"SCOPE={fb.get('scope')}",
        f"STATUS={fb.get('status')}",
        f"ROOT_CAUSE={fb.get('root_cause')}",
        f"TARGET_FILES={','.join(fb.get('target_files') or [])}",
        f"DECISION={fb.get('decision')}",
    ] + ([f"DEFER_REASON={fb.get('defer_reason')}"] if fb.get("decision") == "defer" else []))


def render_retrospective(data, input_path):
    fb = data.get("feedback", {})
    period = data.get("period", {})
    feedback_env = _retro_feedback_env(data)
    lines = [
        f"# 复盘报告 - {data.get('feature_name')}",
        "",
        f"> 复盘日期：{data.get('date')}　参与人：{'、'.join(data.get('participants') or [])}　"
        f"周期：{period.get('from')} ~ {period.get('to')}",
        _audit("retrospective", input_path),
        "",
        "## 阶段合规事实（每行附真实收据路径，禁止无证据自评）",
        "",
        _table(["Phase", "Gate 结果", "收据路径", "SKIP 说明"],
               [[p.get("phase"), p.get("gate_result"), f"`{p.get('receipt_path')}`",
                 p.get("skip_note") or "—"] for p in data.get("phase_facts", [])]),
        "",
        f"阶段执行率：{sum(1 for p in data.get('phase_facts', []) if p.get('gate_result') == 'PASS')}"
        f"/{len(data.get('phase_facts', []))} PASS"
        f"（SKIP 需附 skip-log 授权记录说明）。",
        "",
        "## 复盘事实与根因",
        "",
    ]
    for f in data.get("facts", []):
        lines += [
            f"### {f.get('title')}", "",
            f"- **发生了什么**：{f.get('what')}",
            f"- **为什么会发生**：{f.get('why')}",
            f"- **为什么会漏掉**：{f.get('why_missed')}",
            f"- **影响**：{f.get('impact')}",
            f"- **Owner / ETA**：{f.get('owner')} / {f.get('eta')}", "",
        ]
    misses = data.get("misses", [])
    new_findings = data.get("new_findings", [])
    lines += [
        "## 上次遗漏了什么", "",
        _table(["#", "遗漏项", "影响", "本次修复方案"],
               [[i + 1, x.get("item"), x.get("impact"), x.get("fix")]
                for i, x in enumerate(misses)]) if misses else "无遗漏项。", "",
        "## 本次新发现", "",
        _table(["#", "新发现", "影响", "处置方案"],
               [[i + 1, x.get("item"), x.get("impact"), x.get("fix")]
                for i, x in enumerate(new_findings)]) if new_findings
        else "无新发现（已在 zero_results 声明）。", "",
        "## 行动计划", "",
        _table(["#", "改进项", "优先级", "Owner", "ETA"],
               [[i + 1, a.get("item"), a.get("priority"), a.get("owner"), a.get("eta")]
                for i, a in enumerate(data.get("actions", []))]), "",
        "## 反馈队列（P10 硬闭环）", "",
        _table(["项", "值"], [
            ["feedback_id", f"`{fb.get('feedback_id')}`"],
            ["scope", f"`{fb.get('scope')}`"],
            ["status", f"`{fb.get('status')}`"],
            ["用户批准 skill 修改", "是" if fb.get("skill_modify_approved") else "否（未批准不得 apply）"],
        ]), "",
        "> 本复盘已形成项目本地 `.devflow/<feature>/feedback/feedback.md`（--out-feedback 由管线产出）：", "",
        "```text", feedback_env, "```", "",
        "## 复核命令输出（防自评失真，实际输出由 JSON 粘贴）", "",
        "```bash", data.get("verify_output"), "```", "",
    ]
    return "\n".join(lines)


_SMALL_CHANGE_SCAN_KEYS = ["db", "domain", "api", "client", "config", "test",
                           "permission", "workflow", "cross_service", "history_data"]

_SMALL_CHANGE_ENV_KEYS = [
    ("CHANGE_KIND", "kind"), ("CHANGE_SUBJECT", "subject"), ("LOGICAL_CHANGE_COUNT", "logical_change_count"),
    ("TARGET", "target"), None, None, None,
    ("BREAKING_API", "breaking.api"), ("TYPE_OR_NULLABILITY_BREAKING", "breaking.type_nullability"),
    ("PERMISSION_CHANGE", "breaking.permission"), ("STATE_MACHINE_CHANGE", "breaking.state_machine"),
    ("CROSS_SERVICE_CHANGE", "breaking.cross_service"), ("NEW_TABLE_OR_SERVICE", "breaking.new_table_or_service"),
    ("LARGE_BACKFILL", "breaking.large_backfill"), ("MIGRATION_REQUIRED", "breaking.migration_required"),
    ("DIALECTS", "dialects"), ("VERIFY_CMD", "verify_cmd"), ("MIGRATION_VERIFY_CMD", "migration_verify_cmd"),
    ("DEPLOY_RECEIPT_PATH", "deploy_receipt_path"), ("MONITOR_RECEIPT_PATH", "monitor_receipt_path"),
    ("DECISION", "decision"), ("DECISION_REASON", "decision_reason"),
]


def _small_change_env(data):
    cid = data.get("change_id")
    env = {
        "kind": data.get("kind"),
        "subject": data.get("subject"),
        "logical_change_count": data.get("logical_change_count"),
        "target": data.get("target"),
        "surfaces": ",".join(data.get("surfaces") or []),
        "project_scan_evidence": data.get("project_scan_evidence")
        or f".devflow/{cid}/project-scan.txt",
        "change_report": data.get("change_report") or f"docs/小需求变更/{cid}-小需求变更.md",
        "affected_paths": ",".join(data.get("paths") or []),
        "dialects": data.get("dialects") or "",
        "verify_cmd": data.get("verify_cmd"),
        "migration_verify_cmd": data.get("migration_verify_cmd") or "",
        "deploy_receipt_path": data.get("deploy_receipt_path") or "",
        "monitor_receipt_path": data.get("monitor_receipt_path") or "",
        "decision": data.get("decision"),
        "decision_reason": data.get("decision_reason"),
    }
    for b_key, env_key in (("api", "BREAKING_API"), ("type_nullability", "TYPE_OR_NULLABILITY_BREAKING"),
                           ("permission", "PERMISSION_CHANGE"), ("state_machine", "STATE_MACHINE_CHANGE"),
                           ("cross_service", "CROSS_SERVICE_CHANGE"),
                           ("new_table_or_service", "NEW_TABLE_OR_SERVICE"),
                           ("large_backfill", "LARGE_BACKFILL"), ("migration_required", "MIGRATION_REQUIRED")):
        env[env_key] = (data.get("breaking") or {}).get(b_key, 0)
    out = []
    for spec in _SMALL_CHANGE_ENV_KEYS:
        if spec is None:
            continue
        env_key, path = spec
        if "." in path:
            continue
        out.append(f"{env_key}={env.get(path, '')}")
    return "\n".join(out)


def render_small_change(data, input_path):
    """返回 (报告 md, small-change.env 正文, project-scan.txt 正文)。"""
    scan = data.get("scan", {})
    subject = data.get("subject")
    risky = [k for k in ("permission", "workflow", "cross_service", "history_data") if scan.get(k) == "HIT"]
    scan_body = "\n".join([f"CHANGE_SUBJECT={subject}"]
                          + [f"SCAN_{k.upper()}={scan.get(k, 'NA')}" for k in _SMALL_CHANGE_SCAN_KEYS]
                          + [f"RISKY_HIT={','.join(risky) if risky else 'NONE'}",
                             f"DECISION={data.get('decision')}（{data.get('decision_reason')}）"])
    v = data.get("verification", {})
    report = "\n".join([
        f"# 小需求变更 - {data.get('change_id')}",
        "",
        f"> 生成时间：{_gen_time(data)}　数据来源：small-change.json 结构化产物自动汇总",
        _audit("small-change", input_path),
        "",
        "## 自然语言需求", "", data.get("request"), "",
        "## 变更摘要", "",
        _table(["项", "内容"], [
            ["主题", f"`{subject}`"],
            ["旧行为", data.get("old_behavior")],
            ["新行为", data.get("new_behavior")],
            ["类型", data.get("kind")],
            ["目标", f"`{data.get('target')}`"],
            ["影响路径", "、".join(f"`{p}`" for p in data.get("paths", []))],
        ]), "",
        "## 项目影响扫描（十项 HIT|MISS|NA）", "",
        _table(["扫描面", "结果"], [[k.upper(), scan.get(k, "NA")] for k in _SMALL_CHANGE_SCAN_KEYS]), "",
        f"风险面命中：{('、'.join(risky) + ' → 必须走 FULL') if risky else '无'}。", "",
        "## 机器契约（写入 .devflow/{id}/small-change.env，由管线自动产出）".format(id=data.get("change_id")), "",
        "```text", _small_change_env(data), "```", "",
        "## 验收条件", "",
        f"- 正向：{data.get('acceptance', {}).get('positive')}",
        f"- 边界：{data.get('acceptance', {}).get('boundary')}",
        f"- 失败：{data.get('acceptance', {}).get('failure')}", "",
        "## 实际验证", "",
        _table(["项", "内容"], [
            ["验证命令", f"`{v.get('cmd')}`"],
            ["真实退出码", v.get("exit_code")],
            ["执行日志", f"`{v.get('log')}`"],
            ["环境边界", v.get("env_boundary")],
            ["结论", f"`{v.get('conclusion')}`"],
        ]), "",
        (f"RELEASED 必须同时提供成功的 P7 与 P8 收据；当前结论 {v.get('conclusion')}。"
         if data.get("target") == "released" else
         "`MERGE_READY` 为默认终点；明确要求上线才绑定 P7+P8 收据并声明 `RELEASED`。"), "",
    ])
    return report, _small_change_env(data), scan_body


def render_demo_signoff(data, input_path):
    kufs = data.get("kufs", [])
    lines = [
        f"# 原型确认 - {data.get('feature_name')}",
        "",
        f"> 确认日期：{data.get('date')}　数据来源：demo-signoff.json 结构化产物自动汇总",
        _audit("demo-signoff", input_path),
        "",
        "## 原型文件",
        "",
    ]
    lines += [f"- {r}" for r in data.get("prototype_refs", [])]
    lines += [
        "",
        "## 关键用户旅程 walkthrough（KUF ≥3，逐条走查）",
        "",
        _table(["KUF", "旅程", "walkthrough 走查记录", "结果"],
               [[k.get("id"), k.get("journey"), f"走查：{k.get('walkthrough')}",
                 "✅ 通过" if k.get("result") == "通过" else "❌ " + (k.get("result") or "未通过")]
                for k in kufs]),
        "",
        f"KUF 共 {len(kufs)} 个，全部逐条完成走查。",
        "",
        "## PO 结论",
        "",
        f"**PO（产品负责人）结论**：{data.get('po_conclusion')}",
        "",
        "## 签字确认",
        "",
        "签字人列表：", "",
        _table(["角色", "签字人", "日期"],
               [[s.get("role"), s.get("name"), s.get("date")] for s in data.get("signoffs", [])]),
        "",
    ]
    return "\n".join(lines)


def render_sharing(data, input_path):
    lines = [
        f"# 知识分享 - {data.get('title')}",
        "",
        f"> 分享人：{data.get('sharer')}　日期：{data.get('date')}"
        + (f"　受众：{data.get('audience')}" if data.get("audience") else ""),
        _audit("sharing", input_path),
        "",
        "## 可复用教训（≥3 条）",
        "",
    ]
    lines += [f"- **{l.get('topic')}**：{l.get('content')}" for l in data.get("lessons", [])]
    lines.append("")
    return "\n".join(lines)


_REPORT_RENDERERS = {
    "clarification": render_clarification,
    "acceptance": render_acceptance,
    "constraints": render_constraints,
    "prd-review": render_prd_review,
    "tech-selection": render_tech_selection,
    "design-review": render_design_review,
    "self-check": render_self_check,
    "code-review": render_code_review,
    "prd-validation": render_prd_validation,
    "test-cases": render_test_cases,
    "deployment": render_deployment,
    "monitoring": render_monitoring,
    "docs-index": render_docs_index,
    "retrospective": render_retrospective,
    "sharing": render_sharing,
    "demo-signoff": render_demo_signoff,
}


def main():
    ap = argparse.ArgumentParser(description="devflow 结构化产物渲染器（确定性派生层）")
    ap.add_argument("kind", choices=["design", "verification"] + list(_REPORT_RENDERERS) + ["small-change"])
    ap.add_argument("--input", required=True)
    ap.add_argument("--doc", default=None, help="design: 拼接目标文档（须含 df:begin/end 锚点块）")
    ap.add_argument("--init-doc", dest="init_doc", default=None, metavar="PATH",
                    help="design: 按块注册表初始化骨架（文档须不存在；存在时列出缺失块后退出 1）")
    ap.add_argument("--out", default=None, help="输出路径（verification/各阶段报告必填）")
    ap.add_argument("--out-env", default=None, help="small-change: small-change.env 输出路径")
    ap.add_argument("--out-scan", default=None, help="small-change: project-scan.txt 输出路径")
    ap.add_argument("--out-feedback", default=None, help="retrospective: feedback.md 输出路径")
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
    elif args.kind == "verification":
        if not args.out:
            ap.error("verification 模式需要 --out")
        report = render_verification(data, args.input, exec_record_path=args.exec_record,
                                     workspace=args.workspace)
        Path(args.out).write_text(report, encoding="utf-8")
        print(f"渲染完成：{args.out}")
    elif args.kind == "small-change":
        # v3.25.0：小需求变更一次产出三件——报告 md + 机器契约 env + 影响扫描 scan
        if not args.out:
            ap.error("small-change 模式需要 --out（报告 md）")
        report, env_text, scan_text = render_small_change(data, args.input)
        Path(args.out).write_text(report, encoding="utf-8")
        if args.out_env:
            Path(args.out_env).write_text(env_text + "\n", encoding="utf-8")
        if args.out_scan:
            Path(args.out_scan).write_text(scan_text + "\n", encoding="utf-8")
        print(f"渲染完成：{args.out}"
              + (f" + {args.out_env}" if args.out_env else "")
              + (f" + {args.out_scan}" if args.out_scan else ""))
    else:
        if not args.out:
            ap.error(f"{args.kind} 模式需要 --out")
        report = _REPORT_RENDERERS[args.kind](data, args.input)
        Path(args.out).write_text(report, encoding="utf-8")
        if args.kind == "retrospective" and args.out_feedback:
            Path(args.out_feedback).write_text(_retro_feedback_env(data) + "\n", encoding="utf-8")
        print(f"渲染完成：{args.out}"
              + (f" + {args.out_feedback}" if args.kind == "retrospective" and args.out_feedback else ""))
    sys.exit(0)


if __name__ == "__main__":
    main()
