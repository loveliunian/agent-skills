#!/usr/bin/env bash
# Client platform adapter for PC Web, WeChat Mini Programs, and APPs.
set -uo pipefail

ACTION="${1:-}"
PLATFORM="${2:-}"
CLIENT_DIR="${3:-}"
STRICT=0
EXPECTED_MANIFEST_SHA=""
shift 3 2>/dev/null || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift ;;
    --expected-manifest-sha) { [ -n "${2:-}" ] && [ "${2#-}" = "${2:-}" ]; } || { echo "[FAIL] --expected-manifest-sha requires a non-flag value"; exit 2; }; EXPECTED_MANIFEST_SHA="$2"; shift 2 ;;
    *) echo "[FAIL] unknown argument: $1"; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
FAIL=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; FAIL=$((FAIL + 1)); }

usage() {
  echo "Usage: $0 <validate|build|test|release|hash> <pc-web|mini-program|app|not-applicable> <client-dir> [--strict] [--expected-manifest-sha <sha256>]"
  exit 2
}

[ -n "$ACTION" ] && [ -n "$PLATFORM" ] && [ -n "$CLIENT_DIR" ] || usage
manifest="$CLIENT_DIR/devflow-client.json"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

require_manifest() {
  [ -f "$manifest" ] || { fail "missing client manifest: $manifest"; return; }
  command -v jq >/dev/null 2>&1 || { fail "jq is required for client manifest"; return; }
  actual=$(jq -r '.platform // empty' "$manifest" 2>/dev/null)
  [ "$actual" = "$PLATFORM" ] || fail "manifest platform '$actual' != '$PLATFORM'"
  for key in build test release; do
    jq -e --arg key "$key" '.commands[$key] | arrays | length > 0 and all(.[]; type == "string" and length > 0)' "$manifest" >/dev/null 2>&1 || fail "manifest commands.$key must be a non-empty argv array"
    executable=$(jq -r --arg key "$key" '.commands[$key][0] // empty' "$manifest" 2>/dev/null)
    case "$executable" in
      true|:|echo|replace-with-*|*/true|*/echo) fail "manifest commands.$key uses a placeholder executable: $executable" ;;
    esac
  done
  jq -e '.pages | arrays | length > 0 and all(.[]; type == "string" and length > 0)' "$manifest" >/dev/null 2>&1 || fail "manifest pages must be a non-empty string array"
}

# v3.14.1: 发布制品校验从结构校验中拆出——仅 release 动作要求；
# validate/hash/build/test 发生在 P2 冻结~P6 阶段，此时 P7 制品尚不存在（生命周期死锁修复）
require_release_evidence() {
  [ -f "$manifest" ] || { fail "missing client manifest: $manifest"; return; }
  command -v jq >/dev/null 2>&1 || { fail "jq is required for client manifest"; return; }
  release_evidence=$(jq -r '.release_evidence // empty' "$manifest" 2>/dev/null)
  artifact_path=$(printf '%s' "$release_evidence" | sed -n 's/.*artifact=\([^;]*\).*/\1/p')
  if printf '%s' "$release_evidence" | grep -qE 'artifact=.+;version=.+;location=.+' && [ -n "$artifact_path" ] && [ -f "$CLIENT_DIR/$artifact_path" ]; then
    pass "release evidence artifact exists: $artifact_path"
  else
    fail "release_evidence must identify an existing artifact, version, and location"
  fi
}

verify_manifest_hash() {
  [ -n "$EXPECTED_MANIFEST_SHA" ] || return 0
  actual=$(sha256_file "$manifest" 2>/dev/null || true)
  [ "$actual" = "$EXPECTED_MANIFEST_SHA" ] || { fail "client manifest hash differs from frozen value"; return 1; }
}

validate_pc_web() {
  # v3.15.4: 与 mini-program/app 同口径——manifest 结构 + 冻结哈希校验。
  # 此前 pc-web 的 validate/build/test 完全绕过 manifest：P2 冻结的
  # --expected-manifest-sha 在 P3-P6 生命周期不生效，devflow-client.json 可被篡改至 release 才暴露。
  require_manifest
  verify_manifest_hash
  if [ "$STRICT" -eq 1 ]; then
    bash "$SCRIPT_DIR/../checks/check-frontend-standards.sh" "$CLIENT_DIR" --strict || FAIL=$((FAIL + 1))
  else
    bash "$SCRIPT_DIR/../checks/check-frontend-standards.sh" "$CLIENT_DIR" || FAIL=$((FAIL + 1))
  fi
}

validate_mini_program() {
  [ -f "$CLIENT_DIR/app.json" ] || fail "mini-program requires app.json"
  require_manifest
  verify_manifest_hash
  if [ -f "$CLIENT_DIR/app.json" ] && command -v jq >/dev/null 2>&1; then
    page_count=$(jq -r '.pages | arrays | length' "$CLIENT_DIR/app.json" 2>/dev/null || echo 0)
    [ "${page_count:-0}" -gt 0 ] || fail "mini-program app.json has no pages"
    while IFS= read -r page; do
      [ -z "$page" ] && continue
      if [ -f "$CLIENT_DIR/$page.wxml" ] || [ -f "$CLIENT_DIR/$page.vue" ]; then
        pass "mini-program page exists: $page"
      else
        fail "mini-program page missing: $page (.wxml or .vue)"
      fi
    done < <(jq -r '.pages[]?' "$CLIENT_DIR/app.json" 2>/dev/null)
    manifest_pages=$(mktemp)
    app_pages=$(mktemp)
    jq -c '.pages | sort' "$manifest" > "$manifest_pages" 2>/dev/null
    jq -c '.pages | sort' "$CLIENT_DIR/app.json" > "$app_pages" 2>/dev/null
    if cmp -s "$manifest_pages" "$app_pages"; then
      pass "mini-program manifest pages match app.json"
    else
      fail "mini-program manifest pages differ from app.json"
    fi
    rm -f "$manifest_pages" "$app_pages"
  fi
}

validate_app() {
  require_manifest
  verify_manifest_hash
  if [ -f "$manifest" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r page; do
      [ -z "$page" ] && continue
      [ -f "$CLIENT_DIR/$page" ] && pass "app page exists: $page" || fail "app page missing: $page"
    done < <(jq -r '.pages[]?' "$manifest" 2>/dev/null)
  fi
}

validate() {
  case "$PLATFORM" in
    not-applicable) pass "client scope is not applicable" ;;
    pc-web) validate_pc_web ;;
    mini-program) validate_mini_program ;;
    app) validate_app ;;
    *) fail "unsupported client platform: $PLATFORM" ;;
  esac
}

run_manifest_command() {
  local key="$1"
  local -a command_args=()
  [ -f "$manifest" ] || { fail "missing client manifest: $manifest"; return; }
  while IFS= read -r arg; do command_args+=("$arg"); done < <(jq -r --arg key "$key" '.commands[$key][]?' "$manifest" 2>/dev/null)
  [ "${#command_args[@]}" -gt 0 ] || { fail "manifest commands.$key missing"; return; }
  (cd "$CLIENT_DIR" && "${command_args[@]}") && pass "$PLATFORM $key" || fail "$PLATFORM $key"
}

run_pc_command() {
  local key="$1"
  command -v npm >/dev/null 2>&1 || { fail "npm is required for PC Web $key"; return; }
  (cd "$CLIENT_DIR" && npm run "$key") && pass "pc-web $key" || fail "pc-web $key"
}

case "$ACTION" in
  validate) validate ;;
  hash)
    case "$PLATFORM" in
      pc-web|mini-program|app)
        # v3.15.4: 诊断走 stderr——此前 >/dev/null 2>&1 吞掉失败原因，调用方拿到空哈希无解释
        require_manifest 1>&2
        if [ "$FAIL" -eq 0 ]; then
          sha256_file "$manifest"
        else
          echo "[FAIL] cannot hash client manifest (see diagnostics above)" >&2
        fi ;;
      *) echo "not-applicable" ;;
    esac
    ;;
  build|test|release)
    validate
    if [ "$FAIL" -eq 0 ]; then
      case "$PLATFORM" in
        pc-web)
          if [ "$ACTION" = "release" ]; then
            require_manifest
            require_release_evidence
            [ "$FAIL" -eq 0 ] && { verify_manifest_hash; run_manifest_command release; }
          else
            run_pc_command "$ACTION"
          fi
          ;;
        mini-program|app)
          if [ "$ACTION" = "release" ]; then
            require_manifest
            require_release_evidence
            [ "$FAIL" -eq 0 ] && { verify_manifest_hash; run_manifest_command release; }
          else
            run_manifest_command "$ACTION"
          fi ;;
        not-applicable) pass "client $ACTION not applicable" ;;
      esac
    fi
    ;;
  *) usage ;;
esac

[ "$FAIL" -eq 0 ] || exit 1
