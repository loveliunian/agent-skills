#!/usr/bin/env bash
# gen-skill-manifest.sh · 发布 manifest 生成/校验（版本随 SKILL.md）
# 生成 references/manifest/<version>.json（文件清单 + tree_hash + 链字段），或校验当前树与已发布 manifest 一致。
# v3.15.1 不可变发布记录：
#   - generate：同版本 manifest 已存在即拒绝（exit 1）——manifest 是不可变发布记录，
#     不是可重写的自校验清单；内容变更必须递增版本号后重新发布。
#   - check：全量明细校验——除 tree_hash 外，逐文件核对 SHA-256，并核对文件集合
#     （manifest 缺文件/多文件均 FAIL），杜绝"明细被篡改仍 exit 0"。
# v3.20.3 防历史篡改（hash-chain）：
#   - tree_hash 排除 manifest 目录本身（自引用必需），历史 manifest 由此可被静默
#     改写而不被任何校验发现（审计实证：改 tree_hash 后 check 仍 PASS）。
#   - 新增 CHAIN.json 台账：记录每份 manifest 的字节 SHA-256（manifest_sha256）与
#     递归 chain_hash（chain_n = sha256("chain-v1\n" + version_n + "\n" + tree_hash_n
#     + "\n" + chain_hash_{n-1})，genesis=64 个 0）。check 同时校验：
#     ① 台账每条目对应 manifest 文件字节未变（任何历史篡改即 FAIL）；
#     ② 链重算一致（台账与 manifest 内嵌 chain_hash 互证）；
#     ③ 当前版本是台账最后一项（链头）。
#   - 历史 manifest（<3.20.3）一字节不改：台账以 legacy 条目（chain_hash=null）收录，
#     字节 SHA 同样受绑定。台账只追加不回写（append-only）。
#   - stage/activate 两段式供 release.sh 原子发布：stage 只写外部临时文件不动仓库，
#     activate 校验（含 TOCTOU 重验）后原子落盘 + 台账追加，失败自动回滚。
set -uo pipefail
export LC_ALL=C
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
VERSION=$(sed -n 's/^version: "\([0-9.]*\)"/\1/p; s/^  version: "\([0-9.]*\)"/\1/p' "$ROOT/SKILL.md" | head -1)
MODE="${1:-generate}"
MANIFEST_DIR="$ROOT/references/manifest"
MANIFEST="$MANIFEST_DIR/${VERSION}.json"
LEDGER="$MANIFEST_DIR/CHAIN.json"
CHAIN_GENESIS="0000000000000000000000000000000000000000000000000000000000000000"
# v3.15.3: 版本解析失败守卫（否则会静默产出空名 .json——对比 audit-receipts 的同类守卫）
[ -n "$VERSION" ] || { echo "[FAIL] 无法解析 SKILL.md 版本——版本源读取失败时拒绝生成"; exit 2; }

command -v jq >/dev/null 2>&1 || { echo "[FAIL] gen-skill-manifest 需要 jq"; exit 2; }

_hash_tool() {
  if command -v shasum >/dev/null 2>&1; then printf 'shasum'; return 0; fi
  if command -v sha256sum >/dev/null 2>&1; then printf 'sha256sum'; return 0; fi
  return 1
}
hash_one() {
  local tool
  tool=$(_hash_tool) || return 1
  case "$tool" in
    shasum)    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}' ;;
    sha256sum) sha256sum "$1" 2>/dev/null | awk '{print $1}' ;;
  esac
}
chain_step() {
  # chain_step <version> <tree_hash> <prev_chain> —— 与文件头注释公式严格一致
  printf 'chain-v1\n%s\n%s\n%s' "$1" "$2" "$3" | {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'; else sha256sum | awk '{print $1}'; fi
  }
}

tree_files() {
  # v3.16.0: _archive 排除——与 release-audit active_files 对齐（归档不进发布包）
  find "$ROOT" -type f \
    ! -path "$ROOT/.backups/*" ! -path "$ROOT/_archive/*" ! -path "$ROOT/.devflow/*" ! -path "$ROOT/.git/*" \
    ! -path "$ROOT/tests/logs/*" \
    ! -path "$ROOT/references/manifest/*" ! -name '.DS_Store' \
    ! -name '*.bak' ! -name '*.bak-devflow' \
    ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' ! -name '*.pyc' 2>/dev/null | LC_ALL=C sort \
    | while IFS= read -r f; do printf '%s\n' "${f#"$ROOT"/}"; done
}

# 数值三元组版本排序键（不依赖 sort -V 的 BSD/GNU 差异）
ver_key() { printf '%s' "$1" | awk -F. '{printf "%06d%06d%06d", $1, $2, $3}'; }

# manifest 目录中排在 <version> 之前的最大版本（parent）；无则输出空
find_parent() {
  local ver="$1" best="" best_key="" f v k
  for f in "$MANIFEST_DIR"/*.json; do
    [ -f "$f" ] || continue
    v=$(basename "$f" .json)
    [ "$v" = "CHAIN" ] && continue
    [ "$v" = "$ver" ] && continue
    k=$(ver_key "$v")
    if [ "$k" \< "$(ver_key "$ver")" ]; then
      if [ -z "$best_key" ] || [ "$k" \> "$best_key" ]; then best="$v"; best_key="$k"; fi
    fi
  done
  printf '%s' "$best"
}

# 台账中 <version> 前一版的 chain_hash；无/legacy 条目输出 GENESIS
parent_chain() {
  local parent="$1"
  [ -n "$parent" ] || { printf '%s' "$CHAIN_GENESIS"; return; }
  local ch=""
  [ -f "$LEDGER" ] && ch=$(jq -r --arg p "$parent" '(.entries[] | select(.version==$p) | .chain_hash) // empty' "$LEDGER" 2>/dev/null | head -1)
  [ -n "$ch" ] && { printf '%s' "$ch"; return; }
  printf '%s' "$CHAIN_GENESIS"
}

# 台账完整性校验：逐条目字节 SHA + 链重算（任何历史 manifest 篡改即 FAIL）
verify_ledger() {
  [ -f "$LEDGER" ] || { echo "[FAIL] 台账缺失: $LEDGER"; return 1; }
  jq -e '.entries | type == "array"' "$LEDGER" >/dev/null 2>&1 || { echo "[FAIL] 台账结构非法"; return 1; }
  local n total prev_chain sha ev ver f ch want
  total=$(jq -r '.entries | length' "$LEDGER")
  prev_chain="$CHAIN_GENESIS"
  for ((n=0; n<total; n++)); do
    ev=$(jq -r ".entries[$n]" "$LEDGER")
    ver=$(printf '%s' "$ev" | jq -r '.version')
    f="$MANIFEST_DIR/${ver}.json"
    if [ ! -f "$f" ]; then
      echo "[FAIL] 台账条目对应 manifest 缺失: $ver"
      return 1
    fi
    sha=$(hash_one "$f")
    if [ "$sha" != "$(printf '%s' "$ev" | jq -r '.manifest_sha256')" ]; then
      echo "[FAIL] 历史 manifest 被篡改（字节 SHA 与台账不符）: $ver"
      return 1
    fi
    ch=$(printf '%s' "$ev" | jq -r '.chain_hash // empty')
    if [ -n "$ch" ]; then
      want=$(chain_step "$ver" "$(printf '%s' "$ev" | jq -r '.tree_hash')" "$prev_chain")
      if [ "$ch" != "$want" ]; then
        echo "[FAIL] 链重算不一致: $ver"
        return 1
      fi
      prev_chain="$ch"
    fi
  done
  return 0
}

# 从既有 manifest 引导台账（legacy 条目；已存在则幂等跳过）
init_ledger() {
  [ -f "$LEDGER" ] && return 0
  mkdir -p "$MANIFEST_DIR" || return 1
  local entries="[]" tmp f v
  tmp=$(mktemp) || return 1
  for f in "$MANIFEST_DIR"/*.json; do
    [ -f "$f" ] || continue
    v=$(basename "$f" .json)
    [ "$v" = "$VERSION" ] && continue
    entries=$(printf '%s' "$entries" | jq --arg v "$v" \
      --arg sha "$(hash_one "$f")" \
      --arg tree "$(jq -r '.tree_hash // empty' "$f")" \
      '. + [{version:$v, manifest_sha256:$sha, tree_hash:$tree, chain_hash:null}]') || { rm -f "$tmp"; return 1; }
  done
  entries=$(printf '%s' "$entries" | jq 'sort_by((.version | split(".") | map(tonumber)))')
  jq -n --argjson entries "$entries" '{schema:"chain-v1", entries:$entries}' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LEDGER" || { rm -f "$tmp"; return 1; }
  echo "[OK] 台账引导完成: $LEDGER ($(printf '%s' "$entries" | jq 'length') 条 legacy 绑定，历史文件一字节未动)"
}

# 追加当前 manifest 的台账条目（原子写；chain_hash 取 manifest 内嵌值）
append_ledger() {
  # append_ledger <manifest-file>
  local mf="$1" ver sha tree ch tmp
  ver=$(jq -r '.version' "$mf")
  sha=$(hash_one "$mf")
  tree=$(jq -r '.tree_hash' "$mf")
  ch=$(jq -r '.chain_hash // empty' "$mf")
  [ -n "$ch" ] || ch=$(chain_step "$ver" "$tree" "$(parent_chain "$(jq -r '.parent // empty' "$mf")")")
  tmp=$(mktemp) || return 1
  jq --arg ver "$ver" --arg sha "$sha" --arg tree "$tree" --arg ch "$ch" \
    '.entries += [{version:$ver, manifest_sha256:$sha, tree_hash:$tree, chain_hash:$ch}]' \
    "$LEDGER" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$LEDGER" || { rm -f "$tmp"; return 1; }
}

case "$MODE" in
  stage)
    # v3.20.3: 供 release.sh 原子发布——只写外部临时文件，不动 manifest/台账（只读预检段安全）
    STAGE_OUT="${2:-}"
    [ -n "$STAGE_OUT" ] || { echo "[FAIL] stage 用法: $0 stage <output-file>"; exit 2; }
    [ -f "$MANIFEST" ] && { echo "[FAIL] manifest 已存在: ${MANIFEST}（同版本禁止重写，须升版）"; exit 1; }
    TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh") || { echo "[FAIL] 树哈希计算失败"; exit 1; }
    PARENT=$(find_parent "$VERSION")
    PARENT_CHAIN=$(parent_chain "$PARENT")
    TMP_MANIFEST=$(mktemp) || { echo "[FAIL] 无法创建临时文件" >&2; exit 1; }
    trap 'rm -f "$TMP_MANIFEST"' EXIT
    {
      echo "{"
      echo "  \"version\": \"$VERSION\","
      echo "  \"generated_at\": \"deterministic-by-version\","
      echo "  \"tree_hash\": \"$TREE\","
      if [ -n "$PARENT" ]; then
        echo "  \"parent\": \"$PARENT\","
        echo "  \"parent_manifest_sha256\": \"$(hash_one "$MANIFEST_DIR/${PARENT}.json")\","
      else
        echo "  \"parent\": null,"
        echo "  \"parent_manifest_sha256\": null,"
      fi
      echo "  \"chain_hash\": \"$(chain_step "$VERSION" "$TREE" "$PARENT_CHAIN")\","
      echo "  \"files\": {"
      first=1
      while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        SHA=$(hash_one "$ROOT/$rel")
        if [ -z "$SHA" ] || ! printf '%s' "$SHA" | grep -qE '^[0-9a-f]{64}$'; then
          echo "[FAIL] 文件哈希失败: $rel" >&2
          exit 1
        fi
        [ "$first" -eq 1 ] && first=0 || printf ',\n'
        printf '    "%s": "%s"' "$rel" "$SHA"
      done < <(tree_files)
      echo ""
      echo "  }"
      echo "}"
    } > "$TMP_MANIFEST"
    if ! jq empty "$TMP_MANIFEST" 2>/dev/null; then
      echo "[FAIL] 生成的 manifest 非合法 JSON——请重试"
      exit 1
    fi
    mv "$TMP_MANIFEST" "$STAGE_OUT"
    trap - EXIT
    echo "[OK] staged manifest: $STAGE_OUT (tree_hash=$TREE, parent=${PARENT:-none}——activate 前不落盘)"
    ;;
  activate)
    # v3.20.3: release.sh 专用——staged 文件校验通过后原子落盘 + 台账追加；失败回滚
    STAGE_IN="${2:-}"
    [ -n "$STAGE_IN" ] && [ -f "$STAGE_IN" ] || { echo "[FAIL] activate 用法: $0 activate <staged-file>"; exit 2; }
    [ -f "$MANIFEST" ] && { echo "[FAIL] manifest 已存在: ${MANIFEST}（并发发布或重复 activate）"; exit 1; }
    jq -e --arg v "$VERSION" '.version == $v and (.tree_hash | test("^[0-9a-f]{64}$")) and (.chain_hash | test("^[0-9a-f]{64}$"))' "$STAGE_IN" >/dev/null 2>&1 \
      || { echo "[FAIL] staged manifest 版本/字段校验失败"; exit 1; }
    # TOCTOU 防护：stage 与 activate 之间树若漂移则拒绝
    CUR_TREE=$(bash "$ROOT/scripts/gate-skill-tree.sh") || { echo "[FAIL] 树哈希计算失败"; exit 1; }
    [ "$(jq -r '.tree_hash' "$STAGE_IN")" = "$CUR_TREE" ] || { echo "[FAIL] stage 后树已漂移——重新 stage"; exit 1; }
    init_ledger || { echo "[FAIL] 台账引导失败"; exit 1; }
    verify_ledger || { echo "[FAIL] 台账完整性校验失败——拒绝在此之上追加发布"; exit 1; }
    cp "$STAGE_IN" "$MANIFEST.tmp-activate" || { echo "[FAIL] 无法暂存 manifest"; exit 1; }
    mv "$MANIFEST.tmp-activate" "$MANIFEST" || { rm -f "$MANIFEST.tmp-activate"; echo "[FAIL] manifest 原子落盘失败"; exit 1; }
    if ! append_ledger "$MANIFEST"; then
      echo "[FAIL] 台账追加失败——回滚本次 manifest"
      rm -f "$MANIFEST"
      exit 1
    fi
    if ! bash "$0" check >/dev/null 2>&1; then
      echo "[FAIL] 激活后自校验不通过——回滚本次 manifest 与台账"
      LEDGER_TMP=$(mktemp)
      if jq --arg v "$VERSION" '.entries |= map(select(.version != $v))' "$LEDGER" > "$LEDGER_TMP"; then
        mv "$LEDGER_TMP" "$LEDGER"
      else
        rm -f "$LEDGER_TMP"
      fi
      rm -f "$MANIFEST"
      exit 1
    fi
    echo "[OK] manifest 已激活: ${MANIFEST}（台账已追加，链头=$(jq -r '.entries[-1].version' "$LEDGER")）"
    ;;
  generate)
    # v3.15.1: 不可变发布记录——同版本 manifest 已存在即拒绝覆盖
    if [ -f "$MANIFEST" ]; then
      echo "[FAIL] manifest 已存在: $MANIFEST"
      echo "       同版本 manifest 是不可变发布记录，禁止覆盖重写。"
      echo "       修复指引: 递增 SKILL.md 版本号后重新 generate；被污染的已发布版本须作废并升版。"
      exit 1
    fi
    mkdir -p "$MANIFEST_DIR"
    STAGED=$(mktemp) || { echo "[FAIL] 无法创建临时文件" >&2; exit 1; }
    if ! bash "$0" stage "$STAGED"; then
      rm -f "$STAGED"
      exit 1
    fi
    if bash "$0" activate "$STAGED"; then
      rm -f "$STAGED"
      echo "[OK] generate 完成（不可变——同版本禁止重写；全部历史 manifest 由 CHAIN.json 绑定）"
    else
      rm -f "$STAGED"
      echo "[FAIL] activate 失败——未发布（详见上文）"
      exit 1
    fi
    ;;
  check)
    [ -f "$MANIFEST" ] || { echo "[FAIL] manifest 缺失: $MANIFEST —— 先运行 gen-skill-manifest.sh generate"; exit 1; }
    # ① JSON 结构合法性
    if ! jq -e '.version and .tree_hash and (.files | type == "object")' "$MANIFEST" >/dev/null 2>&1; then
      echo "[FAIL] manifest 结构非法（缺少 version/tree_hash/files）: $MANIFEST"; exit 1
    fi
    MV=$(jq -r '.version' "$MANIFEST")
    if [ "$MV" != "$VERSION" ]; then
      echo "[FAIL] manifest version=$MV 与 SKILL.md 版本 $VERSION 不一致"; exit 1
    fi
    # ② tree_hash 与当前树一致
    EXPECTED=$(jq -r '.tree_hash' "$MANIFEST")
    if ! printf '%s' "$EXPECTED" | grep -qE '^[0-9a-f]{64}$'; then
      echo "[FAIL] manifest tree_hash 非法: $EXPECTED"; exit 1
    fi
    ACTUAL=$(bash "$ROOT/scripts/gate-skill-tree.sh") || { echo "[FAIL] 树哈希计算失败"; exit 1; }
    if [ "$EXPECTED" != "$ACTUAL" ]; then
      echo "[FAIL] 树 hash 漂移: manifest=$EXPECTED 当前=$ACTUAL —— 内容已变更，需重新发布（升版本号后 generate）"
      exit 1
    fi
    echo "[PASS] 树 hash 与已发布 manifest 一致: $ACTUAL"
    # ③ v3.15.1: 文件集合一致性（缺文件/多文件均 FAIL）
    MANIFEST_FILES=$(mktemp); CURRENT_FILES=$(mktemp)
    trap 'rm -f "$MANIFEST_FILES" "$CURRENT_FILES"' EXIT
    jq -r '.files | keys[]' "$MANIFEST" | LC_ALL=C sort > "$MANIFEST_FILES"
    tree_files > "$CURRENT_FILES"
    MISSING_IN_MANIFEST=$(LC_ALL=C comm -13 "$MANIFEST_FILES" "$CURRENT_FILES")
    EXTRA_IN_MANIFEST=$(LC_ALL=C comm -23 "$MANIFEST_FILES" "$CURRENT_FILES")
    if [ -n "$MISSING_IN_MANIFEST" ]; then
      echo "[FAIL] manifest 缺少文件（当前树有而 manifest 无）:"
      printf '%s\n' "$MISSING_IN_MANIFEST" | sed 's/^/  /'
      exit 1
    fi
    if [ -n "$EXTRA_IN_MANIFEST" ]; then
      echo "[FAIL] manifest 多出文件（manifest 有而当前树无）:"
      printf '%s\n' "$EXTRA_IN_MANIFEST" | sed 's/^/  /'
      exit 1
    fi
    echo "[PASS] 文件清单与当前树一致 ($(wc -l < "$MANIFEST_FILES" | tr -d ' ') files)"
    # ④ v3.15.1: 逐文件 SHA-256 明细校验
    DETAIL_FAIL=0
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      EXPECTED_SHA=$(jq -r --arg p "$rel" '.files[$p] // empty' "$MANIFEST")
      if ! printf '%s' "$EXPECTED_SHA" | grep -qE '^[0-9a-f]{64}$'; then
        echo "[FAIL] manifest 明细哈希非法: $rel -> ${EXPECTED_SHA:-缺失}"
        DETAIL_FAIL=$((DETAIL_FAIL + 1)); continue
      fi
      ACTUAL_SHA=$(hash_one "$ROOT/$rel")
      if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
        echo "[FAIL] 文件明细哈希不匹配: $rel (manifest=$EXPECTED_SHA actual=${ACTUAL_SHA:-读取失败})"
        DETAIL_FAIL=$((DETAIL_FAIL + 1))
      fi
    done < "$MANIFEST_FILES"
    if [ "$DETAIL_FAIL" -gt 0 ]; then
      echo "[FAIL] manifest 明细校验失败 ${DETAIL_FAIL} 项"
      exit 1
    fi
    echo "[PASS] 全部文件明细 SHA-256 校验通过"
    # ⑤ v3.20.3: hash-chain 校验——历史 manifest 字节不可变 + 链重算 + 当前为链头
    if [ ! -f "$LEDGER" ]; then
      echo "[FAIL] 台账缺失: $LEDGER —— 历史不可变性无锚点（先 chain-init 或 generate）"
      exit 1
    fi
    if ! verify_ledger; then
      echo "[FAIL] hash-chain 校验失败（见上文）——发布记录完整性被破坏"
      exit 1
    fi
    CHAIN_OK=$(jq -r --arg v "$VERSION" --arg ch "$(jq -r '.chain_hash // empty' "$MANIFEST")" \
      '(.entries[-1].version == $v) and ((.entries[-1].chain_hash // "") == $ch)' "$LEDGER" 2>/dev/null)
    if [ "$CHAIN_OK" != "true" ]; then
      echo "[FAIL] 当前版本不是台账链头或 chain_hash 与台账不符（version=${VERSION}）"
      exit 1
    fi
    echo "[PASS] hash-chain 完整（$(jq -r '.entries | length' "$LEDGER") 条发布记录，链头=${VERSION}）"
    ;;
  chain-init)
    init_ledger || { echo "[FAIL] 台账引导失败"; exit 1; }
    verify_ledger || { echo "[FAIL] 引导后台账校验失败"; exit 1; }
    echo "[OK] chain-init 校验通过"
    ;;
  *) echo "Usage: $0 generate|check|stage <out>|activate <staged>|chain-init"; exit 2 ;;
esac
