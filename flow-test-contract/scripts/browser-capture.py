#!/usr/bin/env python3
"""browser-capture.py v1 —— 浏览器通道采集器（playwright-cli 驱动，双系统同构）。

将「老系统浏览器对比测试」数十轮实战沉淀的 SOP 固化为 skill 资产（2026-09-09）：
  - G3.1  95306 数据弹窗 SOP：重置 → 清日期 → 查询 → 等 8~10s → 选未使用行 → 确定
  - G3.3  处理人为空 → 提交静默失败 → 提交前补选（handlerPick.mode: textbox 下拉 | button 对话框）
  - G3.4  无菜单账号双通道入口（结算处理 → 港口待处理结算）
  - JWT 切号唯一可靠方式 = 整浏览器 close-reopen（同 profile）
  - 00 日期陷阱：键入不进模型（FYRQ undefined → 提交恒置灰），必须日历面板点选
  - 同人自动流转弹窗：提交确定后再弹确定（autoConfirmPopups）

与 api-capture.py 完全同构：
  用法   browser-capture.py --systems <yaml> --scenario <case.yaml> --run-id <id> --exec-dir <dir>
  产出   <exec-dir>/field-captures/<systems.id>/<case_id>.json
         <exec-dir>/screenshots/<systems.id>/s<seq>_<node>_{form,submitted}.png（逐环节证据）（capture 契约 §3：身份三要素
         run_id/case_id/flow_code + instance_no + steps.sN.fields/routing/buttons + channel: browser）
  铁律   fail-closed：任何一步失败 → exit 2 不落 capture；占位残留（__UI_RECORD__）→ 拒跑；
         凭据只从 actorMap 指定 env 读取，缺即拒；launch-first 实例隔离，s≥2 任务查找
         强制绑定 instance_no（一旦已知）；动作前一律重新 snapshot 解析 ref（ref 随快照失效）。

辅助模式（不触数据）:
  --selftest      结构自检（配置 schema / 场景解析 / capture 写出 / 负向路径），无需浏览器
  --check-config  仅校验 systems 配置（占位/必填/凭据 env 存在性），exit 0/2
  --probe         实机只读探针：登录 + 导航到待处理列表 + 探针命中报告，不发起/不提交

驱动层：playwright-cli（node）。CLI 解析顺序：env PLAYWRIGHT_CLI（可执行脚本路径）
  → $HOME/.codex/skills/playwright/scripts/playwright_cli.sh → npx 兜底。
  会话隔离：--session <browser.session>；持久 profile：--profile <browser.profile>。
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

sys.dont_write_bytecode = True   # 审计第 2 轮 F2：动态加载 ftc_env 零字节码（skill 目录零副作用）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # spec 加载（selftest）时补齐 scripts 目录
import ftc_env  # noqa: E402  凭据解析唯一实现（v1.3.3 去 .env 化：env 文件 + 显式授权 FLOWTEST_DEFAULT_PWD 兜底）

_SYSTEMS_PATH: str | None = None   # main() 注入——actor_credentials 据此定位 $RUNTIME_DIR/env

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 browser-capture.py …")

PLACEHOLDER = "__UI_RECORD__"
DATE_VALUE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}")


class Fail(Exception):
    pass


# ────────────────────────── 配置加载与校验 ──────────────────────────

def load_systems(path: Path) -> dict:
    if not path.exists():
        raise Fail(f"systems 配置缺失: {path}")
    cfg = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(cfg, dict):
        raise Fail(f"systems 配置非法（须 YAML 对象）: {path}")
    if cfg.get("channel") != "browser":
        raise Fail(f"systems channel 须为 browser，实为 {cfg.get('channel')!r}: {path}")
    # 占位残留检查（与 api 通道同纪律：解析后的值里出现占位即拒）
    def walk(v):
        if isinstance(v, str):
            if PLACEHOLDER in v:
                raise Fail(f"配置含未录制占位 {PLACEHOLDER}（先做 UI 录制，见 references/browser-channel.md）: {path}")
        elif isinstance(v, dict):
            for x in v.values():
                walk(x)
        elif isinstance(v, list):
            for x in v:
                walk(x)
    walk(cfg)
    for key in ("browser", "nav", "form", "actorMap"):
        if not isinstance(cfg.get(key), dict):
            raise Fail(f"配置缺必填块 {key}: {path}")
    b = cfg["browser"]
    for key in ("baseUrl", "session"):
        if not b.get(key):
            raise Fail(f"browser.{key} 必填: {path}")
    hp = cfg.get("handlerPick")
    if hp is not None:
        if not isinstance(hp, dict):
            raise Fail(f"handlerPick 须为对象: {path}")
        mode = hp.get("mode", "textbox")
        if mode not in ("textbox", "button"):
            raise Fail(f"handlerPick.mode 仅支持 textbox|button，实为 {mode!r}"
                       f"（未知取值不静默回退——防误判提交成功）: {path}")
    return cfg


def actor_credentials(cfg: dict, actor: str, systems_path=None) -> tuple[str, str]:
    am = cfg.get("actorMap") or {}
    ent = am.get(actor)
    if not isinstance(ent, dict):
        raise Fail(f"actorMap 未登记 actor={actor!r}（配置 actorMap 后重试；凭据零明文，只写 env 名）")
    try:
        return ftc_env.resolve_credentials(
            systems_path if systems_path is not None else _SYSTEMS_PATH,
            actor, str(ent.get("username") or ""), str(ent.get("password") or ""),
            warn=lambda m: print(f"[browser-capture] {m}"))
    except ftc_env.CredentialError as e:
        raise Fail(str(e))


def load_scenario(path: Path) -> dict:
    if not path.exists():
        raise Fail(f"场景缺失: {path}")
    sc = yaml.safe_load(path.read_text(encoding="utf-8"))
    if not isinstance(sc, dict) or not sc.get("case_id") or not sc.get("flow_code"):
        raise Fail(f"场景缺 case_id/flow_code: {path}")
    steps = sc.get("steps")
    if not isinstance(steps, list) or not steps:
        raise Fail(f"场景无 steps: {path}")
    return sc


# ────────────────────────── playwright-cli 驱动 ──────────────────────────

class Browser:
    def __init__(self, cfg: dict, headed: bool):
        b = cfg["browser"]
        self.base = b["baseUrl"]
        self.session = b["session"]
        self.profile = b.get("profile") or ""
        self.login_wait = float(b.get("loginWaitSeconds", 2.5))
        self.cli_timeout = int(b.get("cliTimeoutSeconds", 60))
        self.headed = headed if b.get("headed") is None else bool(b.get("headed"))
        self.switch_mode = b.get("switchAccount", "close-reopen")
        self._cli = self._resolve_cli()
        self._cur_actor = None

    @staticmethod
    def _resolve_cli() -> list[str]:
        """CLI 解析（1.1.0 可复现性）：正式运行必须指向已固定版本的本地工具。

        优先级：PLAYWRIGHT_CLI（显式，推荐）→ 本地包装脚本 → npx latest（**仅演练/探针**）。
        npx --yes @playwright/cli 会联网下载且版本随时间漂移——同一契约不同日期跑出不同
        浏览器行为，正式 PASS 不可复现。故 FLOWTEST_FORMAL_RUN=1（pipeline 正式执行时注入）
        下禁用 npx 回退，fail-closed 报错要求显式配置。
        """
        env = os.environ.get("PLAYWRIGHT_CLI", "").strip()
        if env:
            return [env]
        fallback = Path.home() / ".codex/skills/playwright/scripts/playwright_cli.sh"
        if fallback.exists():
            return ["bash", str(fallback)]
        if os.environ.get("FLOWTEST_FORMAL_RUN", "").strip() in ("1", "true", "True"):
            raise Fail(
                "正式运行禁止 npx latest 回退（未锁版本=联网下载+版本漂移，正式 PASS 不可复现）"
                "——请设 PLAYWRIGHT_CLI 指向已固定版本的本地 playwright-cli，"
                "或安装本地包装脚本 ~/.codex/skills/playwright/scripts/playwright_cli.sh；"
                "演练/探针（--probe/--drill）不受此限制"
            )
        return ["npx", "--yes", "--package", "@playwright/cli", "playwright-cli"]

    def cli_version(self) -> str:
        """当前 CLI 的版本串（进账本，供复现核对）；探测失败不阻断执行，记 unknown。"""
        try:
            out = subprocess.run([*self._cli, "--version"], capture_output=True, text=True, timeout=20)
            v = (out.stdout or out.stderr or "").strip().splitlines()
            return f"{' '.join(self._cli)} :: {v[0]}" if v else f"{' '.join(self._cli)} :: unknown"
        except Exception as e:
            return f"{' '.join(self._cli)} :: probe-failed({type(e).__name__})"

    def _run(self, *args: str, timeout: int | None = None) -> str:
        env = dict(os.environ)
        env["PLAYWRIGHT_CLI_SESSION"] = self.session
        p = subprocess.run([*self._cli, *args], capture_output=True, text=True,
                           timeout=timeout or self.cli_timeout, env=env)
        return p.stdout + (p.stderr or "")

    # —— 会话生命周期 ——
    def open_app(self):
        args = ["open", self.base]
        if self.profile:
            args += ["--profile", self.profile]
        if self.headed:
            args += ["--headed"]
        out = self._run(*args, timeout=90)
        if "Error" in out and "http" not in out:
            raise Fail(f"浏览器打开失败: {out.strip()[:300]}")
        time.sleep(2.0)

    def close(self):
        try:
            self._run("close")
        except Exception:
            pass

    # —— 快照与元素解析 ——
    def snap(self) -> str:
        out = self._run("snapshot")
        if "### Snapshot" not in out:
            raise Fail(f"snapshot 失败: {out.strip()[:200]}")
        return out

    @staticmethod
    def _ref(line: str) -> str | None:
        m = re.search(r"\[ref=([A-Za-z0-9_]+)\]", line) or re.search(r"ref=([A-Za-z0-9_]+)", line)
        return m.group(1) if m else None

    def find(self, snap: str, pattern: str, nth: int = 0, region: str | None = None) -> str:
        """按行正则找第 nth 个元素的 ref。region: ('between', start_pat, end_pat) 限定区段。"""
        lines = snap.splitlines()
        if region:
            kind, p1, p2 = region
            try:
                i1 = next(i for i, l in enumerate(lines) if re.search(p1, l))
                i2 = next(i for i, l in enumerate(lines[i1 + 1:], i1 + 1) if re.search(p2, l))
            except StopIteration:
                raise Fail(f"region 未命中: {p1} → {p2}")
            lines = lines[i1:i2 + 1]
        hits = [(l, self._ref(l)) for l in lines if re.search(pattern, l)]
        hits = [(l, r) for l, r in hits if r]
        if len(hits) <= nth:
            raise Fail(f"元素未找到（命中 {len(hits)}<={nth}）: {pattern}")
        return hits[nth][1]

    def click(self, ref: str):
        self._run("click", ref)

    def fill(self, ref: str, text: str):
        self._run("fill", ref, text)

    # —— 高层动作 ——
    def login(self, cfg: dict, actor: str):
        if self._cur_actor == actor:
            return  # 同账号免重登（JWT 未变）
        if self._cur_actor is not None or self.switch_mode == "close-reopen":
            self.close()          # JWT 切号唯一可靠方式：整浏览器关开（同 profile）
            self.open_app()
        user, pwd = actor_credentials(cfg, actor)
        lg = cfg["browser"].get("login") or {}
        snap = self.snap()
        if lg.get("userRef") and lg.get("passRef") and lg.get("submitRef"):
            u, p, s = lg["userRef"], lg["passRef"], lg["submitRef"]
        else:  # 探针兜底：登录页前两个 textbox + 登录按钮
            boxes = re.findall(r'- textbox [^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
            if len(boxes) < 2:
                raise Fail("登录页探针未找到两个输入框（配置 browser.login.userRef/passRef/submitRef）")
            u, p = boxes[0], boxes[1]
            btns = re.findall(r'- button [^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
            if not btns:
                raise Fail("登录页探针未找到提交按钮")
            s = btns[-1]
        self.fill(u, user)
        self.fill(p, pwd)
        self.click(s)
        time.sleep(self.login_wait)
        who = cfg["browser"].get("whoamiContains")
        if who and who not in self.snap():
            raise Fail(f"登录后未见身份标识 {who!r}（账号 {actor} 登录失败？）")
        self._cur_actor = actor

    def nav_click(self, cfg: dict, *names: str):
        """依序点击菜单名（每步重新快照解析 ref）。"""
        for name in names:
            snap = self.snap()
            ref = self.find(snap, rf'menuitem "[^"]*{re.escape(name)}')
            self.click(ref)
            time.sleep(1.2)

    def open_todo(self, cfg: dict) -> bool:
        """打开待处理列表。无菜单账号走 G3.4 fallback；返回是否走了 fallback。"""
        nav = cfg["nav"]
        snap = self.snap()
        if not re.search(rf'menuitem "[^"]*{re.escape(nav["flowMenu"])}', snap):
            fb = nav.get("fallbackMenu") or {}
            if not (fb.get("parent") and fb.get("item")):
                raise Fail(f"未见流程菜单 {nav['flowMenu']!r} 且未配置 nav.fallbackMenu（G3.4）")
            self.nav_click(cfg, fb["parent"], fb["item"])
            time.sleep(1.5)
            return True
        self.nav_click(cfg, nav["flowMenu"], nav["todoItem"])
        time.sleep(1.8)
        return False

    def launch(self, cfg: dict) -> None:
        """launch-first：发起流程 → 选第一行 → 启动按钮 → 自动确认弹窗。"""
        nav = cfg["nav"]
        snap = self.snap()
        if not re.search(rf'menuitem "[^"]*{re.escape(nav["flowMenu"])}', snap):
            raise Fail(f"发起人未见流程菜单 {nav['flowMenu']!r}（发起必须有菜单；G3.4 fallback 仅适用待办）")
        self.nav_click(cfg, nav["flowMenu"], nav["launchItem"])
        time.sleep(2.0)
        snap = self.snap()
        # 第一行内的可点击 generic（实测：row "1" 区段内带 cursor 的 generic）
        ref = self.find(snap, r'generic \[ref=.*cursor', 0, ("between", r'row "1"', r"rowgroup"))
        self.click(ref)
        time.sleep(1.0)
        snap = self.snap()
        ref = self.find(snap, rf'button "[^"]*{re.escape(nav["launchButton"])}')
        self.click(ref)
        time.sleep(3.0)
        self.auto_confirm(cfg)

    def auto_confirm(self, cfg: dict, rounds: int | None = None):
        """确认可能出现的弹窗（同人自动流转/启动确认）。最多 rounds 次。"""
        n = rounds if rounds is not None else int(cfg["form"].get("autoConfirmPopups", 1))
        for _ in range(max(0, n)):
            snap = self.snap()
            hits = re.findall(r'- button "[^"]*确定[^"]*"[^\n]*\[ref=([A-Za-z0-9_]+)\]', snap) \
                or re.findall(r'- button "[^"]*确 定[^"]*"[^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
            if not hits:
                return
            self.click(hits[-1])
            time.sleep(2.0)

    def open_task(self, cfg: dict, instance: str | None, node: str, wait_s: int) -> str:
        """打开待办任务；instance 已知则强制绑定该实例行，返回行内提取的实例号。"""
        nav = cfg["nav"]
        deadline = time.time() + max(5, wait_s)
        last_err = ""
        while time.time() < deadline:
            self.open_todo(cfg)
            snap = self.snap()
            rows = [(l, self._ref(l)) for l in snap.splitlines()
                    if re.search(r'generic \[ref=.*cursor', l) and self._ref(l)]
            if rows:
                try:
                    row_line, row_ref = rows[0], rows[0][1]
                    if instance:
                        hit = next(((l, r) for l, r in rows if False), None)  # 行文本绑定见下
                    # 行级文本：取该 cursor generic 所在 row 的祖先文本——快照顺序近似：
                    # 找 cursor 行之前最近的 row "…" 行文本 + 之后 3 行
                    idx = snap.splitlines().index(row_line)
                    ctx = "\n".join(snap.splitlines()[max(0, idx - 6): idx + 4])
                    if instance and instance not in ctx:
                        # 该行不是本实例：页内其他行找实例号
                        if instance not in snap:
                            last_err = f"待办首行非本实例且页内未见 {instance}"
                            self.close()
                            self.open_app()
                            continue
                    m = re.search(cfg["browser"].get("instancePattern") or r"[A-Z]{2,10}\d{5,}", ctx)
                    inst = m.group(0) if m else instance
                    # 去处理
                    href = self.find(snap, rf'button "[^"]*{re.escape(nav["handleButton"])}')
                    self.click(row_ref)
                    time.sleep(0.8)
                    self.click(href)
                    time.sleep(2.0)
                    return inst or ""
                except Fail as e:
                    last_err = str(e)
            time.sleep(2.0)
        raise Fail(f"待办任务未出现/未打开（node={node} instance={instance}）: {last_err}")

    # —— 表单策略（forms.<node>）——
    def apply_form(self, cfg: dict, node: str, values: dict[str, str]):
        """按配置策略填单：popupSelect / datePanel（面板点选，键入不进模型）/ textboxes / popupSop。"""
        spec = ((cfg["form"].get("forms") or {}).get(str(node))) or {}
        for item in spec.get("popupSelect") or []:
            snap = self.snap()
            boxes = re.findall(r'- textbox "[^"]*请选择"[^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
            nth = int(item.get("triggerNth", 1)) - 1
            if len(boxes) <= nth:
                raise Fail(f"节点 {node} popupSelect 触发器未找到（nth={nth + 1}）")
            self.click(boxes[nth])
            time.sleep(1.5)
            snap = self.snap()
            opt = self.find(snap, rf'listitem [^/n]*{re.escape(item["optionContains"])}')
            self.click(opt)
            time.sleep(1.0)
        if spec.get("datePanel"):
            snap = self.snap()
            trig = self.find(snap, rf'textbox "[^"]*{re.escape(cfg["form"].get("datePanelTrigger", "选择日期时间"))}')
            self.click(trig)
            time.sleep(1.5)
            snap = self.snap()
            day = spec["datePanel"].get("day", "today")
            day_num = date.today().day if day == "today" else int(day)
            cell = self.find(snap, rf'cell "{day_num}"')
            self.click(cell)
            time.sleep(1.0)
        for item in spec.get("textboxes") or []:
            snap = self.snap()
            boxes = re.findall(r'- textbox "[^"]*请输入"[^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
            nth = int(item.get("nth", 1)) - 1
            if len(boxes) <= nth:
                raise Fail(f"节点 {node} 第 {nth + 1} 个输入框未找到（页内共 {len(boxes)}）")
            val = str(item.get("value", ""))
            val = re.sub(r"\$\{ENV:([A-Z0-9_]+)\}", lambda m: os.environ.get(m.group(1), ""), val)
            self.fill(boxes[nth], val)
            time.sleep(0.3)
        if spec.get("popupSop"):
            self.popup_sop(cfg, str(spec["popupSop"]), values)

    def popup_sop(self, cfg: dict, name: str, values: dict[str, str]):
        """G3.1 数据选择弹窗 SOP：打开→重置→清日期→查询→等→选未使用行→确定。"""
        pop = (cfg.get("popups") or {}).get(name)
        if not isinstance(pop, dict):
            raise Fail(f"popups.{name} 未配置（G3.1 SOP 需要显式配置，不猜）")
        snap = self.snap()
        ref = self.find(snap, rf'button "[^"]*{re.escape(pop["openButtonContains"])}')
        self.click(ref)
        time.sleep(2.0)
        snap = self.snap()
        self.click(self.find(snap, rf'button "[^"]*{re.escape(pop["resetButton"])}'))
        time.sleep(1.0)
        snap = self.snap()
        for tb in re.findall(r'- textbox [^\n]*\[ref=([A-Za-z0-9_]+)\][^\n]*: (\d{4}-\d{2}-\d{2})', snap):
            self.fill(tb[0], "")
            time.sleep(0.3)
        self.click(self.find(self.snap(), rf'button "[^"]*{re.escape(pop["queryButton"])}'))
        time.sleep(float(pop.get("waitSeconds", 9)))   # 老库忙时 8~10s 才出数（实测）
        snap = self.snap()
        used = pop.get("usedMarker", "已被使用")
        lines = snap.splitlines()
        chosen = None
        for i, l in enumerate(lines):
            if "- checkbox" not in l:
                continue
            ref = self._ref(l)
            if not ref or "[disabled]" in l:
                continue
            ctx = "\n".join(lines[max(0, i - 8): i + 4])
            if used and used in ctx:
                continue
            chosen = ref
            break
        if not chosen:
            raise Fail(f"G3.1 弹窗无未使用行可选（usedMarker={used!r}）——需补数据或换配对")
        self.click(chosen)
        time.sleep(0.8)
        snap = self.snap()
        confs = re.findall(r'- button "[^"]*确定[^"]*"[^\n]*\[ref=([A-Za-z0-9_]+)\]', snap)
        if not confs:
            raise Fail("弹窗确定按钮未找到")
        self.click(confs[-1])
        time.sleep(1.5)
        values["popup_sop"] = name

    # —— 保存 / 选环节 / 提交 ——
    def save_and_submit(self, cfg: dict, expect_next: str, values: dict[str, str]) -> dict:
        fm = cfg["form"]
        routing: dict = {}
        self.click(self.find(self.snap(), rf'button "[^"]*{re.escape(fm["saveButton"])}'))
        time.sleep(2.0)
        # 选下一环节（G3.3 补选处理人在环节选择之后）
        self.click(self.find(self.snap(), rf'textbox "[^"]*{re.escape(fm["nextNodeLabel"])}'))
        time.sleep(1.2)
        snap = self.snap()
        names = cfg.get("nodeNames") or {}
        want = names.get(str(expect_next), str(expect_next))
        li = self.find(snap, rf'listitem [^\n]*{re.escape(want)}')
        routing["selected_next"] = str(expect_next)
        self.click(li)
        time.sleep(1.0)
        # G3.3 处理人补选：触发器存在且需要时选第一候选
        hp = cfg.get("handlerPick") or {}
        if hp.get("enabled"):
            mode = hp.get("mode", "textbox")
            if mode == "button":
                snap = self.snap()
                handler_label = hp.get("handlerLabel", "处理人:")
                handler_filled = False
                for i, l in enumerate(snap.splitlines()):
                    if re.search(rf'"{re.escape(handler_label)}"', l):
                        for j in range(i + 1, min(i + 8, len(snap.splitlines()))):
                            m2 = re.search(r'textbox(?:\s+\[[^\]]*\])*\s+\[ref=[^\]]+\]:\s*(\S+)', snap.splitlines()[j])
                            if m2 and m2.group(1).strip():
                                handler_filled = True
                                break
                        break
                if not handler_filled:
                    pat = rf'button "[^"]*{re.escape(hp.get("triggerLabel", "选择处理人"))}'
                    if re.search(pat, snap):
                        ref = self._ref([l for l in snap.splitlines() if re.search(pat, l)][0])
                        self.click(ref)
                        time.sleep(1.5)
                        s2 = self.snap()
                        confs = re.findall(r'- button "[^"]*确定[^"]*"[^\n]*\[ref=([A-Za-z0-9_]+)\]', s2) \
                            or re.findall(r'- button "[^"]*确 定[^"]*"[^\n]*\[ref=([A-Za-z0-9_]+)\]', s2)
                        if confs:
                            self.click(confs[-1])
                            time.sleep(1.0)
                            routing["handler_picked"] = True
            else:
                snap = self.snap()
                m = re.search(rf'- textbox "[^"]*{re.escape(hp.get("triggerLabel", "请选择处理人"))}', snap)
                if m:
                    line = next(l for l in snap.splitlines() if f'textbox "{hp.get("triggerLabel", "请选择处理人")}' in l)
                    if not re.search(r":\s*\S", line.split("[ref=")[0].split("]")[0] if "[ref=" in line else line):
                        ref = self._ref(line)
                        self.click(ref)
                        time.sleep(1.0)
                        s2 = self.snap()
                        items = re.findall(r'- (?:listitem|option) [^\n]*\[ref=([A-Za-z0-9_]+)\]', s2)
                        if items:
                            self.click(items[0])
                            time.sleep(0.8)
                            routing["handler_picked"] = True
        # 提交 → 确定 → 同人自动弹窗确认
        self.click(self.find(self.snap(), rf'button "[^"]*{re.escape(fm["submitButton"])}'))
        time.sleep(2.0)
        self.auto_confirm(cfg, rounds=1 + int(fm.get("autoConfirmPopups", 1)))
        routing["submitted"] = True
        return routing

    def shot(self, path: Path):
        """环节截图（执行证据：第三十轮——产物随 run 目录落 docs/<流程>/自动化测试/对比测试/）。"""
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            self._run("screenshot", "--filename", str(path))
        except Exception:
            pass   # 截图失败不阻断执行（证据缺失在报告中如实呈现）

    # —— 表单读回（capture fields）——
    def readback(self, snap: str) -> dict[str, str]:
        fields: dict[str, str] = {}
        n = 0
        for l in snap.splitlines():
            m = re.search(r'- textbox "([^"]*)"[^\n]*?\[ref=[A-Za-z0-9_]+\](?:[^\n:]*): (.+)', l)
            if m:
                n += 1
                val = m.group(2).strip()
                if val and val not in ("请输入", "请选择"):
                    fields[f"t{n}"] = val
        return fields


# ────────────────────────── 主流程 ──────────────────────────

def run_capture(cfg: dict, scenario: dict, run_id: str, exec_dir: Path, headed: bool | None) -> Path:
    flow_code = str(scenario["flow_code"])
    case_id = str(scenario["case_id"])
    wait_s = int((cfg["browser"].get("taskWaitSeconds", 15)))
    br = Browser(cfg, headed=headed if headed is not None else True)
    steps_out: dict[str, dict] = {}
    instance: str | None = None
    shots = cfg["browser"].get("screenshots", True)
    cap_shots = exec_dir / "screenshots" / str(cfg["id"])
    try:
        for step in scenario["steps"]:
            seq = str(step.get("seq", len(steps_out) + 1))
            key = f"s{seq}"
            node = str(step.get("node", ""))
            actor = str(step.get("actorAccount") or step.get("actor") or "")
            values: dict[str, str] = {}
            br.login(cfg, actor)
            if seq == str(scenario["steps"][0].get("seq", 1)) and not instance:
                br.launch(cfg)                       # launch-first：首步必发起
            else:
                instance = br.open_task(cfg, instance, node, wait_s) or instance
            br.apply_form(cfg, node, values)
            if shots:
                br.shot(cap_shots / f"s{seq}_{node}_form.png")
            snap = br.snap()
            fields = br.readback(snap)
            fields.update({k: v for k, v in values.items()})
            routing: dict = {}
            if step.get("expectNext") is not None:
                routing = br.save_and_submit(cfg, str(step["expectNext"]), values)
                if shots:
                    br.shot(cap_shots / f"s{seq}_{node}_submitted.png")
            steps_out[key] = {"fields": fields, "routing": routing,
                              "buttons": ["保存单据", "提交流程"] if routing else []}
            time.sleep(1.0)
        if not instance:
            raise Fail("全程未取得实例号（instance_no 为空）——capture 不落盘")
        cap_dir = exec_dir / "field-captures" / str(cfg["id"])
        cap_dir.mkdir(parents=True, exist_ok=True)
        cap = {"run_id": run_id, "case_id": case_id, "flow_code": flow_code,
               "side": cfg["id"], "instance_no": instance, "fixture_pairs": scenario.get("fixturePairs") or [],
               "steps": steps_out, "channel": "browser"}
        out = cap_dir / f"{case_id}.json"
        out.write_text(json.dumps(cap, ensure_ascii=False, indent=2), encoding="utf-8")
        return out
    finally:
        br.close()


def probe(cfg: dict, headed: bool) -> int:
    """只读探针：登录 → 待处理导航 → 探针命中报告。不发起/不提交。"""
    actor = next(iter(cfg["actorMap"]), None)
    if not actor:
        print("actorMap 为空，无法探针")
        return 2
    br = Browser(cfg, headed=headed)
    report: list[str] = []
    try:
        br.open_app()
        br.login(cfg, actor)
        report.append(f"login {actor}: OK")
        fb = br.open_todo(cfg)
        report.append(f"todo 导航: OK（{'G3.4 fallback' if fb else '流程菜单'}）")
        snap = br.snap()
        for name, pat in [("保存单据", rf'button "[^"]*{re.escape(cfg["form"]["saveButton"])}'),
                          ("提交流程", rf'button "[^"]*{re.escape(cfg["form"]["submitButton"])}'),
                          ("待处理计数", r"共 \d+ 条")]:
            report.append(f"probe {name}: {'命中' if re.search(pat, snap) else '未命中（办理页打开后才可见，属正常）'}")
        print("\n".join(report))
        return 0
    except Fail as e:
        print("\n".join(report))
        print(f"PROBE FAIL: {e}")
        return 2
    finally:
        br.close()


def selftest() -> int:
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        good = {
            "id": "t", "channel": "browser",
            "browser": {"baseUrl": "http://x", "session": "s", "headed": False,
                        "login": {"userRef": "e1", "passRef": "e2", "submitRef": "e3"},
                        "instancePattern": "[A-Z]{2,10}\\d{5,}"},
            "nav": {"flowMenu": "F", "launchItem": "L", "todoItem": "T", "handleButton": "H", "launchButton": "S"},
            "form": {"saveButton": "保存", "nextNodeLabel": "环节", "submitButton": "提交", "confirmButton": "确定",
                     "forms": {"35": {"popupSop": "s95306"}}},
            "popups": {"s95306": {"openButtonContains": "95306", "resetButton": "重置", "queryButton": "查询"}},
            "handlerPick": {"enabled": True},
            "nodeNames": {"01": "审核"},
            "actorMap": {"a": {"username": "T_USER", "password": "T_PWD"}},
        }
        p = tmp / "s.yaml"
        p.write_text(yaml.safe_dump(good, allow_unicode=True), encoding="utf-8")
        try:
            c = load_systems(p)
            check(ok := ok and True, "load_systems 合法配置通过")
        except Fail as e:
            check(False, f"load_systems 合法配置应通过: {e}"); ok = False
        bad = dict(good); bad["form"] = dict(good["form"], saveButton = PLACEHOLDER)
        p2 = tmp / "b.yaml"; p2.write_text(yaml.safe_dump(bad), encoding="utf-8")
        try:
            load_systems(p2); check(False, "占位配置应拒绝"); ok = False
        except Fail:
            check(True, "占位配置拒绝（fail-closed）")
        p3 = tmp / "c.yaml"; p3.write_text(yaml.safe_dump({**good, "channel": "api"}), encoding="utf-8")
        try:
            load_systems(p3); check(False, "channel 非 browser 应拒绝"); ok = False
        except Fail:
            check(True, "channel 校验（fail-closed）")
        p4 = tmp / "hp_btn.yaml"
        p4.write_text(yaml.safe_dump({**good, "handlerPick": {"enabled": True, "mode": "button",
                                                              "triggerLabel": "选择处理人"}},
                                     allow_unicode=True), encoding="utf-8")
        try:
            load_systems(p4); check(True, "handlerPick mode=button 合法（按钮型选人页）")
        except Fail as e:
            check(False, f"handlerPick mode=button 应通过: {e}"); ok = False
        p5 = tmp / "hp_bad.yaml"
        p5.write_text(yaml.safe_dump({**good, "handlerPick": {"enabled": True, "mode": "popup"}},
                                     allow_unicode=True), encoding="utf-8")
        try:
            load_systems(p5); check(False, "handlerPick.mode 未知取值应拒绝"); ok = False
        except Fail:
            check(True, "handlerPick.mode 未知取值拒绝（不静默回退 textbox=防误判提交成功）")
        os.environ.pop("T_USER", None)
        os.environ.pop("T_PWD", None)
        os.environ.pop(ftc_env.DEFAULT_PWD_ENV, None)   # 兜底关闭后凭据缺失才可复现拒绝
        try:
            actor_credentials(good, "a", systems_path=str(p)); check(False, "凭据缺失应拒绝"); ok = False
        except Fail:
            check(True, "凭据缺失拒绝（BB3 同纪律；env 文件与默认密码兜底均不在场）")
        sc = {"case_id": "C-01", "flow_code": "F1", "steps": [{"seq": 1, "node": "00", "actorAccount": "a", "expectNext": "01"}]}
        sp = tmp / "sc.yaml"; sp.write_text(yaml.safe_dump(sc), encoding="utf-8")
        try:
            load_scenario(sp); check(True, "场景解析通过")
        except Fail as e:
            check(False, f"场景解析失败: {e}"); ok = False
        cap_dir = tmp / "cap"
        cap_dir.mkdir()
        out = cap_dir / "field-captures" / "t" / "C-01.json"
        out.parent.mkdir(parents=True)
        out.write_text(json.dumps({"run_id": "r", "case_id": "C-01", "flow_code": "F1"}), encoding="utf-8")
        check(out.exists(), "capture 契约写出布局 field-captures/<id>/<case_id>.json")
    return 0 if ok else 1


def check(ok: bool, msg: str):
    print(("✅ " if ok else "❌ ") + msg)


def check_config_only(cfg_path: Path, env_names: list[str]) -> int:
    try:
        cfg = load_systems(cfg_path)
    except Fail as e:
        print(f"✗ {e}")
        return 2
    ftc_env.load_env_file(ftc_env.env_file_for(cfg_path))   # v1.3.3：先并入 $RUNTIME_DIR/env
    default_pwd = (bool(os.environ.get(ftc_env.DEFAULT_PWD_ENV, "").strip()) and
                   os.environ.get(ftc_env.ALLOW_DEFAULT_PWD_ENV, "").strip().lower() in ("1", "true", "yes"))
    missing = [n for n in env_names if not os.environ.get(n, "").strip()]
    if missing and not default_pwd:
        print(f"✗ 凭据 env 缺失且无显式默认密码授权（需 {ftc_env.ALLOW_DEFAULT_PWD_ENV}=1 + "
              f"{ftc_env.DEFAULT_PWD_ENV}）: {', '.join(missing)}")
        return 2
    if missing:
        print(f"⚠ 凭据 env 缺失 {len(missing)} 个（已显式授权以 {ftc_env.DEFAULT_PWD_ENV} 兜底："
              f"用户名回退 actor 本名、密码回退统一默认密码）: {', '.join(missing)}")
    print(f"✓ {cfg_path}（browser 通道配置校验通过；actor={len(cfg['actorMap'])}）")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--systems", required=False)
    ap.add_argument("--scenario")
    ap.add_argument("--run-id", default="run-selftest")
    ap.add_argument("--exec-dir")
    ap.add_argument("--headed", dest="headed", action="store_true", default=None)
    ap.add_argument("--headless", dest="headed", action="store_false")
    ap.add_argument("--probe", action="store_true", help="只读探针：登录+导航，不触数据")
    ap.add_argument("--check-config", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    global _SYSTEMS_PATH
    _SYSTEMS_PATH = a.systems
    if a.selftest:
        return selftest()
    if not a.systems:
        ap.error("--systems 必填（除非 --selftest）")
    cfg_path = Path(a.systems)
    if a.check_config:
        try:
            cfg = load_systems(cfg_path)
        except Fail as e:
            print(f"✗ {e}")
            return 2
        envs = [v for ent in cfg["actorMap"].values() for v in ent.values()]
        return check_config_only(cfg_path, envs)
    try:
        cfg = load_systems(cfg_path)
        if a.probe:
            return probe(cfg, headed=a.headed if a.headed is not None else True)
        if not a.scenario or not a.exec_dir:
            ap.error("--scenario 与 --exec-dir 必填（除非 --selftest/--check-config/--probe）")
        sc = load_scenario(Path(a.scenario))
        out = run_capture(cfg, sc, a.run_id, Path(a.exec_dir), a.headed)
        print(f"✅ browser capture → {out}")
        return 0
    except Fail as e:
        print(f"[browser-capture] BLOCKED: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
