#!/usr/bin/env bash
source "$(cd "$(dirname "$0")" && pwd)/testlib.sh"

echo "=== devflow client platform tests ==="
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/web-no-tests" "$TMP/web/tests"
printf '{"scripts":{"build":"true"}}\n' > "$TMP/web-no-tests/package.json"
printf '{"scripts":{"build":"true","type-check":"true","test":"true"}}\n' > "$TMP/web/package.json"
printf 'export {}\n' > "$TMP/web/tests/smoke.test.ts"

if bash "$ROOT/checks/check-frontend-standards.sh" "$TMP/web-no-tests" --strict >/dev/null 2>&1; then
  bad "strict PC Web validation rejects missing tests"
else
  ok "strict PC Web validation rejects missing tests"
fi
if bash "$ROOT/checks/check-frontend-standards.sh" "$TMP/web" --strict >/dev/null 2>&1; then
  ok "strict PC Web validation accepts build/type/test scripts"
else
  bad "strict PC Web validation accepts build/type/test scripts"
fi
if bash "$ROOT/checks/check-frontend-standards.sh" "$TMP/missing-client" --not-applicable >/dev/null 2>&1; then
  ok "backend-only scope is explicit"
else
  bad "backend-only scope is explicit"
fi

mkdir -p "$TMP/mini/pages/home" "$TMP/app/lib"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/mini/command.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/app/command.sh"
chmod +x "$TMP/mini/command.sh" "$TMP/app/command.sh"
printf 'mini artifact\n' > "$TMP/mini/mini.zip"
printf 'app artifact\n' > "$TMP/app/app.apk"
printf '{"pages":["pages/home/index"]}\n' > "$TMP/mini/app.json"
printf '<view>home</view>\n' > "$TMP/mini/pages/home/index.wxml"
printf '{"platform":"mini-program","commands":{"build":["./command.sh"],"test":["./command.sh"],"release":["./command.sh"]},"pages":["pages/home/index"],"release_evidence":"artifact=mini.zip;version=1.0.0;location=preview"}\n' > "$TMP/mini/devflow-client.json"
printf 'void main() {}\n' > "$TMP/app/lib/main.dart"
printf '{"platform":"app","commands":{"build":["./command.sh"],"test":["./command.sh"],"release":["./command.sh"]},"pages":["lib/main.dart"],"release_evidence":"artifact=app.apk;version=1.0.0;location=store"}\n' > "$TMP/app/devflow-client.json"

for item in "mini-program:$TMP/mini" "app:$TMP/app"; do
  platform=${item%%:*}
  dir=${item#*:}
  if bash "$ROOT/scripts/client-adapter.sh" validate "$platform" "$dir" --strict >/dev/null 2>&1; then
    ok "$platform manifest validates"
  else
    bad "$platform manifest validates"
  fi
  if bash "$ROOT/scripts/client-adapter.sh" release "$platform" "$dir" --strict >/dev/null 2>&1; then
    ok "$platform release command executes"
  else
    bad "$platform release command executes"
  fi
done

if command -v jq >/dev/null 2>&1 && \
   WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" init client-fixture --frontend=mini-program --frontend-dir="$TMP/mini" >/dev/null && \
   WORKSPACE="$TMP/state" bash "$ROOT/scripts/devflow-state.sh" client-freeze client-fixture >/dev/null && \
   jq -e '.scope.client_manifest_sha256 | strings | length == 64' "$TMP/state/.devflow/client-fixture.state.json" >/dev/null; then
  ok "state freezes client manifest hash"
else
  bad "state freezes client manifest hash"
fi

finish CLIENTS
