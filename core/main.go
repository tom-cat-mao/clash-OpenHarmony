// main.go - mihomo 内核 c-shared 导出入口（libmihomo.so）
//
// 导出符号（供 C++/NAPI 桥接层经专用 worker 线程调用）:
//
//	mihomoInit(homeDir *C.char) *C.char   初始化内核，返回错误串或 nil
//	mihomoStartTun(fd C.int, configJson *C.char, overridesJson *C.char) *C.char
//	                                     用系统下发的 tun fd 起 mihomo（TUN 强制 gVisor 栈），
//	                                     overridesJson 为用户设置覆写（JSON，可为空串）
//	mihomoStop()                          停止 TUN 与全部 listener
//	mihomoFree(p *C.char)                 释放上述函数返回的 C 字符串
//
// 注意: 所有导出函数必须经由桥接层 worker 线程调用（鸿蒙 musl 主线程 TLS 布局与
// pthread 线程不同，主线程直进 Go c-shared 会 SIGSEGV，详见 clash-openharmony/BUILD.md）。
package main

/*
#include <stdlib.h>
*/
import "C"

import "unsafe"

//export mihomoInit
func mihomoInit(homeDir *C.char) *C.char {
	err := coreInit(C.GoString(homeDir))
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

//export mihomoStartTun
func mihomoStartTun(fd C.int, configJson *C.char, overridesJson *C.char) *C.char {
	err := coreStartTun(int(fd), C.GoString(configJson), C.GoString(overridesJson))
	if err == nil {
		return nil
	}
	return C.CString(err.Error())
}

//export mihomoStop
func mihomoStop() {
	coreStop()
}

//export mihomoFree
func mihomoFree(p *C.char) {
	if p == nil {
		return
	}
	C.free(unsafe.Pointer(p))
}

func main() {}
