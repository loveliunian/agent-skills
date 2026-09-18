#!/usr/bin/env python3
# check-contract-consistency.py · Contract Registry 一致性 linter（v3.27.2 · 审查报告 P0-1）
# =============================================================================
# 来源：深度审查报告 P0 建议——"同一概念有 7~8 处定义"是当前最大架构风险。
# 本脚本校验跨文件契约一致性，防止再次发生 sample/probe/section 漂移。
# 检查项（逐步扩展）：
#   1. sample template.version == 当前 SKILL.md 版本
#   2. schema probe enum 覆盖 methodology 声明的探针 ID
#   3. spawn 时序措辞一致性（禁止"spawn 前 begin"）
#   4. core.md 禁止技术栈字面量（stack-neutral 契约）
# =============================================================================
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
errors = []
warnings = []


def get_skill_version():
    text = (ROOT / "SKILL.md").read_text(encoding="utf-8")
    m = re.search(r'version: "([0-9.]+)"', text)
    return m.group(1) if m else ""


def check_sample_versions(skill_ver):
    """检查 structured sample 的 template.version 是否与 SKILL.md 版本一致"""
    for f in sorted((ROOT / "examples" / "structured").glob("*.sample.json")):
        try:
            d = json.loads(f.read_text(encoding="utf-8"))
            tv = d.get("template", {}).get("version", "")
            if tv and tv != skill_ver:
                # 允许历史 fixture 版本（测试夹具故意使用旧版本时由测试自行控制）
                errors.append(
                    f"sample template.version 漂移: {f.relative_to(ROOT)} "
                    f"version={tv!r} != SKILL.md {skill_ver!r}"
                )
        except (json.JSONDecodeError, KeyError):
            pass


def check_probe_enum():
    """检查 schema probe enum 是否覆盖 methodology 声明的探针"""
    schema_path = ROOT / "schemas" / "design-review.schema.json"
    if not schema_path.is_file():
        return
    try:
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        errors.append("design-review.schema.json JSON 解析失败")
        return
    enum_ids = set()
    # 递归搜索 schema 中所有含 "P1" 的 enum 数组
    def _find_enums(obj):
        if isinstance(obj, dict):
            for k, v in obj.items():
                if k == "enum" and isinstance(v, list) and "P1" in v:
                    enum_ids.update(v)
                else:
                    _find_enums(v)
        elif isinstance(obj, list):
            for item in obj:
                _find_enums(item)
    _find_enums(schema)
    # methodology 中声明的探针 ID
    meth = ROOT / "concepts" / "review-depth-methodology.md"
    if meth.is_file():
        text = meth.read_text(encoding="utf-8")
        # 抓取表格行中的 P[N] 探针 ID
        for m in re.finditer(r"\b(P[1-9][a-c]?)\b", text):
            pid = m.group(1)
            if pid not in enum_ids and pid not in ("P1", "P2", "P3", "P4", "P5", "P6"):
                # P4a/b/c 和 P7 是新增的，不在 enum 中即报错
                if pid in ("P4a", "P4b", "P4c", "P7"):
                    errors.append(
                        f"methodology 探针 {pid} 不在 schema enum 中 "
                        f"(enum={sorted(enum_ids)})——契约分裂"
                    )


def check_spawn_timing():
    """检查"spawn 前 begin"矛盾措辞"""
    offenders = []
    for rel in [
        "commands/design-review.md",
        "scripts/p2a_design_review_gate.sh",
    ]:
        f = ROOT / rel
        if f.is_file() and re.search(r"spawn\s*前\s*began|spawn\s*前\s*begin|在 spawn 前 begin", f.read_text(encoding="utf-8")):
            offenders.append(rel)
    if offenders:
        errors.append(
            f'spawn 时序措辞矛盾（应为"spawn 返回 agent_id 后 begin"）: {offenders}'
        )


def check_core_stack_literals():
    """检查 core.md 是否泄漏技术栈字面量（允许注释/历史引用）"""
    core = ROOT / "concepts" / "core.md"
    if not core.is_file():
        return
    text = core.read_text(encoding="utf-8")
    # 去掉代码块和历史教训引用（只查正文叙述）
    clean = re.sub(r"```.*?```", "", text, flags=re.S)
    clean = re.sub(r"<!--.*?-->", "", clean, flags=re.S)
    # 这些字面量不应出现在 Core 正文
    forbidden = [
        (r"@PreAuthorize", "@PreAuthorize"),
        (r"\bFlyway\b", "Flyway"),
        (r"\bJaCoCo\b", "JaCoCo"),
        (r"src/main/java", "src/main/java"),
        (r"\bMyBatis\b", "MyBatis"),
    ]
    for pat, label in forbidden:
        if re.search(pat, clean):
            # 白名单：core.md 的禁止声明本身（"不得假设 Maven/Spring/Flyway"）不算泄漏
            context = [l for l in clean.splitlines() if re.search(pat, l)]
            real_leak = [l for l in context if not re.search(r"不(得|能|应)?假设|不(得|能|应)?预设|禁止|不得.*Flyway|stack.neutral|stack.specific|MUST NOT", l, re.I)]
            if real_leak:
                errors.append(f"core.md 技术栈字面量泄漏: {label} → {real_leak[0][:80]}")


def main():
    skill_ver = get_skill_version()
    if not skill_ver:
        errors.append("SKILL.md version 字段缺失")
        return 1
    print(f"contract-consistency: SKILL.md version = {skill_ver}")
    check_sample_versions(skill_ver)
    check_probe_enum()
    check_spawn_timing()
    check_core_stack_literals()
    if errors:
        print(f"\nCONTRACT CONSISTENCY: FAIL ({len(errors)} errors)")
        for e in errors:
            print(f"  ✗ {e}")
        return 1
    print("CONTRACT CONSISTENCY: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
