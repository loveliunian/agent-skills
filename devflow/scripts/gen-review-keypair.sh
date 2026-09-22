#!/usr/bin/env bash
# gen-review-keypair.sh · 生成 P2a 评审签名密钥对（降低 attestation 起步门槛，v3.29.5）
# =============================================================================
# 背景：P2a 设计评审的收据两阶段签名（review-attestation.sh）要求环境变量
# REVIEW_ATTESTATION_PUBKEY 指向评审发起方公钥；此前没有任何密钥生成指引，
# 单人/小团队会在 P2a 首次撞上 BLOCKED。
#
# 用法:
#   bash scripts/gen-review-keypair.sh [输出目录] [--force]
#   （默认输出目录 .review-keys；已存在时须 --force 覆盖）
#
# 产物:
#   <目录>/attest-private.pem   私钥（chmod 600）——交给评审发起方，勿入库
#   <目录>/attest-public.pem    公钥——REVIEW_ATTESTATION_PUBKEY 指向它
#
# 用法衔接:
#   export REVIEW_ATTESTATION_PUBKEY=<目录>/attest-public.pem
# 私钥保管: 建议加入 .gitignore；泄露时重新生成并更换公钥（旧收据按当时公钥审计）。
# 另见: scripts/review-attest-init.sh keygen（含 env/sign/verify 完整签名工作流）。
set -euo pipefail

DIR=".review-keys"
FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) DIR="$a" ;;
  esac
done

command -v openssl >/dev/null 2>&1 || { echo "[FAIL] openssl 不可用——无法生成密钥对"; exit 1; }

if [ -e "$DIR/attest-private.pem" ] && [ "$FORCE" -ne 1 ]; then
  echo "[FAIL] $DIR/attest-private.pem 已存在（覆盖须 --force；重生成后旧收据按新公钥审计会失配）"
  exit 1
fi

mkdir -p "$DIR"
openssl genrsa -out "$DIR/attest-private.pem" 2048 >/dev/null 2>&1
openssl rsa -in "$DIR/attest-private.pem" -pubout -out "$DIR/attest-public.pem" >/dev/null 2>&1
chmod 600 "$DIR/attest-private.pem"

echo "[OK] 密钥对已生成: $DIR"
echo "  私钥（评审发起方持有，勿入库）: $DIR/attest-private.pem"
echo "  公钥: $DIR/attest-public.pem"
echo ""
echo "启用（写入 shell profile 或 CI 环境）:"
echo "  export REVIEW_ATTESTATION_PUBKEY=$DIR/attest-public.pem"
