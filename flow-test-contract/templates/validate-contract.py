#!/usr/bin/env python3
"""validate-contract.py v2 —— test-contract.yaml 契约校验（fail-closed，结构化）。

v2（2026-09-05 第二轮审计后）：
  - test_ready 级强制 meta.status == TEST_READY（DRAFT 越级执行封死）
  - 结构化凭据扫描：递归遍历 YAML 键，禁止 password/pwd/secret/token/密码/口令/credential/api_key
    等键（accounts[].env=CURRENT_*_PWD 引用除外）；叠加文本正则兜底
  - 引用完整性：steps.actor 必须在 accounts 登记（node 为空的观察步除外）；node 必须在 nodes 登记
  - 完整性：sources 非空；fixtures 必须含 legacy_ref/current_ref/pairing_rule；required 用例必须有
    assertions；field_mappings 显式 fixture_pair_id 必须存在于 fixtures
1.3.0（2026-09-09 P1 双修）：
  - 豁免取证链入契约门：exemptions 八字段必填（原五字段 + approval_ref/source_run_id/
    source_compare_sha256_16），且对源 run 账本现算复验 sha/结论（verify_exemption_provenance，
    --runs-dir 可显式指定证据库，默认 <契约同目录>/对比测试）——真实 run 绑定同时保护
    "生成器入口"与"最终契约入口"，绕过 exempt 手写豁免不再可采信
  - 分支覆盖双态：meta.branch_coverage 必须声明 accounted_complete（分支全分类）与
    formal_complete（无仅 drill 探索的反向分支）且与计数自洽——reverse_explore>0 的契约
    只覆盖正向分支，conclude 据此把结论限定为『正向 PASS / 反向未正式验证』
1.3.1（2026-09-09 P0/P1）：
  - 豁免核验重写为共享模块全链（scripts/run_evidence.py，与生成器 exempt 唯一实现，
    禁另写简化版）：五件齐全（+gates/case-results）/run-id 三方一致/账本登记 sha 现算/
    toolchain 指纹/底层证据轻量重算/scope-match 绑定源 diffs 真实条目——自制两个 JSON
    伪造八字段取证链被拒绝（此前简化版核验放过该形态）
  - runs-dir 智能解析：契约同目录/对比测试 → 上一级/对比测试（生成件/ 布局不再找错证据库）
退出码: 0=通过 / 2=失败。只有 test_ready 通过才允许生成正式执行件与运行。
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

# 动态加载共享核验模块 run_evidence（1.3.1 P0）时不写字节码——skill 目录零副作用承诺
sys.dont_write_bytecode = True

PLAINTEXT_PWD = re.compile(
    r"(Aa\d{8,}#"
    r"|(?i:password|passwd|secret|token|apikey|api_key)\s*[:：=]\s*\S"
    r"|(?i:pwd)\s*[:：=]\s*(?!CURRENT_)[A-Za-z0-9#]{6,}"
    # 第七轮审计：中文关键词邻接值形式（"密码：Xxx"/"口令=Xxx"，含全角冒号）此前不设防——
    # 自由文本位（meta.notes 等）可夹带明文并渲染进产物，违反凭据零明文承诺
    r"|(?:密码|口令|凭据)\s*[:：=]\s*(?!CURRENT_)[^\s]{6,}"
    r")")
# 子串匹配（非全词）：db_password / pwd2 / access_token / my_api_key / 密码2 等前后缀变体一并拦截
FORBIDDEN_KEY_SUBSTR = re.compile(r"(?i)(password|passwd|pwd|secret|token|credential|api_?key|apikey|passphrase|密码|口令|凭据)")
# 裸 pass 键（仅小写、前后非字母数字；避开 passed/passed_by 业务词与 conclusions.PASS 协议键）
PASS_KEY = re.compile(r"(?<![a-z0-9])pass(?![a-z0-9])")


def load_yaml_unique_keys(text: str):
    """safe_load + 重复键拒绝（后值静默覆盖前值=夹带风险：如双写 status: DRAFT/TEST_READY）。"""
    import yaml

    class _L(yaml.SafeLoader):
        pass

    def _no_dup(loader, node, deep=False):
        mapping = {}
        for k_node, v_node in node.value:
            key = loader.construct_object(k_node, deep=deep)
            if key in mapping:
                raise yaml.YAMLError(f"重复 YAML 键: {key!r}（后值覆盖前值=夹带风险，拒绝解析）")
            mapping[key] = loader.construct_object(v_node, deep=deep)
        return mapping

    _L.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup)
    return yaml.load(text, Loader=_L)


def walk_forbidden_keys(obj, path="", msgs=None):
    """递归找禁止键（含前缀/后缀/引号变体）。accounts[].env 的值必须仍是 CURRENT_*_PWD 引用。"""
    if msgs is None:
        msgs = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kp = f"{path}.{k}" if path else str(k)
            if FORBIDDEN_KEY_SUBSTR.search(str(k)) or PASS_KEY.search(str(k)):
                msgs.append(f"禁止键 {kp}（凭据只允许 accounts[].env 引用）")
            if str(k) == "env" and not re.match(r"^CURRENT_[A-Z0-9_]+_PWD$", str(v)):
                msgs.append(f"{kp}={v!r} 不符合 CURRENT_<账号大写>_PWD 引用格式")
            walk_forbidden_keys(v, kp, msgs)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk_forbidden_keys(v, f"{path}[{i}]", msgs)
    return msgs


def walk_nonfinite(obj, path="", msgs=None):
    """第十轮审计：契约任意位置的 .inf/.nan（YAML 原生非有限浮点）——经 gen 会以非标准
    JSON 常量（Infinity）进 rules，对拍端 exact 路径 inf==inf 记假 MATCH。立契期拒绝。"""
    if msgs is None:
        msgs = []
    if isinstance(obj, float) and not math.isfinite(obj):
        msgs.append(f"{path or '$'} 含非有限数值 {obj!r}（.inf/.nan——对拍端一律 BLOCKED，立契期拒绝）")
    elif isinstance(obj, dict):
        for k, v in obj.items():
            walk_nonfinite(v, f"{path}.{k}" if path else str(k), msgs)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            walk_nonfinite(v, f"{path}[{i}]", msgs)
    return msgs


def check_tolerance(tol, where, msgs):
    """第三轮审计：tolerance 必须是 'exact' 或 'abs:<有限非负数>'——abs:inf/1e999/nan/负数在
    对拍端会容忍/扭曲一切数值差异（假 OK），必须在立契期拒绝。"""
    if tol in (None, "exact"):
        return
    if not isinstance(tol, str) or not re.match(r"^abs:[0-9.eE+-]+$", tol):
        msgs.append(f"{where} tolerance={tol!r} 非法（只允许 exact 或 abs:<有限非负数>，如 abs:0.01）")
        return
    try:
        t = float(tol.split(":", 1)[1])
    except ValueError:
        msgs.append(f"{where} tolerance={tol!r} 不是可解析数值")
        return
    if not math.isfinite(t) or t < 0:
        msgs.append(f"{where} tolerance={tol!r} 非有限非负数（abs:inf/nan/负数=可绕过数值差异）")


def check_gate_value_satisfiability(gates: list, msgs):
    """第二十轮（实测反哺）：evidence_schema 断言值的可满足性——运行期才炸=浪费 run-id。
    gate-evidence-check 的标量守卫：eq/contains/regex 要求 actual 是标量，value 为
    list/dict/None 的断言**结构性不可能通过**（如 {failed_accounts, eq, []}），立契期拒绝。
    gte/lte 走数值化路径，list/dict 同样不可数值化——一并拒绝。"""
    for g in gates:
        gid = g.get("id")
        es = g.get("evidence_schema") or {}
        if not isinstance(es, dict) or es.get("kind") != "report":
            continue
        req = es.get("required_fields")
        if not isinstance(req, list):
            continue
        for rf in req:
            if not isinstance(rf, dict):
                continue
            op, val = rf.get("op"), rf.get("value")
            if isinstance(val, (dict, list)) or val is None:
                msgs.append(f"gate {gid} required_fields {rf.get('path')}: op={op} value={val!r} "
                            f"非标量——断言结构性不可能通过（eq/contains/regex 有标量守卫，gte/lte 需可数值化）；"
                            f"改用标量计数（如 failed_accounts_count eq 0）")
            elif op in ("eq", "contains", "regex") and isinstance(val, float) and not math.isfinite(val):
                msgs.append(f"gate {gid} required_fields {rf.get('path')}: value 非有限数值")


def check_health_coverage(envs, msgs):
    """第二十轮（实测反哺）：双侧环境健康覆盖——本次实测 legacy 宕机但门禁全绿
    （health_checks 只覆盖新系统），宕机要拖到 runner 阶段才暴露（7 用例全超时）。
    每个 environments.<side>.base_url 的主机必须被至少一条 health_checks 覆盖。"""
    if not isinstance(envs, dict):
        return
    from urllib.parse import urlparse
    checks_text = " ".join(str(x) for x in (envs.get("health_checks") or []))
    for side in ("legacy", "current"):
        e = envs.get(side)
        if not isinstance(e, dict) or not e.get("base_url"):
            continue
        host = urlparse(str(e["base_url"])).netloc
        if host and host not in checks_text:
            msgs.append(f"environments.{side}.base_url={e['base_url']} 无任何覆盖该主机的 health_checks"
                        f"——该侧宕机要等 runner 阶段才暴露（补一条该主机的 curl 健康检查）")


def check_case_route_consistency(cases: list, node_next: dict, warns, msgs, allow_drift=False):
    """用例路由一致性——第三十四轮（P2-3 收紧）：C-02 实测 44→99 与 nodes[44].next=[45]
    自相矛盾，此前仅 WARN 仍可进 TEST_READY；但 TEST_READY 执行会产生真实流程副作用
    （发单/办结/盖章链），矛盾路由此=执行期被服务端候选拒绝甚至误触其他分支。现口径：
      - cases[].notes 显式声明特殊流转（退回/作废等）→ 放行（可审计豁免）；
      - 未声明 + --allow-route-drift → WARN（仅限 pipeline --drill 演练探索，不出正式结论）；
      - 未声明 + 默认 → 立契期 FAIL（fail-closed）。
    DRAFT 级不做语义校验，探索性路径天然允许。"""
    for case in cases:
        cid = case.get("id")
        notes = str(case.get("notes") or "")
        for i, s in enumerate(case.get("steps") or []):
            if not isinstance(s, dict):
                continue
            node = str(s.get("node")) if s.get("node") not in (None, "", "-") else ""
            en = s.get("next") or s.get("expectNext")  # 契约 steps 用 next；场景 steps 用 expectNext
            if not node or en in (None, "", "-"):
                continue
            declared = node_next.get(node)
            if declared is None:
                continue
            if str(en) not in declared:
                if notes:
                    continue  # cases[].notes 已声明特殊流转（退回/作废等），可审计豁免
                text = (f"用例 {cid} step[{i}] 期望路由 {node}→{en!r} 不在 nodes[{node}].next={declared}")
                if allow_drift:
                    warns.append(text + "——--allow-route-drift 放行（仅限 --drill 演练探索；正式执行须在 cases[].notes 声明特殊流转）")
                else:
                    msgs.append(text + "——执行期服务端可能拒绝/误触分支；若确属退回/作废等特殊按钮流转，"
                                "请在 cases[].notes 声明，或用 --drill 演练（探索性路径不出正式结论）")


def _load_run_evidence():
    """动态加载共享核验模块 scripts/run_evidence.py（双布局兼容；禁写字节码——skill 目录零副作用）。
    找不到 = None（调用方 fail-closed）。"""
    import importlib.util
    here = Path(__file__).resolve().parent
    for c in (here.parent / "scripts" / "run_evidence.py",                       # skill 布局 templates/ → scripts/
              here.parent.parent / ".flow-test-contract" / "scripts" / "run_evidence.py",  # 项目部署布局
              here / "run_evidence.py"):                                         # 同目录（罕见）
        if c.is_file():
            spec = importlib.util.spec_from_file_location("ftc_run_evidence", c)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            return mod
    return None


def verify_exemption_provenance(exemptions: list, contract_path: Path, msgs, runs_dir: str | None):
    """1.3.0（P1）引入；1.3.1（P0）重写为共享模块全链核验——豁免账本核验与生成器 exempt
    共用 scripts/run_evidence.py 的唯一实现（五件齐全/run-id 三方一致/账本登记与 sha 现算
    一致/结论 ∈ PASS/FAIL/toolchain 指纹/底层证据轻量重算），另强制 scope/match 绑定源 run
    field-compare.diffs 的真实条目——自制 manifest/summary + 手算 sha + 凭空 match 的伪造
    八字段豁免在契约入口拒绝。同一源 run 多条豁免只核验一次。"""
    if not exemptions:
        return
    re_mod = _load_run_evidence()
    if re_mod is None:
        msgs.append("找不到共享核验模块 run_evidence.py（scripts/）——豁免取证链无法核验"
                    "（fail-closed）；重新同步/安装 skill 后重试")
        return
    # runs-dir 解析：显式 --runs-dir 优先；否则 契约同目录/对比测试 → 上一级/对比测试
    #（生成件/ 布局：docs/<流程>/自动化测试/生成件/ 的真实 run 在 自动化测试/对比测试/）
    if runs_dir:
        runs_base = Path(runs_dir)
    else:
        pd = contract_path.parent
        cands = [pd / "对比测试", pd.parent / "对比测试"]
        runs_base = next((p for p in cands if p.is_dir()), cands[0])
    if not runs_base.is_dir():
        msgs.append(f"契约声明 {len(exemptions)} 条豁免但 run 证据库不存在: {runs_base}"
                    f"（亦尝试 {runs_base if runs_dir else contract_path.parent / '对比测试'} 同级的上一目录）"
                    f"——豁免必须由 exempt 子命令从真实 run 生成（--runs-dir 可显式指定证据库）")
        return
    seen: dict[str, list[str]] = {}  # source_run_id → 本契约豁免 id 列表（同一 run 只核验一次）
    for e in exemptions:
        sid = str(e.get("source_run_id") or "").strip()
        if not sid:
            continue  # 缺字段已由必填检查报告，此处不重复
        seen.setdefault(sid, []).append(str(e.get("id") or "?"))
    for sid, eids in seen.items():
        cand = next((p for p in (runs_base / f"run-{sid}", runs_base / sid) if p.is_dir()), None)
        if cand is None:
            msgs.append(f"豁免 {eids} 取证链断: 源 run 目录不存在（{runs_base}/run-{sid} 或 /{sid}）"
                        f"——手写/凭空的 source_run_id 不构成豁免依据；请用 exempt 子命令重新生成")
            continue
        if cand.is_symlink():
            msgs.append(f"豁免 {eids} 取证链断: 源 run 目录为符号链接 {cand}（证据必须是实体目录）")
            continue
        try:
            ev = re_mod.verify_run_dir(cand)
        except re_mod.RunEvidenceError as ex:
            msgs.append(f"豁免 {eids} 取证链断（源 run {cand.name}）: {ex}")
            continue
        # 豁免声明的 sha 与现算比对（共享模块已核账本登记 sha；此处核"声明=被核验对象"）
        declared = {str(x.get("source_compare_sha256_16") or "") for x in exemptions
                    if str(x.get("source_run_id") or "").strip() == sid} - {""}
        if declared and ev["fc_sha16"] not in declared:
            msgs.append(f"豁免 {eids} 取证链断: 源 run field-compare sha 不一致"
                        f"（现算={ev['fc_sha16']} 声明={sorted(declared)}）——豁免声明被篡改或指向被改动的对拍")
            continue
        # scope/match 必须绑定源 run 的真实 diffs 条目（凭空 match 在此拒绝）
        sid_exemptions = [x for x in exemptions if str(x.get("source_run_id") or "").strip() == sid]
        for prob in re_mod.exemption_binding_problems(sid_exemptions, ev["fc"]):
            msgs.append(f"豁免 {eids} 取证链断（源 run {cand.name}）: {prob}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--contract", required=True)
    ap.add_argument("--level", choices=["draft", "test_ready"], default="test_ready")
    ap.add_argument("--allow-route-drift", action="store_true",
                    help="用例路由与 nodes.next 矛盾降为 WARN（仅限 --drill 演练探索；正式执行禁止）")
    ap.add_argument("--require-coverage", action="store_true",
                    help="v1.6.0：TEST_READY 强制要求 meta.coverage_manifest（新契约立契口径；"
                         "未传时缺账本仅告警——PASS 语义=已声明契约范围）")
    ap.add_argument("--schema", default=str(Path(__file__).parent / "test-contract.schema.json"))
    ap.add_argument("--env", default="",
                    help="可选：env 文件路径（如 $RUNTIME_DIR/env）——校验 accounts[].env 引用的键是否存在"
                         "（只查键名，不读值；缺失=WARN 不阻断——执行期可由 FLOWTEST_DEFAULT_PWD 兜底）")
    ap.add_argument("--runs-dir", default="",
                    help="可选：run 证据库目录（默认 <契约同目录>/对比测试）——豁免取证链核验在此定位 source_run_id")
    args = ap.parse_args()

    try:
        import yaml
    except ImportError:
        sys.exit("需要 PyYAML：uv run --with pyyaml,jsonschema python3 validate-contract.py …")

    msgs: list[str] = []
    warns: list[str] = []
    text = Path(args.contract).read_text(encoding="utf-8")
    if m := PLAINTEXT_PWD.search(text):
        msgs.append(f"明文凭据嫌疑（文本正则）: …{m.group(0)[:24]}…")
    try:
        c = load_yaml_unique_keys(text)
    except Exception as e:
        print(f"YAML 解析失败（含重复键拒绝）: {e}", file=sys.stderr)
        raise SystemExit(2)
    if not isinstance(c, dict):
        print("契约根节点必须是 mapping", file=sys.stderr)
        raise SystemExit(2)

    msgs += walk_forbidden_keys(c)
    msgs += walk_nonfinite(c)  # 第十轮：.inf/.nan 立契期拒绝（draft/test_ready 双级）

    # 第六轮审计：结构守卫（draft/test_ready 两级都过）——meta/容器类型畸形此前直接
    # AttributeError crash exit 1（test_ready 级 schema 报错后仍继续执行语义段，同样 crash；
    # 文档口径 0/2，crash 1 是未定义退出码）。一律折为结构化 msgs → exit 2
    meta = c.get("meta")
    if meta and not isinstance(meta, dict):
        msgs.append(f"meta 非对象（拿到 {type(meta).__name__}）——结构损坏")
        meta = {}

    def as_dict_list(key: str) -> list:
        """容器类型守卫：非列表→msgs+[]；列表内非对象条目→msgs+过滤（后续 .get 不再 crash）。"""
        v = c.get(key)
        if not v:
            return []
        if not isinstance(v, list):
            msgs.append(f"{key} 非列表（拿到 {type(v).__name__}）——结构损坏")
            return []
        bad = [i for i in v if not isinstance(i, dict)]
        if bad:
            msgs.append(f"{key} 存在非对象条目（{len(bad)} 个）——结构损坏")
        return [i for i in v if isinstance(i, dict)]

    def set_safe(vals, where: str) -> set:
        """不可哈希值（list/dict 作 id 等）不 crash——结构损坏 msgs，可哈希照常去重。"""
        out = set()
        for v in vals:
            try:
                out.add(v)
            except TypeError:
                msgs.append(f"{where} 含不可定位（不可哈希）值: {v!r}——结构损坏")
        return out
    for k in ("flow_name", "flow_code", "shape", "contract_version", "status"):
        if not meta.get(k):
            msgs.append(f"meta.{k} 缺失/为空")
    if meta.get("shape") not in (None, "S1", "S2", "S3"):
        msgs.append(f"meta.shape 非法: {meta.get('shape')}")
    status = meta.get("status")
    if status not in (None, "DRAFT", "TEST_READY"):
        msgs.append(f"meta.status 非法: {status}")
    # P0-1：状态门禁——test_ready 校验只对 TEST_READY 契约放行
    if args.level == "test_ready" and status != "TEST_READY":
        msgs.append(f"meta.status={status!r}——test_ready 校验仅适用于 TEST_READY 契约（DRAFT 不得生成/执行）")

    # —— v1.5.0 任务完成门①：声明 coverage_manifest 时，账本必须存在且结构合法
    #    （conclude_core 按其判定"全流程 PASS"是否成立；声明了却给不出合法账本=fail-closed）——
    cm_decl = meta.get("coverage_manifest")
    if cm_decl:
        _cm_path = cm_decl.get("path") if isinstance(cm_decl, dict) else cm_decl
        if not isinstance(_cm_path, str) or not _cm_path.strip():
            msgs.append("meta.coverage_manifest 须为 {path: 账本yaml路径} 或路径字符串")
        else:
            try:
                _vdir = Path(__file__).resolve().parent.parent / "scripts"
                if not _vdir.is_dir():
                    raise RuntimeError(f"覆盖账本校验库不可用（{_vdir}）")
                import sys as _sys5
                if str(_vdir) not in _sys5.path:
                    _sys5.path.insert(0, str(_vdir))
                import coverage_manifest as _cmmod
                # v1.6.0：相对路径按契约所在目录解析 + 深度校验（case/step/node/维度/evidence——
                # covered 不能挂在任意合法 case 上，审计第 8 轮 P0-2）
                _m, _err = _cmmod.load_manifest_for_contract(Path(args.contract), _cm_path)
                if _err:
                    msgs.append(f"meta.coverage_manifest: {_err}")
                else:
                    _probs = _cmmod.validate(_m, contract=c,
                                             manifest_path=_cmmod.resolve_path(Path(args.contract), _cm_path))
                    if _probs:
                        msgs.append("meta.coverage_manifest 深度校验非法: " + "; ".join(_probs[:5]))
            except Exception as e:
                msgs.append(f"meta.coverage_manifest 校验异常: {type(e).__name__}: {e}")
    elif args.level == "test_ready":
        # v1.6.0 P0-1：两类 PASS 语义——未声明账本 = contract_scope_only（已声明契约范围）；
        # 新契约立契口径传 --require-coverage 强制；存量迁移期默认告警不拒
        _msg_cov = ("meta.coverage_manifest 未声明——本契约的 PASS 只能是『已声明契约范围』"
                    "（conclude 以 contract_scope_only 标注），不构成全流程双端 PASS；"
                    "scaffold 覆盖账本后声明即可升级为全流程口径")
        if getattr(args, "require_coverage", False):
            msgs.append(_msg_cov + "（--require-coverage 已开启，强制拒绝）")
        else:
            warns.append(_msg_cov)
    if args.level == "test_ready":
        schema = Path(args.schema)
        if schema.exists():
            try:
                import jsonschema
                jsonschema.validate(c, __import__("json").loads(schema.read_text(encoding="utf-8")))
            except ImportError:
                msgs.append("未安装 jsonschema（uv run --with jsonschema）——Schema 校验跳过属不安全，拒绝放行")
            except Exception as e:
                msgs.append(f"Schema: {str(e)[:200]}")
        else:
            msgs.append(f"找不到 Schema: {schema}")

        # —— 语义完整性 ——
        if not meta.get("sources"):
            msgs.append("meta.sources 为空——契约必须登记取证快照（可追溯性）")
        # 多分支覆盖交叉核验（1.2.3 P0）：此前 sources 只校验非空，skipped>0 的不完整分支集
        # 仍可 TEST_READY——21/21 通过被误读为"全分支 PASS"（分母被静默缩小）。
        bc = meta.get("branch_coverage")
        if bc is not None:
            if not isinstance(bc, dict):
                msgs.append("meta.branch_coverage 必须是对象（多分支覆盖自证字段）")
            else:
                need = ("total_in_source", "formal_cases", "reverse_explore", "skipped_unknown_node")
                miss = [k for k in need if not isinstance(bc.get(k), int)]
                if miss:
                    msgs.append(f"meta.branch_coverage 缺整型字段 {miss}——分支覆盖不可核验")
                else:
                    tot, fml = bc["total_in_source"], bc["formal_cases"]
                    rev, skp = bc["reverse_explore"], bc["skipped_unknown_node"]
                    if tot != fml + rev + skp:
                        msgs.append(f"meta.branch_coverage 计数不自洽：total={tot} ≠ formal={fml}"
                                    f" + reverse={rev} + skipped={skp}（取证源与生成结果对不上）")
                    n_formal = len([c for c in as_dict_list("cases") if c.get("id")])
                    if fml != n_formal:
                        msgs.append(f"meta.branch_coverage.formal_cases={fml} 与实际 cases 数 {n_formal} 不符"
                                    f"——契约声明的分支覆盖与内容矛盾")
                    if skp > 0:
                        msgs.append(f"分支集不完整：{skp}/{tot} 支因未知环节名被跳过——"
                                    f"TEST_READY 要求 skipped=0（否则 {fml}/{fml} 通过会被误读为全分支 PASS）；"
                                    f"补 --node-map-extra 重新生成，或降级 DRAFT 作 partial 草稿")
                    if bc.get("complete") is not True and skp == 0:
                        msgs.append("meta.branch_coverage.complete 应为 true（skipped=0 时）")
                    # 1.3.0（P1）：accounted_complete（全部分支已分类）与 formal_complete（所有分支
                    # 均有正式执行路径，即无"仅 drill 探索"的反向分支）必须显式声明且自洽——
                    # 缺字段=旧版生成器产物，拒绝（重新生成）；值与计数矛盾=契约自证造假。
                    if not isinstance(bc.get("accounted_complete"), bool) or not isinstance(bc.get("formal_complete"), bool):
                        msgs.append("meta.branch_coverage 缺 accounted_complete/formal_complete（布尔）"
                                    "——1.3.0 起必填，用当前版本 gen-multibranch-contract.py 重新生成")
                    else:
                        if bc["accounted_complete"] != (skp == 0):
                            msgs.append(f"meta.branch_coverage.accounted_complete={bc['accounted_complete']}"
                                        f" 与 skipped={skp} 矛盾（应为 {skp == 0}）")
                        if bc["formal_complete"] != (skp == 0 and rev == 0):
                            msgs.append(f"meta.branch_coverage.formal_complete={bc['formal_complete']} 与"
                                        f" reverse={rev}/skipped={skp} 矛盾（应为 {skp == 0 and rev == 0}）"
                                        f"——reverse_explore>0 时本契约只覆盖正向分支，结论须标注『正向 PASS / 反向未正式验证』")
        fms = as_dict_list("field_mappings")
        if not fms:
            msgs.append("field_mappings 为空——没有语义合同的契约不允许 TEST_READY")
        fixtures = as_dict_list("fixtures")
        fx_ids = [f.get("fixture_pair_id") for f in fixtures]
        for f in fixtures:
            for k in ("legacy_ref", "current_ref", "pairing_rule"):
                if not f.get(k):
                    msgs.append(f"fixture {f.get('fixture_pair_id')} 缺 {k}（双端引用与配对规则必须显式）")
        if fx_ids and len(fx_ids) != len(set_safe(fx_ids, "fixtures.fixture_pair_id")):
            msgs.append(f"fixture_pair_id 重复: {fx_ids}")
        for fm in fms:
            fpid = fm.get("fixture_pair_id")
            if fpid and fpid not in fx_ids:
                msgs.append(f"field_mappings[{fm.get('legacy_field')}] 显式绑定的 fixture_pair_id={fpid} 未在 fixtures 登记")
            check_tolerance(fm.get("tolerance"), f"field_mappings[{fm.get('legacy_field')}]", msgs)
        formulas = as_dict_list("formulas")
        for f in formulas:
            check_tolerance(f.get("tolerance"), f"formulas[{f.get('id')}]", msgs)

        # —— 第七轮审计：字符串集合化族在立契期拦截（对拍端 set(map(str,…)) 会把字符串
        #    字符集合化——must_not_contain/expect_hidden 等断言静默失效记假 OK）——
        for r_ in as_dict_list("routing"):
            for fld in ("candidates_legacy", "must_not_contain"):
                v = r_.get(fld)
                if v is not None and not isinstance(v, list):
                    msgs.append(f"routing[{r_.get('node')}] {fld} 非列表（{type(v).__name__}）——对拍端会字符集合化记假判定")
        btn_list = as_dict_list("buttons")
        if c.get("buttons") and not any(b.get("node") for b in btn_list):
            msgs.append("buttons 声明非空但无任何带 node 的可比条目——注记条目不得替代断言")
        for b in btn_list:
            for fld in ("expect_visible", "expect_hidden"):
                v = b.get(fld)
                if v is not None and not isinstance(v, list):
                    msgs.append(f"buttons[{b.get('node')}] {fld} 非列表（{type(v).__name__}）——字符串会被字符集合化，断言失效")

        # —— 引用唯一性（重复 id = 账目不可信）——
        acc_list = as_dict_list("accounts")
        acc_ids = [a.get("id") for a in acc_list]
        if len(acc_ids) != len(set_safe(acc_ids, "accounts.id")):
            msgs.append(f"accounts id 重复: {[i for i in acc_ids if acc_ids.count(i) > 1]}")
        # 第二十一轮：.env 键存在性告警（只查键名、不读值；缺失只 WARN——执行期才需要真值）
        if args.env:
            _env_path = Path(args.env)
            if not _env_path.exists():
                warns.append(f"--env {_env_path} 不存在——跳过凭据键存在性检查")
            else:
                _env_keys = set()
                for _line in _env_path.read_text(encoding="utf-8", errors="replace").splitlines():
                    _line = _line.strip()
                    if _line.startswith("export "):
                        _line = _line[7:]
                    if "=" in _line and not _line.startswith("#"):
                        _env_keys.add(_line.split("=", 1)[0].strip())
                for _a in acc_list:
                    for _f in ("env", "username", "password"):
                        _k = str(_a.get(_f) or "")
                        if _k.startswith("CURRENT_") or _k.startswith("LEGACY_"):
                            if _k not in _env_keys:
                                warns.append(f"账号 {_a.get('id')}: env 键 {_k} 不在 {args.env}"
                                             f"——执行期需补键或显式设 FLOWTEST_ALLOW_DEFAULT_PWD=1 + FLOWTEST_DEFAULT_PWD 兜底（凭据勿写入契约）")
        node_list = as_dict_list("nodes")
        node_codes_list = [str(n.get("code")) for n in node_list]
        if len(node_codes_list) != len(set(node_codes_list)):
            msgs.append(f"nodes code 重复: {[i for i in node_codes_list if node_codes_list.count(i) > 1]}")
        fm_pairs = [(fm.get("legacy_field"), fm.get("target_field")) for fm in fms if isinstance(fm, dict)]
        if len(fm_pairs) != len(set_safe(fm_pairs, "field_mappings 对")):
            msgs.append(f"field_mappings legacy→target 对重复: {[p for p in fm_pairs if fm_pairs.count(p) > 1]}")
        # —— 豁免可审计且可定位（全量豁免禁止）——
        # 1.3.0（P1）：豁免八字段齐全（原五字段 + approval_ref/source_run_id/source_compare_sha256_16）——
        # 真实 run 绑定不能只保护"生成器入口"（exempt 子命令），必须保护"最终契约入口"：
        # 绕过 exempt 手写一条精确 match 的豁免，若无取证链字段/账本佐证，在此拒绝。
        EXEMPTION_REQUIRED_KEYS = ("id", "scope", "match", "reason", "approved_by",
                                   "approval_ref", "source_run_id", "source_compare_sha256_16")
        for e in as_dict_list("exemptions"):
            if not isinstance(e, dict):
                msgs.append(f"exemption 非对象条目: {e!r}")
                continue
            for k in EXEMPTION_REQUIRED_KEYS:
                if not str(e.get(k) or "").strip():
                    msgs.append(f"exemption {e.get('id') or '?'} 缺/空 {k}——TEST_READY 豁免必须可审计且绑定真实 run"
                                f"（取证链三件 approval_ref/source_run_id/source_compare_sha256_16 只能由 exempt 子命令"
                                f"从真实 run 生成；历史手工豁免请补链迁移或降 DRAFT）")
            if e.get("scope") == "*" and e.get("match") == "*":
                msgs.append(f"exemption {e.get('id')} scope='*'+match='*'——全量豁免禁止（差异全免=绕过结论）")
            # 第四轮审计：match='*' 即使 scope 为具体维度也等于整维度全免（对拍端原本放行→假 OK/假 PASS）
            if e.get("match") == "*":
                msgs.append(f"exemption {e.get('id')} match='*'——通配豁免禁止（豁免只作用于本维度本 key，必须精确/稳定键）")
            _sha16 = str(e.get("source_compare_sha256_16") or "")
            if _sha16 and not re.fullmatch(r"[0-9a-f]{16}", _sha16):
                msgs.append(f"exemption {e.get('id')} source_compare_sha256_16={_sha16!r} 非 16 位小写 hex——格式非法")
        # 1.3.0（P1）：豁免账本核验——source_run_id 必须能在 run 证据库（对比测试/）定位到真实
        # run 目录，且该 run 的 field-compare.json 现算 sha256[:16] 与声明一致、结论 ∈ PASS/FAIL。
        # 缺账本/错 sha/结论不可采信（BLOCKED/DRILL）= 豁免证据断链，TEST_READY 拒绝。
        verify_exemption_provenance(as_dict_list("exemptions"), Path(args.contract), msgs, args.runs_dir)

        accounts = set_safe((a.get("id") for a in acc_list), "accounts.id")
        node_codes = set(node_codes_list)
        cases = as_dict_list("cases")
        ids = [x.get("id") for x in cases]
        if len(ids) != len(set_safe(ids, "cases.id")):
            msgs.append(f"case id 重复: {ids}")
        if not any(x.get("required") for x in cases):
            msgs.append("不存在 required: true 的用例——0 必测用例不允许 TEST_READY")
        kbs = [x.get("kb") for x in cases if x.get("kb")]
        if len(kbs) != len(set_safe(kbs, "cases.kb")):
            msgs.append(f"kb 编号重复: {kbs}")
        for case in cases:
            cid = case.get("id")
            raw_steps = case.get("steps")
            if raw_steps and not isinstance(raw_steps, list):
                msgs.append(f"用例 {cid} steps 非列表（拿到 {type(raw_steps).__name__}）——结构损坏")
                raw_steps = []
            steps = raw_steps or []
            if not steps:
                msgs.append(f"用例 {cid} steps 为空")
            for i, s in enumerate(steps):
                if not isinstance(s, dict):
                    msgs.append(f"用例 {cid} step[{i}] 不是对象")
                    continue
                node = s.get("node")
                actor = s.get("actor")
                if node in (None, "", "-"):
                    if actor in (None, ""):
                        msgs.append(f"用例 {cid} step[{i}] node 与 actor 均为空")
                else:
                    if str(node) not in node_codes:
                        msgs.append(f"用例 {cid} step[{i}] node={node!r} 未在 nodes 登记")
                    if actor and str(actor) not in accounts:
                        msgs.append(f"用例 {cid} step[{i}] actor={actor!r} 未在 accounts 登记")
                if not str(s.get("action") or "").strip():
                    msgs.append(f"用例 {cid} step[{i}] action 为空")
            if case.get("required") and not case.get("assertions"):
                msgs.append(f"required 用例 {cid} 无 assertions——必测用例必须声明断言")
        for n in node_list:
            handlers = n.get("handlers")
            if handlers and not isinstance(handlers, list):
                msgs.append(f"节点 {n.get('code')} handlers 非列表——结构损坏")
                handlers = []
            for h in handlers or []:
                try:
                    missing = h and h not in accounts
                except TypeError:  # 不可哈希 handler（list/dict 等）
                    msgs.append(f"节点 {n.get('code')} handler 不可定位: {h!r}——结构损坏")
                    continue
                if missing:
                    msgs.append(f"节点 {n.get('code')} handler 未在 accounts 登记: {h}")
        fids = [f.get("id") for f in formulas]
        if len(fids) != len(set_safe(fids, "formulas.id")):
            msgs.append(f"formula id 重复: {fids}")
        concl = c.get("conclusions") or {}
        for k in ("PASS", "FAIL", "BLOCKED"):
            if k not in concl:
                msgs.append(f"conclusions.{k} 缺失")
        # —— 第十三轮审计：gates 证据 schema（P0——通用 file|url 不能证明具体 gate）——
        # 每个无自动检查器的 gate 必须声明 evidence_schema（http 白名单 / report 报告字段），
        # 否则门禁证据无法证明其声明——立契期拒绝（fail-closed）
        ipol = meta.get("instance_policy")
        if ipol not in (None, "launch", "reuse"):
            msgs.append(f"meta.instance_policy 非法: {ipol!r}（只认 launch/reuse）")
        envs = c.get("environments")
        if not isinstance(envs, dict):
            msgs.append("environments 缺失/非对象——契约必须声明环境（含 health_checks）")
        elif not envs.get("health_checks"):
            msgs.append("environments.health_checks 为空——无健康门禁定义（pipeline 按此执行，环境可移植）")
        gates = as_dict_list("gates")
        for g in gates:
            gid = g.get("id")
            if gid == "GATE-HEALTH":
                continue  # 自动健康检查（pipeline 按 environments.health_checks 执行）
            es = g.get("evidence_schema")
            if not isinstance(es, dict) or not es.get("kind"):
                msgs.append(f"gate {gid} 未声明 evidence_schema（kind: http|report）——无 schema 的证据无法证明本 gate")
                continue
            kind = es.get("kind")
            if kind == "http":
                allowed = es.get("allowed_urls")
                if not isinstance(allowed, list) or not allowed or not all(isinstance(u, str) and u.startswith(("http://", "https://")) for u in allowed):
                    msgs.append(f"gate {gid} evidence_schema.http 须 allowed_urls（http(s) 前缀白名单列表）")
            elif kind == "report":
                fmt = es.get("file_format")
                if fmt not in ("json", "csv", "txt"):
                    msgs.append(f"gate {gid} evidence_schema.report 须 file_format: json|csv|txt")
                req = es.get("required_fields")
                if not isinstance(req, list) or not req:
                    msgs.append(f"gate {gid} evidence_schema.report 须 required_fields（报告字段断言列表）")
                elif any(not (isinstance(x, dict) and x.get("path") and x.get("op") in ("eq", "contains", "regex", "gte", "lte")) for x in req):
                    msgs.append(f"gate {gid} evidence_schema.report.required_fields 条目须 {path, op: eq|contains|regex, value}")
            else:
                msgs.append(f"gate {gid} evidence_schema.kind 非法: {kind!r}（只认 http/report）")

        # —— 第二十轮（实测反哺）：门禁断言可满足性 + 双侧健康覆盖 + 用例路由一致性 ——
        check_gate_value_satisfiability(gates, msgs)
        check_health_coverage(envs, msgs)
        node_next_map = {}
        for n in node_list:
            nx = n.get("next")
            if isinstance(nx, list):
                node_next_map[str(n.get("code"))] = [str(x) for x in nx]
        check_case_route_consistency(cases, node_next_map, warns, msgs, allow_drift=args.allow_route_drift)
        # observer alias：cases[].actor 允许 '任一/any'（gen 期映射为 meta.observer_actor）
        obs = str(meta.get("observer_actor") or "").strip()
        if obs and obs not in accounts:
            msgs.append(f"meta.observer_actor={obs!r} 未在 accounts 登记")
        for case in cases:
            for i, s in enumerate(case.get("steps") or []):
                if isinstance(s, dict) and str(s.get("actor") or "").strip() in ("任一", "any", "ANY") and not obs:
                    msgs.append(f"用例 {case.get('id')} step[{i}] actor='任一' 但 meta.observer_actor 未配置"
                                f"——生成期无法映射为具体账号（runner actorMap 查不到即 BLOCKED）")

    if msgs:
        print("\n".join(f"[{args.level}] FAIL: {m}" for m in msgs), file=sys.stderr)
        raise SystemExit(2)
    if warns:
        print("\n".join(f"[{args.level}] WARN: {m}" for m in warns), file=sys.stderr)
    print(f"[{args.level}] OK: {args.contract}"
          + ("" if args.level == "test_ready" else "（草稿级——不得用于正式执行）")
          + (f"（{len(warns)} 条警告，见 stderr）" if warns else ""))
    raise SystemExit(0)


if __name__ == "__main__":
    main()
