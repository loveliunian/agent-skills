# Develop PRD-to-Design Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Stabilize the develop skill's PRD-to-detailed-design path so every PRD source unit is accounted for, every accepted requirement maps to atomic acceptance points, and every frozen point is represented in the rendered detailed design.

**Architecture:** Keep PRD Markdown as the source, add a deterministic source-unit inventory and structured requirement ledger, retain the reviewed acceptance Markdown as the frozen denominator, and keep detailed-design JSON as the design source of truth. Validators establish source coverage and bidirectional traceability before deterministic template rendering; hashes bind review receipts to their exact inputs and outputs.

**Tech Stack:** Python 3 standard library, JSON Schema subset already implemented in `develop/脚本/develop.py`, Markdown templates, unittest.

---

## Scope and order

The first release focuses on PRD inventory → requirement ledger → reviewed acceptance baseline → detailed-design JSON → Markdown. Work on total/sub document packages follows only after this vertical slice passes its positive and negative fixtures. Do not edit DevFlow. Preserve the existing `README.md`, `sync.sh`, and all existing `develop/` files unless a task below names them.

## File map

- Modify `develop/脚本/develop.py`: retain the current CLI and add deterministic PRD scanning, requirement ledger validation, acceptance baseline checks, and staged generation commands.
- Modify `develop/契约/文档清单.json`: register the PRD inventory artifact, schemas, template identities/versions, generation targets, and block IDs.
- Create `develop/契约/需求提取数据结构.json`: define source units, classifications, requirements, source references, review deltas, and dispositions.
- Modify `develop/契约/详设数据结构.json`: bind the design baseline to source and acceptance fingerprints and require requirement/source references where applicable.
- Modify `develop/模板/01-产品需求.md` and `develop/模板/02-原子验收点清单.md`: make source IDs, requirement IDs, provenance, unresolved items, frozen version, and count explicit.
- Modify `develop/模板/03-详细设计.json`: include the new baseline fields and required cross-reference arrays.
- Modify `develop/模板/03-详细设计.md`: add unique `develop:begin/end` blocks for generated content and keep design rationale outside those blocks.
- Modify `develop/标准/详尽详设标准.md` and `develop/SKILL.md`: describe the extraction ledger, independent review, freeze requirements, and exact command order.
- Create `develop/tests/test_prd_inventory.py`, `develop/tests/test_acceptance_baseline.py`, `develop/tests/test_pipeline.py`, and `develop/tests/test_design_package.py`, Markdown/JSON fixtures under `develop/tests/fixtures/`, and `develop/tests/run-tests.sh`.
- Keep the already committed design at `docs/superpowers/specs/2026-09-28-develop-document-generation-design.md` aligned with implementation decisions.

Test convention: focused test modules load `develop/脚本/develop.py` with `importlib.util.spec_from_file_location`, defines `ROOT = Path(__file__).resolve().parents[2]` and `FIXTURES = ROOT / "develop" / "tests" / "fixtures"`, and uses only `unittest`, `tempfile`, and standard-library file/JSON helpers.

## Task 1: Build a deterministic PRD source-unit inventory

**Files:**
- Modify: `develop/脚本/develop.py`
- Create: `develop/tests/test_prd_inventory.py`
- Create: `develop/tests/fixtures/prd/complete.md`
- Create: `develop/tests/fixtures/prd/unsupported-block.md`

- [x] **Step 1: Add failing source-unit tests**

Add tests that feed a PRD containing headings, paragraphs, nested list items, and a table. Assert the scanner returns every content unit exactly once with `kind`, full heading path, original text, and one-based inclusive source lines. Assert table separator rows and blank lines are excluded. Assert unsupported raw HTML or malformed tables fail with the exact source line instead of disappearing.

```python
class SourceInventoryTests(unittest.TestCase):
    def test_scan_prd_accounts_for_each_content_block(self):
        result = scan_prd(FIXTURES / "prd" / "complete.md")
        texts = [unit["text"] for unit in result["units"]]
        self.assertIn("订单支持部分退款。", texts)
        self.assertIn("退款金额不能超过剩余可退金额。", texts)
        self.assertIn("退款单号", texts)
        self.assertEqual(len({unit["id"] for unit in result["units"]}), len(result["units"]))

    def test_scan_prd_fails_closed_on_unsupported_content(self):
        with self.assertRaisesRegex(ValueError, "unsupported block at line 4"):
            scan_prd(FIXTURES / "prd" / "unsupported-block.md")
```

- [x] **Step 2: Run the focused tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_prd_inventory -v`  
Expected: FAIL because `scan_prd` and the fixtures do not exist yet.

- [x] **Step 3: Implement stable source-unit IDs and inventory output**

Split the manifest-registered PRD Markdown deterministically into heading, paragraph, list-item, table-header, table-data-row, and linked-asset units. Each data-row unit retains its associated column headers; each linked asset records alt text, target, source line, local hash when available, and unresolved state when missing/external. Build each unit ID from the project-relative path, normalized heading path, unit kind, normalized text/headers, and duplicate ordinal; do not use line number alone as identity. Store `prd_sha256`, parser version, and source line ranges. Reject unsupported constructs and malformed input with a nonzero result.

- [x] **Step 4: Run focused tests and confirm the source inventory is complete**

Run: `python3 -m unittest develop.tests.test_prd_inventory -v`  
Expected: all source inventory cases PASS; the unsupported fixture reports its actual line.

## Task 2: Validate the structured requirement ledger and extraction review

**Files:**
- Create: `develop/契约/需求提取数据结构.json`
- Modify: `develop/脚本/develop.py`
- Modify: `develop/契约/文档清单.json`
- Modify: `develop/tests/test_prd_inventory.py`
- Create: `develop/tests/fixtures/requirements/complete.json`
- Create: `develop/tests/fixtures/requirements/missing-source-unit.json`
- Create: `develop/tests/fixtures/requirements/unresolved-delta.json`

- [x] **Step 1: Add failing ledger tests**

Cover source-unit coverage exactly once, unique requirement IDs, valid source references, non-requirement classifications with a reason, multiple requirement clauses from one source unit, and independent-review delta dispositions. A delta disposition must contain a decision, rationale, and source evidence. Missing or unresolved deltas block.

```python
class RequirementLedgerTests(unittest.TestCase):
    def test_requirement_ledger_requires_every_source_unit(self):
        inventory = scan_prd(FIXTURES / "prd" / "complete.md")
        ledger = load_json(FIXTURES / "requirements" / "missing-source-unit.json")
        errors = validate_requirement_ledger(inventory, ledger)
        self.assertTrue(any("unclassified source unit" in error for error in errors))

    def test_requirement_ledger_blocks_unresolved_review_delta(self):
        inventory = scan_prd(FIXTURES / "prd" / "complete.md")
        ledger = load_json(FIXTURES / "requirements" / "unresolved-delta.json")
        errors = validate_requirement_ledger(inventory, ledger)
        self.assertTrue(any("unresolved extraction delta" in error for error in errors))
```

- [x] **Step 2: Run the focused tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_prd_inventory -v`  
Expected: FAIL because the requirement schema and validator do not exist yet.

- [x] **Step 3: Add schema and cross-field validation**

Define classifications for functional requirement, business rule, entity/data, operation, permission, workflow, UI, quality, constraint, assumption, non-goal, risk, context, unresolved question, duplicate, and non-requirement. Each requirement has a stable ID, normalized statement, explicit boolean `mandatory` and `testable` values, one or more `source_refs`, a closed status, and an exclusion reason when status is 已排除. Every source unit must appear exactly once in the classification ledger; units classified as context, duplicate, or non-requirement require a reason. Each linked asset requires a reviewed record with matching hash, summary and evidence; missing/external assets block. Require extractor ID plus a distinct independent reviewer attestation bound to the PRD hash and source-unit count, with a completed conclusion consistent with the delta list. The attestation is process evidence, not proof of semantic correctness. Any unresolved delta or mandatory requirement with a pending status blocks acceptance freeze. Do not calculate a scalar stability score and do not let a score waive a missing or unresolved item.

- [x] **Step 4: Run focused tests**

Run: `python3 -m unittest develop.tests.test_prd_inventory -v`  
Expected: all tests PASS; every invalid ledger returns a path-addressed validation error and nonzero CLI status.

## Task 3: Freeze acceptance points against the PRD ledger

**Files:**
- Modify: `develop/脚本/develop.py`
- Modify: `develop/模板/02-原子验收点清单.md`
- Modify: `develop/契约/文档清单.json`
- Modify: `develop/tests/test_acceptance_baseline.py`
- Create: `develop/tests/fixtures/acceptance/complete.md`
- Create: `develop/tests/fixtures/acceptance/duplicate-id.md`
- Create: `develop/tests/fixtures/acceptance/missing-requirement.md`

- [x] **Step 1: Add failing acceptance baseline tests**

Assert that a frozen list has a nonempty unique AC ID set, every row has valid requirement IDs and PRD source location, each point contains precondition/trigger/observable result/verification, every confirmed requirement maps to at least one AC regardless of automation flag, and every unresolved mandatory requirement blocks freezing. Keep the current AC ID format and do not renumber existing rows.

```python
class AcceptanceBaselineTests(unittest.TestCase):
    def test_acceptance_freeze_requires_all_testable_requirements(self):
        ledger = load_json(FIXTURES / "requirements" / "complete.json")
        acceptance = parse_acceptance(FIXTURES / "acceptance" / "missing-requirement.md")
        errors = validate_acceptance(ledger, acceptance)
        self.assertTrue(any("requirement has no acceptance point" in error for error in errors))
```

- [x] **Step 2: Run the focused tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_acceptance_baseline -v`  
Expected: FAIL because the current parser only extracts AC IDs and one requirement ID.

- [x] **Step 3: Harden acceptance parsing and freeze checks**

Parse the exact registered `原子验收点` and `需求覆盖检查` tables. Validate column count, stable IDs, source references, verification methods, frozen status, declared version and count. Compare the confirmed requirements in the ledger against the coverage table and AC rows. Hash the complete frozen acceptance file and bind the hash to the detailed-design baseline.

- [x] **Step 4: Run focused tests**

Run: `python3 -m unittest develop.tests.test_acceptance_baseline -v`  
Expected: all acceptance positive/negative cases PASS with missing or duplicated IDs reported precisely.

## Task 4: Bind detailed design to the complete requirement and acceptance baselines

**Files:**
- Modify: `develop/契约/详设数据结构.json`
- Modify: `develop/模板/03-详细设计.json`
- Modify: `develop/脚本/develop.py`
- Modify: `develop/tests/test_pipeline.py`
- Create: `develop/tests/fixtures/design/complete.json`
- Create: `develop/tests/fixtures/design/dangling-requirement.json`

- [x] **Step 1: Add failing baseline and traceability tests**

Test stale PRD and acceptance hashes, a frozen AC omitted from coverage, a coverage row with no design object or reason, reverse-reference mismatch, unknown requirement/source references, and a design object that cites a requirement but no acceptance point.

```python
class DesignTraceabilityTests(unittest.TestCase):
    def test_design_must_match_frozen_acceptance_and_requirement_sets(self):
        design_dir = FIXTURES / "design" / "dangling-requirement"
        errors = validate_design_data(design_dir, STRUCTURED_CONFIG)
        self.assertTrue(any("unknown requirement reference" in error for error in errors))
```

- [x] **Step 2: Run the focused tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_pipeline -v`  
Expected: FAIL because design objects do not yet reference the structured requirement ledger or source units.

- [x] **Step 3: Extend schema and semantic checks**

Add `requirements_file`, `requirements_version`, `prd_sha256`, and `acceptance_sha256` to the design baseline. Add `requirement_refs` and `source_refs` to applicable design objects while retaining current `acceptance_refs`. Validate every reference against the requirement ledger, source inventory, and frozen AC set. Preserve current bidirectional relationship checks and require the coverage set to equal the frozen AC set exactly. Do not infer or auto-fill missing mappings.

- [x] **Step 4: Run focused tests**

Run: `python3 -m unittest develop.tests.test_pipeline -v`  
Expected: all complete-design cases PASS and all stale/missing/dangling cases FAIL with the exact object ID and path.

## Task 5: Add deterministic anchored rendering and generation receipts

**Files:**
- Modify: `develop/契约/文档清单.json`
- Modify: `develop/脚本/develop.py`
- Modify: `develop/模板/03-详细设计.md`
- Modify: `develop/SKILL.md`
- Modify: `develop/标准/详尽详设标准.md`
- Modify: `develop/tests/test_pipeline.py`

- [x] **Step 1: Add failing renderer tests**

Verify every registered block appears once, block content is regenerated byte-for-byte, text outside blocks survives, and missing, duplicate, nested, mismatched, or unknown anchors fail. Verify `check-design` rejects an edited generated block and accepts an edited rationale outside generated blocks.

```python
class AnchoredRenderingTests(unittest.TestCase):
    def test_render_design_preserves_text_outside_generated_blocks(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp)
            target = write_design_doc(directory, before="Architecture rationale.", generated="old")
            render_design(directory, MANIFEST)
            text = target.read_text(encoding="utf-8")
            self.assertIn("Architecture rationale.", text)
            self.assertNotIn("old", text)
            self.assertEqual(text.count("<!-- develop:begin:tables -->"), 1)
```

- [x] **Step 2: Run focused renderer tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_pipeline -v`  
Expected: FAIL because the current renderer rewrites the full Markdown document.

- [x] **Step 3: Implement block registry and deterministic rendering**

Add template ID/version and registered block IDs to the manifest. Replace only block contents. Fail closed for malformed blocks and leftover template variables. Keep JSON as the source for tables, interfaces, rules, flows, pages, quality decisions, and coverage. Generate a receipt containing PRD, inventory, requirement ledger, acceptance baseline, design JSON, schema, manifest, template, and output hashes plus tool/template versions and command result.

- [x] **Step 4: Implement `scan-prd`, `check-prd`, and compatibility checks**

`scan-prd` writes the source-unit inventory without altering the PRD. `check-prd` validates the inventory, requirement ledger, independent review, and frozen acceptance baseline in that order. `render-design` refuses to proceed unless `check-prd` and design validation pass. Existing `init`, `render-design`, `check`, and `check-design` names and exit status meanings remain available.

- [x] **Step 5: Run focused renderer and command tests**

Run: `python3 -m unittest develop.tests.test_pipeline -v`  
Expected: all tests PASS; invalid input returns nonzero before changing the design Markdown or emitting a PASS receipt.

## Task 6: Add total/sub design packages after the core path is stable

**Files:**
- Create: `develop/契约/详设输出数据结构.json`
- Modify: `develop/脚本/develop.py`
- Modify: `develop/契约/文档清单.json`
- Modify: `develop/tests/test_design_package.py` and `develop/tests/test_pipeline.py`

- [x] **Step 1: Add failing package tests**

Test unique document paths, exact object ownership or explicit sharing, valid object IDs, document existence, per-document acceptance subsets, and union equality with the frozen acceptance set.

- [x] **Step 2: Run the focused package tests and confirm they fail**

Run: `python3 -m unittest develop.tests.test_design_package -v`  
Expected: FAIL because the current manifest supports one detailed-design document.

- [x] **Step 3: Implement optional package validation and rendering**

Keep monolith as the default. When `03-详设输出.json` exists, require all declared documents, render registered object and acceptance subsets, require every design object to have an owner, and require the union of document acceptance subsets to equal the frozen set. Coverage references must resolve inside each owning subdocument. Shared objects must be explicitly declared and render identically.

- [x] **Step 4: Run package tests**

Run: `python3 -m unittest develop.tests.test_design_package -v`  
Expected: complete package PASS; missing documents, objects, or acceptance IDs FAIL.

## Task 7: Complete regression gate and skill guidance

**Files:**
- Modify: `develop/SKILL.md`
- Modify: `develop/标准/详尽详设标准.md`
- Create: `develop/tests/run-tests.sh`

- [x] **Step 1: Add a portable standard-library test runner**

Create `develop/tests/run-tests.sh` using `set -euo pipefail`, resolve the repository root from the script path, and run `python3 -m unittest discover -s "$ROOT/develop/tests" -p 'test_*.py' -v`. Do not install dependencies.

- [x] **Step 2: Document the exact authoring sequence and bump the skill version**

Update the skill so the agent reads the exact PRD, inventories all source units, extracts and independently reviews requirements, resolves deltas, freezes the acceptance list, fills the detailed-design JSON, renders, runs `check-prd` and `check-design`, then starts detailed-design review. Explicitly state that extraction disagreement or unresolved mandatory facts block the next phase. Update `metadata.version` from `1.0.0` to `1.1.0` in the same change.

- [x] **Step 3: Run the full regression suite**

Run: `bash develop/tests/run-tests.sh`  
Expected: all positive and negative fixtures pass; exit code is 0.

- [x] **Step 4: Run complete and negative end-to-end pipeline cases**

Run: `python3 -m unittest develop.tests.test_pipeline.PrdCommandTests.test_check_prd_accepts_complete_frozen_pipeline -v`  
Expected: exit code 0 and report includes PRD hash, source-unit count, requirement count, AC count, and zero unresolved deltas.

Run: `python3 -m unittest develop.tests.test_pipeline.PrdCommandTests.test_check_prd_rejects_unresolved_mandatory_requirement -v`  
Expected: invalid unresolved state returns nonzero and identifies its requirement.

Run: `python3 -m unittest develop.tests.test_pipeline.DesignTraceabilityTests.test_complete_design_json_renders_with_source_backed_traceability -v`  
Expected: exit code 0, deterministic generated blocks, output hashes, and valid receipt.

Run: `python3 -m unittest develop.tests.test_pipeline.DesignTraceabilityTests.test_design_package_renders_total_and_filtered_subdocument_and_checks_receipt -v`  
Expected: total/sub documents render, tampered or unsafe package outputs are rejected, and output hashes are verified.

- [x] **Step 5: Check change boundaries**

Run: `rtk git status --short` and `rtk git diff --check`. Confirm implementation changes are within `develop/` and the approved design/plan documents; confirm prior `README.md` and `sync.sh` changes remain intact and no `devflow/` file changed.

## Completion evidence

Report separate results for PRD source inventory, requirement extraction reconciliation, acceptance freeze, detailed-design coverage, renderer consistency, and total/sub package validation. Distinguish structural Gate PASS from semantic review and runtime correctness; the generator cannot certify that a business interpretation is true without source-backed human review.

## Task 8: Number headings in generated Markdown

**Files:**
- Modify: `develop/脚本/develop.py`
- Modify: `develop/tests/test_pipeline.py`

- [x] Add failing tests proving `init` numbers all generated Markdown H2+ headings and `render-design` numbers generated H2/H3 headings while keeping the H1 document title unchanged.
- [x] Implement deterministic hierarchical numbering (`1`, `1.1`, `1.1.1`) for headings from level 2 onward. Keep JSON and manifest section names unnumbered; make document checks compare normalized heading text so numbering does not alter the contract.
- [x] Run the focused tests and full regression suite; confirm repeated rendering stays byte-stable.

## Task 9: Render object references as navigable links

**Files:**
- Modify: `develop/脚本/develop.py`
- Modify: `develop/tests/test_pipeline.py`

- [x] Add failing integration coverage for a JSON flow linking to a JSON business rule and for a cross-document package reference.
- [x] Build a typed object-ID-to-anchor/owner index; emit stable anchors at object entries and Markdown links for typed references, resolving relative paths for package documents.
- [x] Run focused tests and the full regression suite; verify all generated links target emitted anchors and repeated output remains deterministic.

## Task 10: Generalize PRD formats, identifiers, and design domains

**Files:**
- Modify: `develop/脚本/prd_inventory.py`, `develop/脚本/acceptance_baseline.py`, `develop/脚本/develop.py`, `develop/脚本/design_package.py`
- Modify: `develop/契约/需求提取数据结构.json`, `develop/契约/详设数据结构.json`, `develop/契约/详设输出数据结构.json`
- Modify: `develop/模板/03-详细设计.json`, `develop/模板/03-详细设计.md`, `develop/契约/文档清单.json`
- Modify: focused tests under `develop/tests/`

- [x] Add failing tests proving fenced/indented code, blockquotes, quoted/unquoted HTML src/href/poster/data, reference-style links, Setext headings, and malformed tables remain represented; project-defined IDs, configured size limits, and raw numbered heading provenance are covered.
- [x] Implement lossless source-unit fallback for unfamiliar Markdown blocks, typed asset references, configurable source/asset limits, and project-defined IDs without fixed prefixes.
- [x] Add generic typed domain objects with attributes, requirement/source/acceptance refs, rendering, anchors, package ownership, and coverage validation; encode type/ID pairs unambiguously; preserve legacy v2 JSON/package inputs and migrate prior 1.1.0 generated Markdown; reject duplicate feature anchors.
- [x] Run the full regression suite and scan the target project PRD to establish a general parser result; do not overwrite any existing design until the complete source-to-design chain is reviewable.

## Task 11: Expand full detailed-design coverage and make output modes explicit

**Files:**
- Modify: `develop/契约/详设数据结构.json`, `develop/契约/详设输出数据结构.json`, `develop/契约/文档清单.json`
- Modify: `develop/脚本/develop.py`, `develop/脚本/design_package.py`
- Modify: `develop/模板/03-详细设计.json`, `develop/模板/03-详细设计.md`
- Modify: `develop/SKILL.md`, `develop/标准/详尽详设标准.md`
- Modify: `docs/superpowers/specs/2026-09-28-develop-document-generation-design.md`

- [x] Add typed design sections for terminology, permission matrices, diagrams, dependencies, and reuse decisions, including source/requirement/acceptance traceability and package ownership.
- [x] Add explicit `single` and `total_subdocuments` output modes, record the frozen mode rationale, and let single mode derive the complete object/acceptance set from the design JSON and frozen baseline; total/subdocument mode requires explicit module ownership, exact acceptance unions, and closed references.
- [x] Allow a caller-specified total-document path such as `m01-base-详细设计.md`, while keeping outputs inside the project root and including each emitted Markdown file in the generation receipt.
- [x] Update skill instructions and the detailed-design standard with a mode-selection decision and complete full-design coverage requirements.
- [x] Perform non-test static review of schema, manifest/template identities, file references, mode branches, and safe output paths; do not modify DevFlow or the target M01 artifact.

## Task 12: Import existing M01 baseline documents into develop without weakening gates

**Files:**
- Modify: `develop/脚本/prd_inventory.py`, `develop/脚本/acceptance_baseline.py`, `develop/脚本/develop.py`
- Modify: `develop/契约/需求提取数据结构.json`, `develop/契约/文档清单.json`
- Create: `develop/契约/需求来源配置数据结构.json`, `develop/模板/01-需求来源配置.json`
- Modify: `develop/SKILL.md`, `develop/标准/详尽详设标准.md`

- [x] Allow projects to register additional Markdown evidence sources (clarifications, constraints, domain reviews, architecture and curated code/database baselines) and include their IDs/hashes in the same inventory and generation receipt.
- [x] Add a legacy acceptance import adapter that preserves existing AC IDs, PRD anchors and verification types, while recording any fields the source format did not provide instead of inventing them.
- [x] Document the conversion of M01's 122-point frozen list and supporting technical evidence; keep the independent-review and frozen-baseline gates intact.
- [x] Enforce `maxItems` in the schema validator and reject unresolved acceptance/action markers (including `待业务补充`, `待独立复核`, and `待复核`), even when a draft is manually relabeled as frozen.
- [x] Add row-level PRD acceptance-scenario-to-AC mapping for structured source tables, with freeze-time checks for missing source rows, invalid AC/REQ links, and unclosed mapping status.
- [ ] Re-run the isolated M01 trial against the exact PRD and supporting files; report any remaining blockers and compare rendered coverage with the existing detailed design without modifying it.
