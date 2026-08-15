#!/usr/bin/env bash
# 用 SDK 自带 OpenHarmony demo 证书给 HAP 签名(路线 A, 零账号零 GUI)
# 流水线与 FlClash-HarmonyOS ohos/hvigor/signing.js 等价:
#   导出 CA 证书 -> generate-app-cert -> 构建 profile JSON -> sign-profile -> sign-app
# 用法: bash scripts/sign-demo.sh [输入.hap] [输出.hap]
set -e
source "$(dirname "$0")/env.sh"
LIB=$OHOS_SDK_HOME/toolchains/lib
IN="${1:-$PROJECT_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
OUT="${2:-$PROJECT_ROOT/dist/clashoh-demo-signed.hap}"
WORK=/tmp/clashoh-signing
mkdir -p "$PROJECT_ROOT/dist" "$WORK"
rm -f "$WORK"/*

KEYSTORE="$LIB/OpenHarmony.p12"
PW=123456
ALG=SHA256withECDSA

keytool -exportcert -alias "openharmony application root ca" -keystore "$KEYSTORE" \
  -storetype PKCS12 -storepass $PW -file "$WORK/root.cer"
keytool -exportcert -alias "openharmony application ca" -keystore "$KEYSTORE" \
  -storetype PKCS12 -storepass $PW -file "$WORK/ca.cer"

java -jar "$LIB/hap-sign-tool.jar" generate-app-cert \
  -keyAlias "openharmony application release" -keyPwd $PW \
  -issuer "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application CA" \
  -issuerKeyAlias "openharmony application ca" -issuerKeyPwd $PW \
  -subject "C=CN,O=OpenHarmony,OU=OpenHarmony Team,CN=OpenHarmony Application Release" \
  -validity 3650 -signAlg $ALG \
  -rootCaCertFile "$WORK/root.cer" -subCaCertFile "$WORK/ca.cer" \
  -keystoreFile "$KEYSTORE" -keystorePwd $PW \
  -outForm certChain -outFile "$WORK/app-chain.cer" \
  -issuerKeystoreFile "$KEYSTORE" -issuerKeystorePwd $PW

python3 - "$WORK/app-chain.cer" "$WORK/profile.json" <<'EOF'
import json, re, sys
chain = open(sys.argv[1]).read()
certs = re.findall(r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', chain, re.S)
leaf = certs[0].strip() + '\n'
profile = {
    'version-name': '2.0.0',
    'version-code': 2,
    'app-distribution-type': 'os_integration',
    'uuid': 'e8c0cf4e-414d-40e9-99df-c00e6a5f0d99',
    'validity': {'not-before': 1710000000, 'not-after': 1893456000},
    'type': 'release',
    'bundle-info': {
        'developer-id': 'OpenHarmony',
        'distribution-certificate': leaf,
        'bundle-name': 'com.clash.dev',
        'apl': 'normal',
        'app-feature': 'hos_normal_app',
    },
    'acls': {'allowed-acls': ['']},
    'permissions': {'restricted-permissions': []},
    'issuer': 'pki_internal',
}
json.dump(profile, open(sys.argv[2], 'w'), indent=2)
EOF

java -jar "$LIB/hap-sign-tool.jar" sign-profile \
  -mode localSign -keyAlias "openharmony application profile release" -keyPwd $PW \
  -profileCertFile "$LIB/OpenHarmonyProfileRelease.pem" \
  -inFile "$WORK/profile.json" -signAlg $ALG \
  -keystoreFile "$KEYSTORE" -keystorePwd $PW \
  -outFile "$WORK/profile.p7b"

java -jar "$LIB/hap-sign-tool.jar" sign-app \
  -mode localSign -keyAlias "openharmony application release" -keyPwd $PW \
  -signAlg $ALG \
  -appCertFile "$WORK/app-chain.cer" \
  -profileFile "$WORK/profile.p7b" \
  -inFile "$IN" \
  -keystoreFile "$KEYSTORE" -keystorePwd $PW \
  -outFile "$OUT"

echo "--- 签名产物 ---"
ls -lh "$OUT"
