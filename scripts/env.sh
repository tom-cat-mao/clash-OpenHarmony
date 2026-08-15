#!/usr/bin/env bash
# ClashOH 环境变量 — 用法: source scripts/env.sh
#
# 路径全部自动推导，克隆到任何机器都无需修改本文件：
#   REPO_ROOT     由本脚本所在位置推导
#   CLT_ROOT      默认 $REPO_ROOT/command-line-tools；如工具链装在别处，
#                 先 export HARMONYOS_CLT_ROOT=/你的路径/command-line-tools 再 source
# 完整环境准备步骤见 INSTALL.md。

_CLASHOH_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT="$(cd "$_CLASHOH_ENV_DIR/.." && pwd)"
export CLT_ROOT="${HARMONYOS_CLT_ROOT:-$REPO_ROOT/command-line-tools}"
export PROJECT_ROOT="$REPO_ROOT/clash-openharmony"
export DEVECO_SDK_HOME=$CLT_ROOT/sdk
export OHOS_SDK_HOME=$CLT_ROOT/sdk/default/openharmony
export OHOS_BASE_SDK_HOME=$OHOS_SDK_HOME
export HDC=$OHOS_SDK_HOME/toolchains/hdc
export PATH=$CLT_ROOT/bin:$OHOS_SDK_HOME/toolchains:$PATH
# 固定公网 npm 源，保证 ohpm/hvigor 拉依赖不被本地私有源配置干扰
export npm_config_registry=https://registry.npmjs.org

# 前置检查：工具链缺失时给出可操作的提示而不是莫名其妙的后续报错
if [ ! -x "$CLT_ROOT/bin/hvigorw" ]; then
  echo "[env.sh] 未找到 HarmonyOS Command Line Tools: $CLT_ROOT" >&2
  echo "[env.sh] 请按 INSTALL.md 第 2 步下载并解压到该目录（或设置 HARMONYOS_CLT_ROOT）" >&2
  return 1 2>/dev/null || exit 1
fi
