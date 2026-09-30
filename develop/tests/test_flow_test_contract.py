"""Structured flow test scenarios remain traceable and renderable."""

import importlib.util
import json
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "develop" / "脚本" / "develop.py"
SCHEMA_PATH = ROOT / "develop" / "契约" / "详设数据结构.json"
SPEC = importlib.util.spec_from_file_location("develop_flow_contract", SCRIPT)
DEVELOP = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = DEVELOP
SPEC.loader.exec_module(DEVELOP)
SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "脚本"))
from design_package import OBJECT_KINDS, validate_design_package


def flow(test_scenarios=None, test_anchor=None):
    result = {
        "id": "FLW-001",
        "name": "登录流程",
        "actor": "用户",
        "trigger": "用户提交登录",
        "preconditions": ["用户已存在"],
        "steps": [{"action": "提交凭据", "result": "认证结果返回"}],
        "state_transition": "未登录到已登录或保持未登录",
        "transaction_concurrency": "单次认证请求",
        "success": "认证成功后建立会话",
        "failure_recovery": "失败时保持未登录并允许重试",
        "table_refs": [],
        "api_refs": [],
        "rule_refs": [],
        "requirement_refs": ["REQ-001"],
        "source_refs": ["SRC-001"],
        "acceptance_refs": ["AC-001"],
        "unreferenced_reason": "",
    }
    if test_scenarios is not None:
        result["test_scenarios"] = test_scenarios
    if test_anchor is not None:
        result["test_anchor"] = test_anchor
    return result


def traceability_fixture(flow_object):
    coverage = {
        "acceptance_id": "AC-001",
        "requirement_refs": ["REQ-001"],
        "source_refs": ["SRC-001"],
        "glossary_refs": [],
        "table_refs": [],
        "api_refs": [],
        "permission_refs": [],
        "rule_refs": [],
        "flow_refs": ["FLW-001"],
        "diagram_refs": [],
        "page_refs": [],
        "dependency_refs": [],
        "reuse_refs": [],
        "quality_refs": [],
        "domain_refs": [],
        "verification": "用户提交凭据并观察认证结果",
        "test_ids": [],
        "not_applicable_reason": "",
    }
    data = {
        "scope": {"features": [], "constraints": [], "assumptions": []},
        "coverage": [coverage],
        "flows": [flow_object],
        "domain_objects": [],
    }
    ledger = {"requirements": [{"id": "REQ-001", "source_refs": ["SRC-001"]}]}
    inventory = {"units": [{"id": "SRC-001"}]}
    return data, ledger, inventory


class FlowTestContractTests(unittest.TestCase):
    def test_legacy_flow_without_test_fields_remains_valid(self):
        errors = DEVELOP.validate_schema(flow(), SCHEMA["definitions"]["flow"], SCHEMA)
        self.assertEqual([], errors)

    def test_flow_accepts_structured_test_scenario_and_anchor(self):
        item = flow(
            test_anchor="m01-flow-login",
            test_scenarios=[{
                "id": "TS-FLW-001-01",
                "given": "用户未登录且账号有效",
                "when": "提交有效凭据",
                "then": "建立会话并进入平台",
                "requirement_refs": ["REQ-001"],
                "source_refs": ["SRC-001"],
                "acceptance_refs": ["AC-001"],
            }],
        )
        errors = DEVELOP.validate_schema(item, SCHEMA["definitions"]["flow"], SCHEMA)
        self.assertEqual([], errors)

    def test_flow_accepts_diagram_refs_and_summary_renderer_links_them(self):
        item = flow(test_anchor="m01-flow-login")
        item["diagram_refs"] = ["DIA-FLW-001"]
        errors = DEVELOP.validate_schema(item, SCHEMA["definitions"]["flow"], SCHEMA)
        self.assertEqual([], errors)

        zero = {key: "无对象" for key in (
            "glossary", "tables", "apis", "permissions", "rules", "flows", "diagrams",
            "pages", "dependencies", "reuse_decisions", "quality_decisions", "domain_objects",
        )}
        data = {
            "project": "流程图链接渲染测试",
            "scope": {"summary": "流程图链接渲染测试", "features": [], "constraints": [], "assumptions": [], "non_goals": []},
            "zero_results": zero,
            "glossary": [], "tables": [], "apis": [], "permissions": [], "rules": [],
            "flows": [item], "diagrams": [{
                "id": "DIA-FLW-001", "title": "登录流程", "kind": "sequence", "format": "mermaid",
                "body": "sequenceDiagram\nUser->>Service: Login",
                "typed_refs": [{"kind": "flows", "id": "FLW-001"}],
                "requirement_refs": ["REQ-001"], "source_refs": ["SRC-001"],
                "acceptance_refs": ["AC-001"], "unreferenced_reason": "",
            }], "pages": [], "dependencies": [],
            "reuse_decisions": [], "quality_decisions": [], "domain_objects": [], "coverage": [],
        }
        key_flow = ("flows", "FLW-001")
        key_diagram = ("diagrams", "DIA-FLW-001")
        diagram_anchor = DEVELOP.design_object_anchor_markup("diagrams", "DIA-FLW-001").split('"')[1]
        context = {
            "catalog": {
                key_flow: {"anchor": "flow-login", "owners": ["03-详细设计.md"]},
                key_diagram: {"anchor": diagram_anchor, "owners": ["03-详细设计.md"]},
            },
            "current_path": "03-详细设计.md",
            "present": {key_flow, key_diagram},
        }
        rendered = DEVELOP.render_design_body(data, reference_context=context, summary=True)["RULES_FLOWS_BODY"]
        self.assertIn(f"[DIA-FLW-001](#{diagram_anchor})", rendered)
        self.assertIn(f'<a id="{diagram_anchor}"></a>', DEVELOP.render_design_body(data, reference_context=context, summary=True)["DIAGRAMS_BODY"])

    def test_flow_diagram_ref_requires_diagram_typed_ref_back_to_flow(self):
        item = flow()
        item["diagram_refs"] = ["DIA-FLW-001"]
        diagram = {"id": "DIA-FLW-001", "typed_refs": []}

        errors = DEVELOP.validate_flow_diagram_links([item], [diagram])

        self.assertTrue(any("flows/FLW-001" in error and "未反向声明" in error for error in errors))

    def test_new_flow_with_scenarios_requires_diagram_refs(self):
        item = flow(test_scenarios=[{
            "id": "TS-FLW-001-01",
            "given": "用户未登录",
            "when": "提交有效凭据",
            "then": "建立会话",
            "requirement_refs": ["REQ-001"],
            "source_refs": ["SRC-001"],
            "acceptance_refs": ["AC-001"],
        }])
        diagram = {
            "id": "DIA-FLW-001",
            "typed_refs": [{"kind": "flows", "id": "FLW-001"}],
        }

        legacy_ids = DEVELOP.legacy_flows_without_diagram_refs([item])
        errors = DEVELOP.validate_flow_diagram_links([item], [diagram])

        self.assertEqual(set(), legacy_ids)
        self.assertTrue(any("test contract" in error.lower() or "测试契约" in error for error in errors))
        self.assertTrue(any("diagrams/DIA-FLW-001" in error for error in errors))

    def test_declared_empty_test_scenarios_is_still_new_flow_schema(self):
        item = flow(test_scenarios=[])

        legacy_ids = DEVELOP.legacy_flows_without_diagram_refs([item])
        errors = DEVELOP.validate_flow_diagram_links([item], [], legacy_ids)

        self.assertEqual(set(), legacy_ids)
        self.assertTrue(any("测试契约" in error for error in errors))

    def test_legacy_flow_without_diagram_refs_remains_compatible(self):
        item = flow()
        diagram = {
            "id": "DIA-FLW-001",
            "typed_refs": [{"kind": "flows", "id": "FLW-001"}],
        }

        legacy_ids = DEVELOP.normalize_legacy_flow_diagram_refs([item])
        errors = DEVELOP.validate_flow_diagram_links([item], [diagram], legacy_ids)

        self.assertEqual({"FLW-001"}, legacy_ids)
        self.assertEqual([], item["diagram_refs"])
        self.assertEqual([], errors)

    def test_legacy_flow_capture_precedes_defaulting_new_test_fields(self):
        old_flow = flow()
        new_schema_flow = flow(test_scenarios=[])
        new_schema_flow["id"] = "FLW-002"

        legacy_ids = DEVELOP.normalize_legacy_flow_diagram_refs([old_flow, new_schema_flow])

        self.assertEqual({"FLW-001"}, legacy_ids)
        self.assertEqual([], old_flow["diagram_refs"])
        self.assertEqual([], new_schema_flow["diagram_refs"])

    def test_flow_scenario_requires_source_refs_for_its_requirement(self):
        item = flow(test_scenarios=[{
            "id": "TS-FLW-001-01",
            "given": "用户未登录",
            "when": "提交有效凭据",
            "then": "建立会话",
            "requirement_refs": ["REQ-001"],
            "source_refs": [],
            "acceptance_refs": ["AC-001"],
        }])
        data, ledger, inventory = traceability_fixture(item)
        errors = DEVELOP.validate_design_traceability(
            data, {"AC-001": {"REQ-001"}}, ledger, inventory
        )
        self.assertTrue(any("test_scenarios/TS-FLW-001-01" in error and "来源" in error for error in errors))

    def test_flow_test_renderer_includes_scenario_anchor_and_steps(self):
        item = flow(
            test_anchor="m01-flow-login",
            test_scenarios=[{
                "id": "TS-FLW-001-01",
                "given": "用户未登录",
                "when": "提交有效凭据",
                "then": "建立会话",
                "requirement_refs": ["REQ-001"],
                "source_refs": ["SRC-001"],
                "acceptance_refs": ["AC-001"],
            }],
        )
        rendered = DEVELOP.render_flow_test_scenarios(item)
        self.assertIn("m01-flow-login", rendered)
        self.assertIn("TS-FLW-001-01", rendered)
        self.assertIn("用户未登录", rendered)
        self.assertIn("提交有效凭据", rendered)
        self.assertIn("建立会话", rendered)

    def test_package_owner_must_include_flow_scenario_acceptance(self):
        item = flow(test_scenarios=[{
            "id": "TS-FLW-001-01",
            "given": "用户未登录",
            "when": "提交有效凭据",
            "then": "建立会话",
            "requirement_refs": ["REQ-001"],
            "source_refs": ["SRC-001"],
            "acceptance_refs": ["AC-001"],
        }])
        total_refs = {kind: [] for kind in OBJECT_KINDS}
        total_refs["flows"] = ["FLW-001"]
        total = {
            "id": "total", "path": "design.md", "template_id": "t", "template_version": "1",
            "acceptance_ids": ["AC-001"], "object_refs": total_refs,
        }
        flow_refs = {kind: [] for kind in OBJECT_KINDS}
        flow_refs["flows"] = ["FLW-001"]
        flow_document = {
            "id": "flow-doc", "path": "flows.md", "template_id": "t", "template_version": "1",
            "acceptance_ids": [], "object_refs": flow_refs,
        }
        acceptance_document = {
            "id": "ac-doc", "path": "acceptance.md", "template_id": "t", "template_version": "1",
            "acceptance_ids": ["AC-001"], "object_refs": {kind: [] for kind in OBJECT_KINDS},
        }
        package = {
            "schema_version": 2, "mode": "total_subdocuments", "mode_reason": "拆分流程与验收说明",
            "total": total, "subdocuments": [flow_document, acceptance_document],
            "shared_object_refs": [],
        }
        design = {
            "scope": {"features": []},
            "flows": [item],
            "coverage": [{
                "acceptance_id": "AC-001", "requirement_refs": ["REQ-001"],
            }],
        }

        errors = validate_design_package(package, design, {"AC-001"}, {"t": "1"})

        self.assertTrue(any("test scenario" in error.lower() or "测试场景" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
