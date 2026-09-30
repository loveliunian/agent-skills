import importlib.util
import hashlib
import json
import os
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "develop" / "tests" / "fixtures"
MODULE_PATH = ROOT / "develop" / "脚本" / "prd_inventory.py"
SPEC = importlib.util.spec_from_file_location("prd_inventory", MODULE_PATH)
prd_inventory = importlib.util.module_from_spec(SPEC)
if MODULE_PATH.exists() and SPEC.loader:
    SPEC.loader.exec_module(prd_inventory)
else:
    prd_inventory = None


def load_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def source_set_sha256(inventory):
    actual = inventory.get("source_set_sha256")
    if actual:
        return actual
    primary_record = f"{inventory['source_path']}\0primary_prd\0{inventory['prd_sha256']}"
    return hashlib.sha256(primary_record.encode("utf-8")).hexdigest()


def ledger_for(inventory, fixture_name="complete.json"):
    ledger = load_json(FIXTURES / "requirements" / fixture_name)
    ledger["schema_version"] = "1"
    ledger["parser_version"] = inventory["parser_version"]
    ledger["source_prd_sha256"] = inventory["prd_sha256"]
    ledger["extractor_id"] = "extractor-v1"
    ledger["independent_review"] = {
        "reviewer_id": "independent-reviewer",
        "status": "completed",
        "reviewed_prd_sha256": inventory["prd_sha256"],
        "reviewed_source_set_sha256": source_set_sha256(inventory),
        "source_unit_count": len(inventory["units"]),
        "conclusion": "no_deltas" if not ledger.get("review_deltas") else "deltas_resolved",
        "evidence": ["Independent line-by-line comparison against the PRD and source inventory."],
    }
    return ledger


def asset_ledger_for(inventory, asset_review_status="reviewed"):
    return {
        "schema_version": "1",
        "parser_version": inventory["parser_version"],
        "source_prd_sha256": inventory["prd_sha256"],
        "extractor_id": "asset-extractor-v1",
        "independent_review": {
            "reviewer_id": "asset-reviewer",
            "status": "completed",
            "reviewed_prd_sha256": inventory["prd_sha256"],
            "reviewed_source_set_sha256": source_set_sha256(inventory),
            "source_unit_count": len(inventory["units"]),
            "conclusion": "no_deltas",
            "evidence": ["Reviewed all PRD source units independently."],
        },
        "classifications": [
            {"source_ref": unit["id"], "classification": "context", "reason": "Asset fixture source"}
            for unit in inventory["units"]
        ],
        "requirements": [],
        "review_deltas": [],
        "asset_reviews": [
            {"source_ref": unit["id"], "status": asset_review_status, "summary": "Reviewed linked asset.", "evidence": [unit["id"]], "asset_sha256": unit["asset_sha256"]}
            for unit in inventory["units"] if unit["kind"] == "asset_reference"
        ],
    }


class PrdInventoryTests(unittest.TestCase):
    def setUp(self):
        if prd_inventory is None:
            self.fail("prd_inventory module is not implemented")

    def test_scan_inventories_headings_paragraphs_individual_list_items_and_table_rows(self):
        result = prd_inventory.scan_prd(FIXTURES / "prd" / "complete.md")
        kinds = [unit["kind"] for unit in result["units"]]
        texts = [unit["text"] for unit in result["units"]]
        self.assertEqual(result["parser_version"], "2")
        self.assertEqual(len(result["prd_sha256"]), 64)
        self.assertIn("heading", kinds)
        self.assertIn("paragraph", kinds)
        self.assertIn("list_item", kinds)
        self.assertIn("table_row", kinds)
        self.assertIn("table_header", kinds)
        self.assertIn("退款金额不能超过剩余可退金额。", texts)
        self.assertIn("退款单号 | 唯一标识退款单", texts)
        self.assertNotIn("---", texts)
        self.assertEqual(len({unit["id"] for unit in result["units"]}), len(result["units"]))
        row = next(unit for unit in result["units"] if unit["text"] == "订单支持部分退款。")
        self.assertEqual(row["heading_path"], ["退款", "退款流程"])
        self.assertEqual((row["start_line"], row["end_line"]), (6, 6))
        self.assertEqual(next(unit for unit in result["units"] if unit["kind"] == "paragraph")["table_headers"], [])
        header = next(unit for unit in result["units"] if unit["kind"] == "table_header")
        self.assertEqual(header["text"], "字段 | 说明")
        self.assertEqual((header["start_line"], header["end_line"]), (12, 12))
        data_row = next(unit for unit in result["units"] if unit["text"] == "退款单号 | 唯一标识退款单")
        self.assertEqual(data_row["table_headers"], ["字段", "说明"])
        self.assertEqual(data_row["start_line"], 14)

    def test_legacy_design_reference_role_is_inventoried_as_non_prd_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp)
            prd = project / "prd.md"
            prd.write_text("# PRD\n\n## Requirement\n\nDo the thing.\n", encoding="utf-8")
            reference = project / "docs" / "reference" / "legacy-design-comparison.md"
            reference.parent.mkdir(parents=True)
            reference.write_text("# Comparison only\n\nNot normative.\n", encoding="utf-8")

            inventory = prd_inventory.scan_prd_sources(
                prd,
                [{
                    "path": "docs/reference/legacy-design-comparison.md",
                    "role": "legacy_design_reference",
                    "required": True,
                    "description": "Comparison only; not a normative PRD source.",
                }],
                project_root=project,
            )

        self.assertEqual(inventory["source_documents"][1]["role"], "legacy_design_reference")
        self.assertTrue(any(unit["source_role"] == "legacy_design_reference" for unit in inventory["units"]))

    def test_ids_do_not_depend_on_line_numbers(self):
        source = FIXTURES / "prd" / "complete.md"
        with tempfile.TemporaryDirectory() as tmp:
            shifted = Path(tmp) / "complete.md"
            shifted.write_text(source.read_text(encoding="utf-8"), encoding="utf-8")
            first = prd_inventory.scan_prd(shifted)
            shifted.write_text("\n\n" + source.read_text(encoding="utf-8"), encoding="utf-8")
            second = prd_inventory.scan_prd(shifted)
        self.assertEqual([u["id"] for u in first["units"]], [u["id"] for u in second["units"]])

    def test_generated_heading_numbers_do_not_change_source_unit_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "01-产品需求.md"
            source.write_text("# 退款\n\n## 背景\n\n退款要可追踪。\n\n### 申请流程\n\n用户提交申请。\n", encoding="utf-8")
            unnumbered = prd_inventory.scan_prd(source)
            source.write_text("# 退款\n\n## 1 背景\n\n退款要可追踪。\n\n### 1.1 申请流程\n\n用户提交申请。\n", encoding="utf-8")
            numbered = prd_inventory.scan_prd(source)
        self.assertEqual([unit["id"] for unit in unnumbered["units"]], [unit["id"] for unit in numbered["units"]])
        unnumbered_heading = next(unit for unit in unnumbered["units"] if unit["kind"] == "heading" and unit["text"] == "背景")
        numbered_heading = next(unit for unit in numbered["units"] if unit["kind"] == "heading" and unit["text"] == "1 背景")
        self.assertEqual(unnumbered_heading["heading_path"], ["退款", "背景"])
        self.assertEqual(numbered_heading["heading_path"], ["退款", "1 背景"])

    def test_duplicate_units_receive_distinct_stable_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "duplicates.md"
            source.write_text("# A\n\nRepeat.\n\nRepeat.\n", encoding="utf-8")
            first = prd_inventory.scan_prd(source)
            source.write_text("\n# A\n\nRepeat.\n\nRepeat.\n", encoding="utf-8")
            shifted = prd_inventory.scan_prd(source)
        first_ids = [u["id"] for u in first["units"] if u["text"] == "Repeat."]
        shifted_ids = [u["id"] for u in shifted["units"] if u["text"] == "Repeat."]
        self.assertEqual(len(set(first_ids)), 2)
        self.assertEqual(first_ids, shifted_ids)

    def test_project_root_keeps_inventory_path_and_ids_stable_across_working_directories(self):
        source = FIXTURES / "prd" / "complete.md"
        old_cwd = Path.cwd()
        try:
            with tempfile.TemporaryDirectory() as first_dir, tempfile.TemporaryDirectory() as second_dir:
                os.chdir(first_dir)
                first = prd_inventory.scan_prd(source, project_root=ROOT)
                os.chdir(second_dir)
                second = prd_inventory.scan_prd(source, project_root=ROOT)
        finally:
            os.chdir(old_cwd)
        self.assertEqual(first["source_path"], "develop/tests/fixtures/prd/complete.md")
        self.assertEqual(first["source_path"], second["source_path"])
        self.assertEqual([unit["id"] for unit in first["units"]], [unit["id"] for unit in second["units"]])

    def test_direct_scan_uses_stable_parent_relative_fallback(self):
        source = FIXTURES / "prd" / "complete.md"
        old_cwd = Path.cwd()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                os.chdir(tmp)
                result = prd_inventory.scan_prd(source)
        finally:
            os.chdir(old_cwd)
        self.assertEqual(result["source_path"], "complete.md")

    def test_scan_preserves_malformed_table_as_opaque_source_unit(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "malformed-table.md")
        self.assertTrue(any(unit["kind"] == "opaque_block" for unit in inventory["units"]))

    def test_scan_preserves_raw_html_as_source_unit(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "unsupported-html.md")
        html_unit = next(unit for unit in inventory["units"] if unit["kind"] == "html_block")
        self.assertIn("<div>", html_unit["text"])

    def test_scan_preserves_fenced_code_as_one_source_unit(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text(
                "# PRD\n\n## 流程\n\n```mermaid\nflowchart LR\n  A --> B\n```\n",
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source)
        code = next(unit for unit in result["units"] if unit["kind"] == "code_block")
        self.assertEqual(code["text"], "```mermaid\nflowchart LR\n  A --> B\n```")
        self.assertEqual((code["start_line"], code["end_line"]), (5, 8))
        self.assertEqual(code["heading_path"], ["PRD", "流程"])

    def test_scan_preserves_blockquotes_and_html_as_source_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text(
                "# PRD\n\n> 业务方原话\n> 续行\n\n<!-- source-note -->\n<div>约束</div>\n",
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source)
        self.assertIn("> 业务方原话\n> 续行", [unit["text"] for unit in result["units"]])
        kinds = [unit["kind"] for unit in result["units"]]
        self.assertIn("blockquote", kinds)
        self.assertIn("html_block", kinds)

    def test_scan_recognizes_setext_heading_levels(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text("Root\n====\n\nChild\n----\n\nRequirement.\n", encoding="utf-8")
            result = prd_inventory.scan_prd(source)
        headings = [unit for unit in result["units"] if unit["kind"] == "heading"]
        self.assertEqual([unit["text"] for unit in headings], ["Root", "Child"])
        self.assertEqual(headings[1]["heading_path"], ["Root", "Child"])

    def test_html_image_link_is_inventoried_as_an_asset_reference(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text('<div>\n<img src="wireframe.png" alt="页面原型">\n</div>\n', encoding="utf-8")
            result = prd_inventory.scan_prd(source)
        asset = next(unit for unit in result["units"] if unit["kind"] == "asset_reference")
        self.assertEqual(asset["asset_alt_text"], "页面原型")
        self.assertEqual(asset["asset_target"], "wireframe.png")
        self.assertEqual(asset["asset_status"], "unresolved")

    def test_html_unquoted_images_and_links_are_asset_references(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text(
                '<img src=wireframe.png alt=Wireframe>\n'
                '<a href="prototype.pdf">原型</a>\n'
                '<video poster=cover.jpg></video>\n'
                '<object data=spec.pdf></object>\n'
                '<img srcset="wireframe-1x.png 1x, wireframe-2x.png 2x">\n',
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source)
        refs = {(unit["asset_target"], unit["asset_alt_text"]) for unit in result["units"] if unit["kind"] == "asset_reference"}
        self.assertIn(("wireframe.png", "Wireframe"), refs)
        self.assertIn(("prototype.pdf", ""), refs)
        self.assertIn(("cover.jpg", ""), refs)
        self.assertIn(("spec.pdf", ""), refs)
        self.assertIn(("wireframe-1x.png", ""), refs)
        self.assertIn(("wireframe-2x.png", ""), refs)

    def test_srcset_keeps_data_uri_commas_inside_the_candidate(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text(
                '<img srcset="fallback.png 1x, data:image/png;base64,AAAA 2x">\n',
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source)
        targets = [unit["asset_target"] for unit in result["units"] if unit["kind"] == "asset_reference"]
        self.assertEqual(targets, ["fallback.png"])

    def test_srcset_data_candidate_without_descriptor_does_not_swallow_external_asset(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "prd.md"
            source.write_text(
                '<img srcset="data:image/png;base64,AAAA, https://cdn.example.test/fallback.png">\n',
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source)
        assets = [unit for unit in result["units"] if unit["kind"] == "asset_reference"]
        self.assertEqual([unit["asset_target"] for unit in assets], ["https://cdn.example.test/fallback.png"])
        self.assertEqual(assets[0]["asset_status"], "unresolved")

    def test_reference_style_markdown_links_resolve_to_asset_units(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            image = root / "wireframe.png"
            image.write_bytes(b"image bytes")
            source = root / "prd.md"
            source.write_text(
                "# PRD\n\n![流程图][wireframe]\n\n[wireframe]: wireframe.png\n",
                encoding="utf-8",
            )
            result = prd_inventory.scan_prd(source, project_root=root)
        assets = [unit for unit in result["units"] if unit["kind"] == "asset_reference"]
        self.assertEqual(len(assets), 1)
        self.assertEqual(assets[0]["asset_target"], "wireframe.png")
        self.assertEqual(assets[0]["asset_alt_text"], "流程图")
        self.assertEqual(assets[0]["asset_status"], "resolved")

    def test_reference_definitions_support_bare_quoted_angle_and_external_targets(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "bare.png").write_bytes(b"bare")
            (root / "quoted.png").write_bytes(b"quoted")
            (root / "angle file.png").write_bytes(b"angle")
            source = root / "prd.md"
            source.write_text(
                "![Bare][bare]\n"
                "![Quoted][quoted]\n"
                "[Angle][angle]\n"
                "![Remote][remote]\n\n"
                "[bare]: bare.png\n"
                "[quoted]: \"quoted.png\" \"title\"\n"
                "[angle]: <angle file.png>\n"
                "[remote]: https://cdn.example.test/remote.png\n",
                encoding="utf-8",
            )
            inventory = prd_inventory.scan_prd(source, project_root=root)
        assets = [unit for unit in inventory["units"] if unit["kind"] == "asset_reference"]
        by_target = {unit["asset_target"]: unit for unit in assets}
        self.assertEqual(set(by_target), {"bare.png", "quoted.png", "angle file.png", "https://cdn.example.test/remote.png"})
        self.assertEqual(by_target["bare.png"]["asset_status"], "resolved")
        self.assertEqual(by_target["quoted.png"]["asset_status"], "resolved")
        self.assertEqual(by_target["angle file.png"]["asset_status"], "resolved")
        self.assertEqual(by_target["https://cdn.example.test/remote.png"]["asset_status"], "unresolved")

    def test_prose_pipe_does_not_start_a_table(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "pipe-prose.md")
        self.assertIn("Use A | B for values.", [unit["text"] for unit in inventory["units"]])

    def test_oversized_prd_is_rejected_by_streaming_size_cap(self):
        old_limit = getattr(prd_inventory, "MAX_PRD_BYTES", None)
        try:
            prd_inventory.MAX_PRD_BYTES = 16
            with tempfile.TemporaryDirectory() as tmp:
                prd = Path(tmp) / "large.md"
                prd.write_bytes(b"# Large PRD\n1234567890")
                with self.assertRaisesRegex(ValueError, "PRD exceeds size limit"):
                    prd_inventory.scan_prd(prd)
        finally:
            if old_limit is None:
                del prd_inventory.MAX_PRD_BYTES
            else:
                prd_inventory.MAX_PRD_BYTES = old_limit

    def test_prd_size_limit_can_be_configured_for_large_projects(self):
        with tempfile.TemporaryDirectory() as tmp:
            prd = Path(tmp) / "large.md"
            prd.write_text("# A\n\n" + "x" * 128, encoding="utf-8")
            inventory = prd_inventory.scan_prd(prd, max_prd_bytes=256)
            self.assertTrue(inventory["units"])
            with self.assertRaisesRegex(ValueError, "PRD exceeds size limit"):
                prd_inventory.scan_prd(prd, max_prd_bytes=32)

    def test_asset_size_limit_can_be_configured_above_default(self):
        old_limit = prd_inventory.MAX_ASSET_BYTES
        try:
            prd_inventory.MAX_ASSET_BYTES = 16
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                docs = root / "docs"
                docs.mkdir()
                (root / "asset.bin").write_bytes(b"01234567890123456789")
                prd = docs / "prd.md"
                prd.write_text("![asset](../asset.bin)\n", encoding="utf-8")
                result = prd_inventory.scan_prd(prd, project_root=root, max_asset_bytes=32)
            asset = next(unit for unit in result["units"] if unit["kind"] == "asset_reference")
            self.assertEqual(asset["asset_status"], "resolved")
        finally:
            prd_inventory.MAX_ASSET_BYTES = old_limit

    def test_repeated_table_separator_is_structural_and_excluded(self):
        result = prd_inventory.scan_prd(FIXTURES / "prd" / "repeated-separator.md")
        texts = [unit["text"] for unit in result["units"]]
        self.assertIn("字段 | 描述", texts)
        self.assertNotIn("--- | ---", texts)

    def test_empty_table_data_cell_is_preserved_in_a_table_row(self):
        result = prd_inventory.scan_prd(FIXTURES / "prd" / "empty-table-cell.md")
        row = next(unit for unit in result["units"] if unit["kind"] == "table_row")
        self.assertEqual(row["text"], "值 | ")

    def test_escaped_pipe_is_kept_inside_a_table_cell(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "escaped-pipe-table.md")
        row = next(unit for unit in inventory["units"] if unit["kind"] == "table_row")
        self.assertEqual(row["table_headers"], ["字段", "说明"])
        self.assertEqual(row["text"], "A | B | literal pipe")

    def test_markdown_asset_references_include_target_alt_text_hash_and_resolution_state(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "assets.md")
        assets = [unit for unit in inventory["units"] if unit["kind"] == "asset_reference"]
        self.assertEqual(len(assets), 4)
        local = next(unit for unit in assets if unit["asset_target"] == "assets/prototype.png")
        self.assertEqual(local["asset_alt_text"], "方案截图")
        self.assertEqual(local["start_line"], 2)
        self.assertEqual(local["asset_status"], "resolved")
        self.assertEqual(len(local["asset_sha256"]), 64)
        external = next(unit for unit in assets if unit["asset_target"].startswith("https://"))
        missing = next(unit for unit in assets if "missing" in unit["asset_target"])
        self.assertEqual(external["asset_status"], "unresolved")
        self.assertEqual(missing["asset_status"], "unresolved")
        self.assertIsNone(external["asset_sha256"])

    def test_local_asset_requires_review_and_valid_evidence(self):
        source = FIXTURES / "prd" / "local-asset.md"
        inventory = prd_inventory.scan_prd_sources(source, project_root=source.parent)
        ledger = asset_ledger_for(inventory)
        ledger["asset_reviews"] = []
        self.assertTrue(any("missing asset review" in error for error in prd_inventory.validate_requirement_ledger(inventory, ledger)))
        ledger = asset_ledger_for(inventory, asset_review_status="unreviewed")
        self.assertTrue(any("asset review is not reviewed" in error for error in prd_inventory.validate_requirement_ledger(inventory, ledger)))
        ledger = asset_ledger_for(inventory)
        self.assertEqual(prd_inventory.validate_requirement_ledger(inventory, ledger), [])

    def test_inaccessible_asset_blocks_even_when_review_record_exists(self):
        source = FIXTURES / "prd" / "assets.md"
        inventory = prd_inventory.scan_prd_sources(source, project_root=source.parent)
        ledger = asset_ledger_for(inventory)
        self.assertTrue(any("unresolved asset reference" in error for error in prd_inventory.validate_requirement_ledger(inventory, ledger)))

    def test_asset_hashing_stays_inside_project_and_obeys_size_limit(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            project = base / "project"
            docs = project / "docs"
            assets = project / "assets"
            (docs / "links").mkdir(parents=True)
            assets.mkdir()
            outside = base / "outside.bin"
            outside.write_bytes(b"outside target")
            valid_bytes = b"normal in-root asset"
            (assets / "valid.bin").write_bytes(valid_bytes)
            with (assets / "oversized.bin").open("wb") as oversized:
                oversized.truncate(20 * 1024 * 1024 + 1)
            (docs / "links" / "escape.bin").symlink_to(outside)
            absolute_target = outside.as_posix()
            prd = docs / "links" / "prd.md"
            prd.write_text(
                "# Assets\n"
                "![valid](../../assets/valid.bin)\n"
                "![traversal](../../../outside.bin)\n"
                "![symlink](escape.bin)\n"
                f"![absolute]({absolute_target})\n"
                "![large](../../assets/oversized.bin)\n",
                encoding="utf-8",
            )
            inventory = prd_inventory.scan_prd(prd, project_root=project)
        by_alt = {unit["asset_alt_text"]: unit for unit in inventory["units"] if unit["kind"] == "asset_reference"}
        self.assertEqual(by_alt["valid"]["asset_status"], "resolved")
        self.assertEqual(by_alt["valid"]["asset_sha256"], hashlib.sha256(valid_bytes).hexdigest())
        for alt in ("traversal", "symlink", "absolute", "large"):
            self.assertEqual(by_alt[alt]["asset_status"], "unresolved")
            self.assertIsNone(by_alt[alt]["asset_sha256"])

    def test_malformed_ledger_shapes_return_errors_instead_of_raising(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "complete.md")
        mutations = [
            ("classifications", [None], "classifications[0]"),
            ("requirements", None, "requirements must be a list"),
            ("requirements", [None], "requirements[0]"),
            ("review_deltas", None, "review_deltas must be a list"),
            ("review_deltas", [None], "review_deltas[0]"),
            ("asset_reviews", None, "asset_reviews must be a list"),
            ("asset_reviews", [None], "asset_reviews[0]"),
        ]
        for field, value, expected in mutations:
            with self.subTest(field=field, value=value):
                ledger = ledger_for(inventory)
                ledger[field] = value
                errors = prd_inventory.validate_requirement_ledger(inventory, ledger)
                self.assertTrue(any(expected in error for error in errors))

    def test_schema_encodes_classification_reasons_and_delta_disposition(self):
        schema = load_json(ROOT / "develop" / "契约" / "需求提取数据结构.json")
        classification_item = schema["properties"]["classifications"]["items"]
        requires_reason = any(
            condition.get("if", {}).get("properties", {}).get("classification", {}).get("enum")
            == ["context", "duplicate", "non_requirement"]
            and "reason" in condition.get("then", {}).get("required", [])
            for condition in classification_item.get("allOf", [])
        )
        self.assertTrue(requires_reason)
        self.assertEqual(classification_item["properties"]["reason"]["minLength"], 1)
        delta_item = schema["properties"]["review_deltas"]["items"]
        self.assertIn("disposition", delta_item["required"])

    def test_non_string_requirement_status_is_a_structural_error(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "complete.md")
        ledger = ledger_for(inventory)
        ledger["requirements"][0]["status"] = []
        errors = prd_inventory.validate_requirement_ledger(inventory, ledger)
        self.assertTrue(any("requirements[0].status must be a string" in error for error in errors))

    def test_unhashable_evidence_entries_return_shape_errors(self):
        inventory = prd_inventory.scan_prd(FIXTURES / "prd" / "local-asset.md")
        ledger = asset_ledger_for(inventory)
        ledger["asset_reviews"][0]["evidence"] = [{}]
        errors = prd_inventory.validate_requirement_ledger(inventory, ledger)
        self.assertTrue(any("asset_reviews[0].evidence entries must be strings" in error for error in errors))

    def test_review_comparison_detects_mandatory_and_requirement_metadata_changes(self):
        canonical = {"requirements": [{"id": "REQ-1", "statement": "Keep this", "mandatory": True, "actors": ["Buyer"], "trigger": "Submit", "observable_result": "Saved", "constraints": ["Limit"]}]}
        independent = {"requirements": [{"id": "REQ-1", "statement": "Keep this", "mandatory": False, "actors": ["Seller"], "trigger": "Approve", "observable_result": "Shown", "constraints": ["Policy"]}]}
        deltas = prd_inventory.compare_requirement_reviews(canonical, independent)
        self.assertTrue(any(delta["kind"] == "changed" for delta in deltas))

    def test_review_comparison_detects_exclusion_reason_and_open_question_changes(self):
        canonical = {"requirements": [{"id": "REQ-X", "statement": "Do not implement", "status": "已排除", "resolution_reason": "Out of scope", "open_questions": ["Who approves?"]}]}
        independent = {"requirements": [{"id": "REQ-X", "statement": "Do not implement", "status": "已排除", "resolution_reason": "Deferred", "open_questions": ["Who approves?"]}]}
        self.assertTrue(any(delta["kind"] == "changed" for delta in prd_inventory.compare_requirement_reviews(canonical, independent)))
        independent["requirements"][0]["resolution_reason"] = "Out of scope"
        independent["requirements"][0]["open_questions"] = ["When is approval needed?"]
        self.assertTrue(any(delta["kind"] == "changed" for delta in prd_inventory.compare_requirement_reviews(canonical, independent)))


class RequirementLedgerTests(unittest.TestCase):
    def setUp(self):
        if prd_inventory is None:
            self.fail("prd_inventory module is not implemented")
        source = FIXTURES / "prd" / "complete.md"
        self.inventory = prd_inventory.scan_prd_sources(source, project_root=source.parent)

    def test_valid_ledger_accounts_for_every_unit_and_supports_multiple_requirements_per_unit(self):
        ledger = ledger_for(self.inventory)
        self.assertEqual(prd_inventory.validate_requirement_ledger(self.inventory, ledger), [])
        shared = next(unit["id"] for unit in self.inventory["units"] if unit["text"] == "订单支持部分退款。")
        refs = [req["id"] for req in ledger["requirements"] if shared in req["source_refs"]]
        self.assertEqual(refs, ["REQ-001", "REQ-002"])

    def test_requirement_ids_keep_project_defined_format(self):
        ledger = ledger_for(self.inventory)
        ledger["requirements"][0]["id"] = "M-01-F01-A01"
        ledger["requirements"][1]["id"] = "user.create"
        errors = prd_inventory.validate_requirement_ledger(self.inventory, ledger)
        self.assertFalse(any("invalid requirement ID" in error for error in errors), errors)

    def test_missing_units_duplicate_ids_and_invalid_refs_are_reported(self):
        ledger = ledger_for(self.inventory, "invalid-ledger.json")
        errors = prd_inventory.validate_requirement_ledger(self.inventory, ledger)
        self.assertTrue(any("unclassified source unit" in e for e in errors))
        self.assertTrue(any("duplicate requirement ID" in e for e in errors))
        self.assertTrue(any("invalid source reference" in e for e in errors))

    def test_context_and_duplicate_classifications_need_reasons(self):
        ledger = ledger_for(self.inventory)
        ledger["classifications"][0]["classification"] = "context"
        ledger["classifications"][0].pop("reason", None)
        self.assertTrue(any("reason required" in e for e in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_requirement_status_testable_and_disposition_decision_are_validated(self):
        ledger = ledger_for(self.inventory)
        ledger["requirements"][0].pop("testable")
        ledger["review_deltas"] = [{
            "id": "DELTA-MANUAL", "kind": "changed", "description": "Review this",
            "source_refs": [self.inventory["units"][3]["id"]],
            "disposition": {"decision": "maybe", "rationale": "reviewed", "evidence": [self.inventory["units"][3]["id"]]},
        }]
        errors = prd_inventory.validate_requirement_ledger(self.inventory, ledger)
        self.assertTrue(any("testable must be boolean" in error for error in errors))
        self.assertTrue(any("invalid review disposition" in error for error in errors))

    def test_unresolved_mandatory_requirement_blocks_ledger(self):
        ledger = ledger_for(self.inventory)
        ledger["requirements"][0]["status"] = "待澄清"
        ledger["requirements"][0]["mandatory"] = True
        self.assertTrue(any("unresolved mandatory requirement" in error for error in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_mandatory_must_be_boolean(self):
        ledger = ledger_for(self.inventory)
        ledger["requirements"][0]["mandatory"] = "yes"
        self.assertTrue(any("mandatory must be boolean" in error for error in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_requirement_status_uses_canonical_enum_and_excluded_requires_reason(self):
        ledger = ledger_for(self.inventory)
        ledger["requirements"][0]["status"] = "unexpected"
        ledger["requirements"][1]["status"] = "已排除"
        errors = prd_inventory.validate_requirement_ledger(self.inventory, ledger)
        self.assertTrue(any("invalid requirement status" in error for error in errors))
        self.assertTrue(any("resolution_reason required" in error for error in errors))

    def test_unresolved_review_delta_blocks_validation(self):
        ledger = ledger_for(self.inventory, "unresolved-delta.json")
        self.assertTrue(any("unresolved review delta" in e for e in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_independent_review_record_is_required(self):
        ledger = ledger_for(self.inventory)
        ledger.pop("review_deltas")
        self.assertTrue(any("independent review must be recorded" in e for e in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_empty_delta_list_requires_independent_review_attestation(self):
        ledger = ledger_for(self.inventory)
        ledger.pop("independent_review", None)
        self.assertTrue(any("independent review attestation required" in e for e in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))

    def test_independent_review_attestation_is_bound_to_inventory_and_delta_conclusion(self):
        ledger = ledger_for(self.inventory)
        ledger["independent_review"]["reviewer_id"] = ledger["extractor_id"]
        ledger["independent_review"]["status"] = "pending"
        ledger["independent_review"]["reviewed_prd_sha256"] = "0" * 64
        ledger["independent_review"]["source_unit_count"] += 1
        ledger["independent_review"]["conclusion"] = "deltas_resolved"
        ledger["independent_review"]["evidence"] = []
        errors = prd_inventory.validate_requirement_ledger(self.inventory, ledger)
        self.assertTrue(any("reviewer_id must differ" in error for error in errors))
        self.assertTrue(any("independent review status must be completed" in error for error in errors))
        self.assertTrue(any("reviewed PRD hash does not match" in error for error in errors))
        self.assertTrue(any("reviewed source unit count does not match" in error for error in errors))
        self.assertTrue(any("independent review conclusion must be no_deltas" in error for error in errors))
        self.assertTrue(any("independent review evidence required" in error for error in errors))

    def test_review_comparison_returns_delta_candidates_and_dispositions_are_required(self):
        canonical = load_json(FIXTURES / "requirements" / "review-canonical.json")
        independent = load_json(FIXTURES / "requirements" / "review-independent.json")
        canonical["requirements"].append({"id": "REQ-OLD", "statement": "已移除", "source_refs": []})
        independent["requirements"].append({"id": "REQ-3", "statement": "需记录退款理由", "source_refs": []})
        canonical["requirements"][0]["source_refs"] = [self.inventory["units"][3]["id"]]
        independent["requirements"][0]["source_refs"] = [self.inventory["units"][3]["id"]]
        independent["requirements"][1]["source_refs"] = [self.inventory["units"][4]["id"]]
        deltas = prd_inventory.compare_requirement_reviews(canonical, independent)
        self.assertTrue(any(d["kind"] == "added" for d in deltas))
        self.assertTrue(any(d["kind"] == "changed" for d in deltas))
        self.assertTrue(any(d["kind"] == "missing" for d in deltas))
        self.assertTrue(any(d["kind"] == "duplicate" for d in deltas))
        canonical["requirements"].append({"id": "REQ-DUPLICATED", "statement": "重复记录", "source_refs": []})
        canonical["requirements"].append({"id": "REQ-DUPLICATED", "statement": "第二份重复记录", "source_refs": []})
        repeated_id_deltas = prd_inventory.compare_requirement_reviews(canonical, independent)
        self.assertTrue(any(d["kind"] == "duplicate" and d.get("requirement_id") == "REQ-DUPLICATED" for d in repeated_id_deltas))
        ledger = ledger_for(self.inventory)
        ledger["review_deltas"] = deltas
        ledger["independent_review"]["conclusion"] = "deltas_resolved"
        self.assertTrue(any("unresolved review delta" in e for e in prd_inventory.validate_requirement_ledger(self.inventory, ledger)))
        for delta in ledger["review_deltas"]:
            delta["disposition"] = {"decision": "accept", "rationale": "Reviewed against source.", "evidence": [self.inventory["units"][0]["id"]]}
        self.assertEqual(prd_inventory.validate_requirement_ledger(self.inventory, ledger), [])


if __name__ == "__main__":
    unittest.main()
