#!/usr/bin/env bash
# 构建 HAP(未签名) — 用法: bash scripts/build-hap.sh [release]
set -e
source "$(dirname "$0")/env.sh"
cd "$PROJECT_ROOT"
MODE="${1:-debug}"
if [ "$MODE" = "release" ]; then
  hvigorw assembleHap -p buildMode=release --no-daemon
else
  hvigorw assembleHap --no-daemon
fi
echo "--- 产物 ---"
ls -lh "$PROJECT_ROOT"/entry/build/default/outputs/default/*.hap
