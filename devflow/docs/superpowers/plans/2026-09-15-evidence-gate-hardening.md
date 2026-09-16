# Evidence Gate Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make P4, P6, and receipt audit fail closed when recorded delivery evidence is not reproducible and complete.

**Architecture:** P4 will execute a declared trusted command and verify a structured acceptance ledger before writing a tree-bound receipt. Receipt audit will cross-check P6 terminal state metadata with the frozen baseline. P6 will require the Gate's own capture to contain test output.

**Tech Stack:** POSIX shell, jq, existing devflow receipt helpers and shell regression fixtures.

---

### Task 1: Add P4 execution-contract regression tests

**Files:**
- Modify: `tests/test-evidence-hardening.sh`
- Modify: `tests/test-contracts.sh`

- [ ] Add a fixture whose validation report declares a trusted command and result TSV containing one `FAIL` row; assert `p4_validation_gate.sh` exits nonzero.
- [ ] Add a fixture with matching frozen IDs, all `PASS` statuses, changed result file, and non-empty capture; assert P4 exits zero and its receipt has `EVIDENCE_PATHS_JSON` and `EVIDENCE_TREE_SHA256`.
- [ ] Run `bash tests/test-evidence-hardening.sh` and confirm the new negative case fails because the existing gate trusts only report text.

### Task 2: Implement P4 executable evidence validation

**Files:**
- Modify: `scripts/p4_validation_gate.sh`
- Modify: `phases/04-PRD验证.md`

- [ ] Require `P4_CMD`, `P4_RESULTS_PATH`, and `VALIDATION_EVIDENCE` in the validation report.
- [ ] Reject shell wrappers and untrusted runners; execute the command from the workspace root and retain `.devflow/<feature>/test-executions/p4-validation.log`.
- [ ] Require a non-empty capture, a results TSV headed `ID<TAB>STATUS`, an exact frozen-ID set, and only `PASS` statuses.
- [ ] Bind report, raw evidence, results TSV, and capture as a receipt evidence tree; mirror the receipt.
- [ ] Re-run the Task 1 fixtures and confirm both the negative and positive cases have the expected exit codes.

### Task 3: Add and implement P6 state/capture regressions

**Files:**
- Modify: `tests/test-report-regressions.sh`
- Modify: `tests/test-p6-hardening.sh`
- Modify: `scripts/audit-receipts.sh`
- Modify: `scripts/s6_final_verification_gate.sh`
- Modify: `commands/test.md`

- [ ] Add a completed-P6 state with zero acceptance counters and absent snapshot metadata; assert `audit-receipts.sh` fails.
- [ ] Add a valid completed-P6 state with counters equal to the frozen baseline and an existing snapshot; assert audit passes.
- [ ] Add a P6 trusted command that redirects all output to its report; assert final verification fails because the Gate capture is empty.
- [ ] In receipt audit, validate the three counters and first-pass snapshot only when P6 is completed.
- [ ] In P6 final verification, reject a successful command with zero captured bytes and document that test commands must not redirect stdout/stderr away from the Gate.
- [ ] Re-run the focused regression suites and confirm the new fixtures turn green.

### Task 4: Release the skill version

**Files:**
- Modify: `SKILL.md`, `commands/*.md`, `phases/*.md`, `references/CHANGELOG.md`, versioned script headers, and release metadata as required by version checks.

- [ ] Bump the authoritative version from `3.20.8` to `3.20.9` using the repository's existing consistency convention.
- [ ] Add a changelog entry describing the three fail-closed contracts and their deliberate historical incompatibility.
- [ ] Run `bash tests/run-tests.sh` and `bash scripts/release.sh`; inspect actual exit codes and the final release report.
