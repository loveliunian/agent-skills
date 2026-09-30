"""Validation helpers for frozen atomic acceptance baselines."""

from __future__ import annotations

import hashlib
import re
import unicodedata
from pathlib import Path
from typing import Any


_SECTION_NUMBER = r"(?:[1-9]\d{0,2}(?:\.\d+)*(?:[.、])?\s+)?"
_BASE_HEADERS = ["验收点 ID", "PRD 需求 ID", "前置条件", "操作/触发", "可观察预期结果", "PRD 位置", "验证方式"]
_COVERAGE_HEADERS = ["PRD 需求 ID", "需求摘要", "原子验收点 ID", "覆盖结论/待澄清项"]
_SCENARIO_HEADERS = ["PRD 来源单元 ID", "PRD 需求 ID", "原子验收点 ID", "映射说明"]
_UNRESOLVED_ACCEPTANCE_MARKERS = (
    "旧版清单未单独列出",
    "复核时确认",
    "待独立复核",
    "待语义复核",
    "待复核",
    "待业务补充",
    "待补充",
    "待确认",
    "TODO",
    "TBD",
    "{{",
    "}}",
)


def _is_stable_id(value: str) -> bool:
    """Validate an opaque project-defined identifier without prescribing its prefix."""
    return bool(value) and value == value.strip() and not any(unicodedata.category(char) == "Cc" for char in value)


def _metadata_value(text: str, label: str) -> str:
    matches = list(re.finditer(rf"(?m)^\s*-\s*{re.escape(label)}\s*[：:]\s*(.*?)\s*$", text))
    if len(matches) > 1:
        raise ValueError(f"元数据重复：{label}")
    if not matches or not matches[0].group(1):
        raise ValueError(f"缺少或为空的元数据：{label}")
    return matches[0].group(1).strip()


def _section_table(text: str, title: str, headers: list[str]) -> list[dict[str, str]]:
    matches = list(re.finditer(rf"(?m)^##\s+{_SECTION_NUMBER}{re.escape(title)}\s*$", text))
    if len(matches) != 1:
        raise ValueError(f"必须且只能包含一个“{title}”章节")
    start = matches[0].end()
    next_heading = re.search(r"(?m)^##\s+", text[start:])
    section = text[start : start + next_heading.start()] if next_heading else text[start:]
    nonempty_lines = [line.strip() for line in section.splitlines() if line.strip()]
    for number, line in enumerate(nonempty_lines, start=1):
        if not line.startswith("|") and "|" in line:
            raise ValueError(f"“{title}”第 {number} 行是表格行但缺少开头的 |")
    lines = [line for line in nonempty_lines if line.startswith("|")]
    if len(lines) < 2:
        raise ValueError(f"“{title}”缺少有效表格")

    parsed_headers = _cells(lines[0])
    if parsed_headers != headers:
        raise ValueError(f"“{title}”表头不符合契约")
    separators = _cells(lines[1])
    if len(separators) != len(headers) or not all(re.fullmatch(r":?-{3,}:?", cell) for cell in separators):
        raise ValueError(f"“{title}”表格分隔行格式错误")

    rows: list[dict[str, str]] = []
    for number, line in enumerate(lines[2:], start=3):
        cells = _cells(line)
        if len(cells) != len(headers):
            raise ValueError(f"“{title}”第 {number} 行列数错误")
        if not any(cells):
            raise ValueError(f"“{title}”第 {number} 行为空")
        rows.append(dict(zip(headers, cells)))
    if not rows:
        raise ValueError(f"“{title}”没有数据行")
    return rows


def _cells(line: str) -> list[str]:
    line = line.strip()
    if line.startswith("|"):
        line = line[1:]
    if line.endswith("|") and not line.endswith(r"\|"):
        line = line[:-1]
    cells: list[str] = []
    current: list[str] = []
    index = 0
    while index < len(line):
        char = line[index]
        if char == "\\" and index + 1 < len(line) and line[index + 1] == "|":
            current.append("|")
            index += 2
            continue
        if char == "|":
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        index += 1
    cells.append("".join(current).strip())
    return cells


def _optional_section_table(text: str, title: str, headers: list[str]) -> list[dict[str, str]]:
    """Parse an optional contract table while still rejecting duplicate/malformed sections."""
    matches = list(re.finditer(rf"(?m)^##\s+{_SECTION_NUMBER}{re.escape(title)}\s*$", text))
    if not matches:
        return []
    try:
        return _section_table(text, title, headers)
    except ValueError as exc:
        if "没有数据行" in str(exc):
            return []
        raise


def parse_acceptance(path: Path) -> dict[str, Any]:
    """Parse required freeze metadata and the two contractual tables."""
    text = Path(path).read_text(encoding="utf-8")
    version = _metadata_value(text, "清单版本")
    status = _metadata_value(text, "状态")
    raw_count = _metadata_value(text, "验收点总数")
    if not re.fullmatch(r"\d+", raw_count):
        raise ValueError("验收点总数必须是非负整数")
    freeze_line = _metadata_value(text, "冻结版本/点数")
    freeze_match = re.fullmatch(r"\s*(.*?)\s*/\s*(\d+)\s*", freeze_line)
    if not freeze_match:
        raise ValueError("冻结版本/点数格式应为“版本 / 点数”")

    return {
        "version": version,
        "status": status,
        "declared_count": int(raw_count),
        "frozen_version": freeze_match.group(1),
        "frozen_count": int(freeze_match.group(2)),
        "acceptance_rows": _section_table(text, "原子验收点", _BASE_HEADERS),
        "coverage_rows": _section_table(text, "需求覆盖检查", _COVERAGE_HEADERS),
        "scenario_rows": _optional_section_table(text, "PRD验收场景映射", _SCENARIO_HEADERS),
    }


def import_legacy_acceptance(
    source_path: Path,
    destination_path: Path,
    project_name: str | None = None,
    requirement_map: dict[str, list[str]] | None = None,
) -> dict[str, Any]:
    """Convert grouped frozen AC tables to develop's canonical table without claiming review.

    The adapter preserves each legacy statement, ID, validation method and PRD anchor. It
    derives the group's requirement reference from an explicit map or the legacy group ID,
    and labels the baseline as pending review so check-prd cannot treat conversion as freeze.
    """
    source_path = Path(source_path)
    text = source_path.read_text(encoding="utf-8")
    lines = text.splitlines()
    heading = re.search(r"(?m)^#\s+(.+?)\s*$", text)
    source_title = heading.group(1).strip() if heading else (project_name or "Imported PRD")
    if not project_name:
        project_name = re.sub(r"^(?:原子验收点清单\s*[-—｜|]\s*)", "", source_title)
    date_match = re.search(r"(?m)^\|\s*拆分日期\s*\|\s*([^|]+?)\s*\|", text)
    source_date = date_match.group(1).strip() if date_match else "unknown-date"
    requirements = requirement_map or {}
    groups: list[tuple[str, str, list[dict[str, str]]]] = []
    current_group: tuple[str, str] | None = None
    current_rows: list[dict[str, str]] = []
    aliases = {
        "验收点ID": "验收点 ID", "验收点 ID": "验收点 ID",
        "验收点描述": "验收点描述", "验证方式": "验证方式",
        "PRD原文锚点": "PRD原文锚点", "PRD 原文锚点": "PRD原文锚点",
        "状态": "状态",
    }
    canonical_headers = {"验收点 ID", "验收点描述", "验证方式", "PRD原文锚点", "状态"}

    def flush_group() -> None:
        nonlocal current_group, current_rows
        if current_group is not None and current_rows:
            groups.append((current_group[0], current_group[1], current_rows))
        current_group = None
        current_rows = []

    index = 0
    while index < len(lines):
        line = lines[index].strip()
        group_match = re.match(r"^#{3,6}\s*功能\s+([^：:]+)[：:]\s*(.+)$", line)
        if group_match:
            flush_group()
            current_group = (group_match.group(1).strip(), group_match.group(2).strip())
            index += 1
            continue
        if current_group is None or not line.startswith("|"):
            index += 1
            continue
        header_cells = _cells(line)
        normalized_headers = [aliases.get(cell.strip()) for cell in header_cells]
        if set(normalized_headers) != canonical_headers:
            index += 1
            continue
        index += 1
        if index < len(lines) and lines[index].strip().startswith("|"):
            index += 1  # separator row
        while index < len(lines) and lines[index].strip().startswith("|"):
            cells = _cells(lines[index].strip())
            if len(cells) != len(normalized_headers):
                raise ValueError(f"legacy acceptance row has {len(cells)} cells, expected {len(normalized_headers)} at line {index + 1}")
            row = dict(zip(normalized_headers, cells))
            if row.get("验收点 ID", "").strip():
                current_rows.append(row)
            index += 1
    flush_group()

    if not groups:
        raise ValueError("未找到按‘### 功能 <ID>：<名称>’分组的旧版验收点表")
    all_ids = [row["验收点 ID"].strip() for _, _, rows in groups for row in rows]
    if len(all_ids) != len(set(all_ids)):
        raise ValueError("旧版验收清单中存在重复验收点 ID")
    invalid = [row["验收点 ID"] for _, _, rows in groups for row in rows if row.get("状态", "").strip().upper() != "FROZEN"]
    if invalid:
        raise ValueError(f"旧版验收清单存在未冻结验收点：{invalid[:5]}")

    source_sha256 = hashlib.sha256(source_path.read_bytes()).hexdigest()
    digest = source_sha256[:12]
    version = f"legacy-{source_date}-{digest}"
    escape = lambda value: str(value).replace("|", r"\|").replace("\n", "<br>")
    out = [
        f"# {project_name}｜原子验收点清单（导入待复核）",
        "",
        f"- 清单版本：{version}",
        "- 状态：导入待复核",
        f"- 验收点总数：{len(all_ids)}",
        f"- 冻结版本/点数：{version} / {len(all_ids)}",
        "",
        "## 验收基线",
        "",
        f"由旧版冻结清单 {source_path.name} 转换；原文件 SHA256：{source_sha256}。保留 AC ID、原描述、验证方式和 PRD 锚点。导入仅完成格式映射，不替代对需求映射和原子性的复核。",
        "",
        "## 原子拆分准则",
        "",
        "本表按旧版验收点分组逐项保留。对旧表未单独列出的前置条件与触发操作，不在转换时推断，需在复核时补足或确认原描述已足够明确。",
        "",
        "## 原子验收点",
        "",
        "| 验收点 ID | PRD 需求 ID | 前置条件 | 操作/触发 | 可观察预期结果 | PRD 位置 | 验证方式 |",
        "|---|---|---|---|---|---|---|",
    ]
    for group_id, group_title, rows in groups:
        mapped = requirements.get(group_id, [f"UNMAPPED:{group_id}"])
        if not isinstance(mapped, list) or not mapped or any(not isinstance(item, str) or not item.strip() for item in mapped):
            raise ValueError(f"需求映射必须为非空 ID 列表：{group_id}")
        req_text = "、".join(mapped)
        for row in rows:
            out.append("| " + " | ".join([
                escape(row["验收点 ID"].strip()), escape(req_text),
                "旧版清单未单独列出；复核时确认是否可由验收点描述表达",
                "旧版清单未单独列出；按验收点描述执行",
                escape(row["验收点描述"].strip()), escape(row["PRD原文锚点"].strip()), escape(row["验证方式"].strip()),
            ]) + " |")
    out.extend(["", "## 需求覆盖检查", "", "| PRD 需求 ID | 需求摘要 | 原子验收点 ID | 覆盖结论/待澄清项 |", "|---|---|---|---|"])
    for group_id, group_title, rows in groups:
        mapped = requirements.get(group_id, [f"UNMAPPED:{group_id}"])
        ids = "、".join(row["验收点 ID"].strip() for row in rows)
        for req_id in mapped:
            out.append(f"| {escape(req_id)} | {escape(group_title)} | {escape(ids)} | 旧版功能分组映射，待独立复核 PRD 需求对应关系 |")
    out.extend([
        "", "## 测试夹具与实现验证TODO（非设计未决项）", "",
        "导入草稿尚未独立复核测试夹具；复核时如存在待实现夹具，应记录对应 AC、触发步骤、可观察结果和清理方式。夹具待实现不代表业务结果未决。", "",
        "", "## 评审与冻结", "",
        "- 来源文档版本：" + version,
        "- 转换结论：待独立复核；当前状态不得用于 render-design。",
        "- 冻结前须核对每个需求 ID、AC ID、原文锚点、原子性、前置条件、操作和可观察结果。",
        "", "## 变更记录", "", "| 版本 | 日期 | 变更的验收点 ID | 原因 | 受影响的详设/测试更新 |", "|---|---|---|---|---|",
        f"| {version} | {source_date} | 全部 {len(all_ids)} 项 | 导入旧版清单，待评审 | 详设/测试尚未更新 |",
        "", "## PRD验收场景映射", "",
        "| PRD 来源单元 ID | PRD 需求 ID | 原子验收点 ID | 映射说明 |",
        "|---|---|---|---|",
    ])
    Path(destination_path).write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
    return {"version": version, "count": len(all_ids), "groups": len(groups), "source_title": source_title, "project_name": project_name}


def _ids(value: str) -> list[str]:
    if not value.strip():
        return []
    parts = [part.strip() for part in re.split(r"[,，、]", value)]
    if any(not part for part in parts):
        raise ValueError(f"ID 列表包含空成员：{value!r}")
    if len(parts) != len(set(parts)):
        raise ValueError(f"ID 列表包含重复成员：{value!r}")
    return parts


def _row_ids(rows: list[dict[str, str]], field: str) -> set[str]:
    found: set[str] = set()
    for row in rows:
        found.update(_ids(row.get(field, "")))
    return found


def validate_acceptance(
    requirement_ledger: dict[str, Any], parsed: dict[str, Any], require_frozen: bool = True,
    inventory: dict[str, Any] | None = None,
) -> list[str]:
    """Return semantic validation errors; raise ValueError for malformed delimited ID lists."""
    errors: list[str] = []
    version = str(parsed.get("version", "")).strip()
    status = str(parsed.get("status", "")).strip()
    rows = parsed.get("acceptance_rows")
    coverage = parsed.get("coverage_rows")
    if not version:
        errors.append("缺少清单版本")
    if require_frozen and status != "已冻结":
        errors.append(f"验收基线状态不是已冻结：{status or '未填写'}")
    if not isinstance(rows, list) or not rows:
        errors.append("原子验收点表缺失或为空")
        rows = []
    if not isinstance(coverage, list) or not coverage:
        errors.append("需求覆盖检查表缺失或为空")
        coverage = []

    ac_ids: list[str] = []
    ac_to_reqs: dict[str, set[str]] = {}
    for index, row in enumerate(rows, 1):
        if not isinstance(row, dict):
            errors.append(f"原子验收点第 {index} 行格式错误")
            continue
        ac_id = str(row.get("验收点 ID", "")).strip()
        if not _is_stable_id(ac_id):
            errors.append(f"验收点 ID 不能为空或包含控制字符：{ac_id or f'第 {index} 行为空'}")
        else:
            ac_ids.append(ac_id)
        for field in _BASE_HEADERS[1:]:
            field_value = str(row.get(field, "")).strip()
            if not field_value:
                errors.append(f"{ac_id or f'第 {index} 行'}缺少必填字段：{field}")
            elif field in {"前置条件", "操作/触发", "可观察预期结果", "验证方式"}:
                marker = next(
                    (item for item in _UNRESOLVED_ACCEPTANCE_MARKERS if item.casefold() in field_value.casefold()),
                    None,
                )
                if marker:
                    errors.append(f"{ac_id or f'第 {index} 行'}的 {field} 仍包含待复核占位标记：{marker}")
        ac_to_reqs[ac_id] = set(_ids(str(row.get("PRD 需求 ID", ""))))
    duplicates = sorted({item for item in ac_ids if ac_ids.count(item) > 1})
    errors.extend(f"验收点 ID 重复：{item}" for item in duplicates)

    declared_count = parsed.get("declared_count")
    if not isinstance(declared_count, int) or isinstance(declared_count, bool):
        errors.append("验收点总数声明无效")
    elif declared_count != len(rows):
        errors.append(f"声明验收点数 {declared_count} 与实际点数 {len(rows)} 不一致")
    frozen_count = parsed.get("frozen_count")
    if not isinstance(frozen_count, int) or isinstance(frozen_count, bool):
        errors.append("冻结点数声明无效")
    elif require_frozen and frozen_count != declared_count:
        errors.append(f"冻结版本点数 {frozen_count} 与声明点数 {declared_count} 不一致")
    frozen_version = str(parsed.get("frozen_version", "")).strip()
    if not frozen_version:
        errors.append("缺少冻结版本")
    elif require_frozen and version and frozen_version != version:
        errors.append(f"冻结版本 {frozen_version} 与清单版本 {version} 不一致")

    ledger_items = requirement_ledger.get("requirements") if isinstance(requirement_ledger, dict) else None
    if not isinstance(ledger_items, list):
        errors.append("需求台账缺少 requirements 列表")
        ledger_items = []
    ledger_by_id: dict[str, dict[str, Any]] = {}
    for item in ledger_items:
        if not isinstance(item, dict) or not str(item.get("id", "")).strip():
            errors.append("需求台账包含缺少 id 的需求")
            continue
        req_id = str(item["id"]).strip()
        if not isinstance(item.get("testable"), bool):
            errors.append(f"需求 {req_id} 的 testable 必须显式为布尔值")
        if not isinstance(item.get("mandatory"), bool):
            errors.append(f"需求 {req_id} 的 mandatory 必须显式为布尔值")
        if not str(item.get("status", "")).strip():
            errors.append(f"需求 {req_id} 缺少 status")
        elif item.get("status") not in {"已确认", "待澄清", "已排除"}:
            errors.append(f"需求 {req_id} 的 status 无效：{item.get('status')}")
        if req_id in ledger_by_id:
            errors.append(f"需求台账 ID 重复：{req_id}")
        ledger_by_id[req_id] = item
        if item.get("mandatory") is True:
            if item.get("status") == "已排除":
                if not str(item.get("resolution_reason", "")).strip():
                    errors.append(f"强制需求 {req_id} 已排除但缺少 resolution_reason")
            elif item.get("status") != "已确认":
                errors.append(f"强制需求 {req_id} 状态未解决：{item.get('status') or '未填写'}")

    ac_reqs = _row_ids(rows, "PRD 需求 ID")
    coverage_reqs: set[str] = set()
    for index, row in enumerate(coverage, 1):
        if not isinstance(row, dict):
            errors.append(f"需求覆盖检查第 {index} 行格式错误")
            continue
        req_id = str(row.get("PRD 需求 ID", "")).strip()
        if not req_id:
            errors.append(f"需求覆盖检查第 {index} 行缺少 PRD 需求 ID")
        else:
            coverage_reqs.add(req_id)
        for field in _COVERAGE_HEADERS[1:]:
            field_value = str(row.get(field, "")).strip()
            if not field_value:
                errors.append(f"需求覆盖检查第 {index} 行缺少必填字段：{field}")
            elif require_frozen and field == "覆盖结论/待澄清项":
                marker = next(
                    (item for item in _UNRESOLVED_ACCEPTANCE_MARKERS if item.casefold() in field_value.casefold()),
                    None,
                )
                if marker:
                    errors.append(f"需求覆盖检查第 {index} 行仍包含未关闭标记：{marker}")
        linked_ids = _ids(str(row.get("原子验收点 ID", "")))
        for linked_id in linked_ids:
            if not _is_stable_id(linked_id):
                errors.append(f"需求覆盖检查中的验收点 ID 为空或包含控制字符：{linked_id}")
            elif linked_id not in ac_to_reqs:
                errors.append(f"需求覆盖检查引用不存在的验收点：{linked_id}")
            elif req_id and req_id not in ac_to_reqs[linked_id]:
                errors.append(f"需求覆盖检查 {req_id} 与验收点 {linked_id} 的需求关联不一致")

    scenario_rows = parsed.get("scenario_rows", [])
    expected_scenarios: dict[str, dict[str, Any]] = {}
    if isinstance(inventory, dict):
        acceptance_headers = {"场景或前置条件", "触发/动作", "预期业务结果", "关键约束或异常结果"}
        expected_scenarios = {
            unit.get("id"): unit
            for unit in inventory.get("units", [])
            if isinstance(unit, dict)
            and unit.get("source_role") == "primary_prd"
            and unit.get("kind") == "table_row"
            and acceptance_headers.issubset(set(unit.get("table_headers", [])))
            and "7.1 功能详细设计" in unit.get("heading_path", [])
            and any(re.search(r"FUN-[0-9]{3}", heading) for heading in unit.get("heading_path", []))
        }
        if expected_scenarios and not scenario_rows and require_frozen:
            errors.append(f"缺少 PRD 验收场景到原子验收点的逐行映射：{len(expected_scenarios)} 个来源场景")

    scenario_refs: set[str] = set()
    source_index = {
        unit.get("id"): unit
        for unit in (inventory or {}).get("units", [])
        if isinstance(unit, dict) and unit.get("id")
    }
    for index, row in enumerate(scenario_rows, 1):
        if not isinstance(row, dict):
            errors.append(f"PRD验收场景映射第 {index} 行格式错误")
            continue
        source_ref = str(row.get("PRD 来源单元 ID", "")).strip()
        req_ids = set(_ids(str(row.get("PRD 需求 ID", ""))))
        linked_ids = set(_ids(str(row.get("原子验收点 ID", ""))))
        rationale = str(row.get("映射说明", "")).strip()
        if not source_ref or not _is_stable_id(source_ref):
            errors.append(f"PRD验收场景映射第 {index} 行缺少有效来源 ID")
        elif source_ref not in source_index:
            errors.append(f"PRD验收场景映射引用不存在的来源单元：{source_ref}")
        elif expected_scenarios and source_ref not in expected_scenarios:
            errors.append(f"PRD验收场景映射来源不是验收场景单元：{source_ref}")
        if source_ref:
            if source_ref in scenario_refs:
                errors.append(f"PRD验收场景来源重复映射：{source_ref}")
            scenario_refs.add(source_ref)
        if not req_ids:
            errors.append(f"PRD验收场景映射第 {index} 行缺少需求 ID")
        for req_id in req_ids:
            if req_id not in ledger_by_id:
                errors.append(f"PRD验收场景映射引用不存在的需求：{req_id}")
        if not linked_ids:
            if require_frozen or "未映射" not in rationale:
                errors.append(f"PRD验收场景映射第 {index} 行没有原子验收点")
        for ac_id in linked_ids:
            if ac_id not in ac_to_reqs:
                errors.append(f"PRD验收场景映射引用不存在的验收点：{ac_id}")
            elif req_ids and not (req_ids & ac_to_reqs[ac_id]):
                errors.append(f"PRD验收场景映射 {source_ref} 的需求与验收点 {ac_id} 不一致")
        if not rationale:
            errors.append(f"PRD验收场景映射第 {index} 行缺少映射说明")
        elif require_frozen:
            marker = next(
                (item for item in _UNRESOLVED_ACCEPTANCE_MARKERS if item.casefold() in rationale.casefold()),
                None,
            )
            if marker:
                errors.append(f"PRD验收场景映射第 {index} 行仍包含未关闭标记：{marker}")

    if expected_scenarios and require_frozen:
        missing_scenarios = sorted(set(expected_scenarios) - scenario_refs)
        if missing_scenarios:
            errors.append(
                f"PRD验收场景未映射到原子验收点：{len(missing_scenarios)} 项，示例={missing_scenarios[:5]}"
            )

    referenced_reqs = ac_reqs | coverage_reqs
    for req_id in sorted(referenced_reqs - ledger_by_id.keys()):
        errors.append(f"引用的需求不存在于台账：{req_id}")
    confirmed_requirements = {
        req_id
        for req_id, item in ledger_by_id.items()
        if item.get("status") == "已确认"
    }
    for req_id in sorted(confirmed_requirements):
        if req_id not in ac_reqs:
            errors.append(f"已确认需求 {req_id} 未映射到原子验收点")
        if req_id not in coverage_reqs:
            errors.append(f"已确认需求 {req_id} 未出现在需求覆盖检查表")
        if not any(
            req_id in _ids(str(row.get("PRD 需求 ID", "")))
            and any(linked in ac_to_reqs and req_id in ac_to_reqs[linked] for linked in _ids(str(row.get("原子验收点 ID", ""))))
            for row in coverage
            if isinstance(row, dict)
        ):
            errors.append(f"已确认需求 {req_id} 在覆盖表中没有关联验收点")
    return errors


def freeze_fingerprint(path: Path) -> str:
    """Return the SHA-256 fingerprint of the exact frozen document bytes."""
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()
