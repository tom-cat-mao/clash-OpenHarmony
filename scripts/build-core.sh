#!/usr/bin/env bash
# build-core.sh - 交叉编译 mihomo 内核为鸿蒙动态库 libmihomo.so
#
# 工具链: OHOS NDK clang（aarch64-unknown-linux-ohos-clang）
# 方式:   GOOS=android GOARCH=arm64 CGO_ENABLED=1 -buildmode=c-shared
#         -tags "netgo ohos cmfa with_gvisor"
#   - netgo: 规避 musl 下 net/cgo 类型冲突，用纯 Go DNS 解析
#   - ohos:  本仓库 core/ 的平台 build tag（强制 gVisor TUN 栈等）
#   - cmfa:  让 mihomo 的 android 路径走 server_notandroid.go（buildAndroidRules
#            变 no-op），绕开 ohos 沙箱里不存在的 android PackageManager binder
#   - android_stub: GOOS=android 链接隐式依赖 -llog，用空 liblog.a 打桩；
#                   android/log.h 映射到 hilog（日志进 hilog，hdc hilog 可 grep）
# 补丁:   patch-gvisor-tun-fd.sh（幂等）绕开 gVisor fdbased 对 tun fd 的 Fstat
#         （鸿蒙沙箱 EPERM），回退到 readv 非 socket 路径
#
# 用法: bash scripts/build-core.sh
# 产物: clash-openharmony/entry/libs/arm64-v8a/libmihomo.so（+ libmihomo.h）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

CORE_DIR="$REPO_ROOT/core"               # <仓库根>/core，Go 内核封装 module
OUT_DIR="$PROJECT_ROOT/entry/libs/arm64-v8a"
STUB_DIR="$CORE_DIR/third_party/android_stub"

NDK="$OHOS_SDK_HOME/native"
LLVM_BIN="$NDK/llvm/bin"
SYSROOT="$NDK/sysroot"
CLANG="$LLVM_BIN/aarch64-unknown-linux-ohos-clang"
TRIPLE="aarch64-linux-ohos"

for f in "$CLANG" "$SYSROOT/usr/lib/$TRIPLE/libhilog_ndk.z.so"; do
  [ -f "$f" ] || { echo "[build-core] missing: $f" >&2; exit 1; }
done

# ---- 1. android_stub: android/log.h -> hilog 映射 + 空 liblog.a ----
STUB_INCLUDE="$STUB_DIR"
STUB_LIB="$STUB_DIR/lib"
mkdir -p "$STUB_LIB"
if [ ! -f "$STUB_DIR/android/log.h" ]; then
  echo "[build-core] android/log.h stub missing, creating"
  mkdir -p "$STUB_DIR/android"
  cat > "$STUB_DIR/android/log.h" <<'EOF'
#ifndef ANDROID_LOG_H
#define ANDROID_LOG_H
// GOOS=android 交叉编译时 Go/cgo 会引用 android/log.h；鸿蒙没有该头，
// 这里映射到 hilog（OH_LOG_VPrint），使内核日志进入 hilog，hdc hilog 可 grep。
#include <stdarg.h>
#include <hilog/log.h>

#define ANDROID_LOG_UNKNOWN 0
#define ANDROID_LOG_DEFAULT 1
#define ANDROID_LOG_VERBOSE 2
#define ANDROID_LOG_DEBUG   3
#define ANDROID_LOG_INFO    4
#define ANDROID_LOG_WARN    5
#define ANDROID_LOG_ERROR   6
#define ANDROID_LOG_FATAL   7
#define ANDROID_LOG_SILENT  8

static inline int __android_log_vprint(int prio, const char *tag, const char *fmt, va_list ap) {
    if (prio < LOG_DEBUG) prio = LOG_DEBUG;
    if (prio > LOG_FATAL) prio = LOG_FATAL;
    return OH_LOG_VPrint(LOG_APP, (LogLevel)prio, 0x3200, tag, fmt, ap);
}

static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    int r; va_list ap; va_start(ap, fmt);
    r = __android_log_vprint(prio, tag, fmt, ap);
    va_end(ap); return r;
}

static inline void __android_log_write(int prio, const char *tag, const char *msg) {
    __android_log_print(prio, tag, "%{public}s", msg);
}
#endif
EOF
fi
if [ ! -f "$STUB_LIB/liblog.a" ]; then
  echo "[build-core] building empty liblog.a stub"
  printf 'void mihomo_android_log_stub(void) {}\n' > "$STUB_LIB/stub.c"
  "$CLANG" --target=$TRIPLE --sysroot="$SYSROOT" -c "$STUB_LIB/stub.c" -o "$STUB_LIB/stub.o"
  "$LLVM_BIN/llvm-ar" rcs "$STUB_LIB/liblog.a" "$STUB_LIB/stub.o"
fi

# ---- 2. gVisor fdbased 补丁（幂等）----
# 先确保 gvisor 模块已进 GOMODCACHE，否则 patch 在冷缓存下会静默跳过，
# go build 会拉取未打补丁的 gvisor，真机 TUN 起不来（Fstat EPERM）
(cd "$CORE_DIR" && go mod download github.com/metacubex/gvisor) || {
  echo "[build-core] go mod download gvisor failed" >&2
  exit 1
}
"$SCRIPT_DIR/patch-gvisor-tun-fd.sh" go

# ---- 3. 交叉编译 ----
echo "[build-core] compiling libmihomo.so (GOOS=android GOARCH=arm64, tags: netgo ohos cmfa with_gvisor)"
export CGO_ENABLED=1 GOOS=android GOARCH=arm64
export CC="$CLANG"
export CGO_CFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -D__MUSL__ -I$STUB_INCLUDE -I$SYSROOT/usr/include"
export CGO_LDFLAGS="--target=$TRIPLE -fuse-ld=lld -L$STUB_LIB -lhilog_ndk.z"
export CGO_CFLAGS_ALLOW=".*"
export CGO_LDFLAGS_ALLOW=".*"
export CFLAGS="--target=$TRIPLE --sysroot=$SYSROOT -D__MUSL__"
export CXXFLAGS="$CFLAGS"

mkdir -p "$OUT_DIR"
(cd "$CORE_DIR" && go build -buildvcs=false \
  -tags "netgo ohos cmfa with_gvisor" \
  -ldflags "-w" \
  -buildmode=c-shared \
  -o "$OUT_DIR/libmihomo.so" .)

echo "[build-core] done:"
ls -lh "$OUT_DIR"/libmihomo.so "$OUT_DIR"/libmihomo.h
