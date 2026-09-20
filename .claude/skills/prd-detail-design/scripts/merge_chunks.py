# -*- coding: utf-8 -*-
"""详设分片合并器：把多个 detail_design.part-*.json 合并为完整 detail_design.json。

为什么需要它：
  大 PRD 生成的 detail_design.json 可能超过单次写入的体积上限，导致生成失败
  （已发生：整文件一次 Write 超限）。解法是「分片产出、机器合并」：按 chunk
  （或任意划分）写多个 part 文件，再由本脚本确定性拼装。人手拼 JSON 必错，
  拼装权必须下沉到脚本层。

part 文件约定：
  - 命名：detail_design.part-01.json、part-02…（按文件名字典序合并，编号留缺口
    视作缺片，报错退出）；
  - 内容：detail_design.json 的任意顶层子集（通常 part-01 放
    meta/architecture/techStack/frontend，其余每 part 放一个或多个 chunk），
    允许每个 part 都是完整骨架的局部覆盖，脚本按策略合并；
  - 不要求 part 内部自洽，最终一致性由 run_design.py 的 schema+闭环校验兜底。

合并策略（确定性，无 AI 参与）：
  - dict：递归合并；
  - list of dict：按键去重拼接（键取该列表的天然主键，如 chunkId/acceptanceId/
    pages 的 route；无主键列表直接拼接去重）；同主键且内容完全相同 = 重复产出，
    静默去重；同主键但内容不同 = FAIL（禁止静默融合，人工决定留哪版）；
  - list of 标量：拼接去重保序；
  - 标量：后者覆盖前者，冲突（值不同且都非占位）打印 WARN 供人核对。

用法：
  python merge_chunks.py --parts "design/ch-07/detail_design.part-*.json" \
      --out design/ch-07/detail_design.json
  成功后建议立刻跑 run_design.py 四段流水做全量校验。
"""
import argparse
import glob
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# 各列表的天然主键（按路径定位）：用于去重与冲突检测
_LIST_KEYS = {
    "chunks": "chunkId",
    "techStack": "layer",
    "frontend.pages": "route",
    "frontend.interactions": "id",
    "frontend.dialogs": "id",
    "frontend.contracts": "id",
}
# 列表元素兜底主键候选（路径未登记时按序探测）
_FALLBACK_KEYS = ("id", "acceptanceId", "chunkId", "name", "route", "path", "key")
_SCALAR = (str, int, float, bool, type(None))


def _key_of(path, item):
    """取列表元素的合并主键：优先路径登记键，再探测兜底键，无则 None。"""
    if not isinstance(item, dict):
        return None
    name = path.rsplit(".", 1)[-1]
    if name in _LIST_KEYS and _LIST_KEYS[name] in item:
        return item[_LIST_KEYS[name]]
    for k in _FALLBACK_KEYS:
        if k in item:
            return item[k]
    return None


def _merge_list(base, over, path, warns, fatals):
    seen = OrderedDict()
    for item in list(base) + list(over):
        key = _key_of(path, item)
        if key is None:
            # 无主键：标量去重拼接；dict 整条保留（允许重复，交给 schema 校验）
            seen[("raw", json.dumps(item, ensure_ascii=False, sort_keys=True))] = item
        else:
            if key in seen:
                if json.dumps(seen[key], ensure_ascii=False, sort_keys=True) == \
                        json.dumps(item, ensure_ascii=False, sort_keys=True):
                    continue  # 完全相同的重复条目（同片重复产出）：静默去重
                if isinstance(seen[key], dict) and isinstance(item, dict):
                    # 同主键且内容不同：不再递归融合，直接 FAIL——静默融合会把两版
                    # 差异吞掉只留一版，宁可停机让人决定留哪版
                    fatals.append(
                        f"{path} 主键 {key!r} 在不同 part 中内容不同——禁止静默融合，"
                        f"请人工核对后只保留正确版本")
                else:
                    fatals.append(f"{path} 主键 {key!r} 冲突且内容不同")
            else:
                seen[key] = item
    return list(seen.values())


def _merge(base, over, path, warns, fatals=None, key_hint=None):
    if fatals is None:
        fatals = []
    tag = f"{path}[{key_hint}]" if key_hint else path
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = _merge(out[k], v, f"{path}.{k}", warns, fatals) if k in out else v
        return out
    if isinstance(base, list) and isinstance(over, list):
        return _merge_list(base, over, path, warns, fatals)
    if isinstance(base, _SCALAR) and isinstance(over, _SCALAR):
        if base != over and base is not None:
            warns.append(f"{tag} 标量冲突: {base!r} -> {over!r}（后者覆盖）")
        return over
    # 类型不一致：后者整体覆盖并告警
    if base != over:
        warns.append(f"{tag} 类型不一致, 后者覆盖: {type(base).__name__} <- {type(over).__name__}")
    return over


def main():
    ap = argparse.ArgumentParser(description="合并 detail_design 分片 part 文件")
    ap.add_argument("--parts", required=True,
                    help="part 文件 glob，如 'design/ch-07/detail_design.part-*.json'")
    ap.add_argument("--out", required=True, help="合并输出路径（detail_design.json）")
    ap.add_argument("--expect", type=int, default=0,
                    help="期望的 part 数量，用于缺口检查（0=不检查）")
    args = ap.parse_args()

    files = sorted(glob.glob(args.parts))
    if not files:
        print(f"[FAIL] glob 未匹配到任何 part 文件: {args.parts}")
        return 1
    # 编号缺口检查：part-NN 序列必须连续，缺片说明有分片未产出
    nums = []
    for f in files:
        m = re.search(r"part-(\d+)\.json$", f)
        if m:
            nums.append(int(m.group(1)))
    if nums and nums != list(range(1, max(nums) + 1)):
        missing = sorted(set(range(1, max(nums) + 1)) - set(nums))
        print(f"[FAIL] part 编号不连续，缺片: {missing} —— 先补齐分片再合并，禁止带洞拼装")
        return 1
    if args.expect and len(files) != args.expect:
        print(f"[FAIL] 期望 {args.expect} 个 part，实际 {len(files)} 个")
        return 1

    warns = []
    fatals = []
    merged = {}
    for f in files:
        with open(f, encoding="utf-8") as fh:
            part = json.load(fh)
        if not isinstance(part, dict):
            print(f"[FAIL] {f} 顶层不是对象，无法合并")
            return 1
        merged = _merge(merged, part, Path(f).name, warns, fatals)

    if fatals:
        for e in fatals:
            print(f"[FAIL] {e}")
        print(f"合并中止：共 {len(fatals)} 处同主键内容冲突，请修正 part 文件后重合并。")
        return 1

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as fh:
        json.dump(merged, fh, ensure_ascii=False, indent=2)

    top = ", ".join(merged.keys())
    print(f"[OK] 合并 {len(files)} 个 part -> {args.out}（顶层键: {top}）")
    for w in warns:
        print(f"[WARN] {w}")
    print("下一步：python run_design.py --input ... --issues ... 跑四段流水做全量校验")
    return 0


if __name__ == "__main__":
    sys.exit(main())
