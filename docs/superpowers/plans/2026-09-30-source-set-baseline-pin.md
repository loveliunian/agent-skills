# Source-Set Baseline Pin Implementation Plan

> **For agentic workers:** Execute this plan inline with focused checks after each step.

**Goal:** Bind a detailed design to the exact PRD source inventory by recording and validating its source-set SHA256 and unit count, while preserving legacy JSON compatibility.

**Architecture:** Add optional source-set fingerprint fields to the schema for legacy documents, require them when initializing new design documents, and validate them when present. Update rendering/receipt contracts and regression tests, then refresh the M01 scratch design to the frozen acceptance checklist and current source set without rendering Markdown.

**Tech Stack:** Python 3, JSON Schema draft-07 subset, pytest.

---

### Task 1: Add failing baseline contract tests

**Files:**
- Modify: `develop/tests/test_acceptance_baseline.py`
- Modify: `develop/tests/test_pipeline.py`

- [ ] Test source-set hash/count validation, mismatch rejection, and old JSON compatibility.
- [ ] Test new document initialization emits source-set fields.
- [ ] Test generation receipt includes the source-set fingerprint.
- [ ] Run focused tests and confirm they fail for the missing behavior.

### Task 2: Extend schema, validator, initializer, and receipt

**Files:**
- Modify: `develop/契约/详设数据结构.json`
- Modify: `develop/脚本/develop.py`
- Modify: `develop/模板/03-详细设计.json` (if the template carries baseline fields)

- [ ] Allow optional source-set fields in legacy baseline JSON.
- [ ] Require them for newly initialized designs and validate exact inventory hash/count when present.
- [ ] Include source-set hash/count in generation receipts and rendered baseline metadata.
- [ ] Preserve validation of legacy baselines that lack the new fields.

### Task 3: Update M01 scratch design and validate

**Files:**
- Modify: `/private/tmp/develop-m01-import-jllxrk/03-详细设计.json`

- [ ] Pin canonical frozen acceptance path, version, and SHA256.
- [ ] Pin the 5919-unit source-set SHA256.
- [ ] Add coverage rows for all 309 canonical ACs and update object acceptance_refs bidirectionally.
- [ ] Run direct validate_design_data and traceability validation; do not render output.
