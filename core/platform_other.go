//go:build !ohos

package main

import (
	"github.com/metacubex/mihomo/constant"
)

// enforceStack - 非 ohos 平台不强制（保留用户在 configJson 中的选择）
func enforceStack(stack constant.TUNStack) constant.TUNStack {
	return stack
}

// applyPlatformDefaults - 非 ohos 平台仅补 external-controller 默认值
func applyPlatformDefaults(overlay map[string]any) {
	if _, ok := overlay["external-controller"]; !ok {
		overlay["external-controller"] = defaultController
	}
}
