import json
import importlib.util
import hashlib
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "脚本"))
from prd_inventory import scan_prd


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "develop" / "脚本" / "develop.py"
DEVELOP_SPEC = importlib.util.spec_from_file_location("develop_pipeline", SCRIPT)
DEVELOP = importlib.util.module_from_spec(DEVELOP_SPEC)
DEVELOP_SPEC.loader.exec_module(DEVELOP)


class ManifestTemplateContractTests(unittest.TestCase):
    def test_all_manifest_sections_match_their_template_h2_headings(self):
        manifest_path = ROOT / "develop" / "契约" / "文档清单.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        for document in manifest["documents"]:
            with self.subTest(document=document["id"]):
                template = ROOT / "develop" / "模板" / document["template"]
                headings = [
                    line[3:].strip()
                    for line in template.read_text(encoding="utf-8").splitlines()
                    if line.startswith("## ")
                ]
                self.assertEqual(headings, document["sections"])


class PrdCommandTests(unittest.TestCase):
    def test_scan_prd_command_writes_deterministic_inventory(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            prd = directory / "01-产品需求.md"
            prd.write_text(
                "# 退款\n\n## 目标\n\n支持用户申请退款。\n",
                encoding="utf-8",
            )

            first = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(first.returncode, 0, first.stderr)
            inventory_path = directory / "01-PRD来源清单.json"
            self.assertTrue(inventory_path.is_file())
            first_inventory = json.loads(inventory_path.read_text(encoding="utf-8"))

            second = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=directory.parent,
                capture_output=True,
                text=True,
            )
            self.assertEqual(second.returncode, 0, second.stderr)
            second_inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
            self.assertEqual(first_inventory, second_inventory)
            self.assertTrue(first_inventory["prd_sha256"])
            self.assertTrue(first_inventory["units"])

    def _write_complete_case(self, directory: Path, arbitrary_source_prd: bool = False) -> None:
        DEVELOP.render_skeleton(
            directory, DEVELOP.load_manifest(), "退款", design_mode_reason="单一功能域，详设对象规模适中。"
        )
        prd = directory / "01-产品需求.md"
        prd_content = (
            "# 退款\n\n## 背景与问题\n\n退款处理需要标准化。\n\n"
            "## 目标与范围\n\n支持用户申请退款。\n\n"
            "## 用户与场景\n\n用户提交退款申请。\n\n"
            "## 需求清单\n\n用户可以申请退款。\n\n"
            "## 验收标准\n\n退款申请成功后返回可观察结果。\n\n"
            "## 风险与待确认\n\n目前没有待确认项。\n"
        )
        if arbitrary_source_prd:
            prd_content = prd_content.replace("## 背景与问题", "## Customer problem")
            prd_content = prd_content.replace("## 目标与范围", "## Product scope")
            prd_content = prd_content.replace("## 用户与场景", "## Actors and journeys")
            prd_content = prd_content.replace("## 需求清单", "## Requirements")
            prd_content = prd_content.replace("## 验收标准", "## Acceptance scenarios")
            prd_content = prd_content.replace("## 风险与待确认", "## Risks")
        else:
            prd_content = DEVELOP.number_markdown_headings(prd_content)
        prd.write_text(prd_content, encoding="utf-8")
        inventory = scan_prd(prd, project_root=directory)
        source_set_record = f"{inventory['source_path']}\0primary_prd\0{inventory['prd_sha256']}"
        reviewed_source_set_sha256 = hashlib.sha256(source_set_record.encode("utf-8")).hexdigest()
        units = inventory["units"]
        requirement_unit = next(unit for unit in units if unit["text"] == "用户可以申请退款。")
        requirement_source = requirement_unit["id"]
        classifications = []
        for unit in units:
            classification = "functional_requirement" if unit["id"] == requirement_source else "context"
            row = {"source_ref": unit["id"], "classification": classification}
            if classification == "context":
                row["reason"] = "仅说明章节结构。"
            classifications.append(row)
        ledger = {
            "schema_version": "1",
            "source_prd_sha256": inventory["prd_sha256"],
            "parser_version": inventory["parser_version"],
            "extractor_id": "agent:extractor",
            "classifications": classifications,
            "requirements": [{
                "id": "REQ-001",
                "statement": "用户可以申请退款。",
                "status": "已确认",
                "mandatory": True,
                "testable": True,
                "source_refs": [requirement_source],
            }],
            "independent_review": {
                "reviewer_id": "agent:reviewer",
                "status": "completed",
                "reviewed_prd_sha256": inventory["prd_sha256"],
                "reviewed_source_set_sha256": reviewed_source_set_sha256,
                "source_unit_count": len(units),
                "conclusion": "no_deltas",
                "evidence": [requirement_source],
            },
            "asset_reviews": [],
            "review_deltas": [],
        }
        (directory / "01-需求提取.json").write_text(
            json.dumps(ledger, ensure_ascii=False, indent=2), encoding="utf-8"
        )
        (directory / "02-原子验收点清单.md").write_text(
            "# 退款｜原子验收点清单\n\n"
            "- 清单版本：1.0\n- 验收点总数：1\n- 状态：已冻结\n- 冻结版本/点数：1.0 / 1\n\n"
            "## 验收基线\n\nPRD 需求已冻结。\n\n"
            "## 原子拆分准则\n\n每点可独立验证。\n\n"
            "## 原子验收点\n\n"
            "| 验收点 ID | PRD 需求 ID | 前置条件 | 操作/触发 | 可观察预期结果 | PRD 位置 | 验证方式 |\n"
            "|---|---|---|---|---|---|---|\n"
            f"| AC-001 | REQ-001 | 用户已登录 | 提交退款申请 | 退款申请成功 | 01-产品需求.md#L{requirement_unit['start_line']} | API |\n\n"
            "## 需求覆盖检查\n\n"
            "| PRD 需求 ID | 需求摘要 | 原子验收点 ID | 覆盖结论/待澄清项 |\n"
            "|---|---|---|---|\n"
            "| REQ-001 | 申请退款 | AC-001 | 已覆盖 |\n\n"
            "## 测试夹具与实现验证TODO（非设计未决项）\n\n无待实现测试夹具。\n\n"
            "## 评审与冻结\n\n评审通过。\n\n"
            "## 变更记录\n\n无。\n\n"
            "## PRD验收场景映射\n\n当前 PRD 未列出独立验收场景行。\n\n"
            "| PRD 来源单元 ID | PRD 需求 ID | 原子验收点 ID | 映射说明 |\n"
            "|---|---|---|---|\n",
            encoding="utf-8",
        )
        acceptance_path = directory / "02-原子验收点清单.md"
        acceptance_path.write_text(
            DEVELOP.number_markdown_headings(acceptance_path.read_text(encoding="utf-8")),
            encoding="utf-8",
        )

    def test_check_prd_accepts_complete_frozen_pipeline(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)

            checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            self.assertIn("REQ-001", checked.stdout)
            self.assertIn("AC-001", checked.stdout)

    def test_check_prd_rejects_unresolved_mandatory_requirement(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            ledger_path = directory / "01-需求提取.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["requirements"][0]["status"] = "待澄清"
            ledger_path.write_text(json.dumps(ledger, ensure_ascii=False), encoding="utf-8")

            checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("REQ-001", checked.stderr + checked.stdout)

    def test_check_prd_reports_malformed_ledger_without_traceback(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            (directory / "01-需求提取.json").write_text("[]", encoding="utf-8")

            checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(checked.returncode, 0)
            self.assertNotIn("Traceback", checked.stderr + checked.stdout)
            self.assertIn("应为 object", checked.stderr + checked.stdout)

    def test_render_design_blocks_before_reading_design_when_prd_is_unresolved(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            ledger_path = directory / "01-需求提取.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["requirements"][0]["status"] = "待澄清"
            ledger_path.write_text(json.dumps(ledger, ensure_ascii=False), encoding="utf-8")

            rendered = subprocess.run(
                [sys.executable, str(SCRIPT), "render-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rendered.returncode, 0)
            self.assertIn("REQ-001", rendered.stderr + rendered.stdout)
            self.assertNotIn("详设 JSON 未通过", rendered.stderr + rendered.stdout)

    def test_check_design_reports_prd_blockers_even_when_design_files_are_missing(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            self._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            ledger_path = directory / "01-需求提取.json"
            ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
            ledger["requirements"][0]["status"] = "待澄清"
            ledger_path.write_text(json.dumps(ledger, ensure_ascii=False), encoding="utf-8")

            checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(checked.returncode, 0)
            self.assertIn("REQ-001", checked.stderr + checked.stdout)


class DesignTraceabilityTests(unittest.TestCase):
    def setUp(self):
        prd = ROOT / "develop" / "tests" / "fixtures" / "prd" / "complete.md"
        self.inventory = scan_prd(prd)
        req_source = next(unit["id"] for unit in self.inventory["units"] if unit["text"] == "订单支持部分退款。")
        self.ledger = {
            "requirements": [{
                "id": "REQ-001", "status": "已确认", "mandatory": True,
                "testable": True, "source_refs": [req_source],
            }]
        }
        self.acceptance_map = {"AC-001": {"REQ-001"}}
        self.design = {
            "tables": [], "apis": [], "rules": [], "flows": [], "pages": [], "quality_decisions": [],
            "coverage": [{
                "acceptance_id": "AC-001", "requirement_refs": ["REQ-001"],
                "source_refs": [req_source], "table_refs": [], "api_refs": [], "rule_refs": [],
                "flow_refs": [], "page_refs": [], "quality_refs": [],
            }],
        }

    def test_design_coverage_closes_ac_requirement_and_source_chain(self):
        errors = DEVELOP.validate_design_traceability(
            self.design, self.acceptance_map, self.ledger, self.inventory
        )
        self.assertEqual(errors, [])

    def test_design_coverage_rejects_missing_requirement_and_source_refs(self):
        self.design["coverage"][0]["requirement_refs"] = []
        self.design["coverage"][0]["source_refs"] = []
        errors = DEVELOP.validate_design_traceability(
            self.design, self.acceptance_map, self.ledger, self.inventory
        )
        self.assertTrue(any("REQ-001" in error for error in errors))
        self.assertTrue(any("source" in error.lower() or "来源" in error for error in errors))

    def test_object_and_field_sources_can_be_direct_while_coverage_closes_source_map(self):
        source_ids = [unit["id"] for unit in self.inventory["units"][:3]]
        ledger = {"requirements": [
            {"id": "REQ-001", "source_refs": source_ids[:2]},
            {"id": "REQ-002", "source_refs": source_ids[2:]},
        ]}
        acceptance_map = {"AC-001": {"REQ-001", "REQ-002"}}
        design = {
            "scope": {"features": [], "constraints": [], "assumptions": []},
            "coverage": [{
                "acceptance_id": "AC-001", "requirement_refs": ["REQ-001", "REQ-002"],
                "source_refs": source_ids, "glossary_refs": [], "table_refs": ["TBL-01"],
                "api_refs": [], "permission_refs": [], "rule_refs": [], "flow_refs": [],
                "diagram_refs": [], "page_refs": [], "dependency_refs": [], "reuse_refs": [],
                "quality_refs": [], "domain_refs": [], "verification": "核对对象与字段契约。",
                "test_ids": [], "not_applicable_reason": "",
            }],
            "tables": [{
                "id": "TBL-01", "requirement_refs": ["REQ-001", "REQ-002"],
                "source_refs": [source_ids[0]], "acceptance_refs": ["AC-001"],
                "fields": [{"name": "field_a", "requirement_refs": ["REQ-001"], "source_refs": [source_ids[1]]}],
            }],
            "flows": [{
                "id": "FLW-01", "requirement_refs": ["REQ-001", "REQ-002"],
                "source_refs": [source_ids[2]], "acceptance_refs": ["AC-001"],
                "test_scenarios": [{
                    "id": "TC-FLW-01", "acceptance_refs": ["AC-001"],
                    "requirement_refs": ["REQ-001", "REQ-002"], "source_refs": [source_ids[0]],
                }],
            }],
        }

        direct_sources = {"AC-001": {source_ids[0]}}
        design["coverage"][0]["source_refs"] = [source_ids[0]]
        errors = DEVELOP.validate_design_traceability(
            design, acceptance_map, ledger, self.inventory, direct_sources
        )

        self.assertEqual(errors, [])

        design["coverage"][0]["source_refs"] = [source_ids[1]]
        errors = DEVELOP.validate_design_traceability(
            design, acceptance_map, ledger, self.inventory, direct_sources
        )
        self.assertTrue(any("直接来源映射" in error for error in errors), errors)

    def test_acceptance_direct_source_map_uses_line_anchors_and_scenario_crosswalk(self):
        source = next(unit for unit in self.inventory["units"] if unit["text"] == "订单支持部分退款。")
        inventory = dict(self.inventory)
        inventory["units"] = [dict(unit, source_file="01-产品需求.md") for unit in self.inventory["units"]]
        parsed = {
            "acceptance_rows": [{
                "验收点 ID": "AC-001",
                "PRD 位置": f"01-产品需求.md#L{source['start_line']}",
            }],
            "scenario_rows": [{
                "PRD 来源单元 ID": source["id"],
                "原子验收点 ID": "AC-001",
            }],
        }

        direct_sources, errors = DEVELOP.extract_acceptance_source_refs(parsed, inventory)

        self.assertEqual(errors, [])
        self.assertEqual(direct_sources, {"AC-001": {source["id"]}})

    def test_duplicate_feature_ids_are_rejected_without_a_design_package(self):
        feature = {"id": "FEATURE-01", "requirement_refs": ["REQ-001"], "source_refs": [self.inventory["units"][0]["id"]]}
        self.design["scope"] = {"features": [feature, dict(feature)]}
        errors = DEVELOP.validate_design_traceability(self.design, self.acceptance_map, self.ledger, self.inventory)
        self.assertTrue(any("features" in error and "重复" in error for error in errors), errors)

    def test_design_acceptance_mapping_preserves_project_defined_ids(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            PrdCommandTests()._write_complete_case(directory)
            acceptance_path = directory / "02-原子验收点清单.md"
            source = acceptance_path.read_text(encoding="utf-8").replace("AC-001", "M-01-F01-A01")
            acceptance_path.write_text(source, encoding="utf-8")
            data = {"baseline": {"acceptance_file": acceptance_path.name, "acceptance_version": "1.0"}}
            mapping, errors = DEVELOP.extract_acceptance_points(directory, data)
        self.assertEqual(errors, [])
        self.assertIn("M-01-F01-A01", mapping)

    def test_design_baseline_binds_current_prd_ledger_and_frozen_acceptance(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            PrdCommandTests()._write_complete_case(directory)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            inventory = json.loads((directory / "01-PRD来源清单.json").read_text(encoding="utf-8"))
            ledger = json.loads((directory / "01-需求提取.json").read_text(encoding="utf-8"))
            acceptance_path = directory / "02-原子验收点清单.md"
            baseline = {
                "prd": "01-产品需求.md",
                "prd_sha256": inventory["prd_sha256"],
                "requirements_file": "01-需求提取.json",
                "requirements_version": ledger["schema_version"],
                "acceptance_file": "02-原子验收点清单.md",
                "acceptance_version": "1.0",
                "acceptance_sha256": hashlib.sha256(acceptance_path.read_bytes()).hexdigest(),
                "source_set_sha256": inventory["source_set_sha256"],
                "source_unit_count": len(inventory["units"]),
            }
            errors = DEVELOP.validate_design_baseline(directory, baseline, DEVELOP.load_manifest())
            self.assertEqual(errors, [])

            baseline["prd_sha256"] = "0" * 64
            errors = DEVELOP.validate_design_baseline(directory, baseline, DEVELOP.load_manifest())
            self.assertTrue(any("PRD SHA256" in error for error in errors))

            baseline["prd_sha256"] = inventory["prd_sha256"]
            baseline["source_set_sha256"] = "0" * 64
            errors = DEVELOP.validate_design_baseline(directory, baseline, DEVELOP.load_manifest())
            self.assertTrue(any("source-set SHA256" in error for error in errors), errors)

            baseline["source_set_sha256"] = inventory["source_set_sha256"]
            baseline["source_unit_count"] = len(inventory["units"]) + 1
            errors = DEVELOP.validate_design_baseline(directory, baseline, DEVELOP.load_manifest())
            self.assertTrue(any("source unit count" in error for error in errors), errors)

            legacy_baseline = dict(baseline)
            legacy_baseline.pop("source_set_sha256")
            legacy_baseline.pop("source_unit_count")
            errors = DEVELOP.validate_design_baseline(directory, legacy_baseline, DEVELOP.load_manifest())
            self.assertEqual(errors, [])

            legacy_baseline["source_set_sha256"] = inventory["source_set_sha256"]
            errors = DEVELOP.validate_design_baseline(directory, legacy_baseline, DEVELOP.load_manifest())
            self.assertTrue(any("必须同时提供" in error for error in errors), errors)

    def test_complete_design_json_renders_with_source_backed_traceability(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            PrdCommandTests()._write_complete_case(directory, arbitrary_source_prd=True)
            scanned = subprocess.run(
                [sys.executable, str(SCRIPT), "scan-prd", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(scanned.returncode, 0, scanned.stderr)
            inventory = json.loads((directory / "01-PRD来源清单.json").read_text(encoding="utf-8"))
            ledger = json.loads((directory / "01-需求提取.json").read_text(encoding="utf-8"))
            source_ref = ledger["requirements"][0]["source_refs"][0]
            acceptance_path = directory / "02-原子验收点清单.md"
            design = {
                "schema_version": 2,
                "project": "退款",
                "baseline": {
                    "prd": "01-产品需求.md",
                    "prd_sha256": inventory["prd_sha256"],
                    "requirements_file": "01-需求提取.json",
                    "requirements_version": ledger["schema_version"],
                    "acceptance_file": "02-原子验收点清单.md",
                    "acceptance_version": "1.0",
                    "acceptance_sha256": hashlib.sha256(acceptance_path.read_bytes()).hexdigest(),
                    "source_set_sha256": inventory["source_set_sha256"],
                    "source_unit_count": len(inventory["units"]),
                },
                "scope": {
                    "summary": "用户申请退款。",
                    "features": [{
                        "id": "FEATURE-01", "name": "退款申请", "responsibility": "受理退款",
                        "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    }],
                    "constraints": [], "assumptions": [], "non_goals": [],
                },
                "domain_objects": [{
                    "kind": "external_integration", "id": "INT-01", "name": "短信通道",
                    "summary": "生产短信渠道不可用时使用模拟通道并保留查询证据。",
                    "attributes": {"provider": "mock", "timeout_ms": 3000, "credential_source": "environment"},
                    "typed_refs": [{"kind": "apis", "id": "API-01"}],
                    "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    "acceptance_refs": ["AC-001"], "unreferenced_reason": "",
                }],
                "tables": [], "apis": [{
                    "id": "API-01", "name": "创建退款申请", "method": "POST", "path": "/refunds",
                    "permission": "已登录用户", "purpose": "创建申请", "request_fields": [], "response_fields": [],
                    "no_request_reason": "请求内容由调用上下文提供。", "no_response_reason": "返回仅使用通用确认语义。",
                    "errors": [], "error_summary": "使用标准校验错误。", "transaction": "单事务处理。",
                    "idempotency": "重复请求需识别。", "timeout": "系统默认超时。", "table_refs": [],
                    "rule_refs": [], "requirement_refs": [], "source_refs": [], "acceptance_refs": [],
                    "unreferenced_reason": "该接口仅用于跨文档引用关系。",
                }],
                "rules": [{
                    "id": "RULE-01", "name": "受理退款", "condition": "申请内容有效",
                    "result": "建立退款申请", "error_semantics": "无效请求返回校验错误",
                    "source_refs": [source_ref], "requirement_refs": ["REQ-001"],
                    "table_refs": [], "api_refs": [], "acceptance_refs": ["AC-001"],
                    "unreferenced_reason": "",
                }],
                "flows": [], "pages": [], "quality_decisions": [],
                "glossary": [], "permissions": [], "diagrams": [], "dependencies": [], "reuse_decisions": [],
                "coverage": [{
                    "acceptance_id": "AC-001", "requirement_refs": ["REQ-001"],
                    "source_refs": [source_ref], "glossary_refs": [], "table_refs": [], "api_refs": [],
                    "permission_refs": [],
                    "rule_refs": ["RULE-01"], "flow_refs": [], "page_refs": [],
                    "diagram_refs": [], "dependency_refs": [], "reuse_refs": [], "quality_refs": [],
                    "domain_refs": [{"kind": "external_integration", "id": "INT-01"}],
                    "verification": "API", "test_ids": ["TC-001"],
                    "not_applicable_reason": "",
                }],
                "zero_results": {
                    "tables": "不新增数据表。", "apis": "", "rules": "",
                    "flows": "不涉及多步骤流程。", "pages": "无前端页面。",
                    "quality_decisions": "无额外质量决策。", "domain_objects": "",
                },
            }
            design_path = directory / "03-详细设计.json"
            design_path.write_text(json.dumps(design, ensure_ascii=False, indent=2), encoding="utf-8")
            design_doc_path = directory / "03-详细设计.md"
            initial_doc = design_doc_path.read_text(encoding="utf-8")
            design_doc_path.write_text(initial_doc + "\n\n### 人工设计说明\n\n这里保留人工填写的方案理由。\n", encoding="utf-8")

            output = subprocess.run(
                [sys.executable, str(SCRIPT), "render-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(output.returncode, 0, output.stderr)
            output_path = directory / "03-详细设计.md"
            rendered = output_path.read_text(encoding="utf-8")
            self.assertTrue(rendered.startswith("# 退款｜退款\n"))
            self.assertIn("## 1 范围、约束与方案", rendered)
            self.assertIn("### 1.1 规模统计", rendered)
            self.assertIn("INT-01", rendered)
            self.assertIn("credential_source", rendered)
            self.assertIn("[API-01](#", rendered)
            self.assertIn("REQ-001", rendered)
            self.assertIn(source_ref, rendered)
            self.assertIn("这里保留人工填写的方案理由。", rendered)
            receipt_path = directory / "03-设计生成收据.json"
            self.assertTrue(receipt_path.is_file())
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            self.assertEqual(receipt["inputs"]["prd_sha256"], inventory["prd_sha256"])
            self.assertEqual(receipt["inputs"]["acceptance_sha256"], design["baseline"]["acceptance_sha256"])
            self.assertEqual(receipt["source_set_binding"], {
                "status": "VERIFIED",
                "sha256": inventory["source_set_sha256"],
                "unit_count": len(inventory["units"]),
            })
            self.assertEqual(receipt["output_sha256"], hashlib.sha256(rendered.encode("utf-8")).hexdigest())
            checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(checked.returncode, 0, checked.stderr)
            rerun = subprocess.run(
                [sys.executable, str(SCRIPT), "render-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(rerun.returncode, 0, rerun.stderr)
            self.assertEqual(output_path.read_text(encoding="utf-8"), rendered)
            self.assertEqual(receipt_path.read_text(encoding="utf-8"), json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")

            design_json_path = directory / DEVELOP.load_manifest()["structured_design"]["file"]
            legacy_design = json.loads(design_json_path.read_text(encoding="utf-8"))
            legacy_design["baseline"].pop("source_set_sha256")
            legacy_design["baseline"].pop("source_unit_count")
            design_json_path.write_text(json.dumps(legacy_design, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            legacy_receipt = DEVELOP.build_generation_receipt(
                directory, DEVELOP.load_manifest(), {output_path.name: rendered}
            )
            self.assertEqual(legacy_receipt["source_set_binding"]["status"], "LEGACY_UNBOUND")
            legacy_receipt["receipt_version"] = 2
            legacy_receipt.pop("source_set_binding")
            receipt_path.write_text(json.dumps(legacy_receipt, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            legacy_checked = subprocess.run(
                [sys.executable, str(SCRIPT), "check-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(legacy_checked.returncode, 0, legacy_checked.stderr)
            self.assertIn("source-set 未绑定", legacy_checked.stdout)

            tampered = rendered.replace("受理退款", "错误规则", 1)
            self.assertNotEqual(tampered, rendered)
            output_path.write_text(tampered, encoding="utf-8")
            rejected = subprocess.run(
                [sys.executable, str(SCRIPT), "check-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("与 JSON 正本渲染结果不一致", rejected.stderr + rejected.stdout)

            regenerated = subprocess.run(
                [sys.executable, str(SCRIPT), "render-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(regenerated.returncode, 0, regenerated.stderr)
            self.assertEqual(output_path.read_text(encoding="utf-8"), rendered)

            acceptance_path.write_text(acceptance_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
            stale = subprocess.run(
                [sys.executable, str(SCRIPT), "check-design", str(directory)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(stale.returncode, 0)
            self.assertIn("验收清单 SHA256", stale.stderr + stale.stdout)

    def test_design_package_renders_total_and_filtered_subdocument_and_checks_receipt(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            PrdCommandTests()._write_complete_case(directory)
            manifest = DEVELOP.load_manifest()
            (directory / manifest["design_output"]["file"]).unlink()
            subprocess.run([sys.executable, str(SCRIPT), "scan-prd", str(directory)], cwd=ROOT, check=True)
            inventory = json.loads((directory / "01-PRD来源清单.json").read_text(encoding="utf-8"))
            ledger = json.loads((directory / "01-需求提取.json").read_text(encoding="utf-8"))
            source_ref = ledger["requirements"][0]["source_refs"][0]
            acceptance_path = directory / "02-原子验收点清单.md"
            design = {
                "schema_version": 2,
                "project": "退款",
                "baseline": {
                    "prd": "01-产品需求.md", "prd_sha256": inventory["prd_sha256"],
                    "requirements_file": "01-需求提取.json", "requirements_version": ledger["schema_version"],
                    "acceptance_file": "02-原子验收点清单.md", "acceptance_version": "1.0",
                    "acceptance_sha256": hashlib.sha256(acceptance_path.read_bytes()).hexdigest(),
                },
                "scope": {
                    "summary": "用户申请退款。", "features": [{
                        "id": "FEATURE-01", "name": "退款申请", "responsibility": "受理退款",
                        "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    }], "constraints": [], "assumptions": [], "non_goals": [],
                },
                "domain_objects": [{
                    "kind": "external_integration", "id": "INT-01", "name": "短信通道",
                    "summary": "生产通道不可用时使用模拟通道。",
                    "attributes": {"provider": "mock", "timeout_ms": 3000, "credential_source": "environment"},
                    "typed_refs": [{"kind": "apis", "id": "API-01"}],
                    "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    "acceptance_refs": ["AC-001"], "unreferenced_reason": "",
                }],
                "tables": [], "apis": [{
                    "id": "API-01", "name": "创建退款申请", "method": "POST", "path": "/refunds",
                    "permission": "已登录用户", "purpose": "创建申请", "request_fields": [], "response_fields": [],
                    "no_request_reason": "请求内容由调用上下文提供。", "no_response_reason": "返回仅使用通用确认语义。",
                    "errors": [], "error_summary": "使用标准校验错误。", "transaction": "单事务处理。",
                    "idempotency": "重复请求需识别。", "timeout": "系统默认超时。", "table_refs": [],
                    "rule_refs": [], "requirement_refs": [], "source_refs": [], "acceptance_refs": [],
                    "unreferenced_reason": "该接口仅用于跨文档引用关系。",
                }],
                "rules": [
                    {"id": "RULE-01", "name": "受理退款", "condition": "申请内容有效", "result": "建立退款申请",
                    "error_semantics": "无效请求返回校验错误", "source_refs": [source_ref], "requirement_refs": ["REQ-001"],
                    "table_refs": [], "api_refs": ["API-01"], "acceptance_refs": ["AC-001"], "unreferenced_reason": ""},
                    {"id": "RULE-02", "name": "退款备注", "condition": "备注为空", "result": "保留空备注",
                     "error_semantics": "无", "source_refs": [source_ref], "requirement_refs": ["REQ-001"],
                     "table_refs": [], "api_refs": [], "acceptance_refs": [], "unreferenced_reason": "辅助规则由 RULE-01 覆盖。"},
                ],
                "flows": [{
                    "id": "FLOW-01", "name": "发起退款", "actor": "用户", "trigger": "用户提交申请",
                    "preconditions": [], "steps": [{"action": "提交申请", "result": "请求进入受理"}],
                    "state_transition": "无 → 待审核", "transaction_concurrency": "单事务处理",
                    "success": "生成退款申请", "failure_recovery": "返回可读错误并允许重试",
                    "table_refs": [], "api_refs": [], "rule_refs": ["RULE-01"],
                    "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    "acceptance_refs": ["AC-001"], "unreferenced_reason": "",
                }], "pages": [], "quality_decisions": [],
                "glossary": [], "permissions": [], "diagrams": [], "dependencies": [], "reuse_decisions": [],
                "coverage": [{
                    "acceptance_id": "AC-001", "requirement_refs": ["REQ-001"], "source_refs": [source_ref],
                    "glossary_refs": [], "table_refs": [], "api_refs": [], "permission_refs": [],
                    "rule_refs": ["RULE-01"], "flow_refs": ["FLOW-01"], "diagram_refs": [], "page_refs": [],
                    "dependency_refs": [], "reuse_refs": [],
                    "quality_refs": [], "domain_refs": [{"kind": "external_integration", "id": "INT-01"}],
                    "verification": "API", "test_ids": ["TC-001"], "not_applicable_reason": "",
                }],
                "zero_results": {"tables": "不新增数据表。", "apis": "", "rules": "", "flows": "",
                                 "pages": "无前端页面。", "quality_decisions": "无额外质量决策。", "domain_objects": ""},
            }
            (directory / "03-详细设计.json").write_text(json.dumps(design, ensure_ascii=False, indent=2), encoding="utf-8")
            package = {
                "schema_version": 1,
                "total": {"id": "total", "path": "03-详细设计.md", "template_id": "详细设计-模板",
                          "template_version": "1.2.0", "acceptance_ids": ["AC-001"],
                          "object_refs": {"features": ["FEATURE-01"], "tables": [], "apis": ["API-01"], "rules": ["RULE-01", "RULE-02"], "flows": ["FLOW-01"], "pages": [], "quality_decisions": [], "domain_objects": ["external_integration:INT-01"]}},
                "subdocuments": [
                    {"id": "refund", "path": "02-退款设计.md", "template_id": "详细设计-模板",
                     "template_version": "1.2.0", "acceptance_ids": ["AC-001"],
                     "object_refs": {"features": ["FEATURE-01"], "tables": [], "apis": [], "rules": ["RULE-01"], "flows": ["FLOW-01"], "pages": [], "quality_decisions": [], "domain_objects": ["external_integration:INT-01"]}},
                    {"id": "notes", "path": "02-备注规则设计.md", "template_id": "详细设计-模板",
                     "template_version": "1.2.0", "acceptance_ids": [],
                     "object_refs": {"features": [], "tables": [], "apis": ["API-01"], "rules": ["RULE-02"], "flows": [], "pages": [], "quality_decisions": [], "domain_objects": []}},
                ],
                "shared_object_refs": [],
            }
            (directory / "03-详设文档包.json").write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")

            rendered = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(rendered.returncode, 0, rendered.stderr)
            total_text = (directory / "03-详细设计.md").read_text(encoding="utf-8")
            sub_text = (directory / "02-退款设计.md").read_text(encoding="utf-8")
            notes_text = (directory / "02-备注规则设计.md").read_text(encoding="utf-8")
            self.assertIn("RULE-02", total_text)
            self.assertIn("INT-01", total_text)
            self.assertIn("RULE-01", sub_text)
            self.assertIn("INT-01", sub_text)
            self.assertIn("credential_source", sub_text)
            self.assertNotIn("RULE-02", sub_text)
            self.assertIn("FEATURE-01", sub_text)
            self.assertIn("FLOW-01", sub_text)
            target_anchor = re.search(r'<a id="([^"]+)"></a>RULE-01', sub_text)
            self.assertIsNotNone(target_anchor, "rule objects need stable link anchors")
            self.assertIn(f"[RULE-01](#{target_anchor.group(1)})", sub_text)
            api_anchor = re.search(r'<a id="([^"]+)"></a>\n### \d+(?:\.\d+)* API-01', notes_text)
            self.assertIsNotNone(api_anchor, "API objects need stable link anchors")
            linked_document = quote("02-备注规则设计.md", safe="/-._~")
            self.assertIn(f"[API-01]({linked_document}#{api_anchor.group(1)})", sub_text)
            self.assertIn("RULE-02", notes_text)
            self.assertNotIn("FEATURE-01", notes_text)
            receipt = json.loads((directory / "03-设计生成收据.json").read_text(encoding="utf-8"))
            self.assertEqual(set(receipt["outputs"]), {"03-详细设计.md", "02-退款设计.md", "02-备注规则设计.md"})

            checked = subprocess.run([sys.executable, str(SCRIPT), "check-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(checked.returncode, 0, checked.stderr)
            package_path = directory / "03-详设文档包.json"
            package_bytes = package_path.read_bytes()
            package["subdocuments"][0]["object_refs"]["rules"] = []
            package["subdocuments"][1]["object_refs"]["rules"].append("RULE-01")
            package_path.write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")
            invalid_coverage = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(invalid_coverage.returncode, 0)
            self.assertIn("未在本子文档归属", invalid_coverage.stderr + invalid_coverage.stdout)
            package_path.write_bytes(package_bytes)
            package = json.loads(package_bytes.decode("utf-8"))

            package["subdocuments"][0]["template_version"] = "0.0.0"
            package_path.write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")
            before_invalid_render = {
                name: (directory / name).read_bytes()
                for name in ("03-详细设计.md", "02-退款设计.md", "02-备注规则设计.md")
            }
            invalid = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("template_version 不匹配", invalid.stderr + invalid.stdout)
            for name, content in before_invalid_render.items():
                self.assertEqual((directory / name).read_bytes(), content)
            package_path.write_bytes(package_bytes)
            package["subdocuments"][0]["template_version"] = "1.2.0"

            package_path.unlink()
            package_path.mkdir()
            bad_package_path = subprocess.run([sys.executable, str(SCRIPT), "check-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(bad_package_path.returncode, 0)
            self.assertIn("不是普通文件", bad_package_path.stderr + bad_package_path.stdout)
            package_path.rmdir()
            package_path.write_bytes(package_bytes)

            package["subdocuments"][0]["path"] = "03-详细设计.MD"
            package_path.write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")
            alias = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(alias.returncode, 0)
            self.assertIn("冲突", alias.stderr + alias.stdout)
            package_path.write_bytes(package_bytes)

            package["subdocuments"][0]["path"] = "01-需求提取.json"
            package_path.write_text(json.dumps(package, ensure_ascii=False, indent=2), encoding="utf-8")
            collision = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(collision.returncode, 0)
            self.assertIn(".md", collision.stderr + collision.stdout)
            package_path.write_bytes(package_bytes)

            tampered_text = sub_text.replace("RULE-01", "RULE-X", 1)
            self.assertNotEqual(tampered_text, sub_text)
            (directory / "02-退款设计.md").write_text(tampered_text, encoding="utf-8")
            tampered = subprocess.run([sys.executable, str(SCRIPT), "check-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(tampered.returncode, 0)
            self.assertIn("渲染结果不一致", tampered.stderr + tampered.stdout)
            repaired = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertEqual(repaired.returncode, 0, repaired.stderr)

            receipt_path = directory / "03-设计生成收据.json"
            receipt_path.unlink()
            external_receipt = Path(tmp) / "receipt-target.json"
            external_receipt.write_text("leave unchanged", encoding="utf-8")
            receipt_path.symlink_to(external_receipt)
            outputs_before_symlink_attempt = {
                name: (directory / name).read_bytes()
                for name in ("03-详细设计.md", "02-退款设计.md", "02-备注规则设计.md")
            }
            unsafe = subprocess.run([sys.executable, str(SCRIPT), "render-design", str(directory)], cwd=ROOT, capture_output=True, text=True)
            self.assertNotEqual(unsafe.returncode, 0)
            self.assertIn("符号链接", unsafe.stderr + unsafe.stdout)
            self.assertEqual(external_receipt.read_text(encoding="utf-8"), "leave unchanged")
            for name, content in outputs_before_symlink_attempt.items():
                self.assertEqual((directory / name).read_bytes(), content)


class ReferenceLinkTests(unittest.TestCase):
    def test_legacy_package_accepts_global_feature_spanning_child_acceptance_sets(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = DEVELOP.load_manifest()
            core_refs = {kind: [] for kind in ("tables", "apis", "rules", "flows", "pages", "quality_decisions")}
            package = {
                "schema_version": 1,
                "total": {"id": "total", "path": "03-详细设计.md", "template_id": "详细设计-模板",
                          "template_version": "1.2.0", "acceptance_ids": ["M-01-F01-A01", "M-01-F02-A01"],
                          "object_refs": dict(core_refs)},
                "subdocuments": [
                    {"id": "M01", "path": "modules/M01.md", "template_id": "详细设计-模板",
                     "template_version": "1.2.0", "acceptance_ids": ["M-01-F01-A01"], "object_refs": dict(core_refs)},
                    {"id": "M02", "path": "modules/M02.md", "template_id": "详细设计-模板",
                     "template_version": "1.2.0", "acceptance_ids": ["M-01-F02-A01"], "object_refs": dict(core_refs)},
                ],
                "shared_object_refs": [],
            }
            (directory / manifest["design_output"]["legacy_file"]).write_text(
                json.dumps(package, ensure_ascii=False), encoding="utf-8"
            )
            empty_coverage = {
                "requirement_refs": [], "source_refs": [], "glossary_refs": [], "table_refs": [],
                "api_refs": [], "permission_refs": [], "rule_refs": [], "flow_refs": [],
                "diagram_refs": [], "page_refs": [], "dependency_refs": [], "reuse_refs": [],
                "quality_refs": [], "domain_refs": [],
            }
            data = {
                "scope": {"features": [{"id": "FEATURE-01", "name": "基础能力", "responsibility": "全局功能域",
                                         "requirement_refs": ["REQ-01", "REQ-02"], "source_refs": []}]},
                "tables": [], "apis": [], "rules": [], "flows": [], "pages": [], "quality_decisions": [],
                "domain_objects": [],
                "glossary": [], "permissions": [], "diagrams": [], "dependencies": [], "reuse_decisions": [],
                "coverage": [
                    {**empty_coverage, "acceptance_id": "M-01-F01-A01", "requirement_refs": ["REQ-01"]},
                    {**empty_coverage, "acceptance_id": "M-01-F02-A01", "requirement_refs": ["REQ-02"]},
                ],
            }

            normalized, errors = DEVELOP.load_valid_design_package(
                directory, manifest, data, {"M-01-F01-A01", "M-01-F02-A01"}
            )

        self.assertEqual(errors, [])
        self.assertIn({"kind": "features", "id": "FEATURE-01"}, normalized["shared_object_refs"])

    def test_reference_link_resolves_to_object_owner_in_another_subdocument(self):
        design = {
            "scope": {"features": []},
            "tables": [{"id": "TABLE-01"}], "apis": [], "rules": [], "flows": [], "pages": [],
            "quality_decisions": [],
        }
        object_refs = {kind: [] for kind in ("features", "tables", "apis", "rules", "flows", "pages", "quality_decisions", "domain_objects")}
        object_refs["tables"] = ["TABLE-01"]
        package = {
            "total": {"path": "03-详细设计.md"},
            "subdocuments": [{"id": "data", "path": "modules/data.md", "object_refs": object_refs}],
        }
        context = DEVELOP.build_reference_context(design, package, "modules/workflow/main.md")

        rendered = DEVELOP.markdown_reference("tables", "TABLE-01", context)

        anchor = DEVELOP.design_object_anchor("tables", "TABLE-01")
        self.assertEqual(rendered, f"[TABLE-01](../data.md#{anchor})")

    def test_table_field_reference_uses_parent_table_owner(self):
        design = {
            "scope": {"features": []},
            "tables": [{"id": "TABLE-01", "fields": [{"name": "refund_id"}]}],
            "apis": [], "rules": [], "flows": [], "pages": [], "quality_decisions": [],
        }
        object_refs = {kind: [] for kind in ("features", "tables", "apis", "rules", "flows", "pages", "quality_decisions", "domain_objects")}
        object_refs["tables"] = ["TABLE-01"]
        package = {
            "total": {"path": "03-详细设计.md"},
            "subdocuments": [{"id": "data", "path": "modules/data.md", "object_refs": object_refs}],
        }
        context = DEVELOP.build_reference_context(design, package, "modules/workflow/main.md")

        rendered = DEVELOP.markdown_reference("table_fields", "TABLE-01.refund_id", context)

        anchor = DEVELOP.design_object_anchor("table_fields", "TABLE-01.refund_id")
        self.assertEqual(rendered, f"[TABLE-01.refund_id](../data.md#{anchor})")

    def test_typed_domain_object_reference_uses_encoded_pair_once(self):
        design = {
            "scope": {"features": []}, "tables": [], "apis": [], "rules": [], "flows": [],
            "pages": [], "quality_decisions": [],
            "domain_objects": [{
                "kind": "external_integration", "id": "INT-01", "attributes": {},
            }],
        }
        context = DEVELOP.build_reference_context(design, None, "03-详细设计.md")
        object_key = DEVELOP.domain_object_key("external_integration", "INT-01")

        rendered = DEVELOP.markdown_typed_reference("domain_objects", object_key, context)

        anchor = DEVELOP.design_object_anchor("domain_objects", object_key)
        self.assertEqual(rendered, f"[{object_key}](#{anchor})")


class SectionNumberingTests(unittest.TestCase):
    def test_heading_numbering_is_hierarchical_idempotent_and_skips_fenced_code(self):
        source = (
            "# 标题\n## 章节一\n### 小节一\n#### 子节一\n### 小节二\n"
            "## 章节二\n## 2026 年目标\n```markdown\n## 示例标题\n```\n"
        )
        expected = (
            "# 标题\n## 1 章节一\n### 1.1 小节一\n#### 1.1.1 子节一\n### 1.2 小节二\n"
            "## 2 章节二\n## 3 2026 年目标\n```markdown\n## 示例标题\n```\n"
        )
        numbered = DEVELOP.number_markdown_headings(source)
        self.assertEqual(numbered, expected)
        self.assertEqual(DEVELOP.number_markdown_headings(numbered), expected)

    def test_init_numbers_all_generated_markdown_sections_and_checker_accepts_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = DEVELOP.load_manifest()
            DEVELOP.render_skeleton(directory, manifest, "编号样例")

            prd = (directory / "01-产品需求.md").read_text(encoding="utf-8")
            review = (directory / "04-详细设计评审.md").read_text(encoding="utf-8")
            self.assertTrue(prd.startswith("# 编号样例｜产品需求文档\n"))
            self.assertIn("## 1 背景与问题", prd)
            self.assertIn("## 2 目标与范围", prd)
            self.assertIn("## 1 评审基线", review)
            self.assertEqual(DEVELOP.check_documents(directory, manifest), [])
            initialized_design = json.loads((directory / "03-详细设计.json").read_text(encoding="utf-8"))
            self.assertIn("source_set_sha256", initialized_design["baseline"])
            self.assertIn("source_unit_count", initialized_design["baseline"])
            review_path = directory / "04-详细设计评审.md"
            review_path.write_text(review.replace("## 1 评审基线", "## 评审基线", 1), encoding="utf-8")
            errors = DEVELOP.check_documents(directory, manifest)
            self.assertTrue(any("04-详细设计评审.md：章节编号缺失或不一致" in error for error in errors), errors)

    def test_check_documents_accepts_user_prd_with_arbitrary_unNumbered_headings(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = DEVELOP.load_manifest()
            DEVELOP.render_skeleton(directory, manifest, "外部PRD")
            (directory / "01-产品需求.md").write_text(
                "# Customer PRD\n\n## Domain model\n\nArbitrary input headings are valid.\n\n"
                "## Acceptance scenarios\n\nNo develop template numbering is required.\n",
                encoding="utf-8",
            )

            errors = DEVELOP.check_documents(directory, manifest)

            self.assertEqual(errors, [])

    def test_check_documents_still_requires_numbered_acceptance_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = DEVELOP.load_manifest()
            DEVELOP.render_skeleton(directory, manifest, "验收清单边界")
            acceptance_path = directory / "02-原子验收点清单.md"
            acceptance = acceptance_path.read_text(encoding="utf-8")
            acceptance_path.write_text(acceptance.replace("## 1 验收基线", "## 验收基线", 1), encoding="utf-8")

            errors = DEVELOP.check_documents(directory, manifest)

            self.assertTrue(any("02-原子验收点清单.md：章节编号缺失或不一致" in error for error in errors), errors)

    def test_check_documents_still_requires_fixed_acceptance_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            manifest = DEVELOP.load_manifest()
            DEVELOP.render_skeleton(directory, manifest, "验收章节契约")
            acceptance_path = directory / "02-原子验收点清单.md"
            acceptance = acceptance_path.read_text(encoding="utf-8")
            acceptance_path.write_text(acceptance.replace("## 1 验收基线", "## 1 Invented section", 1), encoding="utf-8")

            errors = DEVELOP.check_documents(directory, manifest)

            self.assertTrue(any("02-原子验收点清单.md：二级标题与文档清单.json不一致" in error for error in errors), errors)

    def test_imported_acceptance_is_emitted_with_numbered_fixed_sections(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            source = directory / "legacy-acceptance.md"
            source.write_text(
                "# Legacy acceptance\n\n"
                "### 功能 F-01：示例能力\n\n"
                "| 验收点 ID | 验收点描述 | 验证方式 | PRD原文锚点 | 状态 |\n"
                "|---|---|---|---|---|\n"
                "| F-01-A01 | 保存后可查看结果 | UI | PRD L10 | FROZEN |\n",
                encoding="utf-8",
            )
            imported = subprocess.run(
                [sys.executable, str(SCRIPT), "import-acceptance", str(directory), "--source", str(source)],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
            self.assertEqual(imported.returncode, 0, imported.stderr)
            acceptance = (directory / "02-原子验收点清单.md").read_text(encoding="utf-8")
            self.assertIn("## 1 验收基线", acceptance)
            self.assertIn("## 3 原子验收点", acceptance)
            self.assertEqual(acceptance, DEVELOP.number_markdown_headings(acceptance))
            expected_sections = [
                "验收基线", "原子拆分准则", "原子验收点", "需求覆盖检查",
                "测试夹具与实现验证TODO（非设计未决项）", "评审与冻结", "变更记录", "PRD验收场景映射",
            ]
            actual_sections = [
                DEVELOP.normalize_heading(line[3:].strip())
                for line in acceptance.splitlines()
                if line.startswith("## ")
            ]
            self.assertEqual(actual_sections, expected_sections)


class TemplateMigrationTests(unittest.TestCase):
    def test_migrates_v11_design_markdown_without_losing_manual_prose(self):
        manifest = DEVELOP.load_manifest()
        template_path = Path(__file__).resolve().parents[1] / "模板" / "03-详细设计.md"
        old = template_path.read_text(encoding="utf-8").replace(
            "develop:template-version:1.3.0", "develop:template-version:1.1.0"
        )
        for block in ("GLOSSARY_BODY", "PERMISSIONS_BODY", "DIAGRAMS_BODY", "DEPENDENCIES_BODY", "DOMAIN_OBJECTS_BODY"):
            begin = f"<!-- develop:begin:{block} -->"
            end = f"<!-- develop:end:{block} -->"
            marker_start = old.index(begin)
            section_start = old.rfind("\n## ", 0, marker_start) + 1
            section_end = old.index(end, marker_start) + len(end)
            while section_end < len(old) and old[section_end] == "\n":
                section_end += 1
            old = old[:section_start] + old[section_end:]
        old = old.replace("REUSE_QUALITY_BODY", "QUALITY_BODY")
        old = old.replace("## 复用与质量决策", "## 质量与边界")
        old = old.replace("## 关键流程、业务规则与流程测试场景", "## 关键流程与业务规则")
        new_section = (
            "## 领域扩展对象与集成\n\n"
            "<!-- develop:begin:DOMAIN_OBJECTS_BODY -->\n{{DOMAIN_OBJECTS_BODY}}\n"
            "<!-- develop:end:DOMAIN_OBJECTS_BODY -->\n\n"
        )
        old = old.replace(new_section, "") + "\n人工设计说明。\n"

        migrated = DEVELOP.migrate_design_template(old, manifest)

        self.assertIn("develop:template-version:1.3.0", migrated)
        self.assertIn(new_section.strip(), migrated)
        self.assertIn("人工设计说明。", migrated)
        self.assertEqual(DEVELOP.migrate_design_template(migrated, manifest), migrated)


class SchemaValidationTests(unittest.TestCase):
    def test_source_registry_schema_accepts_legacy_design_reference_role(self):
        schema_path = ROOT / "develop" / "契约" / "需求来源配置数据结构.json"
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        config = {
            "schema_version": 1,
            "sources": [{
                "path": "docs/reference/legacy-design-comparison.md",
                "role": "legacy_design_reference",
                "required": False,
                "description": "只用于比较旧目标详设，不作为 PRD 规范来源。",
            }],
        }

        self.assertEqual(DEVELOP.validate_schema(config, schema, schema), [])

    def test_requirement_inventory_schema_accepts_legacy_design_reference_units(self):
        schema = json.loads(
            (ROOT / "develop" / "契约" / "需求提取数据结构.json").read_text(encoding="utf-8")
        )
        inventory = {
            "prd_sha256": "a" * 64,
            "parser_version": "2",
            "units": [{
                "id": "SRC-aaaaaaaaaaaaaaaaaaaa",
                "kind": "paragraph",
                "heading_path": [],
                "start_line": 1,
                "end_line": 1,
                "text": "Legacy comparison only.",
                "table_headers": [],
                "source_file": "docs/reference/legacy-design-comparison.md",
                "source_role": "legacy_design_reference",
            }],
        }

        self.assertEqual(
            DEVELOP.validate_schema(inventory, {"$ref": "#/$defs/inventory"}, schema), []
        )

    def test_schema_validator_enforces_pattern_integer_bounds_and_unique_items(self):
        schema = {
            "type": "object",
            "required": ["sha", "line", "ids"],
            "additionalProperties": False,
            "properties": {
                "sha": {"type": "string", "pattern": "^[a-f0-9]{4}$"},
                "line": {"type": "integer", "minimum": 1},
                "ids": {"type": "array", "uniqueItems": True, "items": {"type": "string"}},
            },
        }
        errors = DEVELOP.validate_schema(
            {"sha": "xyz", "line": 0, "ids": ["A", "A"]}, schema, schema
        )
        self.assertTrue(any("pattern" in error for error in errors))
        self.assertTrue(any("minimum" in error for error in errors))
        self.assertTrue(any("uniqueItems" in error for error in errors))

    def test_schema_validator_enforces_conditional_and_any_of_contracts(self):
        schema = {
            "type": "object",
            "properties": {
                "classification": {"enum": ["requirement", "context"]},
                "reason": {"type": "string", "minLength": 1},
                "asset_sha256": {
                    "anyOf": [
                        {"type": "string", "pattern": "^[a-f0-9]{4}$"},
                        {"type": "null"},
                    ]
                },
            },
            "allOf": [{
                "if": {"properties": {"classification": {"const": "context"}}},
                "then": {"required": ["reason"]},
            }],
        }
        missing_reason = DEVELOP.validate_schema(
            {"classification": "context", "asset_sha256": None}, schema, schema
        )
        invalid_asset_hash = DEVELOP.validate_schema(
            {"classification": "requirement", "asset_sha256": "bad"}, schema, schema
        )
        self.assertTrue(any("reason" in error for error in missing_reason))
        self.assertTrue(any("anyOf" in error for error in invalid_asset_hash))
        self.assertEqual(
            DEVELOP.validate_schema(
                {"classification": "requirement", "asset_sha256": None}, schema, schema
            ),
            [],
        )


class AnchoredRenderingTests(unittest.TestCase):
    def test_renderer_preserves_text_outside_blocks_and_replaces_each_block(self):
        text = (
            "<!-- develop:template-id:详细设计-模板 -->\n"
            "<!-- develop:template-version:1.1.0 -->\n"
            "Human architecture rationale.\n"
            "<!-- develop:begin:SCOPE_BODY -->old scope<!-- develop:end:SCOPE_BODY -->\n"
            "## More notes\nManual note.\n"
            "<!-- develop:begin:TABLES_BODY -->old tables<!-- develop:end:TABLES_BODY -->\n"
        )
        rendered = DEVELOP.render_anchored_blocks(
            text,
            {"SCOPE_BODY": "new scope", "TABLES_BODY": "new tables"},
            ["SCOPE_BODY", "TABLES_BODY"],
            "详细设计-模板",
            "1.1.0",
        )
        self.assertIn("Human architecture rationale.", rendered)
        self.assertIn("Manual note.", rendered)
        self.assertIn("new scope", rendered)
        self.assertIn("new tables", rendered)
        self.assertNotIn("old scope", rendered)

    def test_renderer_fails_closed_on_missing_duplicate_nested_or_unknown_blocks(self):
        valid = (
            "<!-- develop:template-id:详细设计-模板 -->\n"
            "<!-- develop:template-version:1.1.0 -->\n"
            "<!-- develop:begin:SCOPE_BODY -->x<!-- develop:end:SCOPE_BODY -->"
        )
        cases = [
            valid.replace("<!-- develop:end:SCOPE_BODY -->", ""),
            valid + "\n<!-- develop:begin:SCOPE_BODY -->x<!-- develop:end:SCOPE_BODY -->",
            valid.replace("<!-- develop:begin:SCOPE_BODY -->", "<!-- develop:begin:UNKNOWN -->"),
            valid.replace("x", "<!-- develop:begin:TABLES_BODY -->x<!-- develop:end:TABLES_BODY -->"),
        ]
        for malformed in cases:
            with self.subTest(malformed=malformed), self.assertRaises(ValueError):
                DEVELOP.render_anchored_blocks(
                    malformed, {"SCOPE_BODY": "new"}, ["SCOPE_BODY"], "详细设计-模板", "1.1.0"
                )

    def test_renderer_rejects_template_identity_drift(self):
        text = (
            "<!-- develop:template-id:other -->\n"
            "<!-- develop:template-version:1.1.0 -->\n"
            "<!-- develop:begin:SCOPE_BODY -->x<!-- develop:end:SCOPE_BODY -->"
        )
        with self.assertRaisesRegex(ValueError, "template-id"):
            DEVELOP.render_anchored_blocks(
                text, {"SCOPE_BODY": "new"}, ["SCOPE_BODY"], "详细设计-模板", "1.1.0"
            )

if __name__ == "__main__":
    unittest.main()
