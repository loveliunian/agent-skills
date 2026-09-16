#!/usr/bin/env bash
# flow-test-contract skill → 项目部署脚本（skill 自持后项目侧的唯一入口）
#
# 分发清单唯一事实源：MANIFEST.txt（与本脚本同目录）——存在性校验、复制、字节一致性
# 校验全部以其为准，本脚本不手写任何文件列表（手写列表必然与实际漂移——第三十四轮 P0）。
#
# 职责：按 MANIFEST 把执行链（scripts/）与立契链（templates/）部署进项目：
#   scripts/*   → <project>/.flow-test-contract/scripts/      （契约模式执行链；不动 run-all-plants.js 等既有脚本）
#   templates/* → <project>/docs/自动化测试模板/      （立契/校验/生成/自检）
#   assets/systems-*/*.yaml → <project>/.flow-test-contract/runtime/systems/…（仅当缺失时落示例，绝不覆盖）
#
# 用法：
#   bash install.sh [project-root]           # 缺省=当前目录 git 根；复制 + 字节一致性校验
#   bash install.sh --check [project-root]   # 仅校验已部署副本与 skill 源字节一致（CI 发布门禁，零写入）
# 注意：skill 自持布局默认无需本脚本即可运行——部署副本仅供干净 clone 的 CI 使用。
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SRC/MANIFEST.txt"
[ -f "$MANIFEST" ] || { echo "⛔ 缺分发清单: $MANIFEST"; exit 1; }

CHECK_ONLY=false
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=true; shift; fi
PROJ="${1:-}"
if [ -z "$PROJ" ]; then
  PROJ="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")"
fi
PROJ="$(cd "$PROJ" && pwd)"

if [ "$CHECK_ONLY" = true ]; then
  echo "校验 flow-test-contract 部署副本与 skill 源字节一致 → $PROJ"
else
  echo "部署 flow-test-contract → $PROJ"
fi

# ---------- 按 MANIFEST 逐条处理（列2为空 = 仅随 skill 存在，不部署） ----------
fail=0; copied=0
while IFS=$'\t' read -r rel dst; do
  case "$rel" in ''|'#'*) continue ;; esac
  if [ ! -f "$SRC/$rel" ]; then
    echo "⛔ skill 缺 $SRC/${rel}（MANIFEST.txt 与实际文件漂移——先修清单）"; fail=1; continue
  fi
  [ -n "$dst" ] || continue
  if [ "$CHECK_ONLY" = true ]; then
    cmp -s "$SRC/$rel" "$PROJ/$dst" || { echo "⛔ $dst 与 skill 源不一致（重跑 install.sh 修复）" >&2; fail=1; }
  else
    mkdir -p "$PROJ/$(dirname "$dst")"
    cp "$SRC/$rel" "$PROJ/$dst" && copied=$((copied+1))
  fi
done < "$MANIFEST"
[ $fail -eq 0 ] || exit 1
if [ "$CHECK_ONLY" = true ]; then
  echo "✅ 部署副本与 skill 源字节一致（MANIFEST 全部条目校验通过）"
  exit 0
fi

# ---------- systems 配置种子：项目已有（可能已按真实端点调过）则不动，缺则落示例 ----------
for side in legacy current; do
  sysdir="$PROJ/.flow-test-contract/runtime/systems/api"
  if [ ! -f "$sysdir/$side.yaml" ]; then
    mkdir -p "$sysdir"
    cp "$SRC/assets/systems-api/$side.yaml" "$sysdir/$side.yaml"
    echo "  + .flow-test-contract/runtime/systems/api/$side.yaml（示例，端点按项目实际调整）"
  else
    echo "  = .flow-test-contract/runtime/systems/api/$side.yaml 已存在，保留项目配置"
  fi
done
[ -f "$PROJ/.flow-test-contract/runtime/env.example" ] || { mkdir -p "$PROJ/.flow-test-contract/runtime"; cp "$SRC/assets/env.flowtest.example" "$PROJ/.flow-test-contract/runtime/env.example"; }

echo "完成（按 MANIFEST 复制 $copied 个文件）。后续："
echo "  1) 建议 git add 上述文件并跟踪（干净 clone 的 CI 直接可用；skill 自持布局不依赖项目副本）"
echo "  2) python3 docs/自动化测试模板/selftest.py 验证负向回归全绿（退出码 0；项数以 selftest 输出为准）"
echo "  3) 调整 .flow-test-contract/runtime/systems/api/*.yaml 端点与 .flow-test-contract/runtime/env 凭据（cp env.example env）后即可跑 pipeline"
echo "     老系统端点待按 references/f12-record.md F12 录完；占位残留时"
echo "     api-capture 与 legacy-config-check 都会立即拒绝（绝不假跑）"

# ---------- 部署后字节一致性校验（脚本被并行修改过会在此暴露） ----------
fail=0
while IFS=$'\t' read -r rel dst; do
  case "$rel" in ''|'#'*) continue ;; esac
  [ -n "$dst" ] || continue
  cmp -s "$SRC/$rel" "$PROJ/$dst" || { echo "⛔ $dst 与 skill 源不一致（项目副本被手改过？以 skill 为准重新 cp）" >&2; fail=1; }
done < "$MANIFEST"
[ $fail -eq 0 ] && echo "✅ 全部部署文件与 skill 源字节一致" || exit 1
