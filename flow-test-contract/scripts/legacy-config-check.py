#!/usr/bin/env python3
"""legacy-config-check.py —— 检查 systems/api/*.yaml 残留的 F12 录端点占位符（__F12_RECORD__）。

把人工录端点这件事变成确定性：
  - 扫描 systems/api/legacy.yaml（或 --systems 指定）和 current.yaml 中所有值为 `__F12_RECORD__`
    的字段，连同字段路径（点路径）+ 上下文注释一行；
  - actorMap / submit.defaultButton 等"非 F12 必录"字段不强制检查（仅检查带 F12 录法注释的字段）；
  - 输出可粘贴到 issue 的清单：每行 `  - <path>: <comment>`。

用法:
  python3 legacy-config-check.py --systems <runtime>/systems/api/legacy.yaml
  python3 legacy-config-check.py --systems-dir <runtime>/systems/api      # 扫 legacy + current

退出码: 0=全部已录；1=存在占位或结构缺口（待录清单已打印）；2=配置不可读/格式错/目标文件不存在。
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("需要 PyYAML：uv run --with pyyaml python3 legacy-config-check.py …")

sys.dont_write_bytecode = True   # 审计第 3 轮 R3-1：兄弟模块导入零字节码（skill 目录零副作用）
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ftc_ops_config  # noqa: E402  api.operations schema 唯一校验实现（v1.3.6；api-capture 共用）

PLACEHOLDER = "__F12_RECORD__"
# 注释前缀（扫描命中占位值时，向上回溯到带此注释的最近一行作为上下文）
HINT_PREFIXES = ("TODO: __F12_RECORD__", "TODO:")


def _scan(node, path: list[str], findings: list[tuple[str, str]], comments: dict[tuple[str, ...], str]) -> None:
    """递归扫描；占位命中时按 path 找最近注释作为 note。"""
    if isinstance(node, dict):
        for k, v in node.items():
            _scan(v, path + [str(k)], findings, comments)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            _scan(v, path + [f"[{i}]"], findings, comments)
    elif isinstance(node, str) and PLACEHOLDER in node:
        # 路径作为最简标识；notes 留空（yaml 注释扫描成本高，实用上注释就在同字段上一行）
        findings.append((".".join(path) or "<root>", node))


def _read_yaml(p: Path) -> dict:
    text = p.read_text(encoding="utf-8")
    # 抽离注释（行级 → 简化版：只对占位命中收集同行注释，YAML 注释不进入 safe_load）
    cfg = yaml.safe_load(text) or {}
    return cfg if isinstance(cfg, dict) else {}


def check_one(path: Path) -> tuple[int, list[str]]:
    """占位残留 + 结构完整性检查（第十三轮·审计修复 P1-6：结构缺件早于 run 时拦截）。
    返回 (rc, 残留占位路径列表)（供 --progress-file 快照对比）。"""
    try:
        cfg = _read_yaml(path)
    except Exception as e:
        print(f"⛔ 配置不可读 {path}: {e}", file=sys.stderr)
        return 2, []
    findings: list[tuple[str, str]] = []
    _scan(cfg, [], findings, {})
    rc = 0
    if findings:
        rc = 1
        print(f"⛔ {path}: {len(findings)} 处残留占位 {PLACEHOLDER}（api-capture 启动时会拒绝）")
        print("待录清单（可粘贴到 issue / F12 录端点操作手册 references/f12-record.md）：")
        for pth, raw in findings:
            print(f"  - {pth}: {raw!r}")
        print(f"\n操作：")
        print(f"  1) 打开老系统（{cfg.get('api', {}).get('baseUrl', '?')}）→ 浏览器 F12 → Network")
        print(f"  2) 录一次「登录→待办→发起→打开表单→提交」5 个端点，按 references/f12-record.md 抓 JSONPath")
        print(f"  3) 把 yaml 中 `__F12_RECORD__` 占位与同行 TODO 注释替换为真实值；TODO 注释一并删掉")
        print(f"  4) 重跑本脚本确认无残留，再启动 api-capture")
    # 结构完整性：必填块/字段缺件 → 即使无占位也报（launch-first 缺 launch 块会在 run 时才炸，
    # 配置检查现在就报，省一轮 run）
    # 第二十一轮：认识原生化新形态——login.chain（多步登录链）、todo.mode=ledger（账本待办）
    structural: list[str] = []
    api = cfg.get("api")
    if not isinstance(api, dict):
        structural.append("api 块缺失")
    else:
        for block_name in ("login", "todo", "launch", "form", "submit"):
            blk = api.get(block_name)
            if not isinstance(blk, dict):
                structural.append(f"api.{block_name} 块缺失")
                continue
            is_chain_login = block_name == "login" and isinstance(blk.get("chain"), list) and blk["chain"]
            is_ledger_todo = block_name == "todo" and blk.get("mode") == "ledger"
            if not is_chain_login and not is_ledger_todo and not blk.get("method"):
                structural.append(f"api.{block_name}.method 缺失")
            if not blk.get("path") and not is_chain_login and not is_ledger_todo:
                structural.append(f"api.{block_name}.path 缺失")
            if is_chain_login and not (api.get("todo") or {}).get("mode") == "ledger" and not blk.get("tokenPath"):
                structural.append("api.login.chain 须配 tokenFromRedirectQuery 步骤产出 token（或链外 tokenPath）")
        _todo = api.get("todo") or {}
        if not isinstance(_todo, dict):
            structural.append("api.todo 块缺失")
        elif _todo.get("mode") == "ledger":
            if not _todo.get("nextTaskPath"):
                structural.append("api.todo.mode=ledger 须配 nextTaskPath（提交响应中下一任务 ID 的 JSONPath）")
        elif not _todo.get("flowCodePath"):
            structural.append("api.todo.flowCodePath 缺失（流程身份绑定/实例隔离必需）")
        if not api.get("baseUrl"):
            structural.append("api.baseUrl 缺失")
        # v1.3.6 P0：operations 也纳入结构完整性——此前完全不校验，坏配置仍报"可启动 api-capture"
        # （与 api-capture 启动前置校验共用 scripts/ftc_ops_config.py 唯一实现）。
        structural.extend(ftc_ops_config.validate_operations(api.get("operations")))
    if not isinstance(cfg.get("actorMap"), dict) or not cfg.get("actorMap"):
        structural.append("actorMap 缺失/为空（actor → env 名映射必需）")
    if structural:
        rc = max(rc, 1)
        print(f"⛔ {path}: 结构完整性缺口（launch-first/实例隔离无法运行）:")
        for s in structural:
            print(f"  - {s}")
    if rc == 0:
        print(f"✅ {path}: 无残留占位（{PLACEHOLDER}）且结构完整，可启动 api-capture")
    return rc, [pth for pth, _ in findings]


def main() -> None:
    ap = argparse.ArgumentParser()
    grp = ap.add_mutually_exclusive_group(required=True)
    grp.add_argument("--systems", help="单个 systems api yaml 路径")
    grp.add_argument("--systems-dir", help="目录——扫 legacy.yaml + current.yaml")
    ap.add_argument("--progress-file", default="", help="（可选）进度快照 json：记录残留清单，下次跑对比输出'新清/新增'")
    args = ap.parse_args()
    targets = []
    if args.systems:
        targets = [Path(args.systems)]
    else:
        targets = [Path(args.systems_dir) / f"{s}.yaml" for s in ("legacy", "current")]
    rc = 0
    all_findings: dict[str, list[str]] = {}
    for p in targets:
        if not p.exists():
            # 第二十三轮：目标不存在=配置缺失（此前"跳过"仍 exit 0——路径打错得到假绿，
            # 与全链 fail-closed 口径相悖；契约模式本就要求 legacy+current 双文件齐备）
            print(f"⛔ {p} 不存在（配置缺失按不可读处理——fail-closed；"
                  f"先从 skill assets/systems-api/ 示例落位）", file=sys.stderr)
            rc = 2
            continue
        r, fds = check_one(p)
        rc = max(rc, r)
        all_findings[str(p)] = fds
    if args.progress_file:
        pf = Path(args.progress_file)
        prev: dict[str, list[str]] = {}
        try:
            prev = json.loads(pf.read_text(encoding="utf-8")) if pf.exists() else {}
        except Exception:
            prev = {}
        for k, v in all_findings.items():
            cleared = len(prev.get(k, [])) - len(v)
            if cleared > 0:
                print(f"✓ 较上次修复 {cleared} 处残留: {k}")
            added = len(v) - len(prev.get(k, []))
            if added > 0:
                print(f"⚠ 较上次新增 {added} 处残留: {k}")
        pf.parent.mkdir(parents=True, exist_ok=True)
        pf.write_text(json.dumps(all_findings, ensure_ascii=False, indent=1), encoding="utf-8")
    raise SystemExit(rc)


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except Exception as e:
        import traceback
        traceback.print_exc()
        print(f"⛔ 内部异常: {type(e).__name__}: {e}", file=sys.stderr)
        raise SystemExit(2)
