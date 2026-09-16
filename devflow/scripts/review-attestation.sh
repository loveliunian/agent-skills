#!/usr/bin/env bash
# Verifies externally signed review lifecycle events. This skill never signs.
set -uo pipefail
export LC_ALL=C

fail() { echo "[ATTESTATION-ERR] $*" >&2; exit 1; }
usage() { echo "Usage: $0 verify --event begin|complete --feature F --session-id S --role R --agent-id A --input-sha SHA --output-sha SHA --attestation FILE"; exit 2; }

EVENT=""; FEATURE=""; SESSION_ID=""; ROLE=""; AGENT_ID=""; INPUT_SHA=""; OUTPUT_SHA=""; ATTESTATION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    verify) shift ;;
    --event) EVENT="${2:-}"; shift 2 ;;
    --feature) FEATURE="${2:-}"; shift 2 ;;
    --session-id) SESSION_ID="${2:-}"; shift 2 ;;
    --role) ROLE="${2:-}"; shift 2 ;;
    --agent-id) AGENT_ID="${2:-}"; shift 2 ;;
    --input-sha) INPUT_SHA="${2:-}"; shift 2 ;;
    --output-sha) OUTPUT_SHA="${2:-}"; shift 2 ;;
    --attestation) ATTESTATION="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done

[ "$EVENT" = "begin" ] || [ "$EVENT" = "complete" ] || fail "event must be begin or complete"
[ -n "$FEATURE" ] && [ -n "$SESSION_ID" ] && [ -n "$ROLE" ] && [ -n "$AGENT_ID" ] || fail "event identity is incomplete"
printf '%s' "$INPUT_SHA" | grep -qE '^[0-9a-f]{64}$' || fail "input SHA256 is invalid"
if [ "$EVENT" = "complete" ]; then
  printf '%s' "$OUTPUT_SHA" | grep -qE '^[0-9a-f]{64}$' || fail "complete output SHA256 is invalid"
else
  [ -z "$OUTPUT_SHA" ] || fail "begin output SHA256 must be empty"
fi
[ -n "${REVIEW_ATTESTATION_PUBKEY:-}" ] || fail "REVIEW_ATTESTATION_PUBKEY is required for strict review attestation"
[ -f "$REVIEW_ATTESTATION_PUBKEY" ] || fail "attestation public key missing: $REVIEW_ATTESTATION_PUBKEY"
[ -n "$ATTESTATION" ] && [ -f "$ATTESTATION" ] || fail "attestation file is required"
command -v jq >/dev/null 2>&1 || fail "jq is required"
command -v openssl >/dev/null 2>&1 || fail "openssl is required"

[ "$(jq -r '.payload.schema // empty' "$ATTESTATION" 2>/dev/null)" = "devflow-review-attestation-v1" ] || fail "attestation schema is invalid"
for field in feature session_id role agent_id event input_sha output_sha issued_at nonce; do
  jq -e --arg f "$field" '.payload[$f] != null' "$ATTESTATION" >/dev/null 2>&1 || fail "attestation payload missing $field"
done
match() { [ "$(jq -r --arg f "$1" '.payload[$f]' "$ATTESTATION")" = "$2" ] || fail "attestation $1 does not match receipt transition"; }
match feature "$FEATURE"; match session_id "$SESSION_ID"; match role "$ROLE"; match agent_id "$AGENT_ID"; match event "$EVENT"; match input_sha "$INPUT_SHA"; match output_sha "$OUTPUT_SHA"
nonce=$(jq -r '.payload.nonce' "$ATTESTATION")
printf '%s' "$nonce" | grep -qE '^[A-Za-z0-9._-]{16,128}$' || fail "attestation nonce is invalid"
issued_at=$(jq -r '.payload.issued_at' "$ATTESTATION")
printf '%s' "$issued_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || fail "attestation issued_at is invalid"

tmpdir=$(mktemp -d) || fail "cannot create verification directory"
trap 'rm -rf "$tmpdir"' EXIT
jq -cS '.payload' "$ATTESTATION" > "$tmpdir/payload.json" || fail "cannot canonicalize attestation payload"
jq -r '.signature_b64 // empty' "$ATTESTATION" | openssl base64 -d -A -out "$tmpdir/signature.bin" 2>/dev/null || fail "attestation signature is invalid base64"
openssl dgst -sha256 -verify "$REVIEW_ATTESTATION_PUBKEY" -signature "$tmpdir/signature.bin" "$tmpdir/payload.json" >/dev/null 2>&1 || fail "attestation signature verification failed"
shasum -a 256 "$ATTESTATION" | awk '{print $1}'
