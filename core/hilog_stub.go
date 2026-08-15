//go:build !(android || ohos) || !cgo

// hilog_stub.go - 非鸿蒙平台日志直出 stderr（本地调试用）
package main

import "fmt"

func hilogPrint(level int, tag, msg string) {
	fmt.Printf("[%s] %s\n", tag, msg)
}
