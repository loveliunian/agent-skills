#!/usr/bin/env python3
"""ftc_ops_config.py —— api.operations 按钮语义原语配置的共享 schema 校验（v1.3.6 P0）。

api-capture.py 与 legacy-config-check.py 共用这一份唯一实现：
  - api-capture 在**任何登录/发起/提交之前**调用 validate_operations()——非法即 BLOCKED，
    绝不会先发生产写请求、再回头发现配置不完整（v1.3.5 的真实事故：backWorkflow 已完成、
    才报 MISSING_REFETCH，本地账本还提前删了原任务）；
  - legacy-config-check 把它并入结构完整性缺口——不再出现"检查器说可启动、runner 却拒绝"。

fail-closed 规则：
  - operations 存在时必须是 {BUTTON: 对象}；BUTTON 非空字符串，条目必须为对象；
  - 条目命中即必须合法——**禁止在命中键配置非法时静默回退统一 submit**；
  - path 必填非空；method 若给须为字符串；
  - successStatus 若给须为非空整数列表；
  - ledger 若给 ∈ {finish, refetch}（拼写错误如 "reftch" 不得被当作 finish）；
  - ledger=refetch ⇒ refetch 块必填且 path/listPath/taskIdField/nodeField/instanceField 齐全，
    pollSeconds 若给须为非负整数（退回后新任务异步可见时有限轮询，避免立即 BLOCKED）；
  - backTarget 若给须为对象且 path/listPath/nodeField/idField 齐全；body 引用 ${BACK_TARGET}
    时 backTarget 必配（守卫须在运行时 subst 之前——subst 会把未知占位符替换为空串）。

标量守卫：解析出的 BACK_NODE/BACK_TARGET/taskId 必须为非空有效标量（拒 None/""/"None"/
"null"/dict/list——否则会向老系统发送字符串 "None"）。
"""
from __future__ import annotations

LEDGER_VALUES = ("finish", "refetch")
_SCALAR_SENTINELS = {"", "none", "null", "undefined", "nan", "-"}


def is_valid_scalar(v) -> bool:
    """非空有效标量：拒 None/bool/容器/空白串/None 字面量/非有限浮点。"""
    if v is None or isinstance(v, bool):
        return False
    if isinstance(v, (int, float)):
        if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))):
            return False
        return True
    if isinstance(v, str):
        return v.strip().lower() not in _SCALAR_SENTINELS
    return False


def _problems_for_call_block(prefix: str, blk, required: tuple[str, ...]) -> list[str]:
    probs: list[str] = []
    if not isinstance(blk, dict):
        probs.append(f"{prefix} 须为对象")
        return probs
    p = blk.get("path")
    if not isinstance(p, str) or not p.strip():
        probs.append(f"{prefix}.path 缺失/非字符串")
    m = blk.get("method")
    if m is not None and not isinstance(m, str):
        probs.append(f"{prefix}.method 须为字符串")
    body = blk.get("body")
    if body is not None and not isinstance(body, dict):
        probs.append(f"{prefix}.body 须为对象")
    for k in required:
        v = blk.get(k)
        if not isinstance(v, str) or not v.strip():
            probs.append(f"{prefix}.{k} 缺失/非字符串")
    return probs


def _success_status_problems(prefix: str, entry: dict) -> list[str]:
    ss = entry.get("successStatus")
    if ss is None:
        return []
    if not isinstance(ss, list) or not ss:
        return [f"{prefix}.successStatus 须为非空列表"]
    for x in ss:
        if isinstance(x, bool) or not isinstance(x, int):
            return [f"{prefix}.successStatus 含非整数项: {x!r}（HTTP 状态码必须为整数）"]
    return []


def validate_operation_entry(button: str, entry) -> list[str]:
    """单个 operations 按钮条目的完整校验；返回问题清单（空=合法）。"""
    prefix = f"operations[{button!r}]"
    if not isinstance(button, str) or not button.strip():
        return ["operations 存在空按钮键（BUTTON 必须为非空字符串）"]
    if not isinstance(entry, dict):
        return [f"{prefix} 须为对象（命中键但配置非法——禁止回退统一 submit）"]
    probs = _problems_for_call_block(prefix, entry, ())
    probs += _success_status_problems(prefix, entry)
    # ledger
    ledger = entry.get("ledger")
    if ledger is not None and ledger not in LEDGER_VALUES:
        probs.append(f"{prefix}.ledger={ledger!r} 非法（只认 {'/'.join(LEDGER_VALUES)}）")
    # refetch 块：声明 refetch 就必须在发写请求前齐全
    if ledger == "refetch" or entry.get("refetch") is not None:
        rf = entry.get("refetch")
        rf_req = ("path", "listPath", "taskIdField", "nodeField", "instanceField")
        probs += _problems_for_call_block(f"{prefix}.refetch", rf, rf_req)
        if isinstance(rf, dict):
            ps = rf.get("pollSeconds")
            if ps is not None and (isinstance(ps, bool) or not isinstance(ps, int) or ps < 0):
                probs.append(f"{prefix}.refetch.pollSeconds 须为非负整数")
        if ledger == "refetch" and not isinstance(rf, dict):
            probs.append(f"{prefix}.ledger=refetch 但未配置 refetch 块——禁止先提交再补配置")
    # backTarget 块：配置了就必须齐全；body 引用 ${BACK_TARGET} 则必须配置
    bt = entry.get("backTarget")
    if bt is not None:
        probs += _problems_for_call_block(f"{prefix}.backTarget", bt,
                                          ("listPath", "nodeField", "idField"))
    try:
        import json as _json
        if "${BACK_TARGET}" in _json.dumps(entry.get("body") or {}, ensure_ascii=False) \
                and not isinstance(bt, dict):
            probs.append(f"{prefix}.body 引用 ${{BACK_TARGET}} 但未配置 backTarget 解析器")
    except Exception:
        pass
    return probs


def validate_operations(ops) -> list[str]:
    """api.operations 全量校验；返回问题清单（空=合法）。ops 为 None 时合法（未启用）。
    审计第 5 轮 P0-1：按钮键必须**原始类型即字符串**——YAML 数字/布尔键此前被 str() 强转后
    通过 schema，但运行时按字符串命中（`BUTTON in ops`）永不命中数字键 → 静默回退统一
    submit（退回/作废被编码成普通提交=既有提交漏洞）。非字符串键在入口即拒。"""
    if ops is None:
        return []
    if not isinstance(ops, dict):
        return ["api.operations 须为 {BUTTON: 配置对象} 映射"]
    probs: list[str] = []
    for button, entry in ops.items():
        if not isinstance(button, str):
            probs.append(f"operations 键 {button!r} 非字符串（{type(button).__name__}，YAML 数字/布尔键？）"
                         "——运行时按钮按字符串命中，此类键永不命中并静默回退统一 submit，拒绝"
                         "（请给键加引号写成字符串）")
            continue
        probs += validate_operation_entry(button, entry)
    return probs
