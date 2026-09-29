import copy
import json
import sys
import unittest
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent.parent / "脚本"
sys.path.insert(0, str(SCRIPT_DIR))
from design_package import validate_design_package, validate_design_package_schema


FIXTURES = Path(__file__).resolve().parent / "fixtures" / "design_package"
FROZEN_ACCEPTANCE_IDS = {"AC-001", "AC-002"}
TEMPLATE_REGISTRY = {
    "详细设计-总文档-模板": "1.1.0",
    "详细设计-分文档-模板": "1.1.0",
}


def load_fixture(name):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


class DesignPackageTests(unittest.TestCase):
    def setUp(self):
        self.package = load_fixture("valid-package.json")
        self.design = load_fixture("valid-design.json")

    def assert_rejected(self, package=None, design=None, acceptance_ids=None, message=None):
        errors = validate_design_package(
            self.package if package is None else package,
            self.design if design is None else design,
            FROZEN_ACCEPTANCE_IDS if acceptance_ids is None else acceptance_ids,
            TEMPLATE_REGISTRY,
        )
        self.assertTrue(errors, "invalid package should be rejected")
        if message:
            self.assertTrue(any(message in error for error in errors), errors)

    def test_valid_total_and_subdocument_package_passes(self):
        self.assertEqual(
            validate_design_package(self.package, self.design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY),
            [],
        )

    def test_legacy_package_without_additive_feature_and_domain_refs_is_normalized(self):
        package = copy.deepcopy(self.package)
        for document in [package["total"], *package["subdocuments"]]:
            document["object_refs"].pop("features")
            document["object_refs"].pop("domain_objects")
        design = copy.deepcopy(self.design)
        design["scope"] = {"features": [{"id": "FEATURE-01"}]}
        self.assertEqual(validate_design_package(package, design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY), [])

    def test_domain_object_package_keys_disambiguate_delimiters_in_type_and_id(self):
        design = copy.deepcopy(self.design)
        design["domain_objects"] = [
            {"kind": "billing:source", "id": "x"},
            {"kind": "billing", "id": "source:x"},
        ]
        package = copy.deepcopy(self.package)
        keys = ["billing%3Asource:x", "billing:source%3Ax"]
        package["total"]["object_refs"]["domain_objects"] = keys
        package["subdocuments"][0]["object_refs"]["domain_objects"] = keys
        self.assertEqual(validate_design_package(package, design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY), [])

    def test_domain_object_kind_and_id_must_be_trimmed_and_control_free(self):
        for kind, object_id, package_key in (
            (" external_integration ", "INT-01", "%20external_integration%20:INT-01"),
            ("external_integration", "INT-\x7f-01", "external_integration:INT-%7F-01"),
        ):
            with self.subTest(kind=kind, object_id=object_id):
                design = copy.deepcopy(self.design)
                design["domain_objects"] = [{"kind": kind, "id": object_id}]
                package = copy.deepcopy(self.package)
                package["total"]["object_refs"]["domain_objects"] = [package_key]
                package["subdocuments"][0]["object_refs"]["domain_objects"] = [package_key]
                errors = validate_design_package(package, design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY)
                self.assertTrue(any("domain_objects" in error for error in errors), errors)

    def test_schema_helper_rejects_wrong_root_types_missing_keys_and_extra_keys(self):
        self.assertTrue(validate_design_package_schema([]))
        malformed = copy.deepcopy(self.package)
        malformed["unrecognized"] = True
        malformed["subdocuments"] = {}
        errors = validate_design_package_schema(malformed)
        self.assertTrue(any("unrecognized" in error for error in errors), errors)
        self.assertTrue(any("subdocuments" in error for error in errors), errors)

    def test_rejects_non_object_design_and_malformed_design_object_ids(self):
        self.assert_rejected(design=[])
        malformed_design = copy.deepcopy(self.design)
        malformed_design["tables"].append({"name": "missing id"})
        self.assert_rejected(design=malformed_design, message="tables")

    def test_rejects_absolute_traversal_and_backslash_paths(self):
        for path in ("/tmp/design.md", "../outside.md", "a/../design.md", "a\\..\\outside.md", "C:/design.md"):
            with self.subTest(path=path):
                package = copy.deepcopy(self.package)
                package["total"]["path"] = path
                self.assert_rejected(package=package, message="path")

    def test_rejects_duplicate_document_ids_and_paths(self):
        package = copy.deepcopy(self.package)
        package["subdocuments"].append(copy.deepcopy(package["subdocuments"][0]))
        self.assert_rejected(package=package, message="duplicate")

        package = copy.deepcopy(self.package)
        package["subdocuments"][0]["path"] = package["total"]["path"]
        self.assert_rejected(package=package, message="path")

        package = copy.deepcopy(self.package)
        package["subdocuments"][0]["path"] = "02-设计总览.MD"
        package["total"]["path"] = "02-设计总览.md"
        self.assert_rejected(package=package, message="path")

    def test_rejects_total_acceptance_ids_not_equal_to_frozen_set(self):
        package = copy.deepcopy(self.package)
        package["total"]["acceptance_ids"] = ["AC-001"]
        self.assert_rejected(package=package, message="total")

    def test_subdocument_acceptance_union_must_equal_frozen_ids_but_overlap_is_valid(self):
        package = copy.deepcopy(self.package)
        package["subdocuments"] = [
            copy.deepcopy(package["subdocuments"][0]),
            {
                **copy.deepcopy(package["subdocuments"][0]),
                "id": "M02",
                "path": "详细设计/M03-详细设计.md",
                "acceptance_ids": ["AC-002"],
                "object_refs": {kind: [] for kind in package["total"]["object_refs"]},
            },
        ]
        package["subdocuments"][0]["acceptance_ids"] = ["AC-001"]
        self.assertEqual(validate_design_package(package, self.design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY), [])

        package["subdocuments"][1]["acceptance_ids"] = ["AC-003"]
        self.assert_rejected(package=package, message="acceptance")

    def test_rejects_missing_and_extra_subdocument_acceptance_coverage(self):
        missing = copy.deepcopy(self.package)
        missing["subdocuments"][0]["acceptance_ids"] = ["AC-001"]
        self.assert_rejected(package=missing, message="subdocuments acceptance_ids")

        extra = copy.deepcopy(self.package)
        extra["subdocuments"][0]["acceptance_ids"].append("AC-003")
        self.assert_rejected(package=extra, message="acceptance")

    def test_rejects_nonexistent_acceptance_and_object_references(self):
        package = copy.deepcopy(self.package)
        package["total"]["acceptance_ids"].append("AC-404")
        self.assert_rejected(package=package, message="acceptance")

        package = copy.deepcopy(self.package)
        package["total"]["object_refs"]["tables"].append("TABLE-404")
        self.assert_rejected(package=package, message="TABLE-404")

    def test_total_object_inventory_and_subdocument_ownership_cover_design_objects(self):
        package = copy.deepcopy(self.package)
        package["total"]["object_refs"]["tables"].remove("TABLE-2")
        self.assert_rejected(package=package, message="TABLE-2")

        package = copy.deepcopy(self.package)
        package["subdocuments"][0]["object_refs"]["tables"].remove("TABLE-2")
        self.assertEqual(package["total"]["object_refs"]["tables"], ["TABLE-1", "TABLE-2"])
        errors = validate_design_package(package, self.design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY)
        self.assertTrue(
            any("未分配" in error and "TABLE-2" in error for error in errors), errors
        )

    def test_rejects_subdocument_reference_to_nonexistent_design_object(self):
        package = copy.deepcopy(self.package)
        package["subdocuments"][0]["object_refs"]["tables"].append("TABLE-404")
        self.assert_rejected(package=package, message="TABLE-404")

    def test_duplicate_ownership_across_subdocuments_requires_shared_registration(self):
        package = copy.deepcopy(self.package)
        package["subdocuments"].append({
            **copy.deepcopy(package["subdocuments"][0]),
            "id": "M02",
            "path": "详细设计/M03-详细设计.md",
            "acceptance_ids": ["AC-002"],
            "object_refs": {kind: [] for kind in package["total"]["object_refs"]},
        })
        package["subdocuments"][0]["acceptance_ids"] = ["AC-001"]
        package["subdocuments"][1]["object_refs"]["tables"] = ["TABLE-1"]
        self.assert_rejected(package=package, message="TABLE-1")

        package["shared_object_refs"] = [{"kind": "tables", "id": "TABLE-1"}]
        self.assertEqual(validate_design_package(package, self.design, FROZEN_ACCEPTANCE_IDS, TEMPLATE_REGISTRY), [])

    def test_rejects_shared_registration_when_object_is_not_shared(self):
        package = copy.deepcopy(self.package)
        package["shared_object_refs"] = [{"kind": "tables", "id": "TABLE-2"}]
        self.assert_rejected(package=package, message="shared")

    def test_rejects_shared_reference_to_nonexistent_design_object(self):
        package = copy.deepcopy(self.package)
        package["shared_object_refs"] = [{"kind": "tables", "id": "TABLE-404"}]
        self.assert_rejected(package=package, message="TABLE-404")

    def test_schema_rejects_malformed_nested_object_refs_and_shared_entries(self):
        malformed_refs = copy.deepcopy(self.package)
        malformed_refs["subdocuments"][0]["object_refs"]["tables"] = "TABLE-1"
        errors = validate_design_package_schema(malformed_refs)
        self.assertTrue(any("object_refs.tables" in error for error in errors), errors)

        malformed_shared = copy.deepcopy(self.package)
        malformed_shared["shared_object_refs"] = [{"kind": "unknown", "id": "TABLE-1"}]
        errors = validate_design_package_schema(malformed_shared)
        self.assertTrue(any("shared_object_refs[0].kind" in error for error in errors), errors)

        malformed_shared["shared_object_refs"] = [{"kind": "tables"}]
        errors = validate_design_package_schema(malformed_shared)
        self.assertTrue(any("shared_object_refs[0]" in error and "id" in error for error in errors), errors)

    def test_template_identity_and_version_must_be_present_and_match_registry(self):
        for field, value in (("template_id", ""), ("template_version", " ")):
            package = copy.deepcopy(self.package)
            package["total"][field] = value
            self.assert_rejected(package=package, message=field)

        package = copy.deepcopy(self.package)
        package["total"]["template_version"] = "2.0.0"
        self.assert_rejected(package=package, message="template_version")

        package = copy.deepcopy(self.package)
        package["total"]["template_id"] = "unknown-template"
        self.assert_rejected(package=package, message="template_id")

    def test_without_registry_template_metadata_only_needs_nonempty_strings(self):
        package = copy.deepcopy(self.package)
        package["total"]["template_id"] = "legacy-template"
        package["total"]["template_version"] = "0.5"
        self.assertEqual(validate_design_package(package, self.design, FROZEN_ACCEPTANCE_IDS), [])


if __name__ == "__main__":
    unittest.main()
