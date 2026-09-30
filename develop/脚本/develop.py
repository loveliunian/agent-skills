#!/usr/bin/env python3
"""生成文档，并校验详设 JSON 正本与 Markdown 的完整对应关系。"""

from __future__ import annotations

import argparse
import hashlib
import json
import posixpath
import re
import sys
import unicodedata
from pathlib import Path
from typing import Any
from urllib.parse import quote


SKILL_ROOT = Path(__file__).resolve().parents[1]
SCRIPT_DIR = Path(__file__).resolve().parent
CONTRACT = SKILL_ROOT / "契约" / "文档清单.json"
TOOL_VERSION = "1.3.0"
TOKEN = re.compile(r"{{([A-Z_]+)}}")
HEADING_RE = re.compile(r"^(#{2,6})[ \t]+(.*?)[ \t]*$")
SECTION_NUMBER_RE = re.compile(r"^(?:[1-9]\d{0,2})(?:\.\d+)*(?:[.．、])?[ \t]+")
FENCE_RE = re.compile(r"^ {0,3}(`{3,}|~{3,})")

if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

from acceptance_baseline import freeze_fingerprint, import_legacy_acceptance, parse_acceptance, validate_acceptance
from design_package import normalize_design_package, validate_design_package
from prd_inventory import scan_prd_sources, validate_requirement_ledger


def load_manifest() -> dict[str, Any]:
    """读取文档清单，并核对模板、详设 JSON 契约和渲染模板都存在。"""
    manifest = json.loads(CONTRACT.read_text(encoding="utf-8"))
    documents = manifest.get("documents")
    if manifest.get("version") != 1 or not isinstance(documents, list) or not documents:
        raise ValueError("文档清单.json 必须使用版本 1，且 documents 不能为空")

    for item in documents:
        if not all(isinstance(item.get(key), str) for key in ("id", "title", "file", "template")):
            raise ValueError("每份文档都需要字符串字段 id、title、file 和 template")
        if not isinstance(item.get("sections"), list) or not all(
            isinstance(section, str) for section in item["sections"]
        ):
            raise ValueError(f"{item['id']}：sections 必须是字符串列表")
        template = SKILL_ROOT / "模板" / item["template"]
        if not template.is_file():
            raise ValueError(f"模板不存在：{template}")
        headings = [
            line[3:].strip()
            for line in template.read_text(encoding="utf-8").splitlines()
            if line.startswith("## ")
        ]
        if headings != item["sections"]:
            raise ValueError(f"{template.name}：二级标题必须与文档清单.json一致")

    structured = manifest.get("structured_design")
    required = ("file", "template", "schema", "document", "render_template", "template_id", "template_version", "receipt_file")
    if not isinstance(structured, dict) or not all(isinstance(structured.get(key), str) for key in required):
        raise ValueError("文档清单.json 缺少完整的 structured_design 配置")
    if structured["document"] not in {item["file"] for item in documents}:
        raise ValueError("详设渲染目标必须登记在 documents 中")
    for key in ("template", "render_template"):
        if not (SKILL_ROOT / "模板" / structured[key]).is_file():
            raise ValueError(f"详设模板不存在：{structured[key]}")
    if not (SKILL_ROOT / "契约" / structured["schema"]).is_file():
        raise ValueError(f"详设数据结构不存在：{structured['schema']}")
    blocks = structured.get("render_blocks")
    if not isinstance(blocks, list) or not blocks or len(blocks) != len(set(blocks)):
        raise ValueError("structured_design.render_blocks 必须是非空且不重复的块 ID 列表")
    render_template = (SKILL_ROOT / "模板" / structured["render_template"]).read_text(encoding="utf-8")
    if f"<!-- develop:template-id:{structured['template_id']} -->" not in render_template:
        raise ValueError("详设模板 template-id 与文档清单不一致")
    if f"<!-- develop:template-version:{structured['template_version']} -->" not in render_template:
        raise ValueError("详设模板 template-version 与文档清单不一致")
    for block in blocks:
        if render_template.count(f"<!-- develop:begin:{block} -->") != 1 or render_template.count(f"<!-- develop:end:{block} -->") != 1:
            raise ValueError(f"详设模板生成块契约无效：{block}")
    prd_pipeline = manifest.get("prd_pipeline")
    pipeline_keys = (
        "prd_file", "inventory_file", "ledger_file", "acceptance_file", "sources_file",
        "ledger_template", "sources_template", "sources_schema", "schema",
    )
    if not isinstance(prd_pipeline, dict) or not all(
        isinstance(prd_pipeline.get(key), str) and prd_pipeline[key]
        for key in pipeline_keys
    ):
        raise ValueError("文档清单.json 缺少完整的 prd_pipeline 配置")
    if not (SKILL_ROOT / "契约" / prd_pipeline["schema"]).is_file():
        raise ValueError(f"需求提取数据结构不存在：{prd_pipeline['schema']}")
    if not (SKILL_ROOT / "模板" / prd_pipeline["ledger_template"]).is_file():
        raise ValueError(f"需求台账模板不存在：{prd_pipeline['ledger_template']}")
    if not (SKILL_ROOT / "契约" / prd_pipeline["sources_schema"]).is_file():
        raise ValueError(f"需求来源配置数据结构不存在：{prd_pipeline['sources_schema']}")
    if not (SKILL_ROOT / "模板" / prd_pipeline["sources_template"]).is_file():
        raise ValueError(f"需求来源配置模板不存在：{prd_pipeline['sources_template']}")
    try:
        json.loads((SKILL_ROOT / "模板" / prd_pipeline["ledger_template"]).read_text(encoding="utf-8"))
        json.loads((SKILL_ROOT / "契约" / prd_pipeline["sources_schema"]).read_text(encoding="utf-8"))
        json.loads((SKILL_ROOT / "模板" / prd_pipeline["sources_template"]).read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ValueError(f"需求来源配置 Schema/模板 JSON 无效：{exc}") from exc
    for limit_key in ("max_prd_bytes", "max_asset_bytes"):
        limit = prd_pipeline.get(limit_key)
        if not isinstance(limit, int) or isinstance(limit, bool) or limit < 1:
            raise ValueError(f"prd_pipeline.{limit_key} 必须是正整数")
    raw_output_config = manifest.get("design_output", manifest.get("design_package"))
    if raw_output_config is not None and not isinstance(raw_output_config, dict):
        raise ValueError("design_output 必须是对象")
    package_config = design_output_config(manifest)
    if package_config is not None:
        if not isinstance(package_config, dict) or not all(
            isinstance(package_config.get(key), str) and package_config[key]
            for key in ("file", "schema", "template")
        ):
            raise ValueError("design_output 必须包含 file、schema 和 template")
        package_schema_path = SKILL_ROOT / "契约" / package_config["schema"]
        if not package_schema_path.is_file():
            raise ValueError(f"详设输出数据结构不存在：{package_config['schema']}")
        if not (SKILL_ROOT / "模板" / package_config["template"]).is_file():
            raise ValueError(f"详设输出配置模板不存在：{package_config['template']}")
        try:
            json.loads(package_schema_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise ValueError(f"详设输出数据结构 JSON 无效：{exc}") from exc
        registry = package_config.get("template_registry")
        if not isinstance(registry, dict) or not registry or any(
            not isinstance(key, str) or not key.strip() or not isinstance(value, str) or not value.strip()
            for key, value in registry.items()
        ):
            raise ValueError("design_output.template_registry 必须是非空的模板 ID/版本映射")
    manifest["_receipt_hashes"] = {
        "schema_sha256": _sha256_file(SKILL_ROOT / "契约" / structured["schema"]),
        "requirements_schema_sha256": _sha256_file(SKILL_ROOT / "契约" / prd_pipeline["schema"]),
        "requirements_template_sha256": _sha256_file(SKILL_ROOT / "模板" / prd_pipeline["ledger_template"]),
        "sources_schema_sha256": _sha256_file(SKILL_ROOT / "契约" / prd_pipeline["sources_schema"]),
        "sources_template_sha256": _sha256_file(SKILL_ROOT / "模板" / prd_pipeline["sources_template"]),
        "sources_schema_sha256": _sha256_file(SKILL_ROOT / "契约" / prd_pipeline["sources_schema"]),
        "sources_template_sha256": _sha256_file(SKILL_ROOT / "模板" / prd_pipeline["sources_template"]),
        "manifest_sha256": _sha256_file(CONTRACT),
        "template_sha256": _sha256_file(SKILL_ROOT / "模板" / structured["render_template"]),
    }
    if package_config is not None:
        manifest["_receipt_hashes"]["design_output_schema_sha256"] = _sha256_file(
            SKILL_ROOT / "契约" / package_config["schema"]
        )
    return manifest


def design_output_config(manifest: dict[str, Any]) -> dict[str, Any] | None:
    """Return the explicit single/package output config, with a legacy-key fallback."""
    config = manifest.get("design_output")
    if config is None:
        config = manifest.get("design_package")
    return config if isinstance(config, dict) else None


def normalize_heading(text: str) -> str:
    """Remove a generated hierarchical prefix before comparing a heading to the manifest."""
    return SECTION_NUMBER_RE.sub("", text.strip(), count=1).strip()


def number_markdown_headings(text: str) -> str:
    """Number Markdown H2+ headings hierarchically, preserving H1 titles and fenced code."""
    counters: list[int] = []
    fence_char: str | None = None
    fence_size = 0
    output: list[str] = []
    for line in text.splitlines(keepends=True):
        body = line.rstrip("\r\n")
        ending = line[len(body):]
        fence_match = FENCE_RE.match(body)
        if fence_char is not None:
            output.append(line)
            if fence_match and fence_match.group(1)[0] == fence_char and len(fence_match.group(1)) >= fence_size:
                tail = body[fence_match.end():].strip()
                if not tail:
                    fence_char = None
                    fence_size = 0
            continue
        if fence_match:
            marker = fence_match.group(1)
            fence_char = marker[0]
            fence_size = len(marker)
            output.append(line)
            continue

        heading = HEADING_RE.match(body)
        if heading is None:
            output.append(line)
            continue
        hashes, title = heading.groups()
        title = re.sub(r"[ \t]+#+[ \t]*$", "", title).strip()
        title = normalize_heading(title)
        relative_depth = len(hashes) - 1
        if len(counters) < relative_depth:
            while len(counters) < relative_depth:
                counters.append(1)
        else:
            counters = counters[:relative_depth]
            counters[-1] += 1
        number = ".".join(str(part) for part in counters)
        output.append(f"{hashes} {number} {title}{ending}")
    return "".join(output)


def render_skeleton(
    directory: Path,
    manifest: dict[str, Any],
    name: str,
    design_mode: str = "single",
    design_output: str | None = None,
    design_mode_reason: str | None = None,
) -> list[str]:
    """生成 Markdown 骨架和详设 JSON 空白正本，不覆盖已有文件。"""
    documents = manifest["documents"]
    structured = manifest["structured_design"]
    output_config = design_output_config(manifest)
    config_value: dict[str, Any] | None = None
    if isinstance(output_config, dict):
        config_value = json.loads((SKILL_ROOT / "模板" / output_config["template"]).read_text(encoding="utf-8"))
        config_value["mode"] = design_mode
        if design_mode_reason is not None:
            config_value["mode_reason"] = design_mode_reason
        if design_output:
            config_value["total"]["path"] = design_output
    design_path = config_value["total"]["path"] if config_value else structured["document"]
    _safe_package_output(directory, design_path)
    if Path(design_path).suffix.lower() != ".md":
        raise ValueError("详设输出路径必须以 .md 结尾")
    reserved = {
        str(item["file"]) for item in documents
        if item["file"] != structured["document"]
    } | {structured["file"], structured["receipt_file"]}
    pipeline = manifest["prd_pipeline"]
    reserved.update(pipeline[key] for key in ("prd_file", "inventory_file", "ledger_file", "acceptance_file"))
    canonical = lambda value: unicodedata.normalize("NFC", value).casefold()
    if canonical(design_path) in {canonical(path) for path in reserved}:
        raise ValueError(f"详设输出路径与现有文档或输入文件冲突：{design_path}")
    outputs = [directory / str(item["file"]) for item in documents if item["file"] != structured["document"]]
    outputs.append(directory / design_path)
    outputs.append(directory / structured["file"])
    pipeline = manifest["prd_pipeline"]
    outputs.append(directory / pipeline["ledger_file"])
    outputs.append(directory / pipeline["sources_file"])
    if isinstance(output_config, dict):
        outputs.append(directory / output_config["file"])
    output_keys = [canonical(path.relative_to(directory).as_posix()) for path in outputs]
    if len(output_keys) != len(set(output_keys)):
        raise ValueError("初始化文件路径重复；检查 --design-output 与固定文档路径")
    collision = next((path for path in outputs if path.exists()), None)
    if collision is not None:
        raise FileExistsError(f"拒绝覆盖已有文件：{collision}")

    directory.mkdir(parents=True, exist_ok=True)
    created: list[str] = []
    for item in documents:
        if item["file"] == structured["document"]:
            continue
        template_path = SKILL_ROOT / "模板" / str(item["template"])
        content = template_path.read_text(encoding="utf-8")
        content = content.replace("{{PROJECT_NAME}}", name).replace("{{TITLE}}", str(item["title"]))
        unknown = TOKEN.findall(content)
        if unknown:
            raise ValueError(f"{template_path.name}：存在未知模板变量：{', '.join(unknown)}")
        content = number_markdown_headings(content)
        output = directory / str(item["file"])
        output.write_text(content.rstrip() + "\n", encoding="utf-8")
        created.append(str(output))

    design_template = SKILL_ROOT / "模板" / structured["render_template"]
    design_text = design_template.read_text(encoding="utf-8")
    design_text = design_text.replace("{{PROJECT_NAME}}", name).replace("{{TITLE}}", name)
    design_text = TOKEN.sub("【请填写详设 JSON 后运行 render-design】", design_text)
    design_text = number_markdown_headings(design_text)
    design_output_path = _safe_package_output(directory, design_path)
    design_output_path.parent.mkdir(parents=True, exist_ok=True)
    design_output_path.write_text(design_text.rstrip() + "\n", encoding="utf-8")
    created.append(str(design_output_path))

    json_template = SKILL_ROOT / "模板" / structured["template"]
    json_output = directory / structured["file"]
    # JSON 模板的项目名由填写者提供，避免在 JSON 字符串中引入模板变量。
    json.loads(json_template.read_text(encoding="utf-8"))
    json_output.write_text(json_template.read_text(encoding="utf-8"), encoding="utf-8")
    created.append(str(json_output))
    ledger_template = SKILL_ROOT / "模板" / pipeline["ledger_template"]
    ledger_output = directory / pipeline["ledger_file"]
    json.loads(ledger_template.read_text(encoding="utf-8"))
    ledger_output.write_text(ledger_template.read_text(encoding="utf-8"), encoding="utf-8")
    created.append(str(ledger_output))
    if isinstance(output_config, dict):
        config_output = directory / output_config["file"]
        config_output.write_text(json.dumps(config_value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        created.append(str(config_output))
    source_template = SKILL_ROOT / "模板" / pipeline["sources_template"]
    source_output = directory / pipeline["sources_file"]
    json.loads(source_template.read_text(encoding="utf-8"))
    source_output.write_text(source_template.read_text(encoding="utf-8"), encoding="utf-8")
    created.append(str(source_output))
    return created


def check_documents(directory: Path, manifest: dict[str, Any]) -> list[str]:
    """检查文档集合、固定标题和结构化 JSON 文件是否存在且可解析。"""
    errors: list[str] = []
    documents = manifest["documents"]
    structured = manifest["structured_design"]
    prd_input = str(manifest.get("prd_pipeline", {}).get("prd_file", ""))
    canonical = lambda value: unicodedata.normalize("NFC", value).casefold()
    prd_input_key = canonical(prd_input) if prd_input else ""
    default_design_path = structured["document"]
    expected_files = {str(item["file"]) for item in documents if item["file"] != default_design_path}
    package_config = design_output_config(manifest)
    if isinstance(package_config, dict):
        package_path = directory / package_config["file"]
        legacy_name = package_config.get("legacy_file")
        legacy_path = directory / legacy_name if legacy_name else None
        if package_path.exists() and legacy_path is not None and legacy_path.exists():
            errors.append("同时存在新旧详设输出配置；请合并设置到 " + package_path.name)
        elif not package_path.exists() and legacy_path is not None and legacy_path.exists():
            package_path = legacy_path
        if package_path.exists() or package_path.is_symlink():
            if not package_path.is_file():
                errors.append(f"详设输出配置路径不是普通文件：{package_path.name}")
        if package_path.is_file():
            try:
                package = json.loads(package_path.read_text(encoding="utf-8"))
                if not isinstance(package, dict):
                    errors.append(f"详设输出配置根节点须为对象：{package_path.name}")
                else:
                    total = package.get("total", {})
                    total_path = total.get("path") if isinstance(total, dict) else None
                    if isinstance(total_path, str) and total_path:
                        expected_files.add(total_path)
                    subdocuments = package.get("subdocuments", [])
                    if not isinstance(subdocuments, list):
                        errors.append(f"详设输出配置 subdocuments 须为数组：{package_path.name}")
                        subdocuments = []
                    for item in subdocuments:
                        relative = item.get("path") if isinstance(item, dict) else None
                        if isinstance(relative, str) and relative:
                            expected_files.add(relative)
            except (OSError, json.JSONDecodeError):
                errors.append(f"详设输出配置不可读取：{package_path.name}")
    if not isinstance(package_config, dict) or not (directory / package_config["file"]).is_file():
        if not isinstance(package_config, dict) or not package_config.get("legacy_file") or not (directory / package_config["legacy_file"]).is_file():
            expected_files.add(default_design_path)
    actual_files = {
        relative for relative in expected_files
        if (directory / relative).is_file()
    }
    for missing in sorted(expected_files - actual_files):
        errors.append(f"缺少文档：{missing}")

    for item in documents:
        if item["file"] == default_design_path:
            continue
        # The PRD is a user-provided source document. Its headings and numbering
        # are intentionally not constrained by the develop starter template.
        if prd_input_key and canonical(str(item["file"])) == prd_input_key:
            continue
        path = directory / str(item["file"])
        if not path.is_file():
            continue
        content = path.read_text(encoding="utf-8")
        headings = [
            normalize_heading(line[3:].strip())
            for line in content.splitlines()
            if line.startswith("## ")
        ]
        if headings != list(item["sections"]):
            errors.append(f"{path.name}：二级标题与文档清单.json不一致")

    for relative in sorted(actual_files):
        if prd_input_key and canonical(relative) == prd_input_key:
            continue
        content = (directory / relative).read_text(encoding="utf-8")
        if content != number_markdown_headings(content):
            errors.append(f"{relative}：章节编号缺失或不一致；请重新运行对应生成命令")

    json_path = directory / structured["file"]
    if not json_path.is_file():
        errors.append(f"缺少详设 JSON 正本：{structured['file']}")
    else:
        try:
            json.loads(json_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"详设 JSON 语法错误：{exc}")
    return errors


def scan_prd_directory(directory: Path, manifest: dict[str, Any]) -> Path:
    """Write the deterministic source-unit inventory next to the PRD."""
    pipeline = manifest["prd_pipeline"]
    directory = Path(directory)
    prd_path = directory / pipeline["prd_file"]
    sources = load_supplemental_sources(directory, pipeline)
    inventory = scan_prd_sources(
        prd_path,
        supplemental_sources=sources,
        project_root=directory.resolve(),
        max_prd_bytes=pipeline["max_prd_bytes"],
        max_asset_bytes=pipeline["max_asset_bytes"],
    )
    output = directory / pipeline["inventory_file"]
    output.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    ledger_path = directory / pipeline["ledger_file"]
    if ledger_path.is_file():
        try:
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError(f"现有需求台账不可读取，scan-prd 不覆盖：{exc}") from exc
        if not ledger.get("classifications") and not ledger.get("requirements"):
            ledger["source_prd_sha256"] = inventory["prd_sha256"]
            ledger["parser_version"] = inventory["parser_version"]
            review = ledger.setdefault("independent_review", {})
            review["reviewed_prd_sha256"] = inventory["prd_sha256"]
            review["reviewed_source_set_sha256"] = inventory["source_set_sha256"]
            review["source_unit_count"] = len(inventory["units"])
            ledger_path.write_text(json.dumps(ledger, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return output


def load_supplemental_sources(directory: Path, pipeline: dict[str, Any]) -> list[dict[str, Any]]:
    """Read and structurally validate the project's explicitly registered Markdown evidence files."""
    registry_path = Path(directory) / pipeline["sources_file"]
    if not registry_path.is_file():
        return []
    try:
        registry = json.loads(registry_path.read_text(encoding="utf-8"))
        schema = json.loads((SKILL_ROOT / "契约" / pipeline["sources_schema"]).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"需求来源配置或 Schema 不可读取：{exc}") from exc
    errors = validate_schema(registry, schema, schema)
    if errors:
        raise ValueError("需求来源配置无效：\n- " + "\n- ".join(errors))
    return registry["sources"]


def check_prd(directory: Path, manifest: dict[str, Any]) -> tuple[list[str], dict[str, Any] | None, dict[str, Any] | None]:
    """Check source inventory, requirement ledger, review closure, and frozen acceptance."""
    pipeline = manifest["prd_pipeline"]
    directory = Path(directory)
    prd_path = directory / pipeline["prd_file"]
    inventory_path = directory / pipeline["inventory_file"]
    ledger_path = directory / pipeline["ledger_file"]
    acceptance_path = directory / pipeline["acceptance_file"]
    schema_path = SKILL_ROOT / "契约" / pipeline["schema"]
    errors: list[str] = []

    if not prd_path.is_file():
        return [f"PRD 不存在：{pipeline['prd_file']}"], None, None
    try:
        sources = load_supplemental_sources(directory, pipeline)
        current_inventory = scan_prd_sources(
            prd_path,
            supplemental_sources=sources,
            project_root=directory.resolve(),
            max_prd_bytes=pipeline["max_prd_bytes"],
            max_asset_bytes=pipeline["max_asset_bytes"],
        )
    except (OSError, UnicodeError, ValueError) as exc:
        return [f"PRD 来源清单扫描失败：{exc}"], None, None
    if not inventory_path.is_file():
        errors.append(f"缺少 PRD 来源单元清单：{pipeline['inventory_file']}；先运行 scan-prd")
        return errors, None, None

    try:
        saved_inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        errors.append(f"缺少 PRD 需求台账或契约文件：{exc.filename}")
        return errors, None, None
    except json.JSONDecodeError as exc:
        errors.append(f"PRD 来源清单、需求台账或 Schema JSON 格式错误：{exc}")
        return errors, None, None

    if saved_inventory != current_inventory:
        errors.append(f"PRD 来源单元清单已过期：{pipeline['inventory_file']}；重新运行 scan-prd 并复核需求台账")
    inventory_schema_errors = validate_schema(saved_inventory, {"$ref": "#/$defs/inventory"}, schema)
    ledger_schema_errors = validate_schema(ledger, schema, schema)
    errors.extend(inventory_schema_errors)
    errors.extend(ledger_schema_errors)
    if inventory_schema_errors or ledger_schema_errors:
        return errors, ledger if isinstance(ledger, dict) else None, None
    errors.extend(validate_requirement_ledger(saved_inventory, ledger))

    if not acceptance_path.is_file():
        errors.append(f"缺少冻结验收点清单：{pipeline['acceptance_file']}")
        return errors, ledger, None
    try:
        parsed_acceptance = parse_acceptance(acceptance_path)
    except (OSError, UnicodeError, ValueError) as exc:
        errors.append(f"验收点清单解析失败：{exc}")
        return errors, ledger, None
    try:
        errors.extend(
            validate_acceptance(ledger, parsed_acceptance, require_frozen=True, inventory=saved_inventory)
        )
    except ValueError as exc:
        errors.append(f"验收点列表格式错误：{exc}")
    return errors, ledger, parsed_acceptance


def validate_design_traceability(
    data: dict[str, Any],
    acceptance_map: dict[str, set[str]],
    requirement_ledger: dict[str, Any],
    inventory: dict[str, Any],
    acceptance_source_map: dict[str, set[str]] | None = None,
) -> list[str]:
    """Close AC → requirement/source evidence without copying each REQ's full source set."""
    errors: list[str] = []
    known_acceptance = set(acceptance_map)
    requirement_rows = requirement_ledger.get("requirements", [])
    requirements = {row.get("id"): row for row in requirement_rows if isinstance(row, dict)}
    known_requirements = {req_id for req_id in requirements if req_id}
    source_ids = {unit.get("id") for unit in inventory.get("units", []) if isinstance(unit, dict)}
    scope = data.get("scope", {})
    non_prd_source_ids = {
        item.get("id")
        for key in ("constraints", "assumptions")
        for item in scope.get(key, [])
        if isinstance(item, dict) and item.get("id")
    }
    known_source_ids = source_ids | non_prd_source_ids
    seen_feature_ids: set[str] = set()
    for feature in scope.get("features", []):
        feature_id = str(feature.get("id", "（空）"))
        if feature_id in seen_feature_ids:
            errors.append(f"features：ID 重复 {feature_id}")
        seen_feature_ids.add(feature_id)
        req_refs = set(feature.get("requirement_refs", []))
        src_refs = set(feature.get("source_refs", []))
        if req_refs - known_requirements:
            errors.append(f"features/{feature_id}：引用不存在的需求 {sorted(req_refs - known_requirements)}")
        if src_refs - known_source_ids:
            errors.append(f"features/{feature_id}：引用不存在的来源 {sorted(src_refs - known_source_ids)}")
        # Feature/object source_refs cite direct evidence for their own contract.
        # The full REQ -> source-unit cross-source chain is carried by coverage rows.

    coverage_rows = data.get("coverage", [])
    seen_acceptance: set[str] = set()
    for index, row in enumerate(coverage_rows):
        ac_id = str(row.get("acceptance_id", "")).strip()
        if ac_id not in known_acceptance:
            errors.append(f"coverage[{index}]：引用不存在的验收点 {ac_id or '（空）'}")
            continue
        if ac_id in seen_acceptance:
            errors.append(f"coverage[{index}]：验收点重复 {ac_id}")
        seen_acceptance.add(ac_id)
        expected_requirements = set(acceptance_map[ac_id])
        actual_requirements = set(row.get("requirement_refs", []))
        if actual_requirements != expected_requirements:
            errors.append(
                f"coverage/{ac_id}：需求引用应为 {sorted(expected_requirements)}，实际为 {sorted(actual_requirements)}"
            )
        unknown_requirements = actual_requirements - known_requirements
        if unknown_requirements:
            errors.append(f"coverage/{ac_id}：引用不存在的需求 {sorted(unknown_requirements)}")
        actual_sources = set(row.get("source_refs", []))
        if not actual_sources:
            errors.append(f"coverage/{ac_id}：必须引用至少一个直接来源单元")
        unknown_sources = actual_sources - source_ids
        if unknown_sources:
            errors.append(f"coverage/{ac_id}：引用不存在的 PRD 来源单元 {sorted(unknown_sources)}")
        if acceptance_source_map is not None:
            expected_direct_sources = set(acceptance_source_map.get(ac_id, set()))
            if actual_sources != expected_direct_sources:
                errors.append(
                    f"coverage/{ac_id}：直接来源映射应为 {sorted(expected_direct_sources)}，实际为 {sorted(actual_sources)}"
                )
    missing_acceptance = known_acceptance - seen_acceptance
    extra_acceptance = seen_acceptance - known_acceptance
    if missing_acceptance:
        errors.append(f"详设覆盖缺少冻结验收点：{sorted(missing_acceptance)}")
    if extra_acceptance:
        errors.append(f"详设覆盖包含未冻结验收点：{sorted(extra_acceptance)}")

    collections = (
        "glossary", "tables", "apis", "permissions", "rules", "flows", "diagrams", "pages",
        "dependencies", "reuse_decisions", "quality_decisions", "domain_objects"
    )
    for kind in collections:
        for item in data.get(kind, []):
            item_id = str(item.get("id", "（空）"))
            req_refs = set(item.get("requirement_refs", []))
            src_refs = set(item.get("source_refs", []))
            ac_refs = set(item.get("acceptance_refs", []))
            unknown_requirements = req_refs - known_requirements
            unknown_sources = src_refs - known_source_ids
            unknown_acceptance = ac_refs - known_acceptance
            if unknown_requirements:
                errors.append(f"{kind}/{item_id}：引用不存在的需求 {sorted(unknown_requirements)}")
            if unknown_sources:
                errors.append(f"{kind}/{item_id}：引用不存在的 PRD 来源单元 {sorted(unknown_sources)}")
            if unknown_acceptance:
                errors.append(f"{kind}/{item_id}：引用不存在的验收点 {sorted(unknown_acceptance)}")
            expected_requirements = set().union(*(acceptance_map.get(ac_id, set()) for ac_id in ac_refs))
            if ac_refs and req_refs != expected_requirements:
                errors.append(
                    f"{kind}/{item_id}：需求引用应为 {sorted(expected_requirements)}，实际为 {sorted(req_refs)}"
                )
            # Do not broadcast every source attached to a REQ onto each table,
            # field, API, page, or rule. These refs stay direct and are validated
            # against the registered inventory above; coverage closes the full chain.
            nested: list[tuple[str, dict[str, Any]]] = []
            if kind == "tables":
                nested.extend((f"fields/{field.get('name', '（空）')}", field) for field in item.get("fields", []))
            if kind == "apis":
                nested.extend(
                    (f"fields/{field.get('name', '（空）')}", field)
                    for field in item.get("request_fields", []) + item.get("response_fields", [])
                )
            for nested_path, field in nested:
                nested_requirements = set(field.get("requirement_refs", []))
                nested_sources = set(field.get("source_refs", []))
                unknown_nested_requirements = nested_requirements - known_requirements
                unknown_nested_sources = nested_sources - known_source_ids
                if unknown_nested_requirements:
                    errors.append(f"{kind}/{item_id}/{nested_path}：引用不存在的需求 {sorted(unknown_nested_requirements)}")
                if unknown_nested_sources:
                    errors.append(f"{kind}/{item_id}/{nested_path}：引用不存在的 PRD 来源单元 {sorted(unknown_nested_sources)}")
            # Object and field source_refs are direct evidence only. The full
            # source-set closure is carried by coverage rows and the REQ ledger.
    scenario_ids: set[str] = set()
    for flow in data.get("flows", []):
        flow_id = str(flow.get("id", "（空）"))
        flow_acceptance = set(flow.get("acceptance_refs", []))
        for scenario in flow.get("test_scenarios", []):
            scenario_id = str(scenario.get("id", "（空）"))
            location = f"flows/{flow_id}/test_scenarios/{scenario_id}"
            if scenario_id in scenario_ids:
                errors.append(f"流程测试场景 ID 重复：{scenario_id}")
            scenario_ids.add(scenario_id)
            scenario_acceptance = set(scenario.get("acceptance_refs", []))
            scenario_requirements = set(scenario.get("requirement_refs", []))
            scenario_sources = set(scenario.get("source_refs", []))
            if not scenario_acceptance:
                errors.append(f"{location}：至少需要一个验收点引用")
            missing_acceptance = scenario_acceptance - known_acceptance
            if missing_acceptance:
                errors.append(f"{location}：引用不存在的验收点 {sorted(missing_acceptance)}")
            outside_flow = scenario_acceptance - flow_acceptance
            if outside_flow:
                errors.append(f"{location}：验收点不属于流程 acceptance_refs {sorted(outside_flow)}")
            expected_requirements = set().union(
                *(acceptance_map.get(ac_id, set()) for ac_id in scenario_acceptance)
            )
            if scenario_requirements != expected_requirements:
                errors.append(
                    f"{location}：需求引用应为 {sorted(expected_requirements)}，实际为 {sorted(scenario_requirements)}"
                )
            unknown_requirements = scenario_requirements - known_requirements
            if unknown_requirements:
                errors.append(f"{location}：引用不存在的需求 {sorted(unknown_requirements)}")
            unknown_sources = scenario_sources - known_source_ids
            if unknown_sources:
                errors.append(f"{location}：引用不存在的 PRD 来源单元 {sorted(unknown_sources)}")
            if not scenario_sources:
                errors.append(f"{location}：必须引用至少一个直接来源单元")
            # Scenario source_refs cite the concrete scenario evidence. Coverage
            # rows retain direct AC source anchors; the REQ ledger retains all REQ sources.
    return errors


def extract_acceptance_source_refs(
    parsed_acceptance: dict[str, Any], inventory: dict[str, Any]
) -> tuple[dict[str, set[str]], list[str]]:
    """Extract direct AC source units from the frozen location anchors and scenario crosswalk."""
    units = inventory.get("units", [])
    source_ids = {unit.get("id") for unit in units if isinstance(unit, dict)}
    units_by_file: dict[str, list[dict[str, Any]]] = {}
    for unit in units:
        if isinstance(unit, dict):
            units_by_file.setdefault(str(unit.get("source_file", "")), []).append(unit)

    direct: dict[str, set[str]] = {
        str(row.get("验收点 ID", "")).strip(): set()
        for row in parsed_acceptance.get("acceptance_rows", [])
        if str(row.get("验收点 ID", "")).strip()
    }
    errors: list[str] = []
    location_pattern = re.compile(
        r"(?P<file>[^`\s;；（）()]+?\.md)#L(?P<start>\d+)(?:-L(?P<end>\d+))?"
    )
    source_id_pattern = re.compile(r"SRC-[a-f0-9]{20}")
    aliases = {"docs/PRD/基础能力模块_PRD.md": "01-产品需求.md"}

    for row in parsed_acceptance.get("acceptance_rows", []):
        ac_id = str(row.get("验收点 ID", "")).strip()
        location = str(row.get("PRD 位置", ""))
        for source_id in source_id_pattern.findall(location):
            if source_id in source_ids:
                direct[ac_id].add(source_id)
            else:
                errors.append(f"验收点 {ac_id} 的直接来源单元未登记：{source_id}")
        for match in location_pattern.finditer(location):
            source_file = match.group("file").strip()
            source_file = aliases.get(source_file, source_file)
            start_line = int(match.group("start"))
            end_line = int(match.group("end") or start_line)
            candidates = units_by_file.get(source_file, [])
            if not candidates:
                suffix_matches = [
                    file for file in units_by_file
                    if file.endswith("/" + source_file) or source_file.endswith("/" + file)
                ]
                if len(suffix_matches) == 1:
                    candidates = units_by_file[suffix_matches[0]]
            matched = {
                unit["id"] for unit in candidates
                if unit.get("start_line", 0) <= end_line and unit.get("end_line", 0) >= start_line
            }
            if not matched:
                errors.append(
                    f"验收点 {ac_id} 的来源锚点未映射到来源清单：{source_file}#L{start_line}-L{end_line}"
                )
            direct[ac_id].update(matched)

    for row in parsed_acceptance.get("scenario_rows", []):
        source_id = str(row.get("PRD 来源单元 ID", "")).strip()
        if not source_id:
            continue
        if source_id not in source_ids:
            errors.append(f"验收场景映射引用未登记的直接来源单元：{source_id}")
            continue
        acceptance_ids = [
            value.strip() for value in re.split(r"[,，、]", str(row.get("原子验收点 ID", "")))
            if value.strip()
        ]
        for ac_id in acceptance_ids:
            if ac_id in direct:
                direct[ac_id].add(source_id)

    for ac_id, refs in direct.items():
        if not refs:
            errors.append(f"验收点 {ac_id} 没有可定位的直接来源单元")
    return direct, errors


def validate_design_baseline(
    directory: Path,
    baseline: dict[str, Any],
    manifest: dict[str, Any],
    prd_state: tuple[list[str], dict[str, Any] | None, dict[str, Any] | None] | None = None,
) -> list[str]:
    """Require the design baseline to match the current PRD and frozen inputs."""
    errors, ledger, acceptance = prd_state or check_prd(directory, manifest)
    if errors or ledger is None or acceptance is None:
        return errors or ["无法读取 PRD 需求台账或冻结验收基线"]
    pipeline = manifest["prd_pipeline"]
    directory = Path(directory)
    inventory_path = directory / pipeline["inventory_file"]
    acceptance_path = directory / pipeline["acceptance_file"]
    try:
        inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"无法读取 PRD 来源清单：{exc}"]

    expected = {
        "prd": pipeline["prd_file"],
        "prd_sha256": inventory["prd_sha256"],
        "requirements_file": pipeline["ledger_file"],
        "requirements_version": ledger["schema_version"],
        "acceptance_file": pipeline["acceptance_file"],
        "acceptance_version": acceptance["version"],
        "acceptance_sha256": freeze_fingerprint(acceptance_path),
    }
    labels = {
        "prd": "PRD 路径", "prd_sha256": "PRD SHA256",
        "requirements_file": "需求台账路径", "requirements_version": "需求台账版本",
        "acceptance_file": "验收清单路径", "acceptance_version": "验收清单版本",
        "acceptance_sha256": "验收清单 SHA256",
    }
    for key, expected_value in expected.items():
        actual_value = str(baseline.get(key, "")).strip()
        if actual_value != str(expected_value):
            errors.append(f"详设基线{labels[key]}不匹配：期望 {expected_value}，实际 {actual_value or '（空）'}")

    source_hash_present = "source_set_sha256" in baseline
    source_count_present = "source_unit_count" in baseline
    if source_hash_present != source_count_present:
        errors.append("详设基线 source_set_sha256 与 source_unit_count 必须同时提供；旧详设两者均缺失时按未绑定处理")
    elif source_hash_present:
        source_expected = {
            "source_set_sha256": inventory["source_set_sha256"],
            "source_unit_count": len(inventory["units"]),
        }
        for key, expected_value in source_expected.items():
            actual_value = baseline.get(key)
            if actual_value != expected_value:
                label = "source-set SHA256" if key == "source_set_sha256" else "source unit count"
                errors.append(f"详设基线 {label} 不匹配：期望 {expected_value}，实际 {actual_value!r}")
    return errors


def source_set_binding(baseline: dict[str, Any], inventory: dict[str, Any]) -> dict[str, Any]:
    """Describe source-set binding without treating legacy baselines as verified."""
    has_hash = "source_set_sha256" in baseline
    has_count = "source_unit_count" in baseline
    if not has_hash and not has_count:
        return {"status": "LEGACY_UNBOUND", "sha256": None, "unit_count": None}
    source_hash = baseline.get("source_set_sha256")
    source_count = baseline.get("source_unit_count")
    expected_hash = inventory.get("source_set_sha256")
    expected_count = len(inventory.get("units", []))
    if source_hash == expected_hash and source_count == expected_count:
        status = "VERIFIED"
    else:
        status = "MISMATCH"
    return {"status": status, "sha256": source_hash, "unit_count": source_count}


def resolve_schema_ref(root: dict[str, Any], reference: str) -> dict[str, Any]:
    """解析当前 JSON Schema 使用的本地 #/definitions/... 引用。"""
    node: Any = root
    for part in reference.removeprefix("#/").split("/"):
        node = node[part]
    return node


def validate_schema(value: Any, schema: dict[str, Any], root: dict[str, Any], path: str = "$") -> list[str]:
    """执行契约使用到的 draft-07 子集校验，不依赖外部 Python 包。"""
    if "$ref" in schema:
        return validate_schema(value, resolve_schema_ref(root, schema["$ref"]), root, path)
    errors: list[str] = []
    for child_schema in schema.get("allOf", []):
        errors.extend(validate_schema(value, child_schema, root, path))
    if "anyOf" in schema:
        if not any(not validate_schema(value, option, root, path) for option in schema["anyOf"]):
            errors.append(f"{path}：不匹配 anyOf 的任何分支")
    if "if" in schema:
        condition_matches = not validate_schema(value, schema["if"], root, path)
        branch = schema.get("then") if condition_matches else schema.get("else")
        if branch is not None:
            errors.extend(validate_schema(value, branch, root, path))
    expected_type = schema.get("type")
    checks = {
        "object": lambda item: isinstance(item, dict),
        "array": lambda item: isinstance(item, list),
        "string": lambda item: isinstance(item, str),
        "integer": lambda item: isinstance(item, int) and not isinstance(item, bool),
        "boolean": lambda item: isinstance(item, bool),
        "null": lambda item: item is None,
    }
    if expected_type in checks and not checks[expected_type](value):
        return [f"{path}：应为 {expected_type}"]
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}：必须等于 {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}：取值必须属于 {schema['enum']}")
    if isinstance(value, str) and len(value) < schema.get("minLength", 0):
        errors.append(f"{path}：不能为空")
    if isinstance(value, str) and "pattern" in schema and not re.fullmatch(schema["pattern"], value):
        errors.append(f"{path}：值不匹配 pattern {schema['pattern']}")
    if isinstance(value, list) and len(value) < schema.get("minItems", 0):
        errors.append(f"{path}：至少需要 {schema['minItems']} 项")
    if isinstance(value, list) and "maxItems" in schema and len(value) > schema["maxItems"]:
        errors.append(f"{path}：最多允许 {schema['maxItems']} 项")
    if isinstance(value, list) and schema.get("uniqueItems") is True:
        serialized = [json.dumps(item, ensure_ascii=False, sort_keys=True) for item in value]
        if len(serialized) != len(set(serialized)):
            errors.append(f"{path}：数组元素必须满足 uniqueItems")
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}：数值小于 minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}：数值大于 maximum {schema['maximum']}")
    if isinstance(value, dict):
        properties = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}.{key}：缺少必填字段")
        if schema.get("additionalProperties") is False:
            for key in value.keys() - properties.keys():
                errors.append(f"{path}.{key}：不是契约字段")
        for key, child_schema in properties.items():
            if key in value:
                errors.extend(validate_schema(value[key], child_schema, root, f"{path}.{key}"))
    if isinstance(value, list) and "items" in schema:
        for index, item in enumerate(value):
            errors.extend(validate_schema(item, schema["items"], root, f"{path}[{index}]"))
    return errors


def walk_strings(value: Any, path: str = "$"):
    """递归遍历 JSON 字符串，定位未完成的模板占位内容。"""
    if isinstance(value, str):
        yield path, value
    elif isinstance(value, dict):
        for key, item in value.items():
            yield from walk_strings(item, f"{path}.{key}")
    elif isinstance(value, list):
        for index, item in enumerate(value):
            yield from walk_strings(item, f"{path}[{index}]")


def extract_acceptance_points(
    directory: Path, data: dict[str, Any], parsed: dict[str, Any] | None = None
) -> tuple[dict[str, set[str]], list[str]]:
    """从冻结验收点清单读取 AC→需求集合映射，作为详设完整性分母。"""
    relative = data.get("baseline", {}).get("acceptance_file", "")
    path = directory / relative
    if not path.is_file():
        return {}, [f"验收点清单不存在：{relative}"]
    errors: list[str] = []
    try:
        parsed = parsed or parse_acceptance(path)
    except (OSError, UnicodeError, ValueError) as exc:
        return {}, [f"验收点清单解析失败：{exc}"]
    if parsed["version"] != data.get("baseline", {}).get("acceptance_version"):
        errors.append("详设 JSON 的 acceptance_version 与验收点清单版本不一致")
    acceptance: dict[str, set[str]] = {}
    for row in parsed["acceptance_rows"]:
        ac_id = row["验收点 ID"].strip()
        requirement_refs = {part.strip() for part in re.split(r"[,，、]", row["PRD 需求 ID"]) if part.strip()}
        if not ac_id:
            errors.append("验收点 ID 不能为空")
        if ac_id in acceptance:
            errors.append(f"验收点 ID 重复：{ac_id}")
        acceptance[ac_id] = requirement_refs
    return acceptance, errors


def legacy_flows_without_diagram_refs(flows: list[dict[str, Any]]) -> set[str]:
    """Identify older flows that predate the additive diagram_refs property."""
    return {
        flow["id"] for flow in flows
        if (
            isinstance(flow, dict)
            and isinstance(flow.get("id"), str)
            and "diagram_refs" not in flow
            and "test_anchor" not in flow
            and "test_scenarios" not in flow
        )
    }


def normalize_legacy_flow_diagram_refs(flows: list[dict[str, Any]]) -> set[str]:
    """Capture legacy flows before adding the optional property in memory."""
    legacy_flow_ids = legacy_flows_without_diagram_refs(flows)
    for flow in flows:
        if isinstance(flow, dict):
            flow.setdefault("diagram_refs", [])
    return legacy_flow_ids


def validate_flow_diagram_links(
    flows: list[dict[str, Any]],
    diagrams: list[dict[str, Any]],
    legacy_flow_ids: set[str] | None = None,
) -> list[str]:
    """Validate flow↔diagram links in both directions with legacy compatibility."""
    legacy_flow_ids = legacy_flow_ids or set()
    flows_by_id = {flow.get("id"): flow for flow in flows if isinstance(flow, dict)}
    diagrams_by_id = {diagram.get("id"): diagram for diagram in diagrams if isinstance(diagram, dict)}
    flow_diagram_refs = {
        flow.get("id"): set(flow.get("diagram_refs", []))
        for flow in flows if isinstance(flow, dict)
    }
    diagram_flow_refs: dict[str, set[str]] = {}
    for diagram in diagrams:
        if not isinstance(diagram, dict):
            continue
        diagram_id = diagram.get("id")
        diagram_flow_refs[diagram_id] = {
            ref.get("id") for ref in diagram.get("typed_refs", [])
            if isinstance(ref, dict) and ref.get("kind") == "flows"
        }
    errors: list[str] = []

    for flow in flows:
        if not isinstance(flow, dict):
            continue
        flow_id = flow.get("id")
        diagram_refs = flow.get("diagram_refs", [])
        has_test_contract = "test_anchor" in flow or "test_scenarios" in flow
        if flow_id not in legacy_flow_ids and has_test_contract and not diagram_refs:
            errors.append(f"flows/{flow_id}：有流程测试契约但未关联流程图")
        for diagram_id in diagram_refs:
            if diagram_id in diagrams_by_id and flow_id not in diagram_flow_refs.get(diagram_id, set()):
                errors.append(f"flows/{flow_id}：图示 {diagram_id} 未反向声明该流程")

    for diagram in diagrams:
        if not isinstance(diagram, dict):
            continue
        for ref in diagram.get("typed_refs", []):
            if not isinstance(ref, dict) or ref.get("kind") != "flows":
                continue
            flow_id = ref.get("id")
            flow = flows_by_id.get(flow_id)
            if flow is None or flow_id in legacy_flow_ids:
                continue
            if diagram.get("id") not in flow_diagram_refs.get(flow_id, set()):
                errors.append(
                    f"diagrams/{diagram.get('id')}：声明流程 {flow_id}，但流程未反向引用该图示"
                )
    return errors


def validate_design_data(
    directory: Path,
    structured: dict[str, Any],
    manifest: dict[str, Any] | None = None,
    prd_state: tuple[list[str], dict[str, Any] | None, dict[str, Any] | None] | None = None,
) -> tuple[dict[str, Any] | None, list[str]]:
    """校验 JSON 结构、ID 唯一、验收点全覆盖和跨对象引用闭环。"""
    manifest = manifest or load_manifest()
    prd_state = prd_state or check_prd(directory, manifest)
    prd_errors, ledger, parsed_acceptance = prd_state
    if prd_errors or ledger is None or parsed_acceptance is None:
        return None, prd_errors or ["PRD→验收基线未完成"]
    json_path = directory / structured["file"]
    schema_path = SKILL_ROOT / "契约" / structured["schema"]
    try:
        data = json.loads(json_path.read_text(encoding="utf-8"))
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, [f"无法读取详设 JSON 或 schema：{exc}"]

    # Keep older schema v2 projects additive-compatible as full-design sections grow.
    # Track flows that predate diagram_refs so old diagrams need not be rewritten.
    legacy_flow_diagram_ref_ids = normalize_legacy_flow_diagram_refs(data.get("flows", [])) if (
        isinstance(data, dict) and isinstance(data.get("flows"), list)
    ) else set()
    if isinstance(data, dict):
        for kind in ("glossary", "permissions", "diagrams", "dependencies", "reuse_decisions", "domain_objects"):
            data.setdefault(kind, [])
        if isinstance(data.get("zero_results"), dict):
            reasons = {
                "glossary": "本设计没有需要独立定义的术语。",
                "permissions": "本设计没有独立权限矩阵。",
                "diagrams": "本设计无需额外图示。",
                "dependencies": "本设计没有额外内外部依赖。",
                "reuse_decisions": "本设计没有需记录的复用决策。",
                "domain_objects": "本设计没有额外领域对象。",
            }
            for kind, reason in reasons.items():
                data["zero_results"].setdefault(kind, reason)
        if isinstance(data.get("coverage"), list):
            for row in data["coverage"]:
                if isinstance(row, dict):
                    row.setdefault("domain_refs", [])
                    for field in ("glossary_refs", "permission_refs", "diagram_refs", "dependency_refs", "reuse_refs"):
                        row.setdefault(field, [])

    errors = validate_schema(data, schema, schema)
    if errors:
        return data, errors
    errors.extend(validate_design_baseline(directory, data.get("baseline", {}), manifest, prd_state))
    for location, value in walk_strings(data):
        if any(marker in value for marker in ("待填写", "待补充", "TODO", "TBD", "FIXME", "{{")):
            errors.append(f"{location}：仍有未填写占位内容")
    if errors:
        return data, errors
    acceptance, ac_errors = extract_acceptance_points(directory, data, parsed_acceptance)
    errors.extend(ac_errors)
    acceptance_ids = set(acceptance)

    collections = {
        "glossary": data["glossary"], "tables": data["tables"], "apis": data["apis"],
        "permissions": data["permissions"], "rules": data["rules"], "flows": data["flows"],
        "diagrams": data["diagrams"], "pages": data["pages"], "dependencies": data["dependencies"],
        "reuse_decisions": data["reuse_decisions"], "quality_decisions": data["quality_decisions"],
        "domain_objects": data["domain_objects"],
    }
    requirement_ids = {item["id"] for item in ledger["requirements"]}
    constraint_ids = {item["id"] for item in data["scope"]["constraints"]}
    assumption_ids = {item["id"] for item in data["scope"]["assumptions"]}
    inventory_path = directory / manifest["prd_pipeline"]["inventory_file"]
    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    acceptance_source_map, direct_source_errors = extract_acceptance_source_refs(parsed_acceptance, inventory)
    errors.extend(direct_source_errors)
    source_unit_ids = {unit["id"] for unit in inventory["units"]}
    known_source_ids = source_unit_ids | constraint_ids | assumption_ids
    ids: dict[str, set[str]] = {}
    domain_types: dict[str, set[str]] = {}
    reserved_domain_kinds = set(collections)
    for kind, items in collections.items():
        seen: set[str] = set()
        for index, item in enumerate(items):
            item_id = item["id"]
            identity = domain_object_key(item["kind"], item_id) if kind == "domain_objects" else item_id
            if identity in seen:
                errors.append(f"{kind}[{index}]：ID 重复 {identity}")
            seen.add(identity)
            if kind == "domain_objects":
                object_kind = item["kind"].strip()
                if object_kind != item["kind"] or item_id != item_id.strip() or any(
                    unicodedata.category(char) == "Cc" for char in item["kind"] + item_id
                ):
                    errors.append(f"domain_objects[{index}]：kind 和 id 不得含首尾空白或控制字符")
                if object_kind in reserved_domain_kinds:
                    errors.append(f"domain_objects/{identity}：kind 不得与内置对象类型冲突")
                domain_types.setdefault(object_kind, set()).add(item_id)
            refs = set(item.get("acceptance_refs", []))
            missing = refs - acceptance_ids
            if missing:
                errors.append(f"{kind}/{item_id}：引用了不存在的验收点 {sorted(missing)}")
            if not refs and not item.get("unreferenced_reason", "").strip():
                errors.append(f"{kind}/{item_id}：没有验收点引用，须填写 unreferenced_reason")
            if kind == "tables":
                field_names = [field["name"] for field in item["fields"]]
                if len(field_names) != len(set(field_names)):
                    errors.append(f"tables/{item_id}：字段名重复")
        ids[kind] = seen
        if not items and not data["zero_results"].get(kind, "").strip():
            errors.append(f"{kind} 为空，须在 zero_results.{kind} 说明原因")
        elif items and data["zero_results"].get(kind, "").strip():
            errors.append(f"{kind} 已有设计对象，但 zero_results.{kind} 声明了无对象；请清空零结果理由")

    ids["features"] = {item["id"] for item in data["scope"]["features"]}

    for item in data["domain_objects"]:
        location = f"domain_objects/{domain_object_key(item['kind'], item['id'])}"
        for ref in item["typed_refs"]:
            ref_kind = ref["kind"]
            ref_id = ref["id"]
            if ref_kind == "domain_objects":
                if ref_id not in ids["domain_objects"]:
                    errors.append(f"{location}：引用不存在的领域对象组合 ID {ref_id}")
            elif ref_kind in ids:
                if ref_id not in ids[ref_kind]:
                    errors.append(f"{location}：引用不存在的 {ref_kind} ID {ref_id}")
            elif ref_kind in domain_types:
                if ref_id not in domain_types[ref_kind]:
                    errors.append(f"{location}：引用不存在的领域对象 {ref_kind}/{ref_id}")
            else:
                errors.append(f"{location}：引用了未声明的对象类型 {ref_kind}")

    for kind in ("diagrams", "dependencies", "reuse_decisions"):
        for item in data[kind]:
            location = f"{kind}/{item['id']}"
            for ref in item["typed_refs"]:
                ref_kind, ref_id = ref["kind"], ref["id"]
                if ref_kind in ids:
                    exists = ref_id in ids[ref_kind]
                elif ref_kind in domain_types:
                    exists = ref_id in domain_types[ref_kind]
                else:
                    exists = False
                if not exists:
                    errors.append(f"{location}：引用了不存在或未声明的对象 {ref_kind}/{ref_id}")

    for api in data["apis"]:
        for label, fields in (("请求", api["request_fields"]), ("响应", api["response_fields"])):
            names = [field["name"] for field in fields]
            if len(names) != len(set(names)):
                errors.append(f"apis/{api['id']}：{label}字段名重复")
        if not api["request_fields"] and not api["no_request_reason"].strip():
            errors.append(f"apis/{api['id']}：请求字段为空，须说明 no_request_reason")
        if not api["response_fields"] and not api["no_response_reason"].strip():
            errors.append(f"apis/{api['id']}：响应字段为空，须说明 no_response_reason")

    def check_refs(owner: str, refs: list[str], kind: str, location: str) -> None:
        for ref in refs:
            if ref not in ids[kind]:
                errors.append(f"{location}：引用了不存在的 {owner} ID {ref}")

    for permission in data["permissions"]:
        check_refs("API", permission["api_refs"], "apis", f"permissions/{permission['id']}")
        check_refs("page", permission["page_refs"], "pages", f"permissions/{permission['id']}")
        check_refs("rule", permission["rule_refs"], "rules", f"permissions/{permission['id']}")

    for api in data["apis"]:
        check_refs("table", api["table_refs"], "tables", f"apis/{api['id']}")
        check_refs("rule", api["rule_refs"], "rules", f"apis/{api['id']}")
    for rule in data["rules"]:
        check_refs("table", rule["table_refs"], "tables", f"rules/{rule['id']}")
        check_refs("API", rule["api_refs"], "apis", f"rules/{rule['id']}")
        unknown_sources = set(rule["source_refs"]) - known_source_ids
        if unknown_sources:
            errors.append(f"rules/{rule['id']}：来源引用不存在 {sorted(unknown_sources)}")
    for decision in data["quality_decisions"]:
        unknown_sources = set(decision["source_refs"]) - known_source_ids
        if unknown_sources:
            errors.append(f"quality_decisions/{decision['id']}：来源引用不存在 {sorted(unknown_sources)}")
    for flow in data["flows"]:
        check_refs("table", flow["table_refs"], "tables", f"flows/{flow['id']}")
        check_refs("API", flow["api_refs"], "apis", f"flows/{flow['id']}")
        check_refs("diagram", flow.get("diagram_refs", []), "diagrams", f"flows/{flow['id']}")
        check_refs("rule", flow["rule_refs"], "rules", f"flows/{flow['id']}")
    errors.extend(validate_flow_diagram_links(data["flows"], data["diagrams"], legacy_flow_diagram_ref_ids))
    test_anchors: dict[str, str] = {}
    for flow in data["flows"]:
        anchor = flow.get("test_anchor", "").strip()
        if anchor:
            if anchor in test_anchors:
                errors.append(f"测试锚点重复：{anchor}（{test_anchors[anchor]} 与 flows/{flow['id']}）")
            test_anchors[anchor] = f"flows/{flow['id']}"
    for page in data["pages"]:
        for control in page["controls"]:
            check_refs("table", [ref.split(".", 1)[0] for ref in control["data_refs"]], "tables", f"pages/{page['id']}/controls/{control['name']}")
        for action in page["actions"]:
            check_refs("API", action["api_refs"], "apis", f"pages/{page['id']}/actions/{action['name']}")
            check_refs("rule", action["rule_refs"], "rules", f"pages/{page['id']}/actions/{action['name']}")
        for dialog in page["dialogs"]:
            check_refs("API", dialog["api_refs"], "apis", f"pages/{page['id']}/dialogs/{dialog['name']}")
        if not page["controls"] and not page["actions"] and not page["dialogs"] and not page["empty_content_reason"].strip():
            errors.append(f"pages/{page['id']}：控件、操作和弹窗均为空，须说明 empty_content_reason")

        for collection_name in ("controls", "actions", "dialogs"):
            for item in page[collection_name]:
                anchor = item["test_anchor"]
                if anchor in test_anchors:
                    errors.append(f"测试锚点重复：{anchor}（{test_anchors[anchor]} 与 {page['id']}/{collection_name}）")
                test_anchors[anchor] = f"{page['id']}/{collection_name}"

    table_fields = {table["id"]: {field["name"] for field in table["fields"]} for table in data["tables"]}
    def check_data_refs(refs: list[str], location: str) -> None:
        for ref in refs:
            if "." not in ref:
                errors.append(f"{location}：数据引用须为 表ID.字段名，实际为 {ref}")
                continue
            table_id, field_name = ref.split(".", 1)
            if table_id not in table_fields or field_name not in table_fields.get(table_id, set()):
                errors.append(f"{location}：数据引用不存在 {ref}")
    for api in data["apis"]:
        for field in api["request_fields"] + api["response_fields"]:
            check_data_refs(field["data_refs"], f"apis/{api['id']}/fields/{field['name']}")
            for ref in field["data_refs"]:
                table_id = ref.split(".", 1)[0]
                if table_id not in api["table_refs"]:
                    errors.append(f"apis/{api['id']}/fields/{field['name']}：{ref} 未登记在接口 table_refs")
    for page in data["pages"]:
        for control in page["controls"]:
            check_data_refs(control["data_refs"], f"pages/{page['id']}/controls/{control['name']}")

    api_paths = [(api["method"].upper(), api["path"]) for api in data["apis"]]
    if len(api_paths) != len(set(api_paths)):
        errors.append("接口 method + path 存在重复定义")
    table_names = [table["name"] for table in data["tables"]]
    if len(table_names) != len(set(table_names)):
        errors.append("数据表名称存在重复定义")
    for feature in data["scope"]["features"]:
        missing_requirements = set(feature["requirement_refs"]) - requirement_ids
        if missing_requirements:
            errors.append(f"scope/features/{feature['id']}：需求引用不存在 {sorted(missing_requirements)}")

    coverage = data["coverage"]
    coverage_ids = [row["acceptance_id"] for row in coverage]
    if len(coverage_ids) != len(set(coverage_ids)):
        errors.append("coverage 中存在重复验收点 ID")
    if set(coverage_ids) != acceptance_ids:
        errors.append(
            f"coverage 与冻结验收点集合不一致；缺少 {sorted(acceptance_ids - set(coverage_ids))}，"
            f"多出 {sorted(set(coverage_ids) - acceptance_ids)}"
        )
    field_to_collection = {
        "glossary_refs": "glossary", "table_refs": "tables", "api_refs": "apis",
        "permission_refs": "permissions", "rule_refs": "rules", "flow_refs": "flows",
        "diagram_refs": "diagrams", "page_refs": "pages", "dependency_refs": "dependencies",
        "reuse_refs": "reuse_decisions", "quality_refs": "quality_decisions",
    }
    by_kind = {kind: {item["id"]: item for item in items} for kind, items in collections.items()}
    domain_object_index = {(item["kind"], item["id"]): item for item in data["domain_objects"]}
    linked_acceptance: set[str] = set()
    for row in coverage:
        ac_id = row["acceptance_id"]
        if ac_id not in acceptance_ids:
            errors.append(f"coverage：不存在的验收点 {ac_id}")
        refs_found = False
        for ref in row.get("domain_refs", []):
            refs_found = True
            item = domain_object_index.get((ref["kind"], ref["id"]))
            if item is None:
                errors.append(f"coverage/{ac_id}：领域对象引用不存在 {ref['kind']}/{ref['id']}")
            elif ac_id not in item["acceptance_refs"]:
                errors.append(f"coverage/{ac_id}：领域对象 {ref['kind']}/{ref['id']} 未反向声明该验收点")
        for ref_field, kind in field_to_collection.items():
            refs = set(row[ref_field])
            refs_found = refs_found or bool(refs)
            for ref in refs:
                item = by_kind[kind].get(ref)
                if item is None:
                    errors.append(f"coverage/{ac_id}：{kind} 引用不存在的 ID {ref}")
                elif ac_id not in item["acceptance_refs"]:
                    errors.append(f"coverage/{ac_id}：{kind}/{ref} 未反向声明该验收点")
        if refs_found:
            linked_acceptance.add(ac_id)
        elif not row["not_applicable_reason"].strip():
            errors.append(f"coverage/{ac_id}：没有设计落点，须填写 not_applicable_reason")
        expected_requirements = acceptance.get(ac_id, set())
        actual_requirements = set(row["requirement_refs"])
        if actual_requirements != expected_requirements:
            errors.append(
                f"coverage/{ac_id}：PRD 需求引用应为 {sorted(expected_requirements)}，实际为 {sorted(actual_requirements)}"
            )
    for kind, items in collections.items():
        if kind == "domain_objects":
            continue
        ref_field = next(key for key, value in field_to_collection.items() if value == kind)
        for item in items:
            for ac_id in item["acceptance_refs"]:
                row = next((r for r in coverage if r["acceptance_id"] == ac_id), None)
                if row is None or item["id"] not in row[ref_field]:
                    errors.append(f"{kind}/{item['id']}：验收点 {ac_id} 未在 coverage 中反向登记")
    for item in data["domain_objects"]:
        for ac_id in item["acceptance_refs"]:
            row = next((r for r in coverage if r["acceptance_id"] == ac_id), None)
            if row is None or not any(
                ref["kind"] == item["kind"] and ref["id"] == item["id"]
                for ref in row.get("domain_refs", [])
            ):
                errors.append(f"domain_objects/{domain_object_key(item['kind'], item['id'])}：验收点 {ac_id} 未在 coverage 中反向登记")
    if acceptance_ids - linked_acceptance:
        errors.append(f"未映射到任何设计对象的验收点：{sorted(acceptance_ids - linked_acceptance)}")
    errors.extend(validate_design_traceability(data, acceptance, ledger, inventory, acceptance_source_map))
    return data, errors


def md_cell(value: Any) -> str:
    if isinstance(value, list):
        value = "、".join(str(item) for item in value) if value else "—"
    text = str(value).strip() if value is not None else ""
    return text.replace("|", "\\|").replace("\n", "<br>") or "—"


def md_table(headers: list[str], rows: list[list[Any]]) -> str:
    lines = ["| " + " | ".join(headers) + " |", "|" + "|".join("---" for _ in headers) + "|"]
    lines.extend("| " + " | ".join(md_cell(value) for value in row) + " |" for row in rows)
    if not rows:
        lines.append("| " + " | ".join("—" for _ in headers) + " |")
    return "\n".join(lines)


def render_flow_test_scenarios(flow: dict[str, Any]) -> str:
    """Render optional Given/When/Then scenarios while keeping legacy flows valid."""
    scenarios = flow.get("test_scenarios", [])
    if not scenarios:
        return ""
    anchor = flow.get("test_anchor", "").strip()
    anchor_line = f"流程测试锚点：{anchor}\n\n" if anchor else ""
    rows = [[
        scenario["id"], scenario["given"], scenario["when"], scenario["then"],
        scenario["requirement_refs"], scenario["source_refs"], scenario["acceptance_refs"],
    ] for scenario in scenarios]
    return anchor_line + "测试场景（Given / When / Then）\n\n" + md_table(
        ["场景 ID", "Given 前置", "When 触发", "Then 可观察结果", "REQ", "SRC", "AC"], rows
    )


def domain_object_key(kind: str, object_id: str) -> str:
    """Encode an extensible type/ID pair as an unambiguous package key."""
    return f"{quote(kind, safe='')}:{quote(object_id, safe='')}"


DESIGN_OBJECT_KINDS = (
    "features", "glossary", "tables", "apis", "permissions", "rules", "flows",
    "diagrams", "pages", "dependencies", "reuse_decisions", "quality_decisions", "domain_objects",
)
REFERENCE_KINDS = (*DESIGN_OBJECT_KINDS, "table_fields")


def design_object_anchor(kind: str, object_id: str) -> str:
    """Return a stable, collision-resistant anchor for one typed design object ID."""
    slug = re.sub(r"[^a-z0-9]+", "-", unicodedata.normalize("NFC", object_id).casefold()).strip("-") or "item"
    digest = hashlib.sha256(f"{kind}\0{object_id}".encode("utf-8")).hexdigest()[:10]
    return f"ref-{kind}-{slug}-{digest}"


def build_reference_context(
    data: dict[str, Any], package: dict[str, Any] | None, current_path: str
) -> dict[str, Any]:
    """Index typed design IDs to stable anchors and their subdocument owners."""
    objects: dict[str, list[dict[str, Any]]] = {
        **{kind: data.get(kind, []) for kind in REFERENCE_KINDS if kind not in {"features", "domain_objects"}},
        "features": data.get("scope", {}).get("features", []),
        "domain_objects": [
            {"id": domain_object_key(item["kind"], item["id"])} for item in data.get("domain_objects", [])
        ],
    }
    objects["table_fields"] = [
        {"id": f"{table['id']}.{field['name']}"}
        for table in data.get("tables", [])
        for field in table.get("fields", [])
    ]
    owners: dict[tuple[str, str], list[str]] = {}
    if package is None:
        for kind, entries in objects.items():
            for item in entries:
                owners[(kind, item["id"])] = [current_path]
        present = set(owners)
    else:
        for document in package["subdocuments"]:
            for kind, ids in document["object_refs"].items():
                for object_id in ids:
                    owners.setdefault((kind, object_id), []).append(document["path"])
        for table in data.get("tables", []):
            table_owners = owners.get(("tables", table["id"]), [])
            for field in table.get("fields", []):
                owners[("table_fields", f"{table['id']}.{field['name']}")] = list(table_owners)
        if current_path == package["total"]["path"]:
            present = {(kind, item["id"]) for kind, entries in objects.items() for item in entries}
        else:
            current_doc = next((doc for doc in package["subdocuments"] if doc["path"] == current_path), None)
            present = set()
            if current_doc is not None:
                present = {
                    (kind, object_id)
                    for kind, ids in current_doc["object_refs"].items()
                    for object_id in ids
                }
                for table in data.get("tables", []):
                    if ("tables", table["id"]) in present:
                        present.update(
                            ("table_fields", f"{table['id']}.{field['name']}")
                            for field in table.get("fields", [])
                        )

    catalog: dict[tuple[str, str], dict[str, Any]] = {}
    for kind, entries in objects.items():
        for item in entries:
            key = (kind, item["id"])
            catalog[key] = {
                "anchor": design_object_anchor(*key),
                "owners": owners.get(key, []),
            }
    return {"catalog": catalog, "current_path": current_path, "present": present}


def markdown_reference(kind: str, object_id: str, context: dict[str, Any] | None) -> str:
    if context is None:
        return md_cell(object_id)
    key = (kind, object_id)
    item = context["catalog"].get(key)
    if item is None:
        raise ValueError(f"无法为不存在的设计引用生成链接：{kind}/{object_id}")
    current_path = context["current_path"]
    if key in context["present"]:
        target_path = current_path
    elif item["owners"]:
        target_path = item["owners"][0]
    else:
        raise ValueError(f"设计引用没有文档归属：{kind}/{object_id}")
    if target_path == current_path:
        destination = f"#{item['anchor']}"
    else:
        relative = posixpath.relpath(target_path, posixpath.dirname(current_path) or ".")
        destination = f"{quote(relative, safe='/-._~')}#{item['anchor']}"
    label = object_id.replace("\\", "\\\\").replace("[", "\\[").replace("]", "\\]").replace("|", "\\|")
    return f"[{label}]({destination})"


def markdown_references(kind: str, object_ids: list[str], context: dict[str, Any] | None) -> str:
    if not object_ids:
        return "—"
    return "、".join(markdown_reference(kind, object_id, context) for object_id in object_ids)


def markdown_owner_reference(kind: str, object_id: str, context: dict[str, Any] | None) -> str:
    """Link to the detailed owner document, especially from a total-design index."""
    if context is None:
        return "—"
    key = (kind, object_id)
    item = context["catalog"].get(key)
    if item is None:
        raise ValueError(f"无法解析设计对象归属：{kind}/{object_id}")
    owners = item["owners"]
    if not owners:
        return "—"
    current = context["current_path"]
    target = current if current in owners else owners[0]
    if target == current:
        return f"[本文](#{item['anchor']})"
    relative = posixpath.relpath(target, posixpath.dirname(current) or ".")
    destination = f"{quote(relative, safe='/-._~')}#{item['anchor']}"
    return f"[详设]({destination})"


def markdown_typed_reference(kind: str, object_id: str, context: dict[str, Any] | None) -> str:
    if kind == "domain_objects":
        return markdown_reference("domain_objects", object_id, context)
    if kind in DESIGN_OBJECT_KINDS:
        return markdown_reference(kind, object_id, context)
    return markdown_reference("domain_objects", domain_object_key(kind, object_id), context)


def markdown_table_field_references(references: list[str], context: dict[str, Any] | None) -> str:
    if not references:
        return "—"
    return "、".join(
        markdown_reference("table_fields", reference, context)
        if context is not None and ("table_fields", reference) in context["catalog"]
        else md_cell(reference)
        for reference in references
    )


def design_object_anchor_markup(kind: str, object_id: str) -> str:
    return f'<a id="{design_object_anchor(kind, object_id)}"></a>'


def render_anchored_blocks(
    text: str,
    bodies: dict[str, str],
    required: list[str],
    template_id: str,
    template_version: str,
) -> str:
    """Replace only registered generated blocks and preserve all surrounding prose."""
    id_marker = f"<!-- develop:template-id:{template_id} -->"
    version_marker = f"<!-- develop:template-version:{template_version} -->"
    if text.count("<!-- develop:template-id:") != 1 or id_marker not in text:
        raise ValueError("详设文档 template-id 缺失、重复或不匹配")
    if text.count("<!-- develop:template-version:") != 1 or version_marker not in text:
        raise ValueError("详设文档 template-version 缺失、重复或不匹配")
    if set(bodies) != set(required):
        raise ValueError("渲染内容与注册的 render_blocks 集合不一致")

    marker_re = re.compile(r"<!-- develop:(begin|end):([A-Z][A-Z0-9_]*) -->")
    markers = list(marker_re.finditer(text))
    marker_like = re.findall(r"<!-- develop:(?:begin|end):[^>]* -->", text)
    if len(marker_like) != len(markers):
        raise ValueError("详设文档包含格式错误的生成块标记")
    seen: dict[str, dict[str, re.Match[str]]] = {key: {} for key in required}
    stack: str | None = None
    ranges: dict[str, tuple[int, int]] = {}
    for match in markers:
        kind, key = match.group(1), match.group(2)
        if key not in seen:
            raise ValueError(f"详设文档包含未注册生成块：{key}")
        if kind == "begin":
            if stack is not None:
                raise ValueError(f"详设文档生成块嵌套：{stack} → {key}")
            if "begin" in seen[key]:
                raise ValueError(f"详设文档生成块重复：{key}")
            seen[key]["begin"] = match
            stack = key
        else:
            if stack != key or "begin" not in seen[key] or "end" in seen[key]:
                raise ValueError(f"详设文档生成块未配对或顺序错误：{key}")
            seen[key]["end"] = match
            ranges[key] = (seen[key]["begin"].end(), match.start())
            stack = None
    if stack is not None:
        raise ValueError(f"详设文档生成块未闭合：{stack}")
    for key, pair in seen.items():
        if set(pair) != {"begin", "end"}:
            raise ValueError(f"详设文档缺少生成块或结束标记：{key}")

    rendered = text
    for key in reversed(required):
        start, end = ranges[key]
        body = bodies[key].strip("\n")
        rendered = rendered[:start] + "\n" + body + "\n" + rendered[end:]
    return rendered


def render_design_body(
    data: dict[str, Any], reference_context: dict[str, Any] | None = None, summary: bool = False
) -> dict[str, str]:
    """把 JSON 正本中的完整对象清单渲染成稳定的 Markdown 表格和小节。"""
    scope = data["scope"]
    counts = [
        ["冻结验收点", len(data["coverage"])], ["表/字段", f"{len(data['tables'])}/{sum(len(t['fields']) for t in data['tables'])}"],
        ["接口/请求响应字段", f"{len(data['apis'])}/{sum(len(a['request_fields']) + len(a['response_fields']) for a in data['apis'])}"],
        ["规则/流程", f"{len(data['rules'])}/{len(data['flows'])}"], ["页面/交互", f"{len(data['pages'])}/{sum(len(p['controls']) + len(p['actions']) + len(p['dialogs']) for p in data['pages'])}"],
        ["术语/权限矩阵", f"{len(data['glossary'])}/{len(data['permissions'])}"],
        ["图示/依赖/复用决策", f"{len(data['diagrams'])}/{len(data['dependencies'])}/{len(data['reuse_decisions'])}"],
        ["领域扩展对象", len(data.get("domain_objects", []))],
    ]
    features = md_table(["功能 ID", "功能域", "职责", "需求 ID", "PRD 来源单元"], [[design_object_anchor_markup("features", f["id"]) + f["id"], f["name"], f["responsibility"], f["requirement_refs"], f["source_refs"]] for f in scope["features"]])
    constraints = md_table(["约束 ID", "内容", "来源"], [[x["id"], x["description"], x["source"]] for x in scope["constraints"]])
    assumptions = md_table(["假设 ID", "内容", "来源"], [[x["id"], x["description"], x["source"]] for x in scope["assumptions"]])
    non_goals = md_table(["范围外 ID", "内容", "来源"], [[x["id"], x["description"], x["source"]] for x in scope["non_goals"]])
    scope_body = "\n\n".join([
        data["project"], scope["summary"], "### 规模统计\n\n" + md_table(["对象", "数量"], counts),
        "### 功能域\n\n" + features, "### 技术与业务约束\n\n" + constraints,
        "### 假设\n\n" + assumptions, "### Non-Goals\n\n" + non_goals,
    ])

    glossary_body = md_table(
        ["术语 ID", "术语", "定义", "需求 ID", "PRD 来源", "验收点"],
        [[design_object_anchor_markup("glossary", item["id"]) + item["id"], item["term"], item["definition"], item["requirement_refs"], item["source_refs"], item["acceptance_refs"]] for item in data["glossary"]],
    ) if data["glossary"] else "无需独立定义的术语；原因：" + data["zero_results"]["glossary"]

    table_index = md_table(
        ["表 ID", "表名", "用途", "字段数", "详情文档", "需求 ID", "PRD 来源单元"] if summary else ["表 ID", "表名", "用途", "字段数", "需求 ID", "PRD 来源单元"],
        [[(design_object_anchor_markup("tables", t["id"]) if summary else "") + markdown_reference("tables", t["id"], reference_context), t["name"], t["purpose"], len(t["fields"]), *([markdown_owner_reference("tables", t["id"], reference_context)] if summary else []), t["requirement_refs"], t["source_refs"]] for t in data["tables"]],
    )
    table_parts = ["### 数据表索引\n\n" + table_index]
    for table in data["tables"] if not summary else []:
        fields = md_table(
            ["字段", "类型", "可空/必填", "默认值", "约束", "含义/来源", "决策理由", "需求 ID", "PRD 来源单元"],
            [[design_object_anchor_markup("table_fields", f"{table['id']}.{f['name']}") + f["name"], f["type"], f["nullable"], f["default"], f["constraints"], f["description"] + "；" + f["source"], f["decision_reason"], f["requirement_refs"], f["source_refs"]] for f in table["fields"]],
        )
        table_parts.append(
            f"{design_object_anchor_markup('tables', table['id'])}\n### {table['id']} · {table['name']}\n\n{table['purpose']}\n\n"
            f"主键：{table['primary_key']}\n\n关系：{md_cell(table['relations'])}\n\n"
            f"唯一约束：{md_cell(table['unique_constraints'])}；索引：{md_cell(table['indexes'])}\n\n"
            f"生命周期：{table.get('lifecycle', '') or '—'}\n\n需求：{md_cell(table['requirement_refs'])}；PRD 来源：{md_cell(table['source_refs'])}；验收点：{md_cell(table['acceptance_refs'])}\n\n{fields}"
        )
    if not data["tables"]:
        table_parts.append("无数据表变更；原因：" + data["zero_results"]["tables"])
    tables_body = "\n\n".join(table_parts)

    api_index = md_table(
        ["接口 ID", "方法", "路径", "名称", "权限", "请求/响应字段数", "详情文档", "需求 ID", "PRD 来源单元"] if summary else ["接口 ID", "方法", "路径", "名称", "权限", "请求/响应字段数", "需求 ID", "PRD 来源单元"],
        [[(design_object_anchor_markup("apis", a["id"]) if summary else "") + markdown_reference("apis", a["id"], reference_context), a["method"], a["path"], a["name"], a["permission"], f"{len(a['request_fields'])}/{len(a['response_fields'])}", *([markdown_owner_reference("apis", a["id"], reference_context)] if summary else []), a["requirement_refs"], a["source_refs"]] for a in data["apis"]],
    )
    api_parts = ["### 接口索引\n\n" + api_index]
    for api in data["apis"] if not summary else []:
        req = md_table(["字段", "类型/格式", "必填", "校验", "来源", "敏感信息", "需求 ID", "PRD 来源单元"], [[f["name"], f["type"], f["required"], f["validation"], f["source"] + "；数据：" + markdown_table_field_references(f["data_refs"], reference_context), f["sensitivity"], f["requirement_refs"], f["source_refs"]] for f in api["request_fields"]])
        resp = md_table(["字段", "类型/格式", "出现条件", "取值规则", "来源", "敏感信息", "需求 ID", "PRD 来源单元"], [[f["name"], f["type"], f["presence"], f["value_rule"], f["source"] + "；数据：" + markdown_table_field_references(f["data_refs"], reference_context), f["sensitivity"], f["requirement_refs"], f["source_refs"]] for f in api["response_fields"]])
        errors_md = md_table(["错误码", "HTTP", "触发条件", "返回语义"], [[e["code"], e["http_status"], e["condition"], e["message"]] for e in api["errors"]])
        api_parts.append(
            f"{design_object_anchor_markup('apis', api['id'])}\n### {api['id']} · {api['name']}\n\n{api['method']} `{api['path']}`；权限：{api['permission']}。{api['purpose']}\n\n"
            f"事务：{api['transaction']}；幂等：{api['idempotency']}；超时：{api['timeout']}。\n\n"
            f"数据表：{markdown_references('tables', api['table_refs'], reference_context)}；业务规则：{markdown_references('rules', api['rule_refs'], reference_context)}；需求：{md_cell(api['requirement_refs'])}；PRD 来源：{md_cell(api['source_refs'])}；验收点：{md_cell(api['acceptance_refs'])}\n\n"
            f"请求字段\n\n{req if api['request_fields'] else api['no_request_reason']}\n\n"
            f"响应字段\n\n{resp if api['response_fields'] else api['no_response_reason']}\n\n"
            f"错误处理：{api['error_summary']}\n\n具体错误\n\n{errors_md}"
        )
    apis_body = "\n\n".join(api_parts) if api_parts else "无接口；原因：" + data["zero_results"]["apis"]

    permissions_body = md_table(
        ["权限 ID", "主体/资源", "操作", "权限码", "数据范围", "API", "页面", "规则", "需求", "来源", "验收点"],
        [[
            design_object_anchor_markup("permissions", item["id"]) + item["id"], item["subject"], item["operation"],
            item["permission_code"], item["data_scope"], markdown_references("apis", item["api_refs"], reference_context),
            markdown_references("pages", item["page_refs"], reference_context), markdown_references("rules", item["rule_refs"], reference_context),
            item["requirement_refs"], item["source_refs"], item["acceptance_refs"],
        ] for item in data["permissions"]],
    ) if data["permissions"] else "无独立权限矩阵；原因：" + data["zero_results"]["permissions"]

    rule_headers = ["规则 ID", "规则", "条件", "结果", "错误语义", "需求 ID", "PRD 来源单元", "验收点", "表/API"]
    if summary:
        rule_headers.insert(5, "详情文档")
    rule_rows = [[
        design_object_anchor_markup("rules", rule["id"]) + rule["id"], rule["name"], rule["condition"], rule["result"],
        rule["error_semantics"], *([markdown_owner_reference("rules", rule["id"], reference_context)] if summary else []),
        rule["requirement_refs"], rule["source_refs"], rule["acceptance_refs"],
        markdown_references("tables", rule["table_refs"], reference_context) + " / " + markdown_references("apis", rule["api_refs"], reference_context),
    ] for rule in data["rules"]]
    rule_parts = ["### 业务规则\n\n" + md_table(rule_headers, rule_rows)]
    if not data["rules"]:
        rule_parts.append("无业务规则；原因：" + data["zero_results"]["rules"])
    if summary and data["flows"]:
        rule_parts.append("### 关键流程概览\n\n" + md_table(
            ["流程 ID", "流程", "触发者", "触发条件", "状态变化", "成功/失败处置", "详情文档", "图示", "API", "规则", "测试锚点/场景数", "验收点"],
            [[
                design_object_anchor_markup("flows", flow["id"]) + markdown_reference("flows", flow["id"], reference_context),
                flow["name"], flow["actor"], flow["trigger"], flow["state_transition"],
                flow["success"] + " / " + flow["failure_recovery"], markdown_owner_reference("flows", flow["id"], reference_context), markdown_references("diagrams", flow.get("diagram_refs", []), reference_context), markdown_references("apis", flow["api_refs"], reference_context),
                markdown_references("rules", flow["rule_refs"], reference_context),
                f"{flow.get('test_anchor', '—')} / {len(flow.get('test_scenarios', []))}", flow["acceptance_refs"],
            ] for flow in data["flows"]],
        ))
    for flow in data["flows"] if not summary else []:
        steps = md_table(["步骤", "结果"], [[step["action"], step["result"]] for step in flow["steps"]])
        test_scenarios = render_flow_test_scenarios(flow)
        test_section = f"\n\n{test_scenarios}" if test_scenarios else ""
        rule_parts.append(
            f"{design_object_anchor_markup('flows', flow['id'])}\n### {flow['id']} · {flow['name']}\n\n触发者：{flow['actor']}；触发：{flow['trigger']}\n\n"
            f"前置条件：{md_cell(flow['preconditions'])}\n\n步骤\n\n{steps}\n\n"
            f"状态变化：{flow['state_transition']}\n\n事务/并发：{flow['transaction_concurrency']}\n\n"
            f"成功结果：{flow['success']}\n\n失败/恢复：{flow['failure_recovery']}{test_section}\n\n"
            f"引用表：{markdown_references('tables', flow['table_refs'], reference_context)}；图示：{markdown_references('diagrams', flow.get('diagram_refs', []), reference_context)}；API：{markdown_references('apis', flow['api_refs'], reference_context)}；规则：{markdown_references('rules', flow['rule_refs'], reference_context)}；需求：{md_cell(flow['requirement_refs'])}；PRD 来源：{md_cell(flow['source_refs'])}；验收点：{md_cell(flow['acceptance_refs'])}"
        )
    if not data["flows"]:
        rule_parts.append("无关键流程；原因：" + data["zero_results"]["flows"])
    rules_flows_body = "\n\n".join(rule_parts)

    diagram_parts = []
    for item in data["diagrams"]:
        refs = "、".join(markdown_typed_reference(ref["kind"], ref["id"], reference_context) for ref in item["typed_refs"]) or "—"
        body = f"```{item['format']}\n{item['body']}\n```" if item["format"] else item["body"]
        diagram_parts.append(
            f"{design_object_anchor_markup('diagrams', item['id'])}\n### {item['id']} · {item['title']}\n\n类型：{item['kind']}；需求：{md_cell(item['requirement_refs'])}；PRD 来源：{md_cell(item['source_refs'])}；验收点：{md_cell(item['acceptance_refs'])}\n\n引用对象：{refs}\n\n{body}"
        )
    diagrams_body = "\n\n".join(diagram_parts) if diagram_parts else "无额外图示；原因：" + data["zero_results"]["diagrams"]

    page_headers = ["页面 ID", "页面", "路由", "组件", "权限", "需求 ID", "PRD 来源单元", "验收点"]
    if summary:
        page_headers.insert(5, "详情文档")
    page_rows = [[
        (design_object_anchor_markup("pages", page["id"]) if summary else "") + markdown_reference("pages", page["id"], reference_context),
        page["name"], page["route"], page["component"], page["permission"],
        *([markdown_owner_reference("pages", page["id"], reference_context)] if summary else []),
        page["requirement_refs"], page["source_refs"], page["acceptance_refs"],
    ] for page in data["pages"]]
    page_parts = ["### 页面索引\n\n" + md_table(page_headers, page_rows)]
    for page in data["pages"] if not summary else []:
        controls = md_table(["控件", "类型", "校验", "来源", "数据引用", "测试锚点"], [[c["name"], c["control"], c["validation"], c["source"], markdown_table_field_references(c["data_refs"], reference_context), c["test_anchor"]] for c in page["controls"]])
        actions = md_table(["操作", "权限", "API", "规则", "反馈", "测试锚点"], [[a["name"], a["permission"], markdown_references("apis", a["api_refs"], reference_context), markdown_references("rules", a["rule_refs"], reference_context), a["feedback"], a["test_anchor"]] for a in page["actions"]])
        dialogs = md_table(["弹窗/抽屉", "组件", "权限", "API", "状态", "测试锚点"], [[d["name"], d["component"], d["permission"], markdown_references("apis", d["api_refs"], reference_context), d["state"], d["test_anchor"]] for d in page["dialogs"]])
        page_parts.append(
            f"{design_object_anchor_markup('pages', page['id'])}\n### {page['id']} · {page['name']}\n\n路由：`{page['route']}`；组件：`{page['component']}`；类型：{page['page_type']}；权限：{page['permission']}。\n\n"
            f"状态：{md_cell(page['states'])}\n\n需求：{md_cell(page['requirement_refs'])}；PRD 来源：{md_cell(page['source_refs'])}；验收点：{md_cell(page['acceptance_refs'])}\n\n控件\n\n{controls}\n\n操作\n\n{actions}\n\n弹窗/抽屉\n\n{dialogs}"
        )
    if not data["pages"]:
        page_parts.append("无前端页面；原因：" + data["zero_results"]["pages"])
    pages_body = "\n\n".join(page_parts)

    dependency_parts = [md_table(
        ["依赖 ID", "依赖项", "方向", "用途", "契约/版本", "责任方", "失败处理", "关联对象", "需求", "来源", "验收点"],
        [[
            design_object_anchor_markup("dependencies", item["id"]) + item["id"], item["name"], item["direction"], item["purpose"],
            item["contract"], item["owner"], item["failure_handling"],
            "、".join(markdown_typed_reference(ref["kind"], ref["id"], reference_context) for ref in item["typed_refs"]) or "—",
            item["requirement_refs"], item["source_refs"], item["acceptance_refs"],
        ] for item in data["dependencies"]],
    )] if data["dependencies"] else ["无额外内外部依赖；原因：" + data["zero_results"]["dependencies"]]
    dependencies_body = "\n\n".join(dependency_parts)

    reuse_parts = [md_table(
        ["复用决策 ID", "组件/服务", "使用方式", "决定", "理由", "替代方案", "关联对象", "需求", "来源", "验收点"],
        [[
            design_object_anchor_markup("reuse_decisions", item["id"]) + item["id"], item["component"], item["use"],
            item["decision"], item["rationale"], item["alternatives"],
            "、".join(markdown_typed_reference(ref["kind"], ref["id"], reference_context) for ref in item["typed_refs"]) or "—",
            item["requirement_refs"], item["source_refs"], item["acceptance_refs"],
        ] for item in data["reuse_decisions"]],
    )] if data["reuse_decisions"] else ["无需记录复用选择；原因：" + data["zero_results"]["reuse_decisions"]]
    quality = md_table(["决策 ID", "维度", "适用", "决定", "理由", "需求 ID", "PRD 来源", "验收点"], [[design_object_anchor_markup("quality_decisions", q["id"]) + q["id"], q["dimension"], "是" if q["applies"] else "否", q["decision"], q["rationale"], q["requirement_refs"], q["source_refs"], q["acceptance_refs"]] for q in data["quality_decisions"]])
    reuse_quality_body = "\n\n".join([
        "### 复用与公共能力\n\n" + "\n\n".join(reuse_parts),
        "### 安全、性能、兼容与异常决策\n\n" + (quality if data["quality_decisions"] else "无质量/边界决策；原因：" + data["zero_results"]["quality_decisions"]),
    ])

    domain_object_parts = ["### 领域对象索引\n\n" + md_table(
        ["类型", "对象 ID", "名称", "摘要", *(["详情文档"] if summary else []), "需求 ID", "引用对象"],
        [[
            item["kind"], (design_object_anchor_markup("domain_objects", domain_object_key(item["kind"], item["id"])) if summary else "") + markdown_reference("domain_objects", domain_object_key(item["kind"], item["id"]), reference_context),
            item["name"], item["summary"], *([markdown_owner_reference("domain_objects", domain_object_key(item["kind"], item["id"]), reference_context)] if summary else []), item["requirement_refs"],
            "、".join(markdown_typed_reference(ref["kind"], ref["id"], reference_context) for ref in item["typed_refs"]) or "—",
        ] for item in data.get("domain_objects", [])],
    )]
    for item in data.get("domain_objects", []) if not summary else []:
        domain_key = domain_object_key(item["kind"], item["id"])
        attributes = md_table(
            ["属性", "值"],
            [[key, value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)]
             for key, value in sorted(item["attributes"].items())],
        )
        domain_object_parts.append(
            f"{design_object_anchor_markup('domain_objects', domain_key)}\n"
            f"#### {item['kind']} · {item['id']} · {item['name']}\n\n{item['summary']}\n\n"
            f"需求：{md_cell(item['requirement_refs'])}；PRD 来源：{md_cell(item['source_refs'])}；"
            f"验收点：{md_cell(item['acceptance_refs'])}\n\n属性\n\n{attributes}\n\n"
            f"交叉引用：{'、'.join(markdown_typed_reference(ref['kind'], ref['id'], reference_context) for ref in item['typed_refs']) or '—'}"
        )
    domain_objects_body = "\n\n".join(domain_object_parts) if data.get("domain_objects") else (
        "无领域扩展对象；原因：" + data["zero_results"].get("domain_objects", "未声明领域扩展对象。")
    )

    coverage_body = md_table(
        ["验收点 ID", "PRD 需求 ID", "来源单元", "术语", "表/数据", "接口", "权限", "规则", "流程", "图示", "页面", "依赖", "复用", "质量决定", "领域对象", "验证方式", "测试 ID"],
        [[
            c["acceptance_id"], c["requirement_refs"], c["source_refs"],
            markdown_references("glossary", c["glossary_refs"], reference_context),
            markdown_references("tables", c["table_refs"], reference_context), markdown_references("apis", c["api_refs"], reference_context),
            markdown_references("permissions", c["permission_refs"], reference_context), markdown_references("rules", c["rule_refs"], reference_context),
            markdown_references("flows", c["flow_refs"], reference_context), markdown_references("diagrams", c["diagram_refs"], reference_context),
            markdown_references("pages", c["page_refs"], reference_context), markdown_references("dependencies", c["dependency_refs"], reference_context),
            markdown_references("reuse_decisions", c["reuse_refs"], reference_context), markdown_references("quality_decisions", c["quality_refs"], reference_context),
            "、".join(markdown_reference("domain_objects", domain_object_key(ref["kind"], ref["id"]), reference_context) for ref in c.get("domain_refs", [])) or "—",
            c["verification"], c["test_ids"],
        ] for c in data["coverage"]],
    )
    return {
        "SCOPE_BODY": scope_body, "GLOSSARY_BODY": glossary_body, "TABLES_BODY": tables_body, "APIS_BODY": apis_body,
        "PERMISSIONS_BODY": permissions_body, "RULES_FLOWS_BODY": rules_flows_body, "DIAGRAMS_BODY": diagrams_body,
        "PAGES_BODY": pages_body, "DEPENDENCIES_BODY": dependencies_body,
        "REUSE_QUALITY_BODY": reuse_quality_body, "DOMAIN_OBJECTS_BODY": domain_objects_body, "COVERAGE_BODY": coverage_body,
    }


def render_design_markdown(
    data: dict[str, Any], manifest: dict[str, Any], existing_text: str | None = None,
    package_document: dict[str, Any] | None = None,
    reference_context: dict[str, Any] | None = None,
    summary: bool = False,
) -> str:
    structured = manifest["structured_design"]
    template_path = SKILL_ROOT / "模板" / structured["render_template"]
    content = existing_text if existing_text is not None else template_path.read_text(encoding="utf-8")
    if existing_text is not None:
        content = migrate_design_template(content, manifest)
    design_item = next(item for item in manifest["documents"] if item["file"] == structured["document"])
    title = design_item["title"] if package_document is None or package_document["id"] == "total" else f"{design_item['title']} · {package_document['id']}"
    content = content.replace("{{PROJECT_NAME}}", data["project"]).replace("{{TITLE}}", title)
    content = render_anchored_blocks(
        content,
        render_design_body(data, reference_context, summary),
        structured["render_blocks"],
        structured["template_id"],
        structured["template_version"],
    )
    leftovers = TOKEN.findall(content)
    if leftovers:
        raise ValueError(f"详设渲染模板有未处理变量：{leftovers}")
    return number_markdown_headings(content).rstrip() + "\n"


def migrate_design_template(text: str, manifest: dict[str, Any]) -> str:
    """Upgrade known generated design documents to the current additive render contract."""
    structured = manifest["structured_design"]
    template_id = structured["template_id"]
    template_version = structured["template_version"]
    ids = re.findall(r"(?m)^<!-- develop:template-id:([^>]+) -->$", text)
    versions = re.findall(r"(?m)^<!-- develop:template-version:([^>]+) -->$", text)
    if ids != [template_id] or len(versions) != 1 or versions[0] == template_version:
        return text
    if template_version != "1.3.0" or versions[0] not in {"1.1.0", "1.2.0"}:
        return text
    version = versions[0]
    if version == "1.1.0":
        domain_block = "DOMAIN_OBJECTS_BODY"
        begin = f"<!-- develop:begin:{domain_block} -->"
        end = f"<!-- develop:end:{domain_block} -->"
        if text.count(begin) == 0 and text.count(end) == 0:
            legacy_blocks = ("SCOPE_BODY", "TABLES_BODY", "APIS_BODY", "RULES_FLOWS_BODY", "PAGES_BODY", "QUALITY_BODY", "COVERAGE_BODY")
            for block in legacy_blocks:
                if text.count(f"<!-- develop:begin:{block} -->") != 1 or text.count(f"<!-- develop:end:{block} -->") != 1:
                    raise ValueError(f"旧版详设文档无法迁移：生成块不完整 {block}")
            lines = text.splitlines(keepends=True)
            coverage_heading = "需求追溯与验证"
            insertion = next((index for index, line in enumerate(lines) if line.startswith("## ") and normalize_heading(line[3:].strip()) == coverage_heading), None)
            if insertion is None:
                raise ValueError(f"旧版详设文档无法迁移：找不到目标章节 {coverage_heading}")
            section = f"## 领域扩展对象与集成\n\n{begin}\n{{{{{domain_block}}}}}\n{end}\n\n"
            lines.insert(insertion, section)
            text = "".join(lines)
        elif text.count(begin) != 1 or text.count(end) != 1:
            raise ValueError("旧版详设文档无法迁移：领域扩展生成块标记不完整或重复")
        text = text.replace("<!-- develop:template-version:1.1.0 -->", "<!-- develop:template-version:1.2.0 -->", 1)
        version = "1.2.0"

    if version == "1.2.0":
        text = text.replace("QUALITY_BODY", "REUSE_QUALITY_BODY")
        lines = text.splitlines(keepends=True)
        for index, line in enumerate(lines):
            if line.startswith("## ") and normalize_heading(line[3:].strip()) == "质量与边界":
                prefix = line[: len(line) - len(line.lstrip("#"))]
                lines[index] = f"{prefix} 复用与质量决策\n"
        text = "".join(lines)
        insertions = [
            ("GLOSSARY_BODY", "术语与概念", "表与数据设计"),
            ("PERMISSIONS_BODY", "权限矩阵", "关键流程与业务规则"),
            ("DIAGRAMS_BODY", "架构图与时序图", "前端页面与交互"),
            ("DEPENDENCIES_BODY", "依赖与补偿", "复用与质量决策"),
        ]
        for block, title, before_title in insertions:
            begin = f"<!-- develop:begin:{block} -->"
            end = f"<!-- develop:end:{block} -->"
            if text.count(begin) == 1 and text.count(end) == 1:
                continue
            if text.count(begin) or text.count(end):
                raise ValueError(f"旧版详设文档无法迁移：生成块标记不完整 {block}")
            lines = text.splitlines(keepends=True)
            insertion = next((index for index, line in enumerate(lines) if line.startswith("## ") and normalize_heading(line[3:].strip()) == before_title), None)
            if insertion is None:
                raise ValueError(f"旧版详设文档无法迁移：找不到目标章节 {before_title}")
            lines.insert(insertion, f"## {title}\n\n{begin}\n{{{{{block}}}}}\n{end}\n\n")
            text = "".join(lines)

    migrated_from = "1.2.0" if versions[0] == "1.1.0" else versions[0]
    old_marker = f"<!-- develop:template-version:{migrated_from} -->"
    new_marker = f"<!-- develop:template-version:{template_version} -->"
    return text.replace(old_marker, new_marker, 1)


def _package_render_data(data: dict[str, Any], document: dict[str, Any]) -> dict[str, Any]:
    """Keep global context while limiting object sections and coverage to a subdocument."""
    filtered = dict(data)
    refs = document["object_refs"]
    filtered_scope = dict(data["scope"])
    selected_features = set(refs["features"])
    filtered_scope["features"] = [
        item for item in data["scope"]["features"] if item["id"] in selected_features
    ]
    filtered["scope"] = filtered_scope
    for kind in (
        "glossary", "tables", "apis", "permissions", "rules", "flows", "diagrams", "pages",
        "dependencies", "reuse_decisions", "quality_decisions"
    ):
        selected = set(refs[kind])
        filtered[kind] = [item for item in data[kind] if item["id"] in selected]
        if not filtered[kind] and data[kind]:
            filtered.setdefault("zero_results", dict(data["zero_results"]))[kind] = "本分文档不归属此类对象。"
    selected_domain_objects = set(refs["domain_objects"])
    filtered["domain_objects"] = [
        item for item in data["domain_objects"]
        if domain_object_key(item["kind"], item["id"]) in selected_domain_objects
    ]
    if not filtered["domain_objects"] and data["domain_objects"]:
        filtered.setdefault("zero_results", dict(data["zero_results"]))["domain_objects"] = "本分文档不归属此类对象。"
    acceptance_ids = set(document["acceptance_ids"])
    filtered["coverage"] = [row for row in data["coverage"] if row["acceptance_id"] in acceptance_ids]
    return filtered


def _safe_package_output(directory: Path, relative_path: str) -> Path:
    candidate = Path(directory) / relative_path
    root = Path(directory).resolve()
    current = root
    for part in Path(relative_path).parts:
        current = current / part
        if current.is_symlink():
            raise ValueError(f"文档包输出路径不得经过符号链接：{relative_path}")
    output = candidate.resolve()
    try:
        output.relative_to(root)
    except ValueError as exc:
        raise ValueError(f"文档包输出路径逃逸项目目录：{relative_path}") from exc
    if output == root:
        raise ValueError(f"文档包输出路径不能指向目录本身：{relative_path}")
    return output


def load_valid_design_package(
    directory: Path, manifest: dict[str, Any], data: dict[str, Any], acceptance_ids: set[str]
) -> tuple[dict[str, Any] | None, list[str]]:
    config = design_output_config(manifest)
    if not isinstance(config, dict):
        return None, []
    path = Path(directory) / config["file"]
    legacy_name = config.get("legacy_file")
    legacy_path = Path(directory) / legacy_name if legacy_name else None
    if path.exists() and legacy_path is not None and legacy_path.exists():
        return None, [f"同时存在新旧详设输出配置：{path.name} 与 {legacy_path.name}"]
    if not path.exists() and legacy_path is not None and legacy_path.exists():
        path = legacy_path
    if not path.exists() and not path.is_symlink():
        return None, []
    if not path.is_file():
        return None, [f"详设文档包路径存在但不是普通文件：{path.name}"]
    try:
        package = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return None, [f"详设文档包不可读取：{exc}"]
    package = normalize_design_package(
        package, data, acceptance_ids, config.get("template_registry"), manifest["structured_design"]["document"]
    )
    errors = validate_design_package(
        package,
        data,
        acceptance_ids,
        config.get("template_registry", {}),
    )
    if errors:
        return None, errors
    ownership_kinds = {
        "glossary_refs": "glossary", "table_refs": "tables", "api_refs": "apis",
        "permission_refs": "permissions", "rule_refs": "rules", "flow_refs": "flows",
        "diagram_refs": "diagrams", "page_refs": "pages", "dependency_refs": "dependencies",
        "reuse_refs": "reuse_decisions", "quality_refs": "quality_decisions", "domain_refs": "domain_objects",
    }
    coverage_rows = {row["acceptance_id"]: row for row in data["coverage"]}
    for document in package["subdocuments"]:
        doc_refs = document["object_refs"]
        for acceptance_id in document["acceptance_ids"]:
            row = coverage_rows.get(acceptance_id)
            if row is None:
                continue
            for coverage_key, object_kind in ownership_kinds.items():
                if coverage_key == "domain_refs":
                    covered_refs = {domain_object_key(ref["kind"], ref["id"]) for ref in row.get(coverage_key, [])}
                else:
                    covered_refs = set(row[coverage_key])
                dangling = covered_refs - set(doc_refs[object_kind])
                if dangling:
                    errors.append(
                        f"子文档 {document['id']} 验收点 {acceptance_id} 的 {coverage_key} 未在本子文档归属：{sorted(dangling)}"
                    )
        for object_kind in (
            "glossary", "tables", "apis", "permissions", "rules", "flows", "diagrams", "pages",
            "dependencies", "reuse_decisions", "quality_decisions", "domain_objects"
        ):
            for item in data[object_kind]:
                object_id = domain_object_key(item["kind"], item["id"]) if object_kind == "domain_objects" else item["id"]
                if object_id not in set(doc_refs[object_kind]):
                    continue
                dangling_acceptance = set(item.get("acceptance_refs", [])) - set(document["acceptance_ids"])
                if dangling_acceptance:
                    errors.append(
                        f"子文档 {document['id']} 对象 {object_kind}/{object_id} 引用未列入本子文档的验收点："
                        f"{sorted(dangling_acceptance)}"
                    )
    if errors:
        return None, errors
    structured = manifest["structured_design"]
    canonical = lambda value: unicodedata.normalize("NFC", value).casefold()
    registered = {canonical(str(item["file"])) for item in manifest["documents"]}
    pipeline = manifest["prd_pipeline"]
    reserved_inputs = {
        structured["file"], structured["receipt_file"], config["file"],
        pipeline["prd_file"], pipeline["inventory_file"], pipeline["ledger_file"],
        pipeline["acceptance_file"],
    }
    canonical_reserved = {canonical(path) for path in reserved_inputs}
    for item in [package["total"], *package["subdocuments"]]:
        if item["template_id"] != structured["template_id"] or item["template_version"] != structured["template_version"]:
            errors.append(
                f"文档 {item['id']} 模板必须使用当前渲染器登记的 template_id/version："
                f"{structured['template_id']}@{structured['template_version']}"
            )
        relative = item["path"]
        if Path(relative).suffix.lower() != ".md":
            errors.append(f"文档 {item['id']} 输出路径必须以 .md 结尾：{relative}")
        if canonical(relative) in registered and relative != structured["document"]:
            errors.append(f"详设输出路径与固定文档冲突：{relative}")
        if canonical(relative) in canonical_reserved:
            errors.append(f"详设输出路径与输入/收据文件冲突：{relative}")
        try:
            output = _safe_package_output(directory, relative)
        except ValueError as exc:
            errors.append(str(exc))
            continue
        parent = output.parent
        if parent.exists() and not parent.is_dir():
            errors.append(f"详设子文档父路径不是目录：{relative}")
    return (package if not errors else None), errors


def _sha256_file(path: Path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build_generation_receipt(
    directory: Path, manifest: dict[str, Any], output_texts: dict[str, str]
) -> dict[str, Any]:
    """Bind a generated design document to exact PRD, ledger, contract, and template bytes."""
    pipeline = manifest["prd_pipeline"]
    structured = manifest["structured_design"]
    input_paths = {
        "prd_sha256": Path(directory) / pipeline["prd_file"],
        "inventory_sha256": Path(directory) / pipeline["inventory_file"],
        "requirements_sha256": Path(directory) / pipeline["ledger_file"],
        "acceptance_sha256": Path(directory) / pipeline["acceptance_file"],
        "design_sha256": Path(directory) / structured["file"],
    }
    source_registry_path = Path(directory) / pipeline["sources_file"]
    if source_registry_path.is_file():
        input_paths["supplemental_sources_config_sha256"] = source_registry_path
    package_config = design_output_config(manifest)
    output_config_path = None
    if isinstance(package_config, dict):
        candidate = Path(directory) / package_config["file"]
        legacy_name = package_config.get("legacy_file")
        legacy = Path(directory) / legacy_name if legacy_name else None
        output_config_path = candidate if candidate.is_file() else legacy if legacy is not None and legacy.is_file() else None
    if output_config_path is not None:
        input_paths["design_output_sha256"] = output_config_path
    structured_data = json.loads((Path(directory) / structured["file"]).read_text(encoding="utf-8"))
    inventory = json.loads((Path(directory) / pipeline["inventory_file"]).read_text(encoding="utf-8"))
    binding = source_set_binding(structured_data.get("baseline", {}), inventory)
    output_hashes = {
        relative: hashlib.sha256(text.encode("utf-8")).hexdigest()
        for relative, text in sorted(output_texts.items())
    }
    design_output_path = (
        json.loads(output_config_path.read_text(encoding="utf-8")).get("total", {}).get("path", structured["document"])
        if output_config_path is not None else structured["document"]
    )
    return {
        "receipt_version": 3,
        "status": "PASS",
        "command": "render-design",
        "tool_version": TOOL_VERSION,
        "schema_version": json.loads((Path(directory) / structured["file"]).read_text(encoding="utf-8"))["schema_version"],
        "template_id": structured["template_id"],
        "template_version": structured["template_version"],
        "source_set_binding": binding,
        "design_mode": (
            json.loads(output_config_path.read_text(encoding="utf-8")).get("mode", "total_subdocuments")
            if output_config_path is not None else "single"
        ),
        "inputs": {**manifest["_receipt_hashes"], **{key: _sha256_file(path) for key, path in input_paths.items()}},
        "output_sha256": output_hashes.get(design_output_path),
        "outputs": output_hashes,
    }


def validate_generation_receipt(
    directory: Path, manifest: dict[str, Any], output_texts: dict[str, str]
) -> list[str]:
    try:
        receipt_path = _safe_package_output(directory, manifest["structured_design"]["receipt_file"])
    except ValueError as exc:
        return [str(exc)]
    if not receipt_path.is_file():
        return [f"缺少详设生成收据：{receipt_path.name}；先运行 render-design"]
    try:
        actual = json.loads(receipt_path.read_text(encoding="utf-8"))
        expected = build_generation_receipt(directory, manifest, output_texts)
    except (OSError, json.JSONDecodeError, KeyError) as exc:
        return [f"详设生成收据不可读取或输入不完整：{exc}"]
    if actual != expected:
        structured = manifest["structured_design"]
        baseline = json.loads((Path(directory) / structured["file"]).read_text(encoding="utf-8")).get("baseline", {})
        legacy = "source_set_sha256" not in baseline and "source_unit_count" not in baseline
        if legacy and actual.get("receipt_version") == 2 and "source_set_binding" not in actual:
            compatible = dict(expected)
            compatible["receipt_version"] = 2
            compatible.pop("source_set_binding", None)
            if actual == compatible:
                return []
        return ["详设生成收据与当前 PRD/台账/验收/来源集/JSON/模板/输出指纹不一致；重新运行 render-design"]
    return []


def render_design(directory: Path, manifest: dict[str, Any]) -> list[str]:
    prd_state = check_prd(directory, manifest)
    prd_errors, _, _ = prd_state
    if prd_errors:
        raise ValueError("PRD→验收基线校验失败：\n- " + "\n- ".join(prd_errors))
    structured = manifest["structured_design"]
    data, errors = validate_design_data(directory, structured, manifest, prd_state)
    if errors or data is None:
        raise ValueError("详设 JSON 未通过完整性校验：\n- " + "\n- ".join(errors))
    acceptance = prd_state[2]
    acceptance_ids = {row["验收点 ID"] for row in acceptance["acceptance_rows"]}
    package, package_errors = load_valid_design_package(directory, manifest, data, acceptance_ids)
    if package_errors:
        raise ValueError("详设文档包校验失败：\n- " + "\n- ".join(package_errors))
    receipt_path = _safe_package_output(directory, structured["receipt_file"])

    documents = (
        [package["total"], *package["subdocuments"]]
        if package and package["mode"] == "total_subdocuments"
        else [package["total"]]
        if package
        else [{
        "id": "design", "path": structured["document"], "object_refs": {}, "acceptance_ids": list(acceptance_ids)
        }]
    )
    output_texts: dict[str, str] = {}
    for item in documents:
        relative = item["path"]
        output = _safe_package_output(directory, relative)
        existing_text = output.read_text(encoding="utf-8") if output.is_file() else None
        render_data = _package_render_data(data, item) if package and package["mode"] == "total_subdocuments" and item is not package["total"] else data
        reference_context = build_reference_context(data, package, relative)
        summary_document = bool(package and package["mode"] == "total_subdocuments" and item is package["total"])
        output_texts[relative] = render_design_markdown(
            render_data, manifest, existing_text, item if package else None, reference_context, summary_document
        )
    for relative, rendered in output_texts.items():
        output = _safe_package_output(directory, relative)
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(rendered, encoding="utf-8")

    receipt = build_generation_receipt(directory, manifest, output_texts)
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return [*(str(_safe_package_output(directory, relative)) for relative in output_texts), str(receipt_path)]


def check_design(directory: Path, manifest: dict[str, Any]) -> list[str]:
    errors = check_documents(directory, manifest)
    prd_state = check_prd(directory, manifest)
    prd_errors, _, _ = prd_state
    errors.extend(prd_errors)
    if prd_errors:
        return errors
    data, design_errors = validate_design_data(directory, manifest["structured_design"], manifest, prd_state)
    errors.extend(design_errors)
    if data is None or design_errors:
        return errors
    acceptance = prd_state[2]
    acceptance_ids = {row["验收点 ID"] for row in acceptance["acceptance_rows"]}
    package, package_errors = load_valid_design_package(directory, manifest, data, acceptance_ids)
    errors.extend(package_errors)
    if package_errors:
        return errors
    documents = (
        [package["total"], *package["subdocuments"]]
        if package and package["mode"] == "total_subdocuments"
        else [package["total"]]
        if package
        else [{
        "id": "design", "path": manifest["structured_design"]["document"], "object_refs": {},
        "acceptance_ids": list(acceptance_ids),
        }]
    )
    output_texts: dict[str, str] = {}
    for item in documents:
        relative = item["path"]
        path = _safe_package_output(directory, relative)
        if not path.is_file():
            errors.append(f"缺少详设文档：{relative}")
            continue
        current = path.read_text(encoding="utf-8")
        try:
            render_data = _package_render_data(data, item) if package and package["mode"] == "total_subdocuments" and item is not package["total"] else data
            reference_context = build_reference_context(data, package, relative)
            summary_document = bool(package and package["mode"] == "total_subdocuments" and item is package["total"])
            expected = render_design_markdown(
                render_data, manifest, current, item if package else None, reference_context, summary_document
            )
        except ValueError as exc:
            errors.append(f"{relative} 渲染块契约错误：{exc}")
            continue
        output_texts[relative] = current
        if current != expected:
            errors.append(f"{relative} 与 JSON 正本渲染结果不一致；请运行 render-design")
    if not errors:
        errors.extend(validate_generation_receipt(directory, manifest, output_texts))
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description="生成文档并校验详设 JSON 正本与 Markdown 的完整对应关系")
    commands = parser.add_subparsers(dest="command", required=True)
    init_parser = commands.add_parser("init", help="生成标准文档和待填写的详设 JSON")
    init_parser.add_argument("directory", type=Path)
    init_parser.add_argument("--name", required=True, help="项目或功能名称")
    init_parser.add_argument(
        "--design-mode", choices=("single", "total_subdocuments"), default="single",
        help="详设输出模式：single 单份；total_subdocuments 总文档加分文档",
    )
    init_parser.add_argument("--design-output", help="总详设 Markdown 的项目内相对路径")
    init_parser.add_argument("--design-mode-reason", help="冻结单份/总分结构选择的依据")
    import_ac_parser = commands.add_parser("import-acceptance", help="将旧版分组验收清单转换为 develop 格式（导入后仍须复核冻结）")
    import_ac_parser.add_argument("directory", type=Path)
    import_ac_parser.add_argument("--source", required=True, type=Path, help="旧版验收清单路径")
    import_ac_parser.add_argument("--requirements-map", type=Path, help="可选 JSON：旧分组 ID 到 PRD 需求 ID 数组的映射")
    scan_parser = commands.add_parser("scan-prd", help="扫描 PRD 并确定性生成来源单元清单")
    scan_parser.add_argument("directory", type=Path)
    prd_check_parser = commands.add_parser("check-prd", help="核对 PRD 来源、需求台账、复核和冻结验收基线")
    prd_check_parser.add_argument("directory", type=Path)
    render_parser = commands.add_parser("render-design", help="校验详设 JSON 并确定性生成详设 Markdown")
    render_parser.add_argument("directory", type=Path)
    check_parser = commands.add_parser("check", help="检查文档集合、固定章节和 JSON 语法")
    check_parser.add_argument("directory", type=Path)
    design_parser = commands.add_parser("check-design", help="检查详设完整填写、引用闭环和 JSON/Markdown 一致性")
    design_parser.add_argument("directory", type=Path)
    args = parser.parse_args()

    try:
        manifest = load_manifest()
        if args.command == "scan-prd":
            output = scan_prd_directory(args.directory, manifest)
            inventory = json.loads(output.read_text(encoding="utf-8"))
            print(f"PRD 来源清单已生成：{output}（{len(inventory['units'])} 个来源单元，SHA256={inventory['prd_sha256']}）")
            return 0
        if args.command == "check-prd":
            errors, ledger, acceptance = check_prd(args.directory, manifest)
            if errors:
                print("PRD→验收基线校验失败：", file=sys.stderr)
                for error in errors:
                    print(f"- {error}", file=sys.stderr)
                return 1
            inventory = json.loads(
                (args.directory / manifest["prd_pipeline"]["inventory_file"]).read_text(encoding="utf-8")
            )
            requirement_ids = ",".join(item["id"] for item in ledger["requirements"])
            acceptance_ids = ",".join(row["验收点 ID"] for row in acceptance["acceptance_rows"])
            review = ledger["independent_review"]
            print(
                "PRD→验收基线检查通过："
                f"PRD SHA256={inventory['prd_sha256']}，来源单元 {len(inventory['units'])} 项，"
                f"需求 {len(ledger['requirements'])} 项，"
                f"需求 ID=[{requirement_ids}]，"
                f"验收点 {len(acceptance['acceptance_rows'])} 项 ID=[{acceptance_ids}]，"
                f"验收版本 {acceptance['version']}，复核者={review['reviewer_id']}，"
                f"已审附件 {len(ledger['asset_reviews'])} 项，未裁决差异 0 项"
            )
            return 0
        if args.command == "init":
            paths = render_skeleton(
                args.directory, manifest, args.name, args.design_mode, args.design_output, args.design_mode_reason
            )
            for path in paths:
                print(f"已生成：{path}")
            return 0
        if args.command == "import-acceptance":
            requirement_map = {}
            if args.requirements_map:
                requirement_map = json.loads(args.requirements_map.read_text(encoding="utf-8"))
                if not isinstance(requirement_map, dict):
                    raise ValueError("--requirements-map 根节点必须是 JSON 对象")
            acceptance_path = args.directory / manifest["prd_pipeline"]["acceptance_file"]
            result = import_legacy_acceptance(args.source, acceptance_path, None, requirement_map)
            rendered = number_markdown_headings(acceptance_path.read_text(encoding="utf-8"))
            acceptance_path.write_text(rendered, encoding="utf-8")
            print(
                f"旧版验收清单已转换为待复核草稿：{acceptance_path}；"
                f"{result['count']} 个验收点、{result['groups']} 个分组、版本 {result['version']}。"
                "独立复核并冻结前，check-prd/render-design 会拒绝放行。"
            )
            return 0
        if args.command == "render-design":
            for path in render_design(args.directory, manifest):
                print(f"已渲染：{path}")
            return 0
        if args.command == "check-design":
            errors = check_design(args.directory, manifest)
        else:
            errors = check_documents(args.directory, manifest)
    except (FileExistsError, OSError, json.JSONDecodeError, ValueError, KeyError) as exc:
        print(f"错误：{exc}", file=sys.stderr)
        return 2

    if errors:
        print("文档完整性检查失败：", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    if args.command == "check-design":
        design = json.loads((args.directory / manifest["structured_design"]["file"]).read_text(encoding="utf-8"))
        baseline = design.get("baseline", {})
        if "source_set_sha256" not in baseline and "source_unit_count" not in baseline:
            print("检查通过（legacy source-set 未绑定；此结果不表示来源集已验证）")
            return 0
    print("检查通过")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
