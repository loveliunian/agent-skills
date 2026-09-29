"""Deterministic PRD source inventory and requirement-ledger validation."""

import hashlib
import json
import ntpath
import re
import unicodedata
from collections import Counter
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlsplit


PARSER_VERSION = "2"
SOURCE_ROLES = {
    "technical_constraints", "clarification", "domain_review", "prd_review",
    "acceptance_baseline", "architecture_decisions", "api_contracts", "database_schema",
    "implementation_baseline", "other",
}
CLASSIFICATIONS = {
    "functional_requirement",
    "business_rule",
    "entity_data",
    "operation",
    "permission",
    "workflow",
    "ui",
    "quality",
    "constraint",
    "assumption",
    "non_goal",
    "risk",
    "context",
    "unresolved_question",
    "duplicate",
    "non_requirement",
}
REASON_REQUIRED = {"context", "duplicate", "non_requirement"}
REQUIREMENT_CLASSIFICATIONS = {
    "functional_requirement", "business_rule", "entity_data", "operation", "permission",
    "workflow", "ui", "quality", "constraint", "unresolved_question",
}
_HEADING = re.compile(r"^(#{1,6})[ \t]+(.+?)[ \t]*#*[ \t]*$")
_HEADING_NUMBER = re.compile(r"^(?:[1-9]\d{0,2})(?:\.\d+)*(?:[.、])?[ \t]+")
_LIST = re.compile(r"^( *)(?:[-+*]|\d+[.)])[ \t]+(.*)$")
_HTML_BLOCK_START = re.compile(r"^(?:<!--|<!DOCTYPE|</?[A-Za-z][^>]*>)", re.IGNORECASE)
_HTML_REFERENCE_ELEMENT = re.compile(r"<([A-Za-z][A-Za-z0-9:-]*)\b[^>]*>", re.IGNORECASE)
_HTML_ATTRIBUTE = re.compile(r"\b(src|alt|href|poster|title|data|srcset)\s*=\s*(?:([\"'])(.*?)\2|([^\s\"'=<>`]+))", re.IGNORECASE)
_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_SETEXT_UNDERLINE = re.compile(r"^ {0,3}(?:=+|-+)\s*$")
_TABLE_SEPARATOR_CELL = re.compile(r":?-{3,}:?")
_ASSET_LINK = re.compile(r"(!?)\[([^\]]*)\]\((<[^>]+>|[^)\s]+)(?:\s+[^)]*)?\)")
_REFERENCE_LINK = re.compile(r"(!?)\[([^\]]+)\]\[([^\]]*)\]")
_LINK_DEFINITION = re.compile(r"^ {0,3}\[([^\]]+)\]:\s*(?:<([^>]+)>|(?:\"([^\"]*)\"|'([^']*)'|(\S+)))")
REQUIREMENT_STATUSES = {"已确认", "待澄清", "已排除"}
MAX_ASSET_BYTES = 20 * 1024 * 1024
ASSET_HASH_CHUNK_BYTES = 1024 * 1024
MAX_PRD_BYTES = 10 * 1024 * 1024
PRD_READ_CHUNK_BYTES = 1024 * 1024
_MISSING = object()


def _normalize(value):
    return " ".join(unicodedata.normalize("NFC", value).split()).casefold()


def _relative_source_path(path, project_root=None):
    path = path.resolve()
    if project_root is not None:
        root = Path(project_root).resolve()
        try:
            return path.relative_to(root).as_posix()
        except ValueError as exc:
            raise ValueError(f"PRD path is outside project_root: {path}") from exc
    # Direct callers get a stable path relative to the source file's parent.
    return path.relative_to(path.parent).as_posix()


def _table_cells(line):
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|"):
        backslashes = 0
        for char in reversed(text[:-1]):
            if char != "\\":
                break
            backslashes += 1
        if backslashes % 2 == 0:
            text = text[:-1]
    cells = []
    cell = []
    index = 0
    while index < len(text):
        if text[index] == "\\" and index + 1 < len(text) and text[index + 1] == "|":
            cell.append("|")
            index += 2
        elif text[index] == "|":
            cells.append("".join(cell).strip())
            cell = []
            index += 1
        else:
            cell.append(text[index])
            index += 1
    cells.append("".join(cell).strip())
    return cells


def _is_separator(line):
    cells = _table_cells(line)
    return bool(cells) and all(_TABLE_SEPARATOR_CELL.fullmatch(cell.replace(" ", "")) for cell in cells)


def _hash_local_asset(target, prd_path, project_root=None, max_bytes=None):
    """Hash a local asset only when its resolved file is bounded by the project root."""
    parsed = urlsplit(target)
    if parsed.scheme or parsed.netloc:
        return "unresolved", None
    local_target = unquote(parsed.path)
    if not local_target:
        return "unresolved", None
    root = Path(project_root).resolve() if project_root is not None else Path(prd_path).resolve().parent
    candidate = Path(local_target)
    if not candidate.is_absolute():
        candidate = Path(prd_path).resolve().parent / candidate
    try:
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(root)
        asset_limit = MAX_ASSET_BYTES if max_bytes is None else max_bytes
        if not resolved.is_file() or resolved.stat().st_size > asset_limit:
            return "unresolved", None
        digest = hashlib.sha256()
        total = 0
        with resolved.open("rb") as source:
            while True:
                chunk = source.read(min(ASSET_HASH_CHUNK_BYTES, asset_limit + 1 - total))
                if not chunk:
                    break
                total += len(chunk)
                if total > asset_limit:
                    return "unresolved", None
                digest.update(chunk)
        return "resolved", digest.hexdigest()
    except (OSError, RuntimeError, ValueError):
        return "unresolved", None


def scan_prd(
    path: Path,
    project_root: Path | None = None,
    max_prd_bytes: int | None = None,
    max_asset_bytes: int | None = None,
) -> dict:
    """Inventory Markdown source blocks without dropping unfamiliar constructs."""
    path = Path(path)
    prd_limit = MAX_PRD_BYTES if max_prd_bytes is None else max_prd_bytes
    asset_limit = MAX_ASSET_BYTES if max_asset_bytes is None else max_asset_bytes
    if not isinstance(prd_limit, int) or isinstance(prd_limit, bool) or prd_limit < 1:
        raise ValueError("max_prd_bytes must be a positive integer")
    if not isinstance(asset_limit, int) or isinstance(asset_limit, bool) or asset_limit < 1:
        raise ValueError("max_asset_bytes must be a positive integer")
    raw_chunks = []
    prd_digest = hashlib.sha256()
    total_bytes = 0
    with path.open("rb") as source_file:
        while True:
            chunk = source_file.read(min(PRD_READ_CHUNK_BYTES, prd_limit + 1 - total_bytes))
            if not chunk:
                break
            total_bytes += len(chunk)
            if total_bytes > prd_limit:
                raise ValueError(f"PRD exceeds size limit of {prd_limit} bytes")
            prd_digest.update(chunk)
            raw_chunks.append(chunk)
    raw = b"".join(raw_chunks)
    try:
        source = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(f"unsupported encoding at byte {exc.start}: expected UTF-8") from exc
    lines = source.splitlines()
    link_definitions = {}
    for source_line in lines:
        definition = _LINK_DEFINITION.match(source_line)
        if definition:
            label = _normalize(definition.group(1))
            target = next((item for item in definition.groups()[1:] if item is not None), "")
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            elif len(target) >= 2 and target[0] in {'"', "'"} and target[-1] == target[0]:
                target = target[1:-1]
            link_definitions.setdefault(label, target)
    heading_stack = []
    pending = []
    units = []
    warnings = []
    identity_counts = Counter()
    source_path = _relative_source_path(path, project_root)

    def add(kind, start, end, text, heading_path, table_headers=None, asset_metadata=None):
        identity_text = _HEADING_NUMBER.sub("", text.strip(), count=1) if kind == "heading" else text
        normalized = _normalize(identity_text)
        normalized_path = tuple(_normalize(_HEADING_NUMBER.sub("", part.strip(), count=1)) for part in heading_path)
        key = (normalized_path, kind, normalized)
        ordinal = identity_counts[key] + 1
        identity_counts[key] += 1
        identity = json.dumps([source_path, key[0], kind, normalized, ordinal], ensure_ascii=False, separators=(",", ":"))
        digest = hashlib.sha256(identity.encode("utf-8")).hexdigest()[:20]
        unit = {
            "id": f"SRC-{digest}",
            "kind": kind,
            "heading_path": list(heading_path),
            "start_line": start,
            "end_line": end,
            "text": text,
            "table_headers": list(table_headers or []),
            "_identity": key,
        }
        if asset_metadata is not None:
            unit.update(asset_metadata)
        units.append(unit)

    def add_asset_references(source_line, line_no, heading_path):
        def add_asset(link_text: str, target: str, alt_text: str):
            target = target.strip()
            if target.startswith("<") and target.endswith(">"):
                target = target[1:-1]
            parsed = urlsplit(target)
            if target.startswith("#") or parsed.scheme.lower() in {"mailto", "tel", "javascript", "data"}:
                return
            asset_status, asset_hash = _hash_local_asset(target, path, project_root, asset_limit)
            add(
                "asset_reference", line_no, line_no, link_text, heading_path,
                asset_metadata={
                    "asset_alt_text": alt_text,
                    "asset_target": target,
                    "asset_status": asset_status,
                    "asset_sha256": asset_hash,
                },
            )
        for match in _ASSET_LINK.finditer(source_line):
            add_asset(match.group(0), match.group(3), match.group(2))
        for match in _REFERENCE_LINK.finditer(source_line):
            label = (match.group(3) or match.group(2)).strip()
            target = link_definitions.get(_normalize(label))
            add_asset(match.group(0), target or f"reference:{label}", match.group(2))
        for element in _HTML_REFERENCE_ELEMENT.finditer(source_line):
            element_name = element.group(1).casefold()
            attributes = {}
            for name, quoted_marker, quoted_value, unquoted_value in _HTML_ATTRIBUTE.findall(element.group(0)):
                attributes[name.casefold()] = quoted_value if quoted_marker else unquoted_value
            target_attributes = {
                "a": ("href",), "link": ("href",), "object": ("data",), "video": ("src", "poster"),
                "img": ("src", "srcset"), "source": ("src", "srcset"),
            }.get(element_name, ("src",))
            for attribute in target_attributes:
                raw_targets = attributes.get(attribute, "").strip()
                if not raw_targets:
                    continue
                if attribute == "srcset":
                    if raw_targets.casefold().startswith("data:"):
                        continue
                    targets = [part.strip().split()[0] for part in raw_targets.split(",") if part.strip()]
                else:
                    targets = [raw_targets]
                for target in targets:
                    parsed = urlsplit(target)
                    if target.startswith("#") or parsed.scheme.lower() in {"mailto", "tel", "javascript", "data"}:
                        continue
                    asset_status, asset_hash = _hash_local_asset(target, path, project_root, asset_limit)
                    add(
                        "asset_reference", line_no, line_no, element.group(0), heading_path,
                        asset_metadata={
                            "asset_alt_text": attributes.get("alt", attributes.get("title", "")),
                            "asset_target": target,
                            "asset_status": asset_status,
                            "asset_sha256": asset_hash,
                        },
                    )

    def flush_paragraph():
        nonlocal pending
        if pending:
            paragraph_lines = pending
            add("paragraph", paragraph_lines[0][0], paragraph_lines[-1][0], "\n".join(item[1] for item in paragraph_lines), heading_stack)
            for source_line_no, source_line in paragraph_lines:
                add_asset_references(source_line, source_line_no, heading_stack)
            pending = []

    def add_opaque(kind, start_index, end_index, message):
        block = "\n".join(lines[start_index:end_index])
        add(kind, start_index + 1, end_index, block, heading_stack)
        warnings.append({"line": start_index + 1, "kind": kind, "message": message})

    i = 0
    while i < len(lines):
        line_no = i + 1
        line = lines[i]
        stripped = line.strip()
        fence = _FENCE_OPEN.match(line)
        if fence:
            marker = fence.group(1)
            fence_char = marker[0]
            fence_size = len(marker)
            flush_paragraph()
            end = i + 1
            closed = False
            while end < len(lines):
                candidate = lines[end]
                closing = re.match(rf"^ {{0,3}}{re.escape(fence_char)}{{{fence_size},}}[ \t]*$", candidate)
                end += 1
                if closing:
                    closed = True
                    break
            add_opaque("code_block", i, end, "unterminated fenced block" if not closed else "fenced block")
            i = end
            continue
        if stripped.startswith(">"):
            flush_paragraph()
            end = i + 1
            while end < len(lines) and lines[end].lstrip().startswith(">"):
                end += 1
            add_opaque("blockquote", i, end, "blockquote preserved for semantic review")
            for source_index in range(i, end):
                add_asset_references(lines[source_index], source_index + 1, heading_stack)
            i = end
            continue
        if _HTML_BLOCK_START.match(stripped):
            flush_paragraph()
            end = i + 1
            while end < len(lines) and lines[end].strip():
                end += 1
            add_opaque("html_block", i, end, "raw HTML preserved for semantic review")
            for source_index in range(i, end):
                add_asset_references(lines[source_index], source_index + 1, heading_stack)
            i = end
            continue
        if line.startswith(("    ", "\t")):
            flush_paragraph()
            end = i + 1
            while end < len(lines) and (not lines[end].strip() or lines[end].startswith(("    ", "\t"))):
                end += 1
            add_opaque("code_block", i, end, "indented code block")
            i = end
            continue
        heading = _HEADING.match(line)
        if heading:
            flush_paragraph()
            depth = len(heading.group(1))
            title = heading.group(2).strip()
            heading_stack = heading_stack[: depth - 1]
            heading_stack.append(title)
            add("heading", line_no, line_no, title, heading_stack)
            add_asset_references(line, line_no, heading_stack)
            i += 1
            continue
        if i + 1 < len(lines) and stripped and _SETEXT_UNDERLINE.match(lines[i + 1]):
            flush_paragraph()
            underline = lines[i + 1].strip()
            depth = 1 if underline.startswith("=") else 2
            title = stripped
            heading_stack = heading_stack[: depth - 1]
            heading_stack.append(title)
            add("heading", line_no, line_no + 1, title, heading_stack)
            add_asset_references(line, line_no, heading_stack)
            i += 2
            continue
        if not stripped:
            flush_paragraph()
            i += 1
            continue
        is_pipe_start = line.lstrip().startswith("|")
        has_table_separator = i + 1 < len(lines) and _is_separator(lines[i + 1])
        if is_pipe_start or has_table_separator:
            flush_paragraph()
            candidate_end = i
            while candidate_end < len(lines) and lines[candidate_end].strip() and "|" in lines[candidate_end]:
                candidate_end += 1
            malformed = None
            if not has_table_separator:
                malformed = "table-like block without a separator row"
            header_width = len(_table_cells(line))
            if has_table_separator and len(_table_cells(lines[i + 1])) != header_width:
                malformed = "table separator column count mismatch"
            table_rows = []
            if has_table_separator and malformed is None:
                j = i + 2
                while j < candidate_end:
                    cells = _table_cells(lines[j])
                    if _is_separator(lines[j]):
                        if len(cells) != header_width:
                            malformed = "repeated table separator column count mismatch"
                            break
                        j += 1
                        continue
                    if len(cells) != header_width:
                        malformed = f"table row expected {header_width} cells, found {len(cells)}"
                        break
                    if not any(cells):
                        malformed = "empty table row"
                        break
                    table_rows.append((j, cells))
                    j += 1
            if malformed:
                add_opaque("opaque_block", i, candidate_end, malformed)
                i = candidate_end
                continue
            table_headers = _table_cells(line)
            add("table_header", line_no, line_no, " | ".join(table_headers), heading_stack)
            add_asset_references(line, line_no, heading_stack)
            for row_index, cells in table_rows:
                add("table_row", row_index + 1, row_index + 1, " | ".join(cells), heading_stack, table_headers)
                add_asset_references(lines[row_index], row_index + 1, heading_stack)
            i = candidate_end
            continue
        list_item = _LIST.match(line)
        if list_item:
            flush_paragraph()
            indent = len(list_item.group(1))
            text = [list_item.group(2).rstrip()]
            item_source_lines = [(line_no, line)]
            start = line_no
            i += 1
            while i < len(lines):
                next_line = lines[i]
                if not next_line.strip():
                    break
                nested = _LIST.match(next_line)
                if nested and len(nested.group(1)) > indent:
                    break
                if nested and len(nested.group(1)) <= indent:
                    break
                if len(next_line) - len(next_line.lstrip(" ")) > indent:
                    text.append(next_line.strip())
                    item_source_lines.append((i + 1, next_line))
                    i += 1
                    continue
                break
            add("list_item", start, i, "\n".join(text), heading_stack)
            for source_line_no, source_line in item_source_lines:
                add_asset_references(source_line, source_line_no, heading_stack)
            continue
        pending.append((line_no, line.rstrip()))
        i += 1

    flush_paragraph()
    for unit in units:
        del unit["_identity"]
    return {
        "prd_sha256": prd_digest.hexdigest(),
        "parser_version": PARSER_VERSION,
        "source_path": source_path,
        "units": units,
        "warnings": warnings,
    }


def scan_prd_sources(
    primary_path: Path,
    supplemental_sources: list[dict[str, Any]] | None = None,
    project_root: Path | None = None,
    max_prd_bytes: int | None = None,
    max_asset_bytes: int | None = None,
) -> dict[str, Any]:
    """Inventory the primary PRD plus explicitly registered Markdown evidence files."""
    root = Path(project_root).resolve() if project_root is not None else Path(primary_path).resolve().parent
    primary = scan_prd(primary_path, root, max_prd_bytes, max_asset_bytes)
    primary_relative = _relative_source_path(primary_path, root)
    primary_record = {
        "path": primary_relative, "role": "primary_prd", "sha256": primary["prd_sha256"],
        "unit_count": len(primary["units"]),
    }
    for unit in primary["units"]:
        unit["source_file"] = primary_relative
        unit["source_role"] = "primary_prd"

    records = [primary_record]
    units = list(primary["units"])
    warnings = [{**item, "source_file": primary_relative} for item in primary["warnings"]]
    seen_paths = {unicodedata.normalize("NFC", primary_relative).casefold()}
    for index, entry in enumerate(supplemental_sources or []):
        if not isinstance(entry, dict):
            raise ValueError(f"补充来源[{index}] 必须为对象")
        raw_path = entry.get("path")
        role = entry.get("role")
        if not isinstance(raw_path, str) or not raw_path.strip() or "\\" in raw_path or raw_path.startswith("/"):
            raise ValueError(f"补充来源[{index}].path 必须是项目内相对 POSIX 路径")
        if ntpath.splitdrive(raw_path)[0] or any(part in {"", ".", ".."} for part in raw_path.split("/")):
            raise ValueError(f"补充来源[{index}].path 不得包含盘符、空路径段、. 或 ..")
        if role not in SOURCE_ROLES:
            raise ValueError(f"补充来源[{index}].role 无效：{role!r}")
        relative = Path(raw_path).as_posix()
        canonical = unicodedata.normalize("NFC", relative).casefold()
        if canonical in seen_paths:
            raise ValueError(f"补充来源路径重复：{relative}")
        seen_paths.add(canonical)
        source_path = root / relative
        resolved = source_path.resolve(strict=False)
        try:
            resolved.relative_to(root)
        except ValueError as exc:
            raise ValueError(f"补充来源路径逃逸项目目录：{relative}") from exc
        if not resolved.is_file():
            if entry.get("required", True) is False:
                continue
            raise ValueError(f"必需的补充来源不存在：{relative}")
        if resolved.suffix.casefold() not in {".md", ".markdown", ".txt"}:
            raise ValueError(f"补充来源目前只支持 Markdown/文本；请先整理项目事实为可审阅文本：{relative}")
        scanned = scan_prd(resolved, root, max_prd_bytes, max_asset_bytes)
        records.append({
            "path": relative,
            "role": role,
            "description": str(entry.get("description", "")).strip(),
            "sha256": scanned["prd_sha256"],
            "unit_count": len(scanned["units"]),
        })
        for unit in scanned["units"]:
            unit["source_file"] = relative
            unit["source_role"] = role
        units.extend(scanned["units"])
        warnings.extend({**item, "source_file": relative} for item in scanned["warnings"])

    source_set = "\n".join(f"{row['path']}\0{row['role']}\0{row['sha256']}" for row in records)
    return {
        "prd_sha256": primary["prd_sha256"],
        "source_set_sha256": hashlib.sha256(source_set.encode("utf-8")).hexdigest(),
        "parser_version": PARSER_VERSION,
        "source_path": primary_relative,
        "source_documents": records,
        "units": units,
        "warnings": warnings,
    }


def _ledger_shape_errors(inventory, ledger):
    errors = []
    if not isinstance(inventory, dict):
        return ["inventory must be an object"]
    if not isinstance(ledger, dict):
        return ["requirement ledger must be an object"]
    units = inventory.get("units")
    if not isinstance(units, list):
        errors.append("inventory units must be a list")
    else:
        for index, unit in enumerate(units):
            if not isinstance(unit, dict):
                errors.append(f"inventory units[{index}] must be an object")
            elif not isinstance(unit.get("id"), str):
                errors.append(f"inventory units[{index}].id must be a string")

    for field in ("classifications", "requirements", "review_deltas", "asset_reviews"):
        value = ledger.get(field, _MISSING)
        if value is _MISSING:
            if field == "review_deltas":
                errors.append("missing review_deltas; independent review must be recorded")
            else:
                errors.append(f"{field} must be a list")
            continue
        if not isinstance(value, list):
            errors.append(f"{field} must be a list")
            continue
        for index, item in enumerate(value):
            if not isinstance(item, dict):
                errors.append(f"{field}[{index}] must be an object")
                continue
            if field == "classifications":
                if "source_ref" in item and not isinstance(item["source_ref"], str):
                    errors.append(f"classifications[{index}].source_ref must be a string")
                if "classification" in item and not isinstance(item["classification"], str):
                    errors.append(f"classifications[{index}].classification must be a string")
            elif field == "requirements":
                if "id" in item and not isinstance(item["id"], str):
                    errors.append(f"requirements[{index}].id must be a string")
                if "status" in item and not isinstance(item["status"], str):
                    errors.append(f"requirements[{index}].status must be a string")
                if "source_refs" in item and not isinstance(item["source_refs"], list):
                    errors.append(f"requirements[{index}].source_refs must be a list")
                elif any(not isinstance(ref, str) for ref in item.get("source_refs", [])):
                    errors.append(f"requirements[{index}].source_refs entries must be strings")
            elif field == "review_deltas":
                if "source_refs" in item and not isinstance(item["source_refs"], list):
                    errors.append(f"review_deltas[{index}].source_refs must be a list")
                elif any(not isinstance(ref, str) for ref in item.get("source_refs", [])):
                    errors.append(f"review_deltas[{index}].source_refs entries must be strings")
                if "disposition" in item and not isinstance(item["disposition"], dict):
                    errors.append(f"review_deltas[{index}].disposition must be an object")
                elif isinstance(item.get("disposition"), dict):
                    evidence = item["disposition"].get("evidence", [])
                    if not isinstance(evidence, list):
                        errors.append(f"review_deltas[{index}].disposition.evidence must be a list")
                    elif any(not isinstance(ref, str) for ref in evidence):
                        errors.append(f"review_deltas[{index}].disposition.evidence entries must be strings")
            elif field == "asset_reviews":
                if "source_ref" in item and not isinstance(item["source_ref"], str):
                    errors.append(f"asset_reviews[{index}].source_ref must be a string")
                if "evidence" in item and not isinstance(item["evidence"], list):
                    errors.append(f"asset_reviews[{index}].evidence must be a list")
                elif any(not isinstance(ref, str) for ref in item.get("evidence", [])):
                    errors.append(f"asset_reviews[{index}].evidence entries must be strings")

    independent_review = ledger.get("independent_review", _MISSING)
    if independent_review is not _MISSING and not isinstance(independent_review, dict):
        errors.append("independent_review must be an object")
    elif isinstance(independent_review, dict) and "evidence" in independent_review:
        evidence = independent_review["evidence"]
        if not isinstance(evidence, list):
            errors.append("independent_review.evidence must be a list")
        elif any(not isinstance(item, str) for item in evidence):
            errors.append("independent_review.evidence entries must be strings")
    return errors


def validate_requirement_ledger(inventory: dict, ledger: dict) -> list[str]:
    """Validate source coverage and human review attestations, not business semantics."""
    shape_errors = _ledger_shape_errors(inventory, ledger)
    if shape_errors:
        return shape_errors
    errors = []
    units = inventory.get("units", [])
    valid_sources = {unit.get("id") for unit in units}
    if ledger.get("schema_version") != "1":
        errors.append("unsupported or missing requirement ledger schema_version")
    if ledger.get("parser_version") != inventory.get("parser_version"):
        errors.append("requirement ledger parser_version does not match inventory")
    if ledger.get("source_prd_sha256") != inventory.get("prd_sha256"):
        errors.append("source PRD hash does not match inventory")
    extractor_id = str(ledger.get("extractor_id", "")).strip()
    if not extractor_id:
        errors.append("extractor_id is required")

    classifications = ledger.get("classifications", [])
    class_counts = Counter()
    classified_requirement_refs = set()
    for index, item in enumerate(classifications):
        source_ref = item.get("source_ref")
        classification = item.get("classification")
        if source_ref not in valid_sources:
            errors.append(f"invalid source reference in classification[{index}]: {source_ref}")
        else:
            class_counts[source_ref] += 1
        if classification not in CLASSIFICATIONS:
            errors.append(f"invalid classification in classification[{index}]: {classification}")
        if classification in REASON_REQUIRED and not str(item.get("reason", "")).strip():
            errors.append(f"reason required for {classification} classification of {source_ref}")
        if classification in REQUIREMENT_CLASSIFICATIONS and source_ref in valid_sources:
            classified_requirement_refs.add(source_ref)

    for source_ref in sorted(valid_sources):
        if class_counts[source_ref] == 0:
            errors.append(f"unclassified source unit: {source_ref}")
        elif class_counts[source_ref] > 1:
            errors.append(f"source unit classified more than once: {source_ref}")

    requirements = ledger.get("requirements", [])
    seen_requirement_ids = set()
    for index, requirement in enumerate(requirements):
        req_id = requirement.get("id")
        if not isinstance(req_id, str) or not req_id.strip():
            errors.append(f"missing requirement ID in requirements[{index}]")
        elif req_id != req_id.strip() or any(unicodedata.category(char) == "Cc" for char in req_id):
            errors.append(f"invalid requirement ID: {req_id}")
        elif req_id in seen_requirement_ids:
            errors.append(f"duplicate requirement ID: {req_id}")
        seen_requirement_ids.add(req_id)
        if not str(requirement.get("statement", "")).strip():
            errors.append(f"missing requirement statement for {req_id}")
        if not str(requirement.get("status", "")).strip():
            errors.append(f"missing requirement status for {req_id}")
        elif requirement.get("status") not in REQUIREMENT_STATUSES:
            errors.append(f"invalid requirement status for {req_id}: {requirement.get('status')}")
        if not isinstance(requirement.get("testable"), bool):
            errors.append(f"requirement testable must be boolean for {req_id}")
        if not isinstance(requirement.get("mandatory"), bool):
            errors.append(f"requirement mandatory must be boolean for {req_id}")
        elif requirement["mandatory"] and requirement.get("status") != "已确认":
            errors.append(f"unresolved mandatory requirement: {req_id} (status={requirement.get('status')})")
        if requirement.get("status") == "已排除" and not str(requirement.get("resolution_reason", "")).strip():
            errors.append(f"resolution_reason required for excluded requirement {req_id}")
        refs = requirement.get("source_refs", [])
        if not refs:
            errors.append(f"requirement has no source references: {req_id}")
        for source_ref in refs:
            if source_ref not in valid_sources:
                errors.append(f"invalid source reference in requirement {req_id}: {source_ref}")
    used_requirement_sources = {ref for requirement in requirements for ref in requirement.get("source_refs", []) if ref in valid_sources}
    for source_ref in sorted(classified_requirement_refs - used_requirement_sources):
        errors.append(f"requirement classification has no requirement record: {source_ref}")

    if "review_deltas" not in ledger:
        errors.append("missing review_deltas; independent review must be recorded")
    review_deltas = ledger.get("review_deltas", [])
    for index, delta in enumerate(review_deltas):
        disposition = delta.get("disposition", {})
        decision = str(disposition.get("decision", "")).strip()
        rationale = str(disposition.get("rationale", "")).strip()
        evidence = disposition.get("evidence", [])
        if not decision or not rationale or not evidence:
            errors.append(f"unresolved review delta: {delta.get('id', index)}")
        elif decision not in {"accept", "reject", "merge"}:
            errors.append(f"invalid review disposition in delta {delta.get('id', index)}: {decision}")
        for source_ref in evidence:
            if source_ref not in valid_sources:
                errors.append(f"invalid review evidence source reference in delta {delta.get('id', index)}: {source_ref}")
        for source_ref in delta.get("source_refs", []):
            if source_ref not in valid_sources:
                errors.append(f"invalid source reference in review delta {delta.get('id', index)}: {source_ref}")

    independent_review = ledger.get("independent_review")
    if not isinstance(independent_review, dict):
        errors.append("independent review attestation required")
    else:
        reviewer_id = str(independent_review.get("reviewer_id", "")).strip()
        if not reviewer_id:
            errors.append("independent review reviewer_id is required")
        elif reviewer_id == extractor_id:
            errors.append("independent review reviewer_id must differ from extractor_id")
        if independent_review.get("status") != "completed":
            errors.append("independent review status must be completed")
        if independent_review.get("reviewed_prd_sha256") != inventory.get("prd_sha256"):
            errors.append("reviewed PRD hash does not match inventory")
        reviewed_source_set_sha256 = independent_review.get("reviewed_source_set_sha256")
        if reviewed_source_set_sha256 and reviewed_source_set_sha256 != inventory.get("source_set_sha256"):
            errors.append("reviewed supplemental source set hash does not match inventory")
        elif independent_review.get("status") == "completed" and not reviewed_source_set_sha256:
            errors.append("independent review must record the reviewed supplemental source set hash")
        source_unit_count = independent_review.get("source_unit_count")
        if type(source_unit_count) is not int or source_unit_count != len(units):
            errors.append("reviewed source unit count does not match inventory")
        expected_conclusion = "no_deltas" if not review_deltas else "deltas_resolved"
        if independent_review.get("conclusion") != expected_conclusion:
            errors.append(f"independent review conclusion must be {expected_conclusion}")
        evidence = independent_review.get("evidence", [])
        if not isinstance(evidence, list) or not evidence or any(not isinstance(item, str) or not item.strip() for item in evidence):
            errors.append("independent review evidence required")

    asset_units = {unit["id"]: unit for unit in units if unit.get("kind") == "asset_reference"}
    asset_reviews = ledger.get("asset_reviews", [])
    if asset_units and "asset_reviews" not in ledger:
        errors.append("missing asset_reviews for linked PRD assets")
    review_counts = Counter()
    for index, review in enumerate(asset_reviews):
        source_ref = review.get("source_ref")
        asset = asset_units.get(source_ref)
        if asset is None:
            errors.append(f"invalid asset review source reference in asset_reviews[{index}]: {source_ref}")
            continue
        review_counts[source_ref] += 1
        if review.get("status") != "reviewed":
            errors.append(f"asset review is not reviewed: {source_ref}")
        if not str(review.get("summary", "")).strip():
            errors.append(f"asset review summary required: {source_ref}")
        evidence = review.get("evidence", [])
        if not evidence:
            errors.append(f"asset review evidence required: {source_ref}")
        for evidence_ref in evidence:
            if evidence_ref not in valid_sources:
                errors.append(f"invalid asset review evidence source reference for {source_ref}: {evidence_ref}")
        if review.get("asset_sha256") != asset.get("asset_sha256"):
            errors.append(f"asset review hash does not match inventory: {source_ref}")
    for source_ref, asset in asset_units.items():
        if review_counts[source_ref] == 0:
            errors.append(f"missing asset review: {source_ref}")
        elif review_counts[source_ref] > 1:
            errors.append(f"duplicate asset review: {source_ref}")
        if asset.get("asset_status") != "resolved" or not asset.get("asset_sha256"):
            errors.append(f"unresolved asset reference: {source_ref} ({asset.get('asset_target')})")
    return errors


def compare_requirement_reviews(canonical: dict, independent: dict) -> list[dict]:
    """Find review delta candidates; callers must record a human disposition."""
    canonical_rows = canonical.get("requirements", [])
    independent_rows = independent.get("requirements", [])
    canonical_groups = {}
    independent_groups = {}
    for target, rows in ((canonical_groups, canonical_rows), (independent_groups, independent_rows)):
        for row in rows:
            target.setdefault(row.get("id"), []).append(row)
    deltas = []

    def add(kind, req_id, left=None, right=None):
        body = [kind, req_id, left, right]
        delta_id = "DELTA-" + hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()[:16]
        row = {"id": delta_id, "kind": kind, "requirement_id": req_id}
        if left is not None:
            row["canonical"] = left
        if right is not None:
            row["independent"] = right
        refs = []
        for source in ((left or {}).get("source_refs", []) + (right or {}).get("source_refs", [])):
            if source not in refs:
                refs.append(source)
        row["source_refs"] = refs
        row["description"] = f"{kind} candidate for {req_id}"
        deltas.append(row)

    for owner, groups in (("canonical", canonical_groups), ("independent", independent_groups)):
        for req_id, rows in sorted(groups.items(), key=lambda pair: str(pair[0])):
            if len(rows) > 1:
                refs = []
                for duplicate in rows:
                    for source_ref in duplicate.get("source_refs", []):
                        if source_ref not in refs:
                            refs.append(source_ref)
                repeated = {"source_refs": refs, "count": len(rows)}
                add("duplicate", req_id, left=repeated if owner == "canonical" else None,
                    right=repeated if owner == "independent" else None)

    canonical_by_id = {req_id: rows[0] for req_id, rows in canonical_groups.items()}
    independent_by_id = {req_id: rows[0] for req_id, rows in independent_groups.items()}

    for req_id in sorted(set(canonical_by_id) | set(independent_by_id), key=lambda value: str(value)):
        left = canonical_by_id.get(req_id)
        right = independent_by_id.get(req_id)
        if left is None:
            add("added", req_id, right=right)
        elif right is None:
            add("missing", req_id, left=left)
        elif (_normalize(left.get("statement", "")) != _normalize(right.get("statement", ""))
              or sorted(left.get("source_refs", [])) != sorted(right.get("source_refs", []))
              or any(left.get(field) != right.get(field)
                     for field in (set(left) | set(right)) - {"id", "statement", "source_refs"})):
            add("changed", req_id, left=left, right=right)

    by_statement = {}
    for owner, rows in (("canonical", canonical_rows), ("independent", independent_rows)):
        for row in rows:
            key = _normalize(row.get("statement", ""))
            by_statement.setdefault(key, {}).setdefault(owner, []).append(row)
    for key, owners in sorted(by_statement.items()):
        combined = owners.get("canonical", []) + owners.get("independent", [])
        ids = sorted({row.get("id") for row in combined}, key=lambda value: str(value))
        if len(ids) > 1:
            add("duplicate", ",".join(str(value) for value in ids), left={"source_refs": []}, right={"source_refs": []})
    return deltas
