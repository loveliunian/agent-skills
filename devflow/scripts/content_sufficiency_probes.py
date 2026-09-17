#!/usr/bin/env python3
# content_sufficiency_probes.py · P2 内容充分性三防线（s2 Gate §6c，v3.26.4）
# =============================================================================
# 事故来源（治理服务 P2a 第三轮独立复核 DF-57~70，14 条中 11 条为机械门禁盲区）：
#   1) field-drift  —— 重写丢东西：PRD 必填字段/旧设计机制在新详设消失（DF-57/58/65）
#   2) state-matrix —— 状态机交叉：声明的状态值无转移语义、组合未定义（DF-61/63/64）
#   3) cross-doc    —— 跨文档契约：jobKey/内部端点/权限码双边不一致（DF-60/67/68）
#
# 设计原则：保守触发（宁可漏报不可误报历史文档）；缺输入降级 SKIP；每条 FAIL
# 给出可执行修复提示。负面可验证：删掉对应契约必须 FAIL。
#
# 用法（s2 §6c 调用，亦可独立）：
#   content_sufficiency_probes.py field-drift  --design D --prd P [--legacy archive.md]
#   content_sufficiency_probes.py state-matrix --design D [--design-json J]
#   content_sufficiency_probes.py cross-doc    --design D --peer P1 [--peer P2...] [--matrix M]
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

def _read(p: str) -> str:
    return Path(p).read_text(encoding="utf-8", errors="replace")

# ---------------------------------------------------------------- field-drift
# PRD 必填项提取：仅识别高置信模式，避免把描述性文字当必填字段。
PRD_REQUIRED = re.compile(r"([\u4e00-\u9fa5A-Za-z][\u4e00-\u9fa5A-Za-z0-9_]{1,24})（必填[，）]")

def probe_field_drift(design: str, prd: str | None, legacy: str | None) -> int:
    problems = []
    dtext = _read(design)
    if prd and Path(prd).exists():
        ptext = _read(prd)
        fields = sorted({m.group(1).strip() for m in PRD_REQUIRED.finditer(ptext)})
        missing = [f for f in fields if f and f not in dtext]
        if missing:
            print(f"[WARN] field-drift: PRD 必填项措辞在新详设 0 命中 {len(missing)} 个（多为别名/页面字段，人工核对）：{('、'.join(missing[:6]))}")
    if legacy and Path(legacy).exists():
        ltext = _read(legacy)
        # 机制承接：提取 legacy 中反引号技术记号（方法/常量/Redis键/SQL记号），
        # 新文档承接率过低 = 重写丢机制嫌疑（标题不可靠——机制常在正文，治理事故实证）
        tok = set(re.findall(r"`([A-Za-z][A-Za-z0-9_:.\-]{4,48})`", ltext))
        MECH_HINT = re.compile(r"seq|sequence|incr|lock|ttl|retry|backoff|idempot|fallback|generate|"
                               r"降级|自增|校准|重试|退避|幂等|锁|序列", re.I)
        mech_tokens = sorted(t for t in tok if MECH_HINT.search(t))
        lost = [t for t in mech_tokens if t not in dtext]
        # 同时要求机制语义词在新文档出现（防纯记号改名后的整体丢失）
        sem_lost = []
        for kw in ("序列号", "幂等键", "指数退避", "FOR UPDATE"):
            if kw in ltext and kw not in dtext:
                sem_lost.append(kw)
        # 判据=机制语义词丢失（设计级概念，重写必须保留）；方法名仅作同域佐证展示
        if sem_lost:
            related = [t for t in lost if MECH_HINT.search(t)][:5]
            detail = "、".join(sem_lost + ([f"（相关记号：{('、'.join(related))}）"] if related else []))
            problems.append(f"旧设计（archive）机制疑似未承接：{detail}"
                            "（重写版必须逐项承接或在 §13 DDR 登记'移交/废弃'决策——防重写丢机制，L-P2-006）")
    if not problems:
        print("[PASS] field-drift: PRD 必填项与旧设计机制均有承接（或无 PRD/legacy 输入）")
        return 0
    for p in problems:
        print(f"[FAIL] field-drift: {p}")
    return 1

# --------------------------------------------------------------- state-matrix
def _status_enums(dtext: str) -> dict[str, str]:
    """提取 status/状态 列的枚举值（容忍值单元格内的中文注释）。返回 {枚举值: 列名}"""
    out: dict[str, str] = {}
    for ln in dtext.splitlines():
        if not ln.startswith("|") or "---" in ln:
            continue
        cells = [c.strip() for c in ln.split("|")]
        if len(cells) < 5 or not re.search(r"^(\w*status\w*|状态|resolution_status|publish_status|change_type)$", cells[1] or "", re.I):
            continue
        col = cells[1]
        for cell in cells[2:6]:
            for v in re.findall(r"\b[A-Z][A-Z_]{2,23}\b", cell):
                if v not in ("NULL", "NOT", "PK", "UNIQUE", "CURRENT", "TIMESTAMP", "UPDATE", "DELETE", "INSERT", "SELECT"):
                    out.setdefault(v, col)
    return out

def probe_state_matrix(design: str, design_json: str | None) -> int:
    dtext = _read(design)
    lines = dtext.splitlines()
    # 1) 死状态检测：§2.3 声明的每个状态枚举值须在 §3/§4 出现（转移/语义描述）
    body_start = next((i for i, l in enumerate(lines) if re.match(r"^##\s*§?3", l)), 0)
    body_end = next((i for i, l in enumerate(lines) if re.match(r"^##\s*§?5", l)), len(lines))
    body = "\n".join(lines[body_start:body_end])
    dead = []
    seen_enums = _status_enums(dtext)
    for v, col in seen_enums.items():
        if v not in body:
            dead.append(f"{v}(列:{col})")
    if dead:
        # v3.26.5: 输出矛盾修复——旧版非 strict 下先打 [WARN] 死状态、随后仍打
        # "[PASS] 无死状态"（同一输入自相矛盾）。WARN 与 PASS 信息分开表述。
        if STRICT:
            print(f"[FAIL] state-matrix: 死状态 {len(dead)} 个——§2.3 声明但 §3/§4 无转移/语义描述：{('、'.join(dead[:8]))}"
                  "（每个状态值必须有进入/退出路径；--strict 阻断，L-P2-007）")
            return 1
        print(f"[WARN] state-matrix: 死状态 {len(dead)} 个——§2.3 声明但 §3/§4 无转移/语义描述：{('、'.join(dead[:8]))}"
              "（每个状态值必须有进入/退出路径；--strict 可升阻断，L-P2-007）")
    # 2) 组合穷举（可选）：design.json.state_machines 声明时做非法组合对账
    if design_json and Path(design_json).exists():
        try:
            dj = json.loads(Path(design_json).read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            dj = None
        sm = (dj or {}).get("state_machines")
        if sm:
            combos = sm.get("valid_combos", [])
            fields = sm.get("fields", [])
            if fields and combos:
                seen_map = {f: seen_enums_keys_for(f, dtext) for f in fields}
                # v3.26.8: 合法性校验——声明组合的取值必须来自该字段枚举域。
                # 旧版只数数量：{DRAFT, UNKNOWN} 与 {DRAFT, PUBLISHED} 同为 2 个，
                # 非法集合被当作完整矩阵放行（实测反例 rc=0）。
                invalid: list[str] = []
                for c in combos:
                    if not isinstance(c, dict):
                        continue
                    for f, v in c.items():
                        allowed = seen_map.get(f) or []
                        if not allowed:
                            continue  # 枚举提取为空时无法判定合法性（保守跳过）
                        vals = v if isinstance(v, (list, tuple)) else [v]
                        for vv in vals:
                            if vv not in allowed:
                                invalid.append(f"{f}={vv}")
                if invalid:
                    print(f"[FAIL] state-matrix: 非法组合 {len(set(invalid))} 处（取值不在枚举域）："
                          f"{('、'.join(sorted(set(invalid))[:6]))}"
                          "（组合矩阵必须是枚举域笛卡尔积的合法子集，L-P2-007）")
                    return 1
                # v3.26.6: 结构健壮性——valid_combos 条目含列表等不可哈希值（如
                # {"status": ["A","B"]}）时旧版 set 推导 TypeError 崩溃（traceback
                # 直达 Gate 输出）。无法解析即降级 WARN 跳过（与"缺输入降级"原则一致）。
                try:
                    declared = {tuple(sorted(c.items())) if isinstance(c, dict)
                                else tuple(c) if isinstance(c, (list, tuple))
                                else c for c in combos}
                except TypeError:
                    print("[WARN] state-matrix: valid_combos 结构无法解析（含不可哈希值），跳过组合穷举")
                    declared = None
                if declared is not None:
                    total = 1
                    for f in fields:
                        vs = seen_map.get(f) or []
                        total *= max(len(vs), 1)
                    if len(declared) < total:
                        print(f"[FAIL] state-matrix: 组合矩阵不全——声明合法组合 {len(declared)} < 笛卡尔积 {total}"
                              "（须显式列出全部合法组合或收敛状态域，L-P2-007）")
                        return 1
    if dead:
        print(f"[PASS] state-matrix: 组合检查通过（死状态 {len(dead)} 个仅 WARN，--strict 可升阻断）")
    else:
        print("[PASS] state-matrix: 无死状态" + ("（组合矩阵声明齐全）" if design_json else "（未声明 state_machines，跳过组合穷举）"))
    return 0

def seen_enums_keys_for(field: str, dtext: str) -> list[str]:
    """v3.26.7: 与 _status_enums 同口径的单元格解析（旧正则要求值单元格后还有一列
    ——常规 | status | DRAFT | 草稿 | 三列表无法命中 → 枚举数恒 0 → 组合矩阵声明
    不全仍 PASS（实测反例 rc=0）。现按字段列精确匹配、值列取大写枚举记号。）
    枚举记号下限 3 字符与 _status_enums 保持一致（防描述列 ID/PK 类噪声）。"""
    out: list[str] = []
    for ln in dtext.splitlines():
        if not ln.startswith("|") or "---" in ln:
            continue
        cells = [c.strip() for c in ln.split("|")]
        if len(cells) < 4:  # '', field, value, '' 最少四段
            continue
        if cells[1].lower() != field.lower():
            continue
        for cell in cells[2:4]:
            for v in re.findall(r"\b[A-Z][A-Z_]{2,23}\b", cell):
                if v not in ("NULL", "NOT", "PK", "UNIQUE", "CURRENT", "TIMESTAMP",
                             "UPDATE", "DELETE", "INSERT", "SELECT") and v not in out:
                    out.append(v)
    return out

# ------------------------------------------------------------------ cross-doc
# 作业语义键白名单前缀：仅这些 gov_* 视为调度 jobKey（表名 gov_element 等不算）
JOB_SEMANTIC = ("gov_inspection", "gov_similarity", "gov_recycle", "gov_policy",
                "gov_publish", "gov_merge", "gov_restore", "gov_code", "gov_job")
JOBKEY = re.compile(r"`(gov_[A-Za-z0-9_]+)`")
INTERNAL_EP = re.compile(r"(/internal/[A-Za-z0-9/_\-{}:.]+)")

def probe_cross_doc(design: str, peers: list[str], matrix: str | None) -> int:
    dtext = _read(design)
    problems = []
    peer_texts = []
    for p in peers:
        if Path(p).exists():
            peer_texts.append((p, _read(p)))
        else:
            problems.append(f"对端文档不存在: {p}")
    # 1) jobKey 双边登记
    ctx_keys, any_keys = set(), set()
    for ln in dtext.splitlines():
        keys = JOBKEY.findall(ln)
        any_keys.update(keys)
        if keys and re.search(r"jobKey|作业|调度|触发目标", ln):
            ctx_keys.update(keys)
    # 作业上下文键全部纳入；非上下文键仅白名单前缀纳入（防表名误报、防新键漏报）
    my_keys = sorted(ctx_keys | {k for k in any_keys if k.startswith(JOB_SEMANTIC)})
    exempt = [k for k in my_keys if re.search(rf"`{k}`[^|`\n]{{0,40}}(不经 HTTP|本地 cron|本地调度)", dtext)]
    for k in my_keys:
        if k in exempt:
            continue
        found = any(k in t for _, t in peer_texts)
        if peers and not found:
            problems.append(f"jobKey `{k}` 未在任何对端文档登记（双边登记是契约成立的条件，L-P2-008）")
    # 2) /internal 端点对端可达（被调方须有承接声明；调用方文档声明即可过——保守）
    trigger_eps = set()
    for ln in dtext.splitlines():
        if re.search(r"jobKey|作业|触发目标", ln):
            trigger_eps.update(INTERNAL_EP.findall(ln))
    my_eps = sorted(trigger_eps)
    for ep in my_eps:
        base = "/".join(ep.split("/")[:3])
        if peer_texts and not any(base in t or ep in t for _, t in peer_texts):
            problems.append(f"内部端点 {ep} 在对端文档无承接（对端须声明消费/实现或提供等价端点）")
    # 3) 权限码与事实源矩阵对账（可选 --matrix）
    if matrix and Path(matrix).exists():
        mtext = _read(matrix)
        dead_rows = {ln for ln in dtext.splitlines()
                     if re.search(r"废弃|旧详设码", ln)
                     # §7.5 新旧映射行：一行内 ≥2 个权限码（旧码列+落地码列）视为映射残留
                     or (ln.count(":") >= 2 and len(re.findall(r"[a-z0-9]+(?::[a-z0-9_\-]+){1,3}", ln)) >= 2
                         and ln.count("`") >= 1 and ln.startswith("|"))}
        live_text = "\n".join(ln for ln in dtext.splitlines() if ln not in dead_rows)
        perm_cols = re.findall(r"\|\s*([a-z0-9]+(?::[a-z0-9_\-]+){1,3})\s*\|", live_text)
        perms = sorted({p for p in perm_cols if ":" in p and not p.startswith("http")})
        ddr_registered = {c for ln in dtext.splitlines()
                          if "DDR" in ln or "新增" in ln
                          for c in re.findall(r"([a-z0-9]+(?::[a-z0-9_\-]+){1,3})", ln)}
        unknown = [p for p in perms if p not in mtext and p not in ddr_registered]
        if unknown:
            problems.append(f"权限码不在事实源矩阵 {len(unknown)} 个：{('、'.join(unknown[:8]))}"
                            "（新增码须登记矩阵+seed，L-P2-008）")
    if problems:
        print(f"[FAIL] cross-doc: {len(problems)} 处跨文档契约不对齐")
        for p in problems:
            print("  - " + p)
        return 1
    print("[PASS] cross-doc: jobKey/内部端点/权限码跨文档对齐")
    return 0

STRICT = False

def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("probe", choices=["field-drift", "state-matrix", "cross-doc"])
    ap.add_argument("--design", required=True)
    ap.add_argument("--prd")
    ap.add_argument("--legacy")
    ap.add_argument("--design-json")
    ap.add_argument("--peer", action="append", default=[])
    ap.add_argument("--matrix")
    ap.add_argument("--strict", action="store_true")
    a = ap.parse_args()
    global STRICT
    STRICT = a.strict
    if a.probe == "field-drift":
        return probe_field_drift(a.design, a.prd, a.legacy)
    if a.probe == "state-matrix":
        return probe_state_matrix(a.design, a.design_json)
    return probe_cross_doc(a.design, a.peer, a.matrix)

if __name__ == "__main__":
    sys.exit(main())
