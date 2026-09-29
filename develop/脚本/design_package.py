"""Validation for optional total and module-level design documents."""

from __future__ import annotations

import copy
import json
import ntpath
import unicodedata
from pathlib import PurePosixPath
from typing import Any
from urllib.parse import quote


OBJECT_KINDS = (
    "features", "glossary", "tables", "apis", "permissions", "rules", "flows",
    "diagrams", "pages", "dependencies", "reuse_decisions", "quality_decisions", "domain_objects",
)


def _is_nonempty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _domain_object_key(kind: str, object_id: str) -> str:
    """Encode a typed ID pair without delimiter ambiguity."""
    return f"{quote(kind, safe='')}:{quote(object_id, safe='')}"


def _json_type_matches(value: Any, expected: str) -> bool:
    if expected == "object":
        return isinstance(value, dict)
    if expected == "array":
        return isinstance(value, list)
    if expected == "string":
        return isinstance(value, str)
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if expected == "boolean":
        return isinstance(value, bool)
    if expected == "null":
        return value is None
    return False


def _validate_schema_value(value: Any, schema: dict[str, Any], path: str, errors: list[str]) -> None:
    expected = schema.get("type")
    if expected and not _json_type_matches(value, expected):
        errors.append(f"{path}：应为 {expected}")
        return

    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}：应为 {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}：值不在允许集合中")
    if isinstance(value, str) and len(value) < schema.get("minLength", 0):
        errors.append(f"{path}：长度不得小于 {schema['minLength']}")

    if isinstance(value, dict):
        required = schema.get("required", [])
        for key in required:
            if key not in value:
                errors.append(f"{path}：缺少必填字段 {key}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value.keys() - properties.keys():
                errors.append(f"{path}：包含未知字段 {key}")
        for key, child_schema in properties.items():
            if key in value:
                _validate_schema_value(value[key], child_schema, f"{path}.{key}", errors)

    if isinstance(value, list):
        if schema.get("uniqueItems") and _has_duplicates(value):
            errors.append(f"{path}：元素不得重复 (uniqueItems)")
        item_schema = schema.get("items")
        if item_schema:
            for index, item in enumerate(value):
                _validate_schema_value(item, item_schema, f"{path}[{index}]", errors)


def _has_duplicates(values: list[Any]) -> bool:
    seen: set[str] = set()
    for value in values:
        try:
            key = json.dumps(value, ensure_ascii=False, sort_keys=True)
        except (TypeError, ValueError):
            key = repr(value)
        if key in seen:
            return True
        seen.add(key)
    return False


def _document_schema() -> dict[str, Any]:
    string_list = {"type": "array", "uniqueItems": True, "items": {"type": "string", "minLength": 1}}
    object_refs = {
        "type": "object",
        "additionalProperties": False,
        "required": [kind for kind in OBJECT_KINDS if kind not in {"features", "domain_objects"}],
        "properties": {kind: string_list for kind in OBJECT_KINDS},
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["id", "path", "template_id", "template_version", "acceptance_ids", "object_refs"],
        "properties": {
            "id": {"type": "string", "minLength": 1},
            "path": {"type": "string", "minLength": 1},
            "template_id": {"type": "string", "minLength": 1},
            "template_version": {"type": "string", "minLength": 1},
            "acceptance_ids": string_list,
            "object_refs": object_refs,
        },
    }


def _design_package_schema() -> dict[str, Any]:
    document = _document_schema()
    shared_ref = {
        "type": "object",
        "additionalProperties": False,
        "required": ["kind", "id"],
        "properties": {
            "kind": {"type": "string", "enum": list(OBJECT_KINDS)},
            "id": {"type": "string", "minLength": 1},
        },
    }
    return {
        "type": "object",
        "additionalProperties": False,
        "required": ["schema_version", "mode", "mode_reason", "total", "subdocuments", "shared_object_refs"],
        "properties": {
            "schema_version": {"type": "integer", "const": 2},
            "mode": {"type": "string", "enum": ["single", "total_subdocuments"]},
            "mode_reason": {"type": "string", "minLength": 1},
            "total": document,
            "subdocuments": {"type": "array", "items": document},
            "shared_object_refs": {"type": "array", "uniqueItems": True, "items": shared_ref},
        },
    }


def validate_design_package_schema(package: Any) -> list[str]:
    """Return structural errors for the design-package contract."""
    errors: list[str] = []
    _validate_schema_value(package, _design_package_schema(), "design_package", errors)
    return errors


def normalize_design_package(
    package: Any,
    design: dict[str, Any],
    acceptance_ids: set[str] | None = None,
    template_registry: dict[str, str] | None = None,
    default_document_path: str = "03-详细设计.md",
) -> Any:
    """Backfill old package fields and derive the complete inventory for single mode."""
    if not isinstance(package, dict):
        return package
    normalized = copy.deepcopy(package)
    if normalized.get("schema_version") == 1:
        normalized["schema_version"] = 2
    else:
        normalized.setdefault("schema_version", 2)
    normalized.setdefault("mode", "total_subdocuments")
    normalized.setdefault("mode_reason", "沿用升级前已登记的详设结构决策。")
    normalized.setdefault("subdocuments", [])
    normalized.setdefault("shared_object_refs", [])
    total = normalized.get("total")
    if normalized["mode"] == "single" and isinstance(total, dict):
        total.setdefault("id", "total")
        total.setdefault("path", default_document_path)
        template_id = next(iter(template_registry), "详细设计-模板") if isinstance(template_registry, dict) else "详细设计-模板"
        template_version = template_registry.get(template_id, "1.3.0") if isinstance(template_registry, dict) else "1.3.0"
        total.setdefault("template_id", template_id)
        total.setdefault("template_version", template_version)
        total["acceptance_ids"] = sorted(acceptance_ids or set())
        refs = total.get("object_refs")
        if not isinstance(refs, dict):
            refs = {}
            total["object_refs"] = refs
        for kind in OBJECT_KINDS:
            items = design.get("scope", {}).get("features", []) if kind == "features" else design.get(kind, [])
            refs[kind] = [
                _domain_object_key(item["kind"], item["id"]) if kind == "domain_objects" else item["id"]
                for item in items if isinstance(item, dict) and _is_nonempty_string(item.get("id"))
            ]
    subdocuments = normalized.get("subdocuments")
    documents = [normalized.get("total"), *(subdocuments if isinstance(subdocuments, list) else [])]
    if isinstance(template_registry, dict):
        for document in documents:
            if not isinstance(document, dict):
                continue
            current = template_registry.get(document.get("template_id"))
            if current and document.get("template_version") in {"1.1.0", "1.2.0"}:
                document["template_version"] = current
    scope = design.get("scope") if isinstance(design, dict) else None
    feature_items = scope.get("features", []) if isinstance(scope, dict) else []
    feature_ids = [
        item["id"] for item in feature_items
        if isinstance(item, dict) and _is_nonempty_string(item.get("id"))
    ]
    legacy_features = any(
        isinstance(document, dict)
        and isinstance(document.get("object_refs"), dict)
        and "features" not in document["object_refs"]
        for document in documents
    )
    for document in documents:
        if not isinstance(document, dict) or not isinstance(document.get("object_refs"), dict):
            continue
        refs = document["object_refs"]
        refs.setdefault("features", list(feature_ids) if legacy_features else [])
        for kind in OBJECT_KINDS:
            if kind not in {"features", "domain_objects"}:
                refs.setdefault(kind, [])
        refs.setdefault("domain_objects", [])
    if legacy_features and isinstance(subdocuments, list):
        shared = normalized.setdefault("shared_object_refs", [])
        if isinstance(shared, list):
            for feature_id in feature_ids:
                owners = sum(
                    isinstance(document, dict)
                    and isinstance(document.get("object_refs"), dict)
                    and feature_id in document["object_refs"].get("features", [])
                    for document in subdocuments
                )
                reference = {"kind": "features", "id": feature_id}
                if owners > 1 and reference not in shared:
                    shared.append(reference)
    return normalized


def _valid_relative_path(value: str) -> bool:
    if not value or "\\" in value or value.startswith("/"):
        return False
    if ntpath.splitdrive(value)[0]:
        return False
    path = PurePosixPath(value)
    return not path.is_absolute() and all(part not in ("", ".", "..") for part in value.split("/"))


def _canonical_path(value: str) -> str:
    """Normalize likely case/Unicode aliases before detecting output collisions."""
    return unicodedata.normalize("NFC", value).casefold()


def _design_objects(design: dict[str, Any]) -> tuple[dict[str, set[str]], list[str]]:
    errors: list[str] = []
    objects: dict[str, set[str]] = {}
    for kind in OBJECT_KINDS:
        scope = design.get("scope")
        if kind == "features":
            items = scope.get("features", []) if isinstance(scope, dict) else []
        else:
            items = design.get(kind, [])
        if not isinstance(items, list):
            errors.append(f"design.{kind}：应为数组")
            continue
        ids: set[str] = set()
        for index, item in enumerate(items):
            if (
                not isinstance(item, dict)
                or not _is_nonempty_string(item.get("id"))
                or (
                    kind == "domain_objects"
                    and (
                        not _is_nonempty_string(item.get("kind"))
                        or item.get("kind") != item.get("kind", "").strip()
                        or item.get("id") != item.get("id", "").strip()
                        or any(unicodedata.category(char) == "Cc" for char in item.get("kind", "") + item.get("id", ""))
                    )
                )
            ):
                errors.append(f"design.{kind}[{index}]：对象须包含非空字符串 id")
                continue
            object_id = _domain_object_key(item["kind"], item["id"]) if kind == "domain_objects" else item["id"]
            if object_id in ids:
                errors.append(f"design.{kind}：对象 ID 重复 {object_id}")
            ids.add(object_id)
        objects[kind] = ids
    return objects, errors


def validate_design_package(
    package: dict[str, Any],
    design: dict[str, Any],
    acceptance_ids: set[str],
    template_registry: dict[str, str] | None = None,
) -> list[str]:
    """Validate package structure, frozen acceptance coverage, and object ownership."""
    package = normalize_design_package(package, design, acceptance_ids, template_registry)
    errors = validate_design_package_schema(package)
    if errors:
        return errors

    if not isinstance(acceptance_ids, (set, frozenset)) or any(
        not _is_nonempty_string(item) for item in acceptance_ids
    ):
        return ["acceptance_ids：应为非空字符串组成的集合"]
    if template_registry is not None:
        if not isinstance(template_registry, dict) or any(
            not _is_nonempty_string(key) or not _is_nonempty_string(value)
            for key, value in template_registry.items()
        ):
            return ["template_registry：应为非空字符串键和值组成的对象"]

    if not isinstance(design, dict):
        return ["design：应为 object"]
    actual_objects, design_errors = _design_objects(design)
    errors.extend(design_errors)
    if design_errors:
        return errors

    documents = [package["total"], *package["subdocuments"]]
    mode = package["mode"]
    if not _is_nonempty_string(package["mode_reason"]):
        errors.append("mode_reason：必须记录单份/总分结构选择依据")
    elif any(marker in package["mode_reason"] for marker in ("{{", "待填写", "TODO", "TBD", "FIXME")):
        errors.append("mode_reason：仍有模式决策占位内容，请替换为本项目的选择依据")
    if mode == "single" and package["subdocuments"]:
        errors.append("single 模式不得登记分文档")
    if mode == "total_subdocuments" and not package["subdocuments"]:
        errors.append("total_subdocuments 模式至少需要一份分文档；单份详设请选择 single")
    document_ids: set[str] = set()
    paths: set[str] = set()
    for document in documents:
        document_id = document["id"]
        path = document["path"]
        if document_id in document_ids:
            errors.append(f"文档 ID duplicate：{document_id}")
        document_ids.add(document_id)
        if not _valid_relative_path(path):
            errors.append(f"文档 {document_id} path 必须是无绝对路径或 traversal 的相对路径：{path}")
        canonical_path = _canonical_path(path)
        if canonical_path in paths:
            errors.append(f"文档 path duplicate 或 total 与子文档冲突：{path}")
        paths.add(canonical_path)

        if not document["template_id"].strip():
            errors.append(f"文档 {document_id} template_id 不得为空")
        if not document["template_version"].strip():
            errors.append(f"文档 {document_id} template_version 不得为空")
        if template_registry is not None:
            expected_version = template_registry.get(document["template_id"])
            if expected_version is None:
                errors.append(f"文档 {document_id} template_id 未登记：{document['template_id']}")
            elif expected_version != document["template_version"]:
                errors.append(
                    f"文档 {document_id} template_version 不匹配："
                    f"{document['template_version']} != {expected_version}"
                )

    total = package["total"]
    total_acceptance = set(total["acceptance_ids"])
    if total_acceptance != acceptance_ids:
        errors.append(
            "total acceptance_ids 与冻结集合不一致；"
            f"缺少 {sorted(acceptance_ids - total_acceptance)}，多出 {sorted(total_acceptance - acceptance_ids)}"
        )
    unknown_acceptance = set().union(*(set(document["acceptance_ids"]) for document in documents)) - acceptance_ids
    if unknown_acceptance:
        errors.append(f"文档引用不存在的 acceptance IDs：{sorted(unknown_acceptance)}")
    if mode == "total_subdocuments":
        subdocument_acceptance = set().union(*(set(document["acceptance_ids"]) for document in package["subdocuments"]))
        if subdocument_acceptance != acceptance_ids:
            errors.append(
                "subdocuments acceptance_ids 并集与冻结集合不一致；"
                f"缺少 {sorted(acceptance_ids - subdocument_acceptance)}，"
                f"多出 {sorted(subdocument_acceptance - acceptance_ids)}"
            )

    total_refs = total["object_refs"]
    subdocument_owners: dict[tuple[str, str], set[str]] = {}
    for kind in OBJECT_KINDS:
        missing_total = actual_objects[kind] - set(total_refs[kind])
        extra_total = set(total_refs[kind]) - actual_objects[kind]
        if missing_total or extra_total:
            errors.append(
                f"total object_refs.{kind} 与 design 不一致；"
                f"缺少 {sorted(missing_total)}，多出 {sorted(extra_total)}"
            )

    for document in package["subdocuments"]:
        for kind in OBJECT_KINDS:
            refs = set(document["object_refs"][kind])
            nonexistent = refs - actual_objects[kind]
            if nonexistent:
                errors.append(f"子文档 {document['id']} object_refs.{kind} 引用不存在的对象：{sorted(nonexistent)}")
            for object_id in refs & actual_objects[kind]:
                subdocument_owners.setdefault((kind, object_id), set()).add(document["id"])

    all_keys = {(kind, object_id) for kind, ids in actual_objects.items() for object_id in ids}
    if mode == "total_subdocuments":
        for kind, object_id in sorted(all_keys):
            if (kind, object_id) not in subdocument_owners:
                errors.append(f"设计对象未分配给任何子文档：{kind}/{object_id}")

    registered_shared: set[tuple[str, str]] = set()
    for item in package["shared_object_refs"]:
        key = (item["kind"], item["id"])
        if key not in all_keys:
            errors.append(f"shared_object_refs 引用不存在的设计对象：{key[0]}/{key[1]}")
        registered_shared.add(key)

    for key, owners in sorted(subdocument_owners.items()):
        if len(owners) > 1 and key not in registered_shared:
            errors.append(f"设计对象在多个子文档中重复所有权但未声明 shared：{key[0]}/{key[1]}")
    for key in sorted(registered_shared):
        if len(subdocument_owners.get(key, ())) < 2:
            errors.append(f"shared_object_refs 不是实际共享对象：{key[0]}/{key[1]}")

    return errors
