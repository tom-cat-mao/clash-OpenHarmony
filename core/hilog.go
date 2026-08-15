//go:build (android || ohos) && cgo

// hilog.go - mihomo 日志转发到鸿蒙 hilog。
//
// GOOS=android 交叉编译时没有 android/log.h，build-core.sh 通过 android_stub 提供
// 头文件映射（__android_log_print -> OH_LOG_VPrint），最终落到 hilog，
// 真机可用 `hdc shell hilog | grep mihomo` 抓取内核日志。
package main

/*
#cgo LDFLAGS: -lhilog_ndk.z
#include <android/log.h>
#include <stdlib.h>

// cgo 无法直接调用 variadic 的 __android_log_print，包一层非变参入口
static inline void mihomo_hilog_print(int prio, const char *tag, const char *msg) {
	__android_log_print(prio, tag, "%{public}s", msg);
}
*/
import "C"

import "unsafe"

// hilogPrint - 按 mihomo log level 映射到 hilog 等级输出
func hilogPrint(level int, tag, msg string) {
	prio := C.int(C.ANDROID_LOG_DEBUG)
	switch {
	case level >= 3: // ERROR / SILENT
		prio = C.ANDROID_LOG_ERROR
	case level == 2: // WARNING
		prio = C.ANDROID_LOG_WARN
	case level == 1: // INFO
		prio = C.ANDROID_LOG_INFO
	}
	cTag := C.CString(tag)
	cMsg := C.CString(msg)
	defer C.free(unsafe.Pointer(cTag))
	defer C.free(unsafe.Pointer(cMsg))
	C.mihomo_hilog_print(prio, cTag, cMsg)
}
