#!/usr/bin/env bash
# 用 AGC 调试证书给 HAP 签名(零售真机必须)
# 材料: .signing/{clashoh-debug.p12, clashoh-debug.cer, clashoh-debug.p7b}（获取步骤见 INSTALL.md 第 4 步）
# 口令: 从环境变量 CLASHOH_STORE_PW 或 .signing/store_pw 文件读取（勿把口令写进任何入库文件）
# 用法: bash scripts/sign-agc.sh [输入.hap] [输出.hap]
set -e
source "$(dirname "$0")/env.sh"
SIGN_DIR=$PROJECT_ROOT/.signing
IN="${1:-$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT="${2:-$PROJECT_ROOT/dist/clashoh-signed.hap}"
mkdir -p "$PROJECT_ROOT/dist"

for f in clashoh-debug.p12 clashoh-debug.cer clashoh-debug.p7b; do
  [ -f "$SIGN_DIR/$f" ] || {
    echo "[sign-agc] 缺少签名材料: $SIGN_DIR/$f" >&2
    echo "[sign-agc] 请按 INSTALL.md 第 4 步在 AGC 创建调试证书并放入 $SIGN_DIR/" >&2
    exit 1
  }
done

STORE_PW="${CLASHOH_STORE_PW:-$(cat "$SIGN_DIR/store_pw" 2>/dev/null || true)}"
if [ -z "$STORE_PW" ]; then
  echo "[sign-agc] 未提供 keystore 口令: 设置 CLASHOH_STORE_PW 环境变量，" >&2
  echo "[sign-agc] 或将口令写入 $SIGN_DIR/store_pw（该文件已在 .gitignore 中）" >&2
  exit 1
fi

java -jar "$OHOS_SDK_HOME/toolchains/lib/hap-sign-tool.jar" sign-app \
  -mode localSign \
  -keyAlias "clashoh-debug" \
  -signAlg SHA256withECDSA \
  -appCertFile "$SIGN_DIR/clashoh-debug.cer" \
  -profileFile "$SIGN_DIR/clashoh-debug.p7b" \
  -inFile "$IN" \
  -keystoreFile "$SIGN_DIR/clashoh-debug.p12" \
  -outFile "$OUT" \
  -keyPwd "$STORE_PW" -keystorePwd "$STORE_PW"

echo "--- 签名产物 ---"
ls -lh "$OUT"
