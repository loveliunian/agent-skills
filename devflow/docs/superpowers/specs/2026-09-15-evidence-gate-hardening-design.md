# Evidence Gate Hardening Design

## Goal

Prevent a hand-written P4 report, incomplete state metadata, or empty P6 runner capture from being accepted as delivery evidence.

## Decisions

1. P4 becomes an executing gate. The validation report must declare `P4_CMD`, `P4_RESULTS_PATH`, and `VALIDATION_EVIDENCE`; the gate executes the command, captures its output, requires a non-empty capture, and validates a generated `ID<TAB>STATUS` result file against the frozen acceptance-ID set. Every result must be `PASS`.
2. P4 emits a multi-file evidence tree containing the report, raw validation evidence, generated result table, and execution capture. The receipt remains mirrored under `docs/<feature>/gates/P4/`.
3. Receipt audit rejects a state that claims P6 complete unless its acceptance counters equal the frozen baseline count and its first-pass snapshot path and accuracy are present and valid. `current_stage` and `methodology_stages` remain excluded because they are compatibility-only fields.
4. P6 final verification rejects a successful command whose captured stdout/stderr is empty. This makes shell redirection in a test command invalid; native test-report output must be paired with visible runner output.

## Compatibility

This is intentionally fail-closed. Historical P4 reports and P6 commands that do not meet the new contract must be rerun. No legacy silent pass is retained.

## Verification

Add negative fixtures for: a P4 command that produces a failed acceptance row; a completed P6 state with zero counters or no snapshot; and a P6 command that succeeds while redirecting all output away from the Gate capture. Add positive counterparts and run the full release gate.
