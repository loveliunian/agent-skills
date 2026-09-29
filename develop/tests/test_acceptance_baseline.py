from __future__ import annotations

import hashlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1] / "脚本"))

from acceptance_baseline import freeze_fingerprint, parse_acceptance, validate_acceptance


FIXTURE = Path(__file__).parent / "fixtures" / "frozen_acceptance.md"


def ledger(*items: dict) -> dict:
    return {"requirements": list(items)}


class AcceptanceBaselineTests(unittest.TestCase):
    def test_parse_acceptance_reads_declared_metadata_and_both_exact_tables(self) -> None:
        parsed = parse_acceptance(FIXTURE)

        self.assertEqual(parsed["version"], "1.0")
        self.assertEqual(parsed["status"], "已冻结")
        self.assertEqual(parsed["declared_count"], 2)
        self.assertEqual([row["验收点 ID"] for row in parsed["acceptance_rows"]], ["AC-001", "AC-002"])
        self.assertEqual([row["PRD 需求 ID"] for row in parsed["coverage_rows"]], ["REQ-001", "REQ-002"])

    def test_parse_acceptance_accepts_hierarchically_numbered_section_headings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            numbered = Path(directory) / "numbered-acceptance.md"
            source = FIXTURE.read_text(encoding="utf-8")
            source = source.replace("## 原子验收点", "## 3 原子验收点")
            source = source.replace("## 需求覆盖检查", "## 4 需求覆盖检查")
            numbered.write_text(source, encoding="utf-8")
            parsed = parse_acceptance(numbered)
        self.assertEqual(len(parsed["acceptance_rows"]), 2)
        self.assertEqual(len(parsed["coverage_rows"]), 2)

    def test_parse_rejects_table_like_row_without_leading_pipe(self) -> None:
        bad_rows = (
            "| AC-002 | REQ-001, REQ-002 |",
            "| REQ-002 | 防止重复记录 |",
        )
        replacements = (
            "AC-002 | REQ-001, REQ-002 |",
            "REQ-002 | 防止重复记录 |",
        )
        for bad_row, replacement in zip(bad_rows, replacements):
            with self.subTest(row=bad_row), tempfile.TemporaryDirectory() as directory:
                malformed = Path(directory) / "missing-leading-pipe.md"
                source = FIXTURE.read_text(encoding="utf-8").replace(bad_row, replacement)
                malformed.write_text(source, encoding="utf-8")

                with self.assertRaisesRegex(ValueError, "表格|行"):
                    parse_acceptance(malformed)

    def test_parse_rejects_two_cell_identifier_row_without_leading_pipe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            malformed = Path(directory) / "two-cell-row.md"
            source = FIXTURE.read_text(encoding="utf-8").replace(
                "| AC-001 | REQ-001 |",
                "AC-003 | REQ-003\n| AC-001 | REQ-001 |",
                1,
            )
            malformed.write_text(source, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "表格|行"):
                parse_acceptance(malformed)

    def test_parse_rejects_unrecognized_table_like_row_without_leading_pipe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            malformed = Path(directory) / "unknown-row.md"
            source = FIXTURE.read_text(encoding="utf-8").replace(
                "| AC-001 | REQ-001 |",
                "OTHER-1 | unexpected | extra\n| AC-001 | REQ-001 |",
                1,
            )
            malformed.write_text(source, encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "表格行|开头的 \\|"):
                parse_acceptance(malformed)

    def test_parse_preserves_escaped_pipe_inside_table_cells(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            markdown = Path(directory) / "escaped-pipe.md"
            source = FIXTURE.read_text(encoding="utf-8").replace("点击保存", r"点击保存 A \| B", 1)
            markdown.write_text(source, encoding="utf-8")
            parsed = parse_acceptance(markdown)
            self.assertIn("A | B", parsed["acceptance_rows"][0]["操作/触发"])

    def test_validation_rejects_empty_or_duplicate_id_list_members(self) -> None:
        for malformed_ids in ("REQ-001,,REQ-002", "REQ-001, REQ-001"):
            with self.subTest(ids=malformed_ids):
                parsed = parse_acceptance(FIXTURE)
                parsed["acceptance_rows"][0]["PRD 需求 ID"] = malformed_ids
                with self.assertRaisesRegex(ValueError, "ID 列表"):
                    validate_acceptance(
                        ledger({"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": True},
                               {"id": "REQ-002", "status": "已确认", "testable": True, "mandatory": True}),
                        parsed,
                    )

    def test_parse_rejects_duplicate_required_metadata_declarations(self) -> None:
        metadata = {
            "清单版本": "1.0",
            "状态": "已冻结",
            "验收点总数": "2",
            "冻结版本/点数": "1.0 / 2",
        }
        for label, value in metadata.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as directory:
                duplicate = Path(directory) / "duplicate-metadata.md"
                source = FIXTURE.read_text(encoding="utf-8").replace(
                    "## 原子验收点", f"- {label}：{value}\n\n## 原子验收点", 1
                )
                duplicate.write_text(source, encoding="utf-8")

                with self.assertRaisesRegex(ValueError, label):
                    parse_acceptance(duplicate)

    def test_valid_frozen_acceptance_covers_each_confirmed_testable_requirement_twice(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        requirements = ledger(
            {"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": True},
            {"id": "REQ-002", "status": "已确认", "testable": True, "mandatory": True},
            {"id": "REQ-003", "status": "待澄清", "testable": False, "mandatory": False},
        )

        self.assertEqual(validate_acceptance(requirements, parsed), [])

    def test_acceptance_ids_are_project_defined_and_not_prefix_hardcoded(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            custom = Path(directory) / "custom-ids.md"
            source = FIXTURE.read_text(encoding="utf-8")
            source = source.replace("AC-001", "M-01-F01-A01")
            source = source.replace("AC-002", "M-01-F01-A02")
            custom.write_text(source, encoding="utf-8")
            parsed = parse_acceptance(custom)
        requirements = ledger(
            {"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": True},
            {"id": "REQ-002", "status": "已确认", "testable": True, "mandatory": True},
        )
        self.assertEqual(validate_acceptance(requirements, parsed), [])

    def test_parse_rejects_missing_required_table(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "missing.md"
            missing.write_text(
                "- 清单版本：1.0\n- 验收点总数：1\n- 状态：已冻结\n- 冻结版本/点数：1.0 / 1\n"
                "## 原子验收点\n\n| 验收点 ID | PRD 需求 ID | 前置条件 | 操作/触发 | 可观察预期结果 | PRD 位置 | 验证方式 |\n"
                "|---|---|---|---|---|---|---|\n| AC-001 | REQ-001 | 前置 | 操作 | 结果 | PRD §1 | API |\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "需求覆盖检查"):
                parse_acceptance(missing)

    def test_parse_rejects_row_with_wrong_cell_count(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            malformed = Path(directory) / "malformed.md"
            malformed.write_text(
                "- 清单版本：1.0\n- 验收点总数：1\n- 状态：已冻结\n- 冻结版本/点数：1.0 / 1\n"
                "## 原子验收点\n\n| 验收点 ID | PRD 需求 ID | 前置条件 | 操作/触发 | 可观察预期结果 | PRD 位置 | 验证方式 |\n"
                "|---|---|---|---|---|---|---|\n| AC-001 | REQ-001 | 少列 |\n\n"
                "## 需求覆盖检查\n\n| PRD 需求 ID | 需求摘要 | 原子验收点 ID | 覆盖结论/待澄清项 |\n"
                "|---|---|---|---|\n| REQ-001 | 摘要 | AC-001 | 已覆盖 |\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(ValueError, "列数"):
                parse_acceptance(malformed)

    def test_validation_rejects_empty_or_duplicate_ids_and_empty_required_fields(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        parsed["acceptance_rows"][0]["验收点 ID"] = "  "
        parsed["acceptance_rows"].append(dict(parsed["acceptance_rows"][1]))
        parsed["acceptance_rows"][0]["可观察预期结果"] = "  "

        errors = validate_acceptance(
            ledger({"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": True},
                   {"id": "REQ-002", "status": "已确认", "testable": True, "mandatory": True}),
            parsed,
        )

        self.assertTrue(any("验收点 ID" in error and "空" in error for error in errors))
        self.assertTrue(any("重复" in error for error in errors))
        self.assertTrue(any("可观察预期结果" in error for error in errors))

    def test_validation_rejects_unknown_requirements_and_uncovered_testable_requirements(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        parsed["acceptance_rows"][0]["PRD 需求 ID"] = "REQ-MISSING"
        parsed["coverage_rows"].pop()

        errors = validate_acceptance(
            ledger({"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": True},
                   {"id": "REQ-002", "status": "已确认", "testable": True, "mandatory": True}),
            parsed,
        )

        self.assertTrue(any("REQ-MISSING" in error and "不存在" in error for error in errors))
        self.assertTrue(any("REQ-002" in error and "覆盖" in error for error in errors))

    def test_validation_checks_frozen_state_version_and_declared_count(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        parsed["status"] = "评审中"
        parsed["declared_count"] = 3
        parsed["frozen_version"] = "0.9"

        errors = validate_acceptance(ledger(), parsed)

        self.assertTrue(any("冻结" in error for error in errors))
        self.assertTrue(any("点数" in error for error in errors))
        self.assertTrue(any("版本" in error for error in errors))

    def test_validation_rejects_missing_freeze_metadata_and_non_boolean_testable(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        parsed.pop("frozen_version")
        parsed.pop("frozen_count")

        errors = validate_acceptance(
            ledger({"id": "REQ-001", "status": "已确认", "mandatory": True}), parsed
        )

        self.assertTrue(any("冻结版本" in error for error in errors))
        self.assertTrue(any("冻结点数" in error for error in errors))
        self.assertTrue(any("testable" in error for error in errors))

    def test_mandatory_unresolved_requirement_blocks_even_when_not_testable(self) -> None:
        errors = validate_acceptance(
            ledger({"id": "REQ-UNRESOLVED", "status": "待澄清", "testable": False, "mandatory": True}),
            parse_acceptance(FIXTURE),
        )

        self.assertTrue(any("REQ-UNRESOLVED" in error and "待澄清" in error for error in errors))

    def test_confirmed_mandatory_non_testable_requirement_still_requires_ac_coverage(self) -> None:
        errors = validate_acceptance(
            ledger({
                "id": "REQ-MANUAL",
                "status": "已确认",
                "testable": False,
                "mandatory": True,
            }),
            parse_acceptance(FIXTURE),
        )

        self.assertTrue(any("REQ-MANUAL" in error and "原子验收点" in error for error in errors))
        self.assertTrue(any("REQ-MANUAL" in error and "需求覆盖检查表" in error for error in errors))

    def test_mandatory_excluded_requirement_is_closed_with_resolution_reason(self) -> None:
        errors = validate_acceptance(
            ledger({
                "id": "REQ-EXCLUDED",
                "status": "已排除",
                "testable": False,
                "mandatory": True,
                "resolution_reason": "经产品负责人确认不在本期范围",
            }),
            parse_acceptance(FIXTURE),
        )

        self.assertFalse(any("REQ-EXCLUDED" in error and "未解决" in error for error in errors))

    def test_mandatory_excluded_requirement_without_resolution_reason_blocks(self) -> None:
        errors = validate_acceptance(
            ledger({
                "id": "REQ-EXCLUDED",
                "status": "已排除",
                "testable": False,
                "mandatory": True,
                "resolution_reason": "  ",
            }),
            parse_acceptance(FIXTURE),
        )

        self.assertTrue(any("REQ-EXCLUDED" in error and "resolution_reason" in error for error in errors))

    def test_ledger_requires_explicit_boolean_mandatory(self) -> None:
        errors = validate_acceptance(
            ledger({"id": "REQ-001", "status": "已确认", "testable": True, "mandatory": "yes"}),
            parse_acceptance(FIXTURE),
        )

        self.assertTrue(any("mandatory" in error and "布尔" in error for error in errors))

    def test_require_frozen_can_be_disabled_without_skipping_structural_validation(self) -> None:
        parsed = parse_acceptance(FIXTURE)
        parsed["status"] = "草稿"
        parsed["acceptance_rows"][0]["验证方式"] = ""

        errors = validate_acceptance(ledger(), parsed, require_frozen=False)

        self.assertFalse(any("冻结" in error for error in errors))
        self.assertTrue(any("验证方式" in error for error in errors))

    def test_freeze_fingerprint_is_sha256_of_exact_file_bytes(self) -> None:
        self.assertEqual(freeze_fingerprint(FIXTURE), hashlib.sha256(FIXTURE.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
