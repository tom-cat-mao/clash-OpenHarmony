//go:build ohos

package main

import (
	"github.com/metacubex/mihomo/constant"
	"github.com/metacubex/mihomo/log"
)

// enforceStack - 鸿蒙 VPN 沙箱强制 gVisor 栈。
//
// 原因: mixed/system 栈的 TCP 走内核 NAT（把 SYN 重写回 tun 地址期望内核回环到
// 本地 listener），而鸿蒙 VpnExtension 沙箱没有该内核回环，TCP 会被静默丢弃
// （UDP/DNS 正常，因为直接注入 gVisor）。全部 TCP 必须用户态处理。
func enforceStack(stack constant.TUNStack) constant.TUNStack {
	return constant.TunGvisor
}

// applyPlatformDefaults - ohos 默认值:
//   - external-controller 默认 127.0.0.1:9090（控制面验证入口）
//   - dns.listen 用非特权端口 1053（沙箱内 53 可能被系统保留）
//   - find-process-mode 默认 off（/proc 进程解析在鸿蒙沙箱不可靠且拖慢首包）
//   - sniffer 平台默认（见 applySnifferDefaults）
func applyPlatformDefaults(overlay map[string]any) {
	if _, ok := overlay["external-controller"]; !ok {
		overlay["external-controller"] = defaultController
	}
	if _, ok := overlay["find-process-mode"]; !ok {
		overlay["find-process-mode"] = "off"
	}
	if dns, ok := overlay["dns"].(map[string]any); ok && dns != nil {
		if _, ok := dns["listen"]; !ok {
			dns["listen"] = defaultDNSListen
		}
	}
	applySnifferDefaults(overlay)
}

// snifferDefaults - 各协议嗅探的平台默认端口（字符串形式避免 YAML 重解析类型歧义）
type snifferEntryDefaults struct {
	name  string
	ports []any
}

var snifferDefaults = []snifferEntryDefaults{
	{"TLS", []any{"443", "8443"}},
	{"HTTP", []any{"80", "8080-8880"}},
	{"QUIC", []any{"443"}},
}

// 私网/运营商保留段（跳过嗅探重写，保住订阅里的 IP-CIDR 内网直连规则语义）
var snifferSkipDstAddress = []any{
	"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
	"127.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
	"::1/128", "fc00::/7", "fe80::/10",
}

// applySnifferDefaults - 嗅探平台默认注入（防应用级 HTTPDNS/DoH 拿污染 IP 黑洞）:
//   - 订阅未配置 sniffer 块：尊重默认（不启用嗅探），不动；
//   - 订阅显式 sniffer.enable=false：尊重订阅，不动；
//   - 嗅探开启时：
//     1) sniff 映射内为 TLS/HTTP/QUIC 补 override-destination: true（嗅探到
//        SNI/Host 后按域名重新拨号，由节点侧解析干净 IP；缺端口时补默认端口）；
//     2) sniff 映射缺失（旧式全局 sniffing 列表）时补全局 override-destination；
//     3) 补 skip-dst-address 私网段（私网目标不参与嗅探重写）。
//   订阅显式书写的字段一律以订阅为准（只填空缺）。
func applySnifferDefaults(overlay map[string]any) {
	sn, ok := overlay["sniffer"].(map[string]any)
	if !ok || sn == nil {
		return
	}
	if enabled, ok := sn["enable"].(bool); ok && !enabled {
		log.Infoln("[OHOS] sniffer explicitly disabled by profile, skip platform defaults")
		return
	}

	if sniff, ok := sn["sniff"].(map[string]any); ok && sniff != nil {
		for _, def := range snifferDefaults {
			entry, exists := sniff[def.name]
			if !exists {
				sniff[def.name] = map[string]any{
					"ports":                def.ports,
					"override-destination": true,
				}
				continue
			}
			em, isMap := entry.(map[string]any)
			if !isMap {
				continue // 结构异常交给 mihomo 报错
			}
			if _, has := em["ports"]; !has {
				em["ports"] = def.ports
			}
			if _, has := em["override-destination"]; !has {
				em["override-destination"] = true
			}
		}
	} else {
		if _, has := sn["override-destination"]; !has {
			sn["override-destination"] = true
		}
	}

	if _, has := sn["skip-dst-address"]; !has {
		sn["skip-dst-address"] = snifferSkipDstAddress
	}
	log.Infoln("[OHOS] sniffer platform defaults applied: TLS/HTTP/QUIC override-destination + private skip-dst-address")
}
