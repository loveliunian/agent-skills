#!/usr/bin/env python3
"""api-capture.py v2 —— API 通道采集器（不依赖 FlowTrace CLI / 浏览器）。

v2.0（2026-09-07 第十三轮审计·P0 修复：实例隔离与流程身份绑定）：
  - 默认 launch-first：首步必先发起本流程新实例，此后每步待办查找**强制绑定 instance_no**
    （本采集器只可能拿到自己发起的实例的任务）——绝不从"当前用户全部待办"按 node 盲取
    （此前可采到并提交他流程的同 node 真实任务=误操作+错标 capture）
  - todo 条目按可选 todo.flowCodePath 读服务端流程编码，须与场景 flow_code 一致才入选
  - launch 元素 ID 解析优先级：env <LAUNCH_ELEMENT_ID_<FLOW_CODE>>（按流程命名）
    → systems 配置 launch.elementIdEnv → 无则拒（fail-closed，不猜）
  - 复用待办须**显式声明**：场景 instancePolicy=reuse（契约 meta.instance_policy 生成，
    默认 launch）才允许首步在待办中找任务；找到的任务仍须过 flowCodePath 校验与
    实例绑定

v1（2026-09-07 第十二轮·通道自持）：纯 HTTP 采集（login/todo/launch/form/submit 五原语），
端点全配置化，产出与浏览器通道同构的 field-captures——下游 field-level-compare /
conclude / 账本零改动。

用法（由 run-contract-scenarios.py 以 api 后端调用；也可独立运行）:
  python3 api-capture.py --systems <runtime>/systems/api/current.yaml \
      --scenario <case.yaml> --run-id <id> --exec-dir <exec-dir>

systems api 配置（YAML，全部端点/路径可配——不猜接口，接口路径由配置声明）:
  id: current                    # 侧名（决定 captures 子目录：field-captures/<id>/）
  channel: api
  api:
    baseUrl: http://127.0.0.1:8080
    login:  {method, path, body{...占位}, tokenPath, tokenHeader, tokenScheme}
    todo:   {method, path, params, listPath, taskIdPath, nodePath, instancePath,
             flowCodePath}       # 可选：待办条目中流程编码路径（有则强制 == 场景 flow_code）
    launch: {method, path, body, instancePath, taskIdPath, elementIdEnv}   # 必填（launch-first）
    form:   {method, path(含 ${TASK_ID}), fieldsPath}
    submit: {method, path(含 ${TASK_ID}), body, defaultButton, successStatus[]}
    operations: {<BUTTON>: {method, path, body, successStatus[], backTarget?, ledger?, refetch?}}
               # 第三十五轮（v1.3.5）：按钮语义原语——step.button 命中键时改发该按钮专属端点，
               # 不再走统一 submit（老系统退回/作废是独立端点与载荷，编码成 next_step 会被拒）。
               # backTarget=退回目标步实例解析器；ledger: finish|refetch（refetch=按 todo 列表
               # 重登记退回后新任务，可配 pollSeconds 有限轮询）。详见 _submit_operation docstring。
               # v1.3.6：整套 operations schema 在任何登录/发起/提交前经 ftc_ops_config.py 校验，
               # 命中键但配置非法即拒绝（不回退统一 submit）。
    route_map: {flow_code: {老编码: 目标路由码}} 或扁平 {老编码: 路由码}
               （第二十轮：多体系路由编码映射——场景 nextStep 老编码→目标系统真实路由码，
                 如非 DMN 流程的部署 BPMN taskElementId；未命中保持原值，服务端校验兜底）
    taskWaitSeconds: 15          # 提交后等待下一节点任务可见的轮询窗口
  actorMap:                      # 与 browser 通道同构：actor → 环境变量名（零明文）
    admin: {username: CURRENT_ADMIN_USER, password: CURRENT_ADMIN_PWD}

占位符（${VAR}）：USERNAME/PASSWORD（按步 actor 解析）、TASK_ID/INSTANCE_NO/NODE、
BUTTON（step.button → submit.defaultButton）、NEXT_ASSIGNEE（step.expectAssignee，空则丢弃该键）、
ELEMENT_ID（launch 元素 ID——见 v2.0 解析优先级）。

铁律（fail-closed）:
  - 任何一步失败 → exit 2，**不落 capture**（半执行的采集绝不让下游误判 PASS）
  - capture 仅在全部步骤成功后原子写出，且必带身份三要素：
    run_id（==本次 run）/ case_id（==场景 case_id）/ flow_code / instance_no
  - 实例绑定：凡已知 instance_no，任务查找必须落在该实例（防误操作他流程任务）
  - 密码只从 actorMap 指定的环境变量读取；日志零请求体（错误只报 status+path，防凭据泄漏）
  - channel != api 或配置缺失/非法 → exit 2（诚实拒绝，不猜测端点）
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import re
import sys
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True   # 审计第 3 轮 R3-1：兄弟模块导入零字节码（skill 目录零副作用）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # spec 加载（selftest）时补齐 scripts 目录
import ftc_env  # noqa: E402  凭据解析唯一实现（v1.3.3 去 .env 化：env 文件 + 显式授权 FLOWTEST_DEFAULT_PWD 兜底）
import ftc_ops_config  # noqa: E402  api.operations schema 唯一校验实现（v1.3.6 P0；legacy-config-check 共用）
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 api-capture.py …")

HTTP_TIMEOUT = int(os.environ.get("FLOWTEST_HTTP_TIMEOUT", "15"))  # 老系统后端忙时 15s 不够（2026-09-08 实测 startWorkflow>15s）——可经 env 调大


def body_snippet(obj, limit: int = 200) -> str:
    """响应体片段（die 附带，第二十轮实测反哺）：此前错误只报 status+path，引擎的业务
    失败原因要去翻通道适配层审计才知道。截断 + 脱敏（password/token 类字段值替换 ***），
    空体返回空串。注意：凭据只进请求体、从不进响应体的前提下此片段不构成泄漏面。"""
    if obj is None:
        return ""
    try:
        s = json.dumps(obj, ensure_ascii=False)
    except Exception:
        s = str(obj)
    s = re.sub(r'("[^"]*(?:password|passwd|pwd|token|secret|credential|authorization|passphrase|api[-_]?key)[^"]*"\s*:\s*")[^"]*(")',
               r"\1***\2", s, flags=re.I)
    return f" 响应体: {s[:limit]}{'…' if len(s) > limit else ''}"


def apply_route_map(body, rmap_cfg, flow_code: str) -> dict:
    """route_map（第二十轮）：多体系路由编码映射——场景 nextStep 用业务老编码（如 01），
    目标系统真实路由码可能是另一体系（如非 DMN 流程的部署 BPMN taskElementId task_xxx）。
    systems yaml api.route_map 支持按流程嵌套 {flow_code: {code: route}} 或扁平 {code: route}；
    未命中保持原值（映射缺失不由采集器猜测——服务端校验会诚实拒绝）。"""
    if not isinstance(body, dict):
        return body
    rm = rmap_cfg if isinstance(rmap_cfg, dict) else {}
    if flow_code and isinstance(rm.get(flow_code), dict):
        rm = rm[flow_code]
    ns = body.get("nextStep")
    if ns is not None and str(ns) in rm:
        body["nextStep"] = rm[str(ns)]
    return body


def die(msg: str) -> None:
    print(f"[api-capture] ⛔ {msg}", file=sys.stderr)
    raise SystemExit(2)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """登录链步骤禁用自动重定向（302 Location 携带 token 的系统形态）。"""

    def redirect_request(self, req, fp, code, msg, headers_, newurl):
        return None


def dig(obj, path: str):
    """极简 JSONPath（点号取键，[n] 取数组下标）；任一步缺失/类型不符返回 KeyError。"""
    cur = obj
    for token in re.findall(r"[^.\[\]]+|\[\d+\]", path):
        if token.startswith("["):
            idx = int(token[1:-1])
            if not isinstance(cur, list) or idx >= len(cur):
                raise KeyError(f"{path}（数组越界于 {token}）")
            cur = cur[idx]
        else:
            if not isinstance(cur, dict) or token not in cur:
                raise KeyError(f"{path}（缺键 {token}）")
            cur = cur[token]
    return cur


def subst(v, ctx: dict):
    """递归替换 ${VAR}；字符串解析后为空串 → 标记整键丢弃（None 哨兵由调用方剔除）。"""
    if isinstance(v, str):
        def _r(m):
            return str(ctx.get(m.group(1), ""))
        return re.sub(r"\$\{([A-Za-z0-9_]+)\}", _r, v)
    if isinstance(v, dict):
        out = {}
        for k, val in v.items():
            val = subst(val, ctx)
            if val is None:
                continue
            out[k] = val
        return out
    if isinstance(v, list):
        return [subst(x, ctx) for x in v]
    return v


def drop_empty(body: dict) -> dict:
    """占位符解析为空串的键整对剔除（如 nextAssigneeId 未指定时不发送）。"""
    return {k: v for k, v in body.items() if not (isinstance(v, str) and v == "")}


def norm_name(name) -> str:
    """办理人姓名归一化：剥『(xx)』『（xx）』注记后缀（如 常琨(公路)→常琨）+ 去全部内部空白
    （老系统人名库含排版空格，如 "高 鹏"——仅用于比对，2026-09-08 港口煤 02 节点实测）。"""
    return re.sub(r"\s+", "", re.sub(r"[（(][^（）()]*[)）]\s*$", "", str(name or ""))).strip()


class Api:
    def __init__(self, cfg: dict):
        self.base = str(cfg.get("baseUrl", "")).rstrip("/")
        if not self.base.startswith(("http://", "https://")):
            die(f"api.baseUrl 非法: {self.base!r}")
        self.tokens: dict[str, str] = {}   # actor → token
        self.api = cfg
        lg = cfg.get("login") or {}
        self.token_header = str(lg.get("tokenHeader", "Authorization"))
        self.token_scheme = str(lg.get("tokenScheme", "Bearer ") or "")
        # ── 第十七轮（2026-09-07 真实双端试点反哺）：通道适配原生化 ──
        # 全部为可选配置，缺省=原行为（负向回归全绿兼容）：
        #   headers:      静态附加头（支持 ${UUID}/${VAR} 占位）
        #   rsaPubB64:    rsa_pkcs1 变换公钥（SPKI base64，登录链加密用）
        #   whoami:       {path, namePath}——登录后实查显示名（账本 owner 匹配用）
        #   todo.mode: ledger + nextTaskPath/firstNode——桥内账本待办（服务端响应组装，零编造）
        #   todo.map:     待办条目值映射 {字段: {旧值: 新值}}（实录键值改写）
        #   form.body:    表单采集请求体模板（${TASK_ID}/${INSTANCE_NO}/${FLOW_CODE}）
        #   form.nextStepPath/form.nodePath: 服务端声明的下一环节/本环节码（账本与选人解析用）
        #   submit.retryOn: {messageContains, preButton}——引擎明确报错时先补前置按钮再重试一次
        #   assignee:     {resolver: next-assignees|orgrole, ...}——办理人姓名→ID 服务端实时解析
        self.extra_headers = cfg.get("headers") or {}
        if not isinstance(self.extra_headers, dict):
            die("api.headers 非法：须为 {头名: 值} 映射")
        self.rsa_pub = str(cfg.get("rsaPubB64") or lg.get("rsaPubB64") or "")
        self.whoami = cfg.get("whoami") or {}
        self.ledger: dict[str, dict] = {}     # StepInsCode/任务ID → {node, owner_display, next_step, instance, flow}
        self.task_meta: dict[str, dict] = {}  # 任务ID → {nextStep, node}
        self.actor_display: dict[str, str] = {}  # actor → 显示名（whoami 实查）
        if cfg.get("todo", {}).get("mode") == "ledger":
            tdl = cfg["todo"]
            self.ledger_first_node = str(tdl.get("firstNode", "00"))
            self.ledger_next_task_path = str(tdl.get("nextTaskPath", "") or "")
            if not self.ledger_next_task_path:
                die("todo.mode=ledger 须配置 nextTaskPath（提交响应中下一任务 ID 的 JSONPath）——不猜测")
        # 占位检测口径扩展：rsaPubB64 也是配置值（占位扫描已覆盖整个 cfg，无需额外处理）

    # ── 值变换管道：${VAR|op1|op2}（第十七轮）──
    def _xform(self, val: str, op: str) -> str:
        import base64 as _b64
        import hashlib as _hl
        try:
            if op == "md5_upper":
                return _hl.md5(val.encode("utf-8")).hexdigest().upper()
            if op == "md5":
                return _hl.md5(val.encode("utf-8")).hexdigest()
            if op == "sha256":
                return _hl.sha256(val.encode("utf-8")).hexdigest()
            if op == "b64":
                return _b64.b64encode(val.encode("utf-8")).decode()
            if op == "uri":
                return urllib.parse.quote(val, safe="")
            if op == "upper":
                return val.upper()
            if op == "lower":
                return val.lower()
            if op == "rsa_pkcs1":
                if not self.rsa_pub:
                    die("变换 rsa_pkcs1 需要 api.rsaPubB64（SPKI base64 公钥）——不猜测密钥")
                return self._rsa_pkcs1_b64(val)
        except SystemExit:
            raise
        except Exception as e:
            die(f"值变换 {op} 失败: {type(e).__name__}: {e}")
        die(f"未知值变换 op={op!r}（支持 md5_upper/md5/sha256/b64/uri/upper/lower/rsa_pkcs1）")

    def _rsa_pkcs1_b64(self, plaintext: str) -> str:
        """RSAES-PKCS1-v1_5 公钥加密（stdlib：SPKI DER 解析 + 模幂），输出 base64（JSEncrypt 同构）。"""
        import base64 as _b64
        import secrets as _sk

        def _rlen(data, off):
            b = data[off]; off += 1
            if b < 0x80:
                return b, off
            n = b & 0x7F
            return int.from_bytes(data[off:off + n], "big"), off + n

        def _rtlv(data, off):
            tag = data[off]; off += 1
            ln, off = _rlen(data, off)
            return tag, data[off:off + ln], off + ln

        der = _b64.b64decode(self.rsa_pub)
        _tag, body, _ = _rtlv(der, 0)                 # SEQUENCE
        _t2, _alg, off = _rtlv(body, 0)               # AlgorithmIdentifier
        _t3, bits, _ = _rtlv(body, off)               # BIT STRING
        inner = bits[1:]                              # 去掉未用位数八位组
        _t4, keyseq, _ = _rtlv(inner, 0)              # SEQUENCE
        _t5, n_bytes, off2 = _rtlv(keyseq, 0)         # INTEGER n
        _t6, e_bytes, _ = _rtlv(keyseq, off2)         # INTEGER e
        n = int.from_bytes(n_bytes.lstrip(b"\x00"), "big")
        e = int.from_bytes(e_bytes.lstrip(b"\x00"), "big")
        k = (n.bit_length() + 7) // 8
        m = plaintext.encode("utf-8")
        if len(m) > k - 11:
            die(f"rsa_pkcs1 明文过长（{len(m)} > {k - 11}）")
        ps = bytearray()
        while len(ps) < k - 3 - len(m):
            c = _sk.token_bytes(1)
            if c != b"\x00":
                ps += c
        eb = b"\x00\x02" + bytes(ps) + b"\x00" + m
        c = pow(int.from_bytes(eb, "big"), e, n)
        return _b64.b64encode(c.to_bytes(k, "big")).decode()

    def _resolve(self, v, ctx: dict):
        """subst 的变换增强版：${VAR|op|...}；纯 ${VAR} 行为与 subst 一致。"""
        if isinstance(v, str):
            def _r(m):
                parts = m.group(1).split("|")
                val = str(ctx.get(parts[0], ""))
                for op in parts[1:]:
                    val = self._xform(val, op)
                return val
            return re.sub(r"\$\{([A-Za-z0-9_][A-Za-z0-9_|]*)\}", _r, v)
        if isinstance(v, dict):
            out = {}
            for k, val in v.items():
                val = self._resolve(val, ctx)
                if val is None:
                    continue
                out[k] = val
            return out
        if isinstance(v, list):
            return [self._resolve(x, ctx) for x in v]
        return v

    def call_full(self, method: str, path: str, *, body=None, params=None, token: str | None = None,
                  no_follow: bool = False) -> tuple[int, object, dict, str]:
        """完整版 HTTP：返回 (status, jsonObj|None, respHeaders, text)。call() 语义不变（兼容旧调用）。"""
        url = self.base + path
        if params:
            url += "?" + urllib.parse.urlencode(params)
        data = None
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        for k, v in self.extra_headers.items():
            headers[str(k)] = self._resolve(str(v), {"UUID": uuid.uuid4().hex})
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        if token:
            headers[self.token_header] = self.token_scheme + token
        req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
        opener = urllib.request.build_opener(_NoRedirect) if no_follow else urllib.request.build_opener()
        try:
            with opener.open(req, timeout=HTTP_TIMEOUT) as resp:
                raw = resp.read().decode("utf-8", "replace")
                try:
                    obj = json.loads(raw) if raw else None
                except Exception:
                    obj = None
                return resp.status, obj, dict(resp.headers), raw
        except urllib.error.HTTPError as e:
            # 只报状态码与路径——响应体可能回显凭据，绝不落日志
            raw = e.read().decode("utf-8", "replace")
            try:
                obj = json.loads(raw) if raw else None
            except Exception:
                obj = None
            return e.code, obj, dict(e.headers), raw
        except Exception as e:
            raise ConnectionError(f"{type(e).__name__}: {e}（{method} {path}）")

    def call(self, method: str, path: str, *, body=None, params=None, token: str | None = None) -> tuple[int, object]:
        status, obj, _h, _t = self.call_full(method, path, body=body, params=params, token=token)
        return status, obj

    def login(self, actor: str, username: str, password: str) -> str:
        if actor in self.tokens:
            return self.tokens[actor]
        lg = self.api.get("login") or die("api 配置缺 login 块")
        chain = lg.get("chain")
        if chain:
            token = self._login_chain(actor, lg, chain, username, password)
        else:
            body = drop_empty(self._resolve(lg.get("body") or {}, {"USERNAME": username, "PASSWORD": password}))
            status, obj = self.call(lg.get("method", "POST"), lg.get("path", ""), body=body)
            if status != 200:
                die(f"登录失败（actor={actor}）：HTTP {status} {lg.get('path')}——检查账号/密码/服务可达性")
            try:
                token = str(dig(obj, lg.get("tokenPath", "data.token")))
            except KeyError as e:
                die(f"登录响应取 token 失败（tokenPath={lg.get('tokenPath')}）: {e}")
            if not token:
                die("登录响应 token 为空")
        self.tokens[actor] = token
        # whoami（可选）：登录后实查显示名——账本待办 owner 匹配用（显示名≠登录名的系统必需）
        wa = self.whoami or {}
        if wa.get("path"):
            try:
                _st, obj, _h, _t = self.call_full(wa.get("method", "GET"), subst(str(wa["path"]), {}),
                                                  token=token)
                disp = str(dig(obj or {}, wa.get("namePath", "data.name")))
                if disp:
                    self.actor_display[actor] = disp
            except KeyError:
                pass  # whoami 取不到显示名→账本 owner 退化为原始姓名比对（不阻断）
        return token

    def _login_chain(self, actor: str, lg: dict, chain: list, username: str, password: str) -> str:
        """多步登录链（第十七轮）：步骤可保存中间值（saveAs/savePath）、可禁用重定向并从
        Location 查询参数提取 token（tokenFromRedirectQuery）；body 值支持 ${VAR|变换管道}
        （如密码 ${PASSWORD|md5_upper|rsa_pkcs1|uri}）。全程真实请求，零编造。"""
        if not isinstance(chain, list) or not chain:
            die("login.chain 须为非空步骤数组")
        ctx = {"USERNAME": username, "PASSWORD": password, "UUID": uuid.uuid4().hex}
        token = ""
        for i, st_ in enumerate(chain, 1):
            if not isinstance(st_, dict) or not st_.get("path"):
                die(f"login.chain[{i}] 缺 path")
            body = drop_empty(self._resolve(st_.get("body") or {}, ctx))
            no_follow = bool(st_.get("noFollow"))
            tq = str(st_.get("tokenFromRedirectQuery", "") or "")
            if tq and not no_follow:
                die(f"login.chain[{i}] tokenFromRedirectQuery 须与 noFollow: true 同用（302 Location 提取）")
            status, obj, hdrs, _text = self.call_full(str(st_.get("method", "POST")),
                                                      self._resolve(str(st_["path"]), ctx),
                                                      body=body or None, no_follow=no_follow)
            expect = st_.get("expectStatus") or ([200, 301, 302, 303, 307, 308] if tq else [200])
            if status not in [int(x) for x in expect]:
                die(f"登录链步骤 {i} 失败（actor={actor}）：HTTP {status} {st_['path']}")
            if tq:
                loc = hdrs.get("Location") or hdrs.get("location") or ""
                if f"{tq}=" not in loc:
                    die(f"登录链步骤 {i} 的 302 Location 未携带 {tq}=（实测：{loc[:60]}…）")
                token = loc.split(f"{tq}=", 1)[1].split("&", 1)[0]
            if st_.get("saveAs"):
                try:
                    ctx[str(st_["saveAs"])] = str(dig(obj, str(st_.get("savePath", "data"))))
                except KeyError as e:
                    die(f"登录链步骤 {i} 取值失败（savePath={st_.get('savePath')}）: {e}")
        if not token:
            die("login.chain 未产出 token（末步须 tokenFromRedirectQuery 或配合 tokenPath 单步模式）")
        return token

    def todo_tasks(self, token: str, actor: str = "") -> list[dict]:
        td = self.api.get("todo") or die("api 配置缺 todo 块")
        if td.get("mode") == "ledger":
            return self._ledger_todo(token, actor)
        params = subst(td.get("params") or {}, {})
        status, obj = self.call(td.get("method", "GET"), td.get("path", ""), params=params, token=token)
        if status != 200:
            die(f"待办查询失败: HTTP {status} {td.get('path')}")
        try:
            lst = dig(obj, td.get("listPath", "data.content"))
        except KeyError as e:
            die(f"待办列表取值失败（listPath={td.get('listPath')}）: {e}")
        if not isinstance(lst, list):
            die(f"待办 listPath 非列表: {td.get('listPath')}")
        # 值映射（第十七轮）：实录键值改写（如 stepCode task_3242→00、flowCode PRI_…→WFA_…），
        # 仅按映射表改写条目值，数据本身原样透传——映射表来自治理库/BPMN 实录。
        vmap = td.get("map") or {}
        if vmap:
            if not isinstance(vmap, dict):
                die("todo.map 非法：须为 {条目字段: {旧值: 新值}}")
            for t in lst:
                if not isinstance(t, dict):
                    continue
                for field, mapping in vmap.items():
                    if isinstance(mapping, dict) and t.get(field) in mapping:
                        t[field] = mapping[t[field]]
        return lst

    # ── 账本待办（第十七轮）：launch/submit 真实响应组装（服务端声明的任务 ID/环节码），零编造 ──
    def ledger_register(self, task_id: str, node: str, owner_display: str, instance: str, flow: str):
        # owner 存原始显示名（不做归一化——归一化在查询匹配时做，保留双向可解析性）
        self.ledger[task_id] = {"node": str(node), "owner": str(owner_display or ""),
                                "instance": str(instance), "flow": str(flow)}

    def ledger_finish(self, task_id: str):
        self.ledger.pop(task_id, None)

    def ledger_set_node(self, task_id: str, node: str):
        t = self.ledger.get(task_id) or self.task_meta.get(task_id)
        if t is not None and node:
            if task_id in self.ledger:
                self.ledger[task_id]["node"] = str(node)

    def _ledger_todo(self, token: str, actor: str) -> list[dict]:
        # owner 存原始显示名（提交时被测系统返回的办理人姓名）；此处按 显示名→登录账号 反查
        # （whoami 随各步登录逐步补全——办理人可能在本步才首次登录，故查询时再解析）。
        # 匹配规则：原始显示名与归一化显示名都建反查索引（如 常琨(公路)↔常琨）
        td = self.api.get("todo") or {}
        display_to_actor = {v: k for k, v in self.actor_display.items()}
        norm_to_actor = {norm_name(v): k for k, v in self.actor_display.items()}
        out = []
        for tid, t in self.ledger.items():
            owner_raw = t["owner"]
            if owner_raw:
                owner_actor = display_to_actor.get(owner_raw) or norm_to_actor.get(norm_name(owner_raw)) or owner_raw
                owner = norm_name(owner_actor)
                if actor and owner != actor:
                    continue
            else:
                # 空 owner（第三十五轮 operations.refetch 重登记：老系统 todo 行无办理人姓名字段）
                # → 对任意 actor 可见；实例+环节绑定仍由 find_task 强制，不构成越权面
                owner = ""
            entry = {"taskId": tid, "node": t["node"], "instanceNo": t["instance"],
                     "flowCode": t["flow"], "owner": owner}
            # 按配置路径给出键名（与 find_task 读取路径对齐；缺省=采集契约标准键）
            entry[str(td.get("taskIdPath", "taskId"))] = tid
            entry[str(td.get("nodePath", "stepCode"))] = t["node"]
            entry[str(td.get("instancePath", "flowInstanceNo"))] = t["instance"]
            if td.get("flowCodePath"):
                entry[str(td["flowCodePath"])] = t["flow"]
            out.append(entry)
        return out

    def find_task(self, token: str, node: str, wait_seconds: int, instance_no: str | None,
                  flow_code: str | None, allow_foreign: bool = False, actor: str = "",
                  selectors: dict | None = None) -> dict | None:
        """按节点找当前任务（第十三轮·实例隔离）：instance_no 已知则**强制绑定该实例**；
        todo.flowCodePath 配置时任务须属目标流程（服务端流程编码==场景 flow_code）；
        提交后下一任务可能异步可见→轮询等待。allow_foreign=False 时无实例约束绝不采信。

        v1.3.6 P0（reuse 消歧）：allow_foreign（instancePolicy=reuse 首步）时**禁止任取第一个**
        同流程同节点待办——必须恰一命中；多候选一律 BLOCKED。场景可提供 instanceNo/
        businessKey/fixtureSelector 选择器消歧（businessKey/fixtureSelector 的待办字段路径由
        systems `todo.selectorPaths` 指认，缺失即 fail-closed，不猜测字段）。"""
        td = self.api.get("todo") or die("api 配置缺 todo 块")
        fc_path = td.get("flowCodePath")
        selectors = selectors or {}
        if not isinstance(selectors, dict):
            die("场景选择器非法：须为 {instanceNo|businessKey|fixtureSelector: 值}")
        sel_paths = td.get("selectorPaths") or {}
        if not isinstance(sel_paths, dict):
            die("todo.selectorPaths 非法：须为 {选择器名: 待办条目字段路径}")
        for _name in selectors:
            if _name == "instanceNo":
                continue
            if not str(sel_paths.get(_name) or "").strip():
                die(f"场景声明 {_name} 选择器，但 systems todo.selectorPaths 未配其待办字段路径——"
                    f"无法验明正身（不猜测；补 selectorPaths.{_name} 或移除该选择器）")

        def _selector_ok(t: dict) -> bool:
            for _name, _val in selectors.items():
                _p = (td.get("instancePath", "flowInstanceNo") if _name == "instanceNo"
                      else str(sel_paths[_name]))
                try:
                    if str(dig(t, _p)) != str(_val):
                        return False
                except KeyError:
                    return False
            return True

        deadline = time.time() + max(0, wait_seconds)
        while True:
            matches: list[dict] = []
            for t in self.todo_tasks(token, actor=actor):
                try:
                    if str(dig(t, td.get("nodePath", "stepCode"))) != str(node):
                        continue
                    # 实例绑定：已知实例号的任务才采信——防误操作他流程真实任务
                    if instance_no:
                        if str(dig(t, td.get("instancePath", "flowInstanceNo"))) != str(instance_no):
                            continue
                    elif not allow_foreign:
                        continue  # 未知实例且未显式允许 foreign——不采信任何裸任务
                    # 服务端流程编码绑定（配置了 flowCodePath 才可验；配置了就必须一致）
                    if fc_path:
                        try:
                            fc = str(dig(t, fc_path))
                        except KeyError:
                            continue  # 条目缺流程编码字段=无法验明正身，排除
                        if flow_code and fc != flow_code:
                            continue  # 他流程的同 node 任务——排除（防错采错标）
                    matches.append(t)
                except KeyError:
                    continue
            if selectors:
                matches = [t for t in matches if _selector_ok(t)]
            if len(matches) > 1:
                # 复用/裸查出现同流程同节点多候选——绝不任取第一个（可能提交真实生产单据）
                die(f"步骤任务匹配到 {len(matches)} 条同流程同环节候选（node={node} flow={flow_code}"
                    + (f" instance={instance_no}" if instance_no else "")
                    + "）——必须恰一命中；请提供 instanceNo/businessKey/fixtureSelector 选择器"
                      "（并在 systems todo.selectorPaths 配对应字段路径）消歧，或改用默认 launch 策略")
            if matches:
                return matches[0]
            if time.time() >= deadline:
                return None
            time.sleep(1.0)

    def launch(self, token: str, ctx: dict, flow_code: str) -> tuple[str, str | None]:
        """发起目标流程新实例（第十三轮：launch-first 必填）。元素 ID 解析优先级：
        env LAUNCH_ELEMENT_ID_<FLOW_CODE> → systems 配置 launch.elementIdEnv → 拒（不猜）。"""
        la = self.api.get("launch") or die("api 配置缺 launch 块（launch-first 策略必需）")
        el = os.environ.get(f"LAUNCH_ELEMENT_ID_{flow_code}", "")
        if not el:
            el = os.environ.get(str(la.get("elementIdEnv") or ""), "")
        if not el:
            die(f"无法解析 {flow_code} 的发起元素 ID：设 env LAUNCH_ELEMENT_ID_{flow_code}"
                f"（或 systems launch.elementIdEnv）后再跑——不猜测流程要素")
        ctx = {**ctx, "ELEMENT_ID": el, "FLOW_CODE": flow_code}  # 通用占位：launch body 可按流程引用 ${FLOW_CODE}（多流程共存时免硬编码）
        body = drop_empty(subst(la.get("body") or {}, ctx))
        status, obj = self.call(la.get("method", "POST"), la.get("path", ""), body=body, token=token)
        if status not in (200, 201):
            die(f"发起失败: HTTP {status} {la.get('path')}{body_snippet(obj)}")
        try:
            inst = str(dig(obj, la.get("instancePath", "data.flowInstanceNo")))
        except KeyError as e:
            die(f"发起响应取实例号失败（instancePath={la.get('instancePath')}）: {e}")
        task_id = None
        try:
            task_id = str(dig(obj, la.get("taskIdPath", "data.firstTaskId")))
        except KeyError:
            pass
        return inst, task_id

    def form_fields(self, token: str, task_id: str, instance_no: str = "", flow_code: str = "") -> dict:
        fm = self.api.get("form") or die("api 配置缺 form 块")
        ctx = {"TASK_ID": task_id, "INSTANCE_NO": instance_no or "", "FLOW_CODE": flow_code or ""}
        path = subst(fm.get("path", ""), {"TASK_ID": task_id})
        body = drop_empty(self._resolve(fm.get("body") or {}, ctx)) if fm.get("body") else None
        status, obj = self.call(fm.get("method", "GET"), path, body=body, token=token)
        if status != 200:
            die(f"表单采集失败: HTTP {status} {path}")
        try:
            fields = dig(obj, fm.get("fieldsPath", "data.formData"))
        except KeyError as e:
            die(f"表单字段取值失败（fieldsPath={fm.get('fieldsPath')}）: {e}")
        if not isinstance(fields, dict):
            die(f"表单 fieldsPath 非对象: {fm.get('fieldsPath')}")
        # 服务端声明的环节码/下一环节（第十七轮）：账本节点校正与选人解析的上游事实
        if fm.get("nodePath"):
            try:
                self.task_meta.setdefault(task_id, {})["node"] = str(dig(obj, fm["nodePath"]))
            except KeyError:
                pass
        if fm.get("nextStepPath"):
            try:
                self.task_meta.setdefault(task_id, {})["nextStep"] = str(dig(obj, fm["nextStepPath"]))
            except KeyError:
                pass
        return fields

    def assignee_candidates(self, token: str, task_id: str, ctx: dict):
        """办理人候选原始行 + 路由发现（第二十一轮解析逻辑的提取；v1.4.0 起探索器
        explore-channel 共用这一实现——禁止另写一套候选获取）。

        返回 (rows, wb_nodes, node_code)：
          rows      候选行列表（None=未取到——调用方自行决定兜底，原值透传语义不变）
          wb_nodes  next-assignees 解析器的 workbench nextNodes 原始列表（orgrole=None）
          node_code 本次解析实际使用的下一节点码（显式 NEXT_NODE > 服务端单值声明 > workbench 唯一候选）
        resolver 未配置 → (None, None, "")。"""
        asg = self.api.get("assignee") or {}
        resolver = str(asg.get("resolver", "") or "")
        if not resolver:
            return None, None, ""
        meta = self.task_meta.get(task_id) or {}
        # 下一节点码优先级（第二十轮实测反哺）：场景显式 expectNext（NEXT_NODE，多候选节点
        # 的路由选择即测试语义）> 服务端表单声明（单值才可用——多候选串如 "01,02,03" 不能
        # 直接作查询键）。此前服务端多候选串覆盖场景显式值 → 解析必失败 → 原姓名透传 → 提交 500
        explicit_node = str(ctx.get("NEXT_NODE") or "").strip()
        declared = str(meta.get("nextStep") or "").strip()
        declared_single = declared if (declared and "," not in declared) else ""
        node_code = explicit_node or declared_single
        rctx = {**ctx, "TASK_ID": task_id,
                "NEXT_NODE": node_code or declared,
                "INSTANCE_NO": str(ctx.get("INSTANCE_NO") or ""), "FLOW_CODE": str(ctx.get("FLOW_CODE") or "")}
        try:
            if resolver == "next-assignees":
                wb_path = subst(str(asg.get("workbenchPath", "/engine/flow/task/${TASK_ID}/workbench")),
                                {"TASK_ID": task_id})
                _st, wb, _h, _t = self.call_full("GET", wb_path, token=token)
                wb_nodes = dig(wb, asg.get("nextNodesPath", "data.nextNodes")) if wb else []
                if not isinstance(wb_nodes, list):
                    wb_nodes = []
                if not node_code:
                    if len(wb_nodes) != 1:
                        return None, wb_nodes, node_code  # 多分支/无路由且场景未指明：fail-closed 不解析（原值透传）
                    node_code = str(wb_nodes[0].get(asg.get("nodeCodeField", "taskElementId")) or "")
                    rctx["NEXT_NODE"] = node_code
                cand_body = drop_empty(self._resolve(asg.get("candidatesBody") or {"nodeCode": "${NEXT_NODE}", "formPatch": {}}, rctx))
                _st, cand, _h, _t = self.call_full(
                    "POST", subst(str(asg.get("candidatesPath", "/engine/flow/task/${TASK_ID}/next-assignees")),
                                  {"TASK_ID": task_id}), body=cand_body, token=token)
                rows = cand
                if asg.get("candidatesListPath"):
                    try:
                        rows = dig(cand, asg["candidatesListPath"])
                    except KeyError:
                        rows = None
                if isinstance(rows, list) and not rows and node_code:
                    # routeCode→taskElementId 回退（编码翻译全部来自服务端 workbench 声明，非猜测）：
                    # DMN 路由流程（港口煤 WFA_RY_JM_126001，2026-09-08 实测）submit.nextStep 只认
                    # routeCode（环节码）而 next-assignees.nodeCode 只认 taskElementId——两码空间不对称。
                    _alt = ""
                    for _nd in wb_nodes:
                        if not isinstance(_nd, dict):
                            continue
                        if str(_nd.get("routeCode") or "") == node_code:
                            _alt = str(_nd.get(asg.get("nodeCodeField", "taskElementId")) or "")
                            break
                    if _alt and _alt != node_code:
                        node_code = _alt
                        rctx["NEXT_NODE"] = _alt
                        cand_body = drop_empty(self._resolve(asg.get("candidatesBody") or {"nodeCode": "${NEXT_NODE}", "formPatch": {}}, rctx))
                        _st, cand, _h, _t = self.call_full(
                            "POST", subst(str(asg.get("candidatesPath", "/engine/flow/task/${TASK_ID}/next-assignees")),
                                          {"TASK_ID": task_id}), body=cand_body, token=token)
                rows = cand
                if asg.get("candidatesListPath"):
                    try:
                        rows = dig(cand, asg["candidatesListPath"])
                    except KeyError:
                        rows = None
                return rows, wb_nodes, node_code
            elif resolver == "orgrole":
                cand_body = drop_empty(self._resolve(asg.get("candidatesBody") or {}, rctx))
                if not cand_body:
                    die("assignee.resolver=orgrole 须配置 candidatesBody 模板（含 NEXT_NODE/FLOW_CODE/WorkflowFlag）")
                _st, cand, _h, _t = self.call_full("POST", str(asg.get("candidatesPath", "")), body=cand_body, token=token)
                rows = cand
                if asg.get("candidatesListPath"):
                    try:
                        rows = dig(cand, asg["candidatesListPath"])
                    except KeyError:
                        rows = None
                return rows, None, node_code
            else:
                die(f"assignee.resolver 未知: {resolver!r}（支持 next-assignees / orgrole）")
        except ConnectionError:
            raise
        except SystemExit:
            raise
        except Exception as e:
            die(f"办理人候选获取异常（resolver={resolver}）: {type(e).__name__}: {e}")

    def resolve_assignee(self, token: str, task_id: str, assignee: str, ctx: dict):
        """办理人姓名→ID 服务端实时解析（第二十一轮，本次双端试点反哺：新系统 next-assignees、
        老系统 getUserByOrgRoleNew 两种形态）。候选集全部来自被测系统实时响应；
        解析失败返回 (None, None)——原值透传，由被测系统自行判定（不猜测）。
        v1.4.0：候选获取提取为 assignee_candidates（与探索器共用同一实现）。"""
        asg = self.api.get("assignee") or {}
        if not str(asg.get("resolver", "") or "") or not assignee:
            return None, None
        rows, _wb_nodes, _node_code = self.assignee_candidates(token, task_id, ctx)
        if not isinstance(rows, list):
            return None, None
        nf = str(asg.get("nameField", "name"))
        want = norm_name(assignee)
        matches = [
            (it.get(str(asg.get("idField", "id"))), str(it.get(nf)))
            for it in rows
            if isinstance(it, dict)
            and (norm_name(it.get(nf)) == want or str(it.get(nf, "")).strip() == str(assignee).strip())
        ]
        if not matches:
            return None, None
        if len(matches) == 1:
            return matches[0]
        # 同名多候选（老系统真实存在：如 3 个「侯丽娟」user_id 3599/3600/3601）——
        # 盲取首个会派错人 → 后继办理人 500「没有权限处理该环节实例」（2026-09-08 港口煤实测）。
        # 须 systems assignee.prefer_ids（归一化姓名 → 实值 ID，源自被测系统 whoami 探针）指认；
        # 无指引 = fail-closed 返回 None（原值透传由被测系统判定），绝不猜测。
        prefer = asg.get("prefer_ids") or {}
        pid = prefer.get(want, prefer.get(str(assignee).strip()))
        if pid is not None:
            for uid_, nm_ in matches:
                if str(uid_) == str(pid):
                    return uid_, nm_
        return None, None

    def _business_failed(self, ob) -> bool:
        """业务失败谓词（审计第 5 轮 P0-1）：响应体带 `success` 键但值 ∉ successValues → 失败。
        此前只认 `success is False`——success:0/"false"/"0"/""/None 等 falsy 变体被当成功
        （HTTP 2xx 假成功面）。默认严格：仅布尔 True 算成功；systems `api.submit.successValues`
        可配置（如 [true, 1, "true"]，供确以 1/"true" 表成功的系统）。键不存在 → False（由
        HTTP 状态决定，与既有口径一致）。"""
        if not isinstance(ob, dict) or "success" not in ob:
            return False
        sm = self.api.get("submit") if isinstance(self.api.get("submit"), dict) else {}
        sv = sm.get("successValues") if isinstance(sm, dict) else None
        if not isinstance(sv, list) or not sv:
            # 未配置=严格恒等（审计第 5 轮 P2-1）：仅布尔 True 算成功——`1 == True` 的 Python
            # 陷阱使 `in [True]` 会放行 success:1/1.0，与 docstring"默认仅布尔 True"不符
            return ob.get("success") is not True
        return ob.get("success") not in sv

    def submit(self, token: str, task_id: str, ctx: dict) -> None:
        # 第三十五轮（v1.3.5）：按钮语义原语——step.button 命中 api.operations[<BUTTON>] 时
        # 改发该按钮的专属端点（老系统退回=backWorkflow、作废=cancelWorkflow，与统一提交端点
        # commitWorkflow 不同），不再把退回/作废编码成 next_step 走提交（会被老系统拒
        # 「所选环节并不可用范围」——2026-09-10 铁路 C-03/04/06/07 实测根因）。
        # 配置驱动、通道自持（守护规则 5）：不新增执行器，只是 submit 的端点路由扩展。
        btn0 = str(ctx.get("BUTTON") or "")
        ops = self.api.get("operations")
        if btn0 and ops is not None:
            if not isinstance(ops, dict):
                die(f"api.operations 须为 {{BUTTON: 配置对象}} 映射（收到 {type(ops).__name__}）")
            if btn0 in ops:
                # v1.3.6 P0：命中键但配置非法必须拒绝，禁止静默回退统一 submit（v1.3.5 错误路径）
                probs = ftc_ops_config.validate_operation_entry(btn0, ops.get(btn0))
                if probs:
                    die(f"operations[{btn0!r}] 命中但配置非法（拒绝回退统一 submit）：\n  - "
                        + "\n  - ".join(probs))
                self._submit_operation(token, task_id, ctx, btn0, ops[btn0])
                return
        sm = self.api.get("submit") or die("api 配置缺 submit 块")
        path = subst(sm.get("path", ""), {"TASK_ID": task_id})
        body = drop_empty(subst(sm.get("body") or {}, ctx))
        # 第二十轮：route_map 原生映射（场景 nextStep 老编码 → 目标系统真实路由码）
        body = apply_route_map(body, self.api.get("route_map"), str(ctx.get("FLOW_CODE") or ""))
        # 第二十一轮：业务表单数据透传（场景 step.formData → body.formData；通道适配层
        # 决定其在真实提交体中的载体——新系统原生 formData，老系统桥映射 instObj）
        # 第二十二轮：formData 字符串值经 subst 解析（${TODAY}/${NOW} 等声明式日期上下文）
        if isinstance(ctx.get("_FORM_DATA"), dict) and ctx["_FORM_DATA"]:
            _fd = {k: (subst(v, ctx) if isinstance(v, str) else v) for k, v in ctx["_FORM_DATA"].items()}
            body["formData"] = _fd  # execute-button 请求的 formData(Map) → completeTask formPatch
            # 注意：老系统 commitWorkflow 的表单值走独立保存接口（instObj 保持模板原值），
            # 在此注入会导致服务端 500「当前操作反馈异常结果」（2026-09-08 实测）
        elif sm.get("echo_form_patch") and isinstance(ctx.get("_ECHO_FORM"), dict) and ctx["_ECHO_FORM"]:
            # 整体回显（echo_form_patch 系统开关）：无场景填单的步骤（审核/盖章链）把 workbench
            # 采集到的当前业务表单数据原样作为 formData 提交——引擎对空 formPatch 一律按
            # 「必填字段未填写」阻断（BuiltinButtonDispatcher.formPatch(req.getFormData()) →
            # TaskFormValidationSupport.validateFormSchema），浏览器同构做法即整体回显。
            body["formData"] = dict(ctx["_ECHO_FORM"])

        def _post(bd):
            """发一次提交；返回 (status, obj, text)——retryOn 需要读响应体文案。"""
            st, ob, _h, tx = self.call_full(sm.get("method", "POST"), path, body=bd, token=token)
            return st, ob, tx

        ok = [int(x) for x in (sm.get("successStatus") or [200, 201])]

        def _resp_bad(st, ob) -> bool:
            """正式提交口径的响应校验（HTTP 状态 + 业务失败谓词）——预保存/提交共用。"""
            return st not in ok or self._business_failed(ob)

        # 第二十三轮：save_with_form_data——场景步携带 formData 时先发保存按钮再提交。
        # 新系统 execute-button 的 SUBMIT 不落业务表单（引擎按已保存 revision 校验必填），
        # 同构浏览器「保存单据→提交流程」两步；港口煤 00 发起步实测必需（2026-09-08）。
        # v1.3.6 P0：预保存此前**完全忽略返回状态**（实测 SAVE_FORM→HTTP 500 仍继续 SUBMIT 并
        # 报成功=假 PASS）。现复用正式提交的 HTTP 状态/业务状态校验，失败即 die、禁止发 SUBMIT。
        pre_save = str(sm.get("save_with_form_data") or "")
        if pre_save and isinstance(ctx.get("_FORM_DATA"), dict) and ctx["_FORM_DATA"]:
            pre_body = {k: v for k, v in body.items() if k != "nextAssigneeId"}
            pre_body["buttonCode"] = pre_save  # formData(Map) 原样透传，分发器转 command JSON 串
            pst, pobj, _ptext = _post(pre_body)
            if _resp_bad(pst, pobj):
                die(f"步骤 s{ctx.get('_seq') or '?'}（节点 {ctx.get('NODE')}）表单预保存失败"
                    f"（save_with_form_data={pre_save}）: HTTP {pst} {path}{body_snippet(pobj)}"
                    f"——预保存未通过，禁止继续 SUBMIT（防场景输入未落库却形成假 PASS）")

        status, obj, text = _post(body)
        # 第二十一轮（本次双端试点反哺）：retryOn 自适应前置——引擎明确报「messageContains」时
        # 先补一次 preButton（剥选人键，典型 SAVE_FORM 创建单据 revision）再重试原提交一次。
        # 只在引擎明确报该错时触发（不乱建 revision 使盖章链上节点文件失效）。
        # 第二十三轮：retryOn 支持列表（多个 messageContains→preButton 对，按序尝试）——
        # 港口煤引擎在 SUBMIT 校验「表单存在必填字段未填写」（校验已保存 revision 而非本次载荷），
        # 同构浏览器「保存单据→提交流程」：SAVE_FORM（携 formData）后重试 SUBMIT（2026-09-08 实测）。
        ro = sm.get("retryOn") or {}
        rules = ro if isinstance(ro, list) else ([ro] if isinstance(ro, dict) and ro.get("messageContains") else [])
        if status not in ok:
            for rule in rules:
                if not (isinstance(rule, dict) and rule.get("messageContains") and rule.get("preButton")):
                    continue
                if str(rule["messageContains"]) in (text or ""):
                    pre_body = {k: v for k, v in body.items() if k != "nextAssigneeId"}
                    pre_body["buttonCode"] = str(rule["preButton"])
                    _st, _ob, _tx = _post(pre_body)
                    # 审计第 5 轮 P0-1：前置按钮结果此前被忽略（_st/_ob 丢弃）——前置 SAVE 失败、
                    # 重试 SUBMIT 返回 200 时仍报成功（revision 未落库=假 PASS）。现复用 _resp_bad，
                    # 前置失败即 die，禁止重试 SUBMIT。
                    if _resp_bad(_st, _ob):
                        die(f"步骤 s{ctx.get('_seq') or '?'}（节点 {ctx.get('NODE')}）retryOn 前置按钮"
                            f" {rule['preButton']!r} 失败: HTTP {_st} {path}{body_snippet(_ob)}"
                            f"——前置未通过，禁止重试 SUBMIT（防 revision 未落库却形成假 PASS）")
                    status, obj, text = _post(body)
                    if status in ok and not self._business_failed(obj):
                        break
        if status not in ok:
            die(f"步骤 s{ctx.get('_seq') or '?'}（节点 {ctx.get('NODE')}）办理提交失败: HTTP {status} {path}"
                f"（button={ctx.get('BUTTON')!r}）{body_snippet(obj)}")
        # 第二十轮（实测反哺）：业务失败穿透检测——此前 HTTP 2xx 但响应体 success=false
        # 被静默判成功，下一步"找不到任务"误导排查方向；现显式报错并附响应体片段
        # （审计第 5 轮 P0-1：判定收严为 _business_failed 谓词——success:0/"false"/""/None 同为失败）
        if self._business_failed(obj):
            die(f"步骤 s{ctx.get('_seq') or '?'}（节点 {ctx.get('NODE')}）办理提交业务失败: HTTP {status} {path}"
                f"（button={ctx.get('BUTTON')!r}）{body_snippet(obj)}")
        # 第二十一轮：账本模式——从提交响应登记下一任务（服务端返回的任务 ID；
        # 环节码=表单响应 autoflowStep.nextStep 服务端声明；owner=解析后的办理人显示名）
        if (self.api.get("todo") or {}).get("mode") == "ledger":
            meta = self.task_meta.get(task_id) or {}
            # 登记节点码：场景显式 expectNext（已按 route_map 映射）优先；服务端声明仅在
            # 单值时可用——多候选串（如 "01,02,03"）直接登记会让下一步 find_task 永远失配
            # （2026-09-08 铁路 00 节点实测）
            declared_ns = str(meta.get("nextStep") or "")
            next_step = str(ctx.get("NEXT_NODE") or "") or (declared_ns if "," not in declared_ns else "")
            if next_step and self.ledger_next_task_path:
                try:
                    nxt = str(dig(obj, self.ledger_next_task_path))
                except KeyError:
                    nxt = ""
                if nxt:
                    self.ledger_register(nxt, next_step, str(ctx.get("ASSIGNEE_NAME") or ""),
                                         str(ctx.get("INSTANCE_NO") or ""), str(ctx.get("FLOW_CODE") or ""))
            self.ledger_finish(task_id)

    def _submit_operation(self, token: str, task_id: str, ctx: dict, btn: str, op: dict) -> None:
        """按钮语义原语执行体（第三十五轮 v1.3.5）。op 形状（systems legacy.yaml）：
          operations:
            <BUTTON>:
              method/path/body/successStatus        # 同 submit 原语约定；body 模板可用
                                                    # ${INSTANCE_NO}/${TASK_ID}/${BACK_NODE}/${BACK_TARGET}
              backTarget:                           # 退回目标解析器（body 引用 ${BACK_TARGET} 时必配）
                path/body/listPath/nodeField/idField
              ledger: finish | refetch              # finish=完结当前任务；refetch=重登记退回目标新任务
              refetch: path/body/listPath/taskIdField/nodeField/instanceField/pollSeconds?
        v1.3.6 fail-closed：完整 schema 在发出任何请求（写或读）**之前**校验（共享
        ftc_ops_config）——形状缺项/ledger 非法/refetch 缺块/目标多候选/标量空值一律 die，
        绝不先退回再发现配置不完整、绝不盲发盲登；refetch 支持 pollSeconds 有限轮询。"""
        # v1.3.6 P0：完整 schema 校验前置——任何网络请求（写或读）之前完成；命中键但配置非法
        # 一律 die（绝不先发 backWorkflow 再发现 refetch 缺失、或回退统一 submit）。
        probs = ftc_ops_config.validate_operation_entry(btn, op)
        if probs:
            die(f"operations[{btn!r}] 配置非法（在发出任何请求前拒绝）：\n  - " + "\n  - ".join(probs))
        # BACK_NODE：场景 expectNext 去括号（"19(退回)" → "19"）——退回/撤回目标环节码
        m = re.match(r"[A-Za-z0-9_\-]+", str(ctx.get("NEXT_NODE") or ""))
        back_node = m.group(0) if m else ""
        ctx = {**ctx, "BACK_NODE": back_node}
        body_tpl = op.get("body") or {}
        bt = op.get("backTarget")
        # 标量守卫（v1.3.6 P0）：模板引用 ${BACK_NODE} 或配置了 backTarget 时，退回目标环节码
        # 必须为非空有效标量——拒绝把空/None 传给服务端定位目标。
        try:
            _uses_back_node = ("${BACK_NODE}" in json.dumps(body_tpl, ensure_ascii=False)
                               or (isinstance(bt, dict)
                                   and "${BACK_NODE}" in json.dumps(bt.get("body") or {}, ensure_ascii=False)))
        except Exception:
            _uses_back_node = False
        if (isinstance(bt, dict) or _uses_back_node) and not ftc_ops_config.is_valid_scalar(back_node):
            die(f"operations[{btn!r}] 退回目标环节码 BACK_NODE 解析为空/非法标量"
                f"（NEXT_NODE={ctx.get('NEXT_NODE')!r}）——无法定位退回目标环节，拒绝")
        # 审计第 5 轮 P0-1：ledger=refetch 的定位键（BACK_NODE/INSTANCE_NO/task_id）必须在**任何
        # 写请求之前**验证——此前 /backWorkflow 已发出、才在 refetch 处因空 BACK_NODE 拒绝
        # （生产已退回、本地才报错=不可回滚的写泄漏）。
        led_early = str(op.get("ledger") or "finish")
        if led_early == "refetch":
            _inst_early = str(ctx.get("INSTANCE_NO") or "")
            if (not ftc_ops_config.is_valid_scalar(back_node)
                    or not ftc_ops_config.is_valid_scalar(_inst_early)
                    or not ftc_ops_config.is_valid_scalar(task_id)):
                die(f"operations[{btn!r}] ledger=refetch 定位键非法（BACK_NODE={back_node!r} "
                    f"INSTANCE_NO={_inst_early!r} task_id={task_id!r}）——任何写请求前拒绝："
                    f"绝不先退回/作废再发现无法重登记退回后任务")
        # backTarget 解析器：退回目标步实例（实例绑定 + 恰一命中，多候选=诚实失败）
        if isinstance(bt, dict):
            want = back_node
            st, obj = self.call(bt.get("method", "POST"), subst(str(bt["path"]), ctx),
                                body=drop_empty(subst(bt.get("body") or {}, ctx)), token=token)
            if st not in (200, 201) or self._business_failed(obj):
                die(f"operations[{btn!r}].backTarget 查询失败: HTTP {st} {body_snippet(obj)}")
            try:
                rows = dig(obj, str(bt["listPath"]))
            except KeyError as e:
                die(f"operations[{btn!r}].backTarget listPath 取列表失败: {e}")
            hits = [r for r in (rows or []) if isinstance(r, dict)
                    and str(r.get(str(bt["nodeField"]))) == want]
            if len(hits) != 1:
                die(f"operations[{btn!r}].backTarget 目标环节 {want!r} 命中 {len(hits)} 条（须恰好 1 条）"
                    f"——不猜测退回目标（重办产生多候选时应改用精确 stepInstCode 指认）")
            target_id = hits[0].get(str(bt["idField"]))
            if not ftc_ops_config.is_valid_scalar(target_id):
                die(f"operations[{btn!r}].backTarget 命中行缺有效 {bt['idField']!r} 值"
                    f"（实际 {target_id!r}）——拒绝发送 'None' 类占位给老系统")
            ctx = {**ctx, "BACK_TARGET": str(target_id)}
        body = drop_empty(subst(body_tpl, ctx))
        path = subst(str(op.get("path") or die(f"operations[{btn!r}] 缺 path")), ctx)
        status, obj = self.call(op.get("method", "POST"), path, body=body, token=token)
        ok = [int(x) for x in (op.get("successStatus") or [200, 201])]
        if status not in ok or self._business_failed(obj):
            die(f"步骤 s{ctx.get('_seq') or '?'}（节点 {ctx.get('NODE')}）operations[{btn!r}] 提交失败: "
                f"HTTP {status} {path} {body_snippet(obj)}")
        # 账本：finish=完结当前任务（作废/终态语义）；refetch=按 todo 列表重登记退回目标新任务
        led = str(op.get("ledger") or "finish")
        if led not in ftc_ops_config.LEDGER_VALUES:
            die(f"operations[{btn!r}].ledger={led!r} 非法（只认 finish/refetch）")  # 前置已拦，防御性保留
        self.ledger_finish(task_id)
        if led == "refetch":
            rf = op.get("refetch")
            want_node = back_node
            inst = str(ctx.get("INSTANCE_NO") or "")
            if not ftc_ops_config.is_valid_scalar(want_node) or not ftc_ops_config.is_valid_scalar(inst):
                die(f"operations[{btn!r}].refetch 定位键非法（instance={inst!r} node={want_node!r}）"
                    f"——无法在 todo 列表中恰一定位退回后新任务")
            poll_seconds = int((rf or {}).get("pollSeconds") or 0)
            deadline = time.time() + max(0, poll_seconds)
            while True:  # v1.3.6：有限轮询——操作成功但退回后任务异步可见时不立即 BLOCKED
                st, obj = self.call(rf.get("method", "POST"), subst(str(rf["path"]), ctx),
                                    body=drop_empty(subst(rf.get("body") or {}, ctx)), token=token)
                if st not in (200, 201) or self._business_failed(obj):
                    die(f"operations[{btn!r}].refetch 查询失败: HTTP {st} {body_snippet(obj)}")
                try:
                    rows = dig(obj, str(rf["listPath"]))
                except KeyError as e:
                    die(f"operations[{btn!r}].refetch listPath 取列表失败: {e}")
                hits = [r for r in (rows or []) if isinstance(r, dict)
                        and str(r.get(str(rf["instanceField"]))) == inst
                        and str(r.get(str(rf["nodeField"]))) == want_node]
                if len(hits) > 1:
                    die(f"operations[{btn!r}].refetch 退回目标新任务命中 {len(hits)} 条"
                        f"（instance={inst} node={want_node}，须恰好 1 条）——诚实失败，绝不盲登账本")
                if len(hits) == 1:
                    break
                if time.time() >= deadline:
                    die(f"operations[{btn!r}].refetch 退回目标新任务命中 0 条"
                        f"（instance={inst} node={want_node}，轮询 {poll_seconds}s 后仍未出现）"
                        f"——诚实失败，绝不盲登账本（异步可见慢可调 refetch.pollSeconds）")
                time.sleep(1.0)
            new_task_id = hits[0].get(str(rf["taskIdField"]))
            if not ftc_ops_config.is_valid_scalar(new_task_id):
                die(f"operations[{btn!r}].refetch 命中行缺有效 {rf['taskIdField']!r} 值"
                    f"（实际 {new_task_id!r}）——拒绝登记 'None' 类占位任务 ID")
            # owner 留空：todo 行无办理人姓名字段；空 owner 条目对任意 actor 可见（实例+环节绑定保隔离）
            self.ledger_register(str(new_task_id), want_node, "", inst, str(ctx.get("FLOW_CODE") or ""))
        print(f"[api-capture] s{ctx.get('_seq') or '?'} 节点{ctx.get('NODE')} 按钮原语 {btn} 提交 ✓")


PLACEHOLDER = "__F12_RECORD__"


def _contains_placeholder(obj) -> bool:
    """解析值递归扫描占位符（与 legacy-config-check 同规则：只认配置值，不认注释文本）。"""
    if isinstance(obj, str):
        return PLACEHOLDER in obj
    if isinstance(obj, dict):
        return any(_contains_placeholder(v) for v in obj.values())
    if isinstance(obj, list):
        return any(_contains_placeholder(v) for v in obj)
    return False


def load_scenario(p: Path) -> dict:
    try:
        sc = yaml.safe_load(p.read_text(encoding="utf-8")) or {}
    except Exception as e:
        die(f"场景不可读 {p}: {e}")
    if not isinstance(sc, dict) or not sc.get("steps"):
        die(f"场景缺 steps: {p}")
    return sc


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--systems", required=True, help="systems api 配置（YAML，如 <runtime>/systems/api/current.yaml）")
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--exec-dir", required=True)
    args = ap.parse_args()

    try:
        cfg = yaml.safe_load(Path(args.systems).read_text(encoding="utf-8")) or {}
    except Exception as e:
        die(f"systems 配置不可读 {args.systems}: {e}")
    side = str(cfg.get("id") or "").strip()
    if not side:
        die(f"systems 配置缺 id（侧名决定 captures 子目录）: {args.systems}")
    if cfg.get("channel") != "api":
        die(f"channel={cfg.get('channel')!r} 非 api——本采集器只执行 api 通道（浏览器通道不在本脚本职责内）")
    # 第十五轮审计（P1）：占位检测口径与 legacy-config-check 统一为**解析后配置值**扫描
    # （原始文本扫描会把"注释里提到占位符字样"也误判为残留——如 legacy.yaml 头部说明注释；
    # 注释不是运行值，两者规则必须一致：值含 __F12_RECORD__ 才拒）
    if _contains_placeholder(cfg):
        die(f"systems 配置 {args.systems} 含 F12 录端点占位符 __F12_RECORD__（旧系统端点待人工录）"
            "——运行 python3 $SKILL/scripts/legacy-config-check.py --systems <path> 查看待录清单"
            "并按 references/f12-record.md 录完所有端点（占位全部替换后）再跑")

    actors = cfg.get("actorMap") or {}
    if not isinstance(actors, dict) or not actors:
        die("systems 配置缺 actorMap（actor → {username/password 环境变量名}）")

    sc = load_scenario(Path(args.scenario))
    case_id = str(sc.get("case_id") or sc.get("id") or Path(args.scenario).stem)
    # flow_code 推导：优先场景显式声明；否则按 gen 规则 id=<flow_code>-<case_id 小写> 剥用例后缀
    # （用例号自身含连字符——不能盲 rsplit：WFA_X_0001-c-01 的流程码是 WFA_X_0001 而非 WFA_X_0001-c）
    sid = str(sc.get("id") or "")
    if sc.get("flow_code"):
        flow_code = str(sc["flow_code"])
    elif sid.lower().endswith("-" + case_id.lower()):
        flow_code = sid[: -(len(case_id) + 1)]
    else:
        flow_code = sid.rsplit("-", 1)[0]
    api = Api(cfg.get("api") or die("systems 配置缺 api 块"))
    wait_s = int((cfg.get("api") or {}).get("taskWaitSeconds", 15))
    # v1.3.6 P0：api.operations 完整 schema 校验前置——在任何登录/发起/提交之前统一执行。
    # 与 legacy-config-check.py 共用同一实现（scripts/ftc_ops_config.py）：命中键但配置非法
    # （缺 path/refetch/backTarget、ledger 拼写错、successStatus 非法等）在这里即 BLOCKED，
    # 绝不会先发生产写请求（backWorkflow/cancelWorkflow）再回头发现配置不完整。
    _ops_problems = ftc_ops_config.validate_operations((cfg.get("api") or {}).get("operations"))
    if _ops_problems:
        die("systems api.operations 配置非法（在任何登录/发起/提交前拒绝，禁止回退统一 submit）：\n  - "
            + "\n  - ".join(_ops_problems))
    # 审计第 5 轮 P2-3：submit.successValues 若配置须为非空列表（业务成功值白名单）——
    # 类型非法即拒，不静默回退默认口径（配置错误被静默吞掉=fail-open）
    _sv5 = ((cfg.get("api") or {}).get("submit") or {}).get("successValues") \
        if isinstance((cfg.get("api") or {}).get("submit"), dict) else None
    if _sv5 is not None and (not isinstance(_sv5, list) or not _sv5):
        die(f"api.submit.successValues 配置非法: {_sv5!r}（须为非空列表，如 [true, 1, 'true']）")
    # 实例策略（第十三轮·实例隔离）：默认 launch——每 run 发起本流程新实例，绝不碰他流程任务；
    # reuse 仅当契约 meta.instance_policy 显式声明（场景 instancePolicy 随之生成）才允许
    policy = str(sc.get("instancePolicy") or "launch").strip().lower()
    if policy not in ("launch", "reuse"):
        die(f"场景 instancePolicy 非法: {policy!r}（只认 launch/reuse——由契约 meta.instance_policy 生成）")
    td = (cfg.get("api") or {}).get("todo") or {}
    # reuse（显式声明）也必须能验明任务流程身份：todo.flowCodePath 缺失 → 拒（防盲取他流程任务）
    if policy == "reuse" and not td.get("flowCodePath"):
        die("场景 instancePolicy=reuse 但 systems todo 缺 flowCodePath——复用待办必须能按服务端流程编码"
            "验明正身（防采到他流程的同 node 任务）；请补 todo.flowCodePath 或改用默认 launch 策略")
    # v1.3.6 P0（reuse 消歧）：场景可提供实例号/业务键/fixture 选择器——find_task 据此在
    # 同流程同节点多候选中恰一定位；无选择器且多候选 → BLOCKED（绝不任取第一个真实生产单据）。
    _selectors: dict[str, str] = {}
    for _dst, _keys in (("instanceNo", ("instanceNo", "instance_no")),
                        ("businessKey", ("businessKey", "business_key")),
                        ("fixtureSelector", ("fixtureSelector", "fixture_selector"))):
        for _k in _keys:
            _v = sc.get(_k)
            if isinstance(_v, dict):
                # 审计第 5 轮 P1-3：分侧映射 {legacy: ..., current: ...}——双端业务键不同时
                # 按本侧（systems id）取值；缺本侧键=诚实拒绝（不跨侧借用）
                _side_v = _v.get(side)
                if isinstance(_side_v, str) and _side_v.strip():
                    _selectors[_dst] = _side_v.strip()
                elif _side_v is not None:
                    die(f"场景 {_k} 分侧映射中本侧（{side}）值非法: {_side_v!r}")
                else:
                    die(f"场景 {_k} 为分侧映射但缺本侧（{side}）键——双端业务键不同须两侧都给"
                        f"（防错拿他侧业务键复用待办）")
                break
            if _v is not None and str(_v).strip() not in ("", "None", "null"):
                _selectors[_dst] = str(_v)
                break

    steps_out: dict[str, dict] = {}
    task_ids: dict[str, str] = {}
    instance_no: str | None = None
    if policy == "reuse" and _selectors.get("instanceNo"):
        instance_no = _selectors["instanceNo"]  # reuse 显式实例号：直接建立实例绑定
    for st in sc["steps"]:
        if not isinstance(st, dict):
            die("场景 steps 存在非对象条目")
        seq, node = st.get("seq"), st.get("node")
        actor = st.get("actorAccount") or st.get("actor")
        if seq is None or node is None or not actor:
            die(f"步骤缺 seq/node/actorAccount: {st!r}")
        if str(node).strip() in ("", "-", "None"):  # 观察步：无流程任务，不采集不提交
            steps_out[f"s{seq}"] = {"fields": {}, "observation": True}
            print(f"[api-capture] {side} s{seq} 观察步（node 空）跳过采集/提交")
            continue
        amap = actors.get(str(actor))
        if not isinstance(amap, dict):
            die(f"actor {actor!r} 不在 actorMap——补 systems 配置后再跑")
        try:
            username, password = ftc_env.resolve_credentials(
                args.systems, str(actor),
                str(amap.get("username") or ""), str(amap.get("password") or ""),
                warn=lambda m: print(f"[api-capture] {m}"))
        except ftc_env.CredentialError as e:
            die(str(e))
        token = api.login(str(actor), username, password)

        first = not steps_out
        task_id_hint: str | None = None
        if first and policy == "launch":
            # launch-first（默认）：先发起本流程新实例再取首任务——instance_no 由此建立，
            # 此后每步强制绑定该实例，天然不可能采到他流程的同 node 真实任务
            instance_no, task_id_hint = api.launch(token, {"USERNAME": username, "PASSWORD": password}, flow_code)
            # 账本模式：登记启动任务（owner=发起人；节点=todo.firstNode，提交前由表单响应 nodePath 校正）
            if (td.get("mode") == "ledger") and task_id_hint:
                api.ledger_register(task_id_hint, str(td.get("firstNode", "00")),
                                    api.actor_display.get(str(actor), str(actor)),
                                    str(instance_no), flow_code)

        # 任务查找：launch 后/reuse 后继步一律绑定 instance_no（allow_foreign=False 不采信裸任务）；
        # reuse 首步允许在待办中找——但须 todo.flowCodePath 可验流程身份，否则 find_task 恒无果
        allow_foreign = bool(first and policy == "reuse")
        task = api.find_task(token, str(node), wait_s, instance_no, flow_code,
                             allow_foreign=allow_foreign, actor=str(actor),
                             selectors=(_selectors if allow_foreign else None))
        task_id = task_id_hint
        if task is None and task_id is None:
            die(f"步骤 s{seq}（节点 {node}，actor {actor}）找不到任务"
                + (f"（实例 {instance_no}，流程 {flow_code}）" if instance_no else f"（流程 {flow_code}）")
                + ("——reuse 策略要求待办带流程编码（todo.flowCodePath）且存在该流程待办"
                   if (allow_foreign and not td.get("flowCodePath"))
                   else ""))
        if task_id is None:
            try:
                _tid_raw = dig(task, td.get("taskIdPath", "taskId"))
            except KeyError as e:
                die(f"待办条目取 taskId 失败: {e}")
            if not ftc_ops_config.is_valid_scalar(_tid_raw):
                die(f"待办条目 taskId 非有效标量（{_tid_raw!r}）——拒绝以 'None' 类占位提交")
            task_id = str(_tid_raw)
        if instance_no is None and task is not None:
            # reuse 首步：从待办条目取实例号并建立绑定（取不到=实例身份缺失，不采信）
            try:
                _inst_raw = dig(task, td.get("instancePath", "flowInstanceNo"))
            except KeyError as e:
                die(f"待办条目取实例号失败（instancePath={td.get('instancePath')}）: {e}"
                    "——实例身份缺失不可采信")
            if not ftc_ops_config.is_valid_scalar(_inst_raw):
                die(f"待办条目实例号非有效标量（{_inst_raw!r}）——实例身份缺失不可采信")
            instance_no = str(_inst_raw)

        fields = api.form_fields(token, task_id, instance_no=instance_no or "", flow_code=flow_code)
        steps_out[f"s{seq}"] = {"fields": fields}
        task_ids[f"s{seq}"] = task_id

        # 账本模式：以表单响应的服务端声明校正本任务环节码（nodePath）
        if td.get("mode") == "ledger":
            meta = api.task_meta.get(task_id) or {}
            if meta.get("node"):
                api.ledger_set_node(task_id, str(meta["node"]))

        ctx = {
            "USERNAME": username, "PASSWORD": password, "TASK_ID": task_id,
            "INSTANCE_NO": instance_no or "", "NODE": str(node),
            "BUTTON": str(st.get("button") or (cfg.get("api") or {}).get("submit", {}).get("defaultButton", "提交")),
            "NEXT_ASSIGNEE": str(st.get("expectAssignee") or st.get("pick") or ""),
            "NEXT_NODE": apply_route_map(
                {"nextStep": (lambda v: "" if str(v).strip().lower() in ("", "none", "null", "-", "实测") else str(v))(
                    st.get("expectNext") or st.get("nextStep"))},
                (cfg.get("api") or {}).get("route_map"), flow_code)["nextStep"],
            "_FORM_DATA": st.get("formData") if isinstance(st.get("formData"), dict) else None,
            # 第二十三轮：整体回显域——本步 workbench 采集到的当前业务表单数据（echo_form_patch 用）
            "_ECHO_FORM": fields if isinstance(fields, dict) else None,
            "FLOW_CODE": flow_code, "_seq": seq,
            # 第二十二轮：声明式测试输入的日期上下文（formData/instObj 模板用；当天口径=手工用例基准）
            "TODAY": time.strftime("%Y-%m-%d"), "NOW": time.strftime("%Y-%m-%d %H:%M:%S"),
        }
        # 选人解析（第二十一轮）：场景给姓名 → 服务端候选实时解析为系统 ID（候选集/组织均来自被测系统）；
        # 解析失败保留原值透传（由被测系统判定——不猜测）。ASSIGNEE_NAME 供账本 owner 登记。
        ctx["ASSIGNEE_NAME"] = ctx["NEXT_ASSIGNEE"]
        uid, matched_name = api.resolve_assignee(token, task_id, ctx["NEXT_ASSIGNEE"], ctx)
        if uid is not None:
            ctx["NEXT_ASSIGNEE"] = str(uid)
            if matched_name:
                ctx["ASSIGNEE_NAME"] = matched_name
        api.submit(token, task_id, ctx)
        print(f"[api-capture] {side} s{seq} 节点{node} 采集 {len(fields)} 字段并提交 ✓")

    capture = {
        "run_id": args.run_id,           # 身份三要素——runner/conclude 据此采信
        "case_id": case_id,
        "flow_code": flow_code,
        "side": side,
        "fixture_pairs": list(sc.get("fixturePairs") or sc.get("fixture_pairs") or []),
        "steps": steps_out,
        "instance_no": instance_no,
        "task_ids": task_ids,
        "channel": "api",
    }
    out = Path(args.exec_dir) / "field-captures" / side / f"{case_id}.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + f".tmp-{os.getpid()}")
    tmp.write_text(json.dumps(capture, ensure_ascii=False, indent=2), encoding="utf-8")
    tmp.replace(out)
    print(f"[api-capture] capture → {out}")


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except ConnectionError as e:
        print(f"[api-capture] ⛔ 系统不可达/网络异常: {e}", file=sys.stderr)
        raise SystemExit(2)
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"[api-capture] ⛔ 内部异常（fail-closed，未落 capture）: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
