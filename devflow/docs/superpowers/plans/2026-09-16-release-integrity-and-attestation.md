# Release Integrity and Independent Review Attestation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Release devflow v3.21.2 with externally attested P2a identities and a release-evidence chain that cannot be silently rewritten by the local workflow process.

**Architecture:** The strict P2a path verifies detached OpenSSL signatures over canonical begin/complete review events and never signs locally. A manifest root outside the excluded manifest directory anchors legacy history into v3.21.2's protected tree. Production tree hashing always computes the real tree; test fixtures remain responsible for speed.

**Tech Stack:** Bash 3.2+, jq, OpenSSL, SHA-256, existing shell regression fixtures.

---

### Task 1: Make the v3.20.3 hardening fixture idempotent and close the tree-hash bypass

**Files:**
- Modify: `tests/test-v3203-hardening.sh`
- Modify: `tests/run-tests.sh`
- Modify: `scripts/gate-skill-tree.sh`
- Create: `tests/test-v3212-integrity.sh`

- [ ] **Step 1: Write failing regression assertions**

Add a `test-v3212-integrity.sh` fixture that invokes `gate-skill-tree.sh` with `RUN_TESTS_ACTIVE=1`, a 64-zero `DEVFLOW_SKILL_TREE_SHA`, and matching root. Assert the output is the independently computed real hash, not 64 zeros. In `test-v3203-hardening.sh`, assert a copied published skill can run the manifest hardening fixture without attempting to generate an already-published version.

- [ ] **Step 2: Run RED tests**

Run: `bash tests/test-v3212-integrity.sh && bash tests/test-v3203-hardening.sh`

Expected: the cache assertion fails because the production script returns the injected hash; the published-copy fixture fails because it calls same-version `generate`.

- [ ] **Step 3: Implement minimal fixes**

Delete the environment-cache branch from `scripts/gate-skill-tree.sh`. Remove cache exports from `tests/run-tests.sh`. In the hardening sandbox, remove only the copied current manifest and matching ledger entry before exercising first-release `generate`; keep the source tree untouched.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test-v3212-integrity.sh && bash tests/test-v3203-hardening.sh`

Expected: both exit 0; injected environment variables cannot alter the real tree hash.

### Task 2: Require externally signed reviewer lifecycle events

**Files:**
- Modify: `scripts/review-receipt.sh`
- Modify: `scripts/p2a_design_review_gate.sh`
- Modify: `phases/02a-详细设计评审.md`
- Modify: `references/agent-runtime-adapter.md`
- Modify: `tests/test-v3212-integrity.sh`

- [ ] **Step 1: Write failing strict-attestation tests**

In `test-v3212-integrity.sh`, generate an ephemeral RSA keypair under `mktemp`. Assert that unsigned begin/complete receipts fail; assert a payload signed by a different key fails; assert six correctly signed, role-distinct events pass only when the event fields match feature, session, role, agent ID, input SHA, output SHA, event kind, timestamp, and nonce.

- [ ] **Step 2: Run RED test**

Run: `bash tests/test-v3212-integrity.sh`

Expected: unsigned and forged events currently pass because `review-receipt.sh` trusts caller parameters.

- [ ] **Step 3: Implement strict verifier**

Require `REVIEW_ATTESTATION_PUBKEY` and `openssl`. Add `--attestation <json>` to `begin` and `complete`. Canonicalize the event with `jq -cS`, base64-decode `signature_b64` into a private temporary file, and call `openssl dgst -sha256 -verify "$REVIEW_ATTESTATION_PUBKEY" -signature <sig> <payload>`. Store the verified event SHA in each receipt. Reject missing, malformed, duplicate-nonce, mismatched, expired, or locally self-declared events. Keep no signing command or private key path in the skill.

- [ ] **Step 4: Bind P2a to strict verification**

Make `p2a_design_review_gate.sh` propagate a failed strict receipt verification as P0. Document the dispatcher contract: an external service/CI agent creates events from platform-issued identities; absent attestation means `BLOCKED`.

- [ ] **Step 5: Verify GREEN**

Run: `bash tests/test-v3212-integrity.sh`

Expected: only valid external-key signatures pass; a single local process with arbitrary IDs cannot produce accepted receipts without the external private key.

### Task 3: Anchor legacy manifests in a protected root

**Files:**
- Create: `references/manifest-root.json`
- Modify: `scripts/gen-skill-manifest.sh`
- Modify: `tests/test-v3212-integrity.sh`

- [ ] **Step 1: Write failing co-tamper tests**

Copy the skill into a temporary directory, change legacy `3.20.2.json`, update its `CHAIN.json` SHA and tree value, and assert `gen-skill-manifest.sh check` fails. Add an unledgered manifest and a duplicate ledger version; assert both fail.

- [ ] **Step 2: Run RED test**

Run: `bash tests/test-v3212-integrity.sh`

Expected: co-tampering currently passes because `CHAIN.json` is mutable and legacy entries have no chained hash.

- [ ] **Step 3: Implement root and exact-set checks**

Generate `references/manifest-root.json` as canonical sorted legacy inventory through v3.21.1 plus SHA-256 of `CHAIN.json`. Because this file is outside `references/manifest/`, v3.21.2's tree manifest protects it. Make `verify_ledger` require exact manifest-file/ledger/root equality, unique ascending versions, valid parent SHA, and a chain head matching the current version. Reject any root/ledger/manifest mismatch before stage or activate.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test-v3212-integrity.sh`

Expected: rewriting a legacy manifest and its mutable ledger entry still fails because the protected root no longer matches.

### Task 4: Correct copy sync, release rollback, and Codex metadata

**Files:**
- Modify: `scripts/sync-copies.sh`
- Modify: `scripts/release.sh`
- Modify: `agents/openai.yaml`
- Modify: `tests/test-release-hardening.sh`
- Modify: `tests/test-v3212-integrity.sh`

- [ ] **Step 1: Write failing copy and release tests**

Create a source/target fixture with a runtime file under `tests/logs/` and one ordinary content drift; assert `sync-copies.sh --apply` does not copy the runtime log. Add a B3 fixture in which apply succeeds but the final check is forced to fail; assert rollback is requested. Assert `agents/openai.yaml` has top-level `interface`, `policy`, and `dependencies` keys.

- [ ] **Step 2: Run RED tests**

Run: `bash tests/test-release-hardening.sh && bash tests/test-v3212-integrity.sh`

Expected: rsync copies logs and B3 lacks a rollback marker; current metadata has unsupported top-level keys.

- [ ] **Step 3: Implement minimal fixes**

Add `tests/logs/` to rsync and both portable apply/delete exclusions. Mark B3 copy recheck failure rollback-eligible and create an exclusive release lock with cleanup trap. Keep source-manifest rollback explicit; emit a recovery record when a real copy may already have changed. Replace `agents/openai.yaml` with the documented `interface`, `policy`, and optional empty `dependencies` structure.

- [ ] **Step 4: Verify GREEN**

Run: `bash tests/test-release-hardening.sh && bash tests/test-v3212-integrity.sh`

Expected: runtime logs remain local, B3 failure enters rollback, and metadata has the supported shape.

### Task 5: Publish v3.21.2 and verify the complete release path

**Files:**
- Modify: `SKILL.md`, `README.md`, active `commands/`, `phases/`, `subagents/`, `concepts/`, `agents/openai.yaml`, script banners, and `references/CHANGELOG.md`
- Test: `tests/run-tests.sh`, `scripts/check-skill-version.sh`, `scripts/release-audit.sh`, `scripts/release.sh`

- [ ] **Step 1: Bump the release version**

Use the existing version-consistency convention to change every active version stamp from `3.21.1` to `3.21.2`; update `metadata.updated` to the release date and add one changelog entry describing strict attestation, protected manifest root, and release/sync behavior.

- [ ] **Step 2: Run focused and full verification**

Run: `bash tests/test-v3203-hardening.sh`, `bash tests/test-v3212-integrity.sh`, `bash tests/run-tests.sh`, `bash scripts/check-skill-version.sh`, and `bash scripts/release-audit.sh`.

Expected: each exits 0, all release tests are rerunnable after publication, and no current manifest is overwritten.

- [ ] **Step 3: Run the sole publish entry**

Run: `bash scripts/release.sh`

Expected: `RELEASE GATE: ALL GREEN`; manifest v3.21.2, root inventory, ledger, and linked user copies agree.
