#!/usr/bin/env bash
# 安装并启动 ClashOH — 用法: bash scripts/install.sh [hap路径]
set -e
source "$(dirname "$0")/env.sh"
HAP="${1:-$PROJECT_ROOT/dist/clashoh-signed.hap}"
$HDC list targets
$HDC install -r "$HAP"
$HDC shell aa start -b com.clash.dev -a EntryAbility
