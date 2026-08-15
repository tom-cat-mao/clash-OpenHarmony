// engine.go - mihomo 内核生命周期管理（初始化 / 启动 TUN / 停止）
//
// 启动流程:
//  1. coreInit: 设置 homeDir（country.mmdb / config 缓存等落盘目录）
//  2. coreStartTun: 把 ArkTS 侧传入的 configJson（JSON，YAML 兼容）覆盖到 mihomo
//     默认配置上 -> config.ParseRawConfig -> hub.ApplyConfig（起 mixed-port /
//     dns / external-controller）-> 用系统下发的 tun fd 单独起 gVisor TUN 入站
//  3. coreStop: 关 TUN -> listener.StopListener（external-controller 随 config
//     重载关闭；Go runtime 常驻不卸载，dlclose 不安全）
package main

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unicode/utf8"

	"github.com/metacubex/mihomo/config"
	"github.com/metacubex/mihomo/constant"
	MDNS "github.com/metacubex/mihomo/dns"
	"github.com/metacubex/mihomo/hub"
	"github.com/metacubex/mihomo/hub/route"
	"github.com/metacubex/mihomo/listener"
	LC "github.com/metacubex/mihomo/listener/config"
	"github.com/metacubex/mihomo/listener/sing_tun"
	"github.com/metacubex/mihomo/log"
	"github.com/metacubex/mihomo/tunnel"
	"gopkg.in/yaml.v3"
)

const (
	defaultMixedPort  = 7890
	defaultController = "127.0.0.1:9090"
	defaultDNSListen  = "0.0.0.0:1053"
)

var (
	runLock     sync.Mutex
	initialized bool
	tunListener *sing_tun.Listener
	logFile     *os.File
	homeDir     string
	logSub      <-chan log.Event
)

// sanitizeConfigJson - 清洗 ArkTS 侧传入的配置文本（防御性，双端修复）：
//  1. 去 UTF-8 BOM
//  2. 修复旧版前端导入路径造成的 UTF-8 双重编码：String.fromCharCode 把原始
//     字节逐字节映射成 U+0000~U+00FF 字符再落盘，续字节 0x80~0x9F 变成 C1 控制符，
//     yaml.v3 解析报 "control characters are not allowed"。检测到 C1 控制符且
//     全部码点 ≤0xFF 时，把码点还原为字节（恢复原始 UTF-8 字节流）。
func sanitizeConfigJson(s string) string {
	s = strings.TrimPrefix(s, "\ufeff")
	hasC1 := false
	allLatin1 := true
	for _, r := range s {
		if r >= 0x80 && r <= 0x9F {
			hasC1 = true
		}
		if r > 0xFF {
			allLatin1 = false
		}
	}
	if !hasC1 || !allLatin1 {
		return s
	}
	bytes := make([]byte, 0, len(s))
	for _, r := range s {
		bytes = append(bytes, byte(r))
	}
	if utf8.Valid(bytes) {
		log.Warnln("[OHOS] configJson repaired from byte-flattened UTF-8 (%d -> %d bytes)", len(s), len(bytes))
		return string(bytes)
	}
	return s
}

// tunExt - configJson 中 "tun" 节点的扩展字段（mihomo RawTun 没有 address 字段，
// 由 wrapper 消费后不传给 mihomo 本体）
type tunExt struct {
	stack     string
	address   string
	mtu       uint32
	dnsHijack []string
}

func defaultTunExt() tunExt {
	return tunExt{
		stack:     "gvisor",
		address:   "172.19.0.1/30",
		mtu:       9000,
		dnsHijack: []string{"0.0.0.0:53"},
	}
}

func coreInit(home string) error {
	runLock.Lock()
	defer runLock.Unlock()

	if home == "" {
		return errors.New("mihomoInit: empty home dir")
	}
	if err := os.MkdirAll(home, 0o755); err != nil {
		return fmt.Errorf("mihomoInit: mkdir home: %w", err)
	}
	homeDir = home
	constant.SetHomeDir(home)
	log.SetLevel(log.INFO)

	// 覆盖 android build tag 的 embed 默认值：mihomo hub/route/patch_android.go
	// （//go:build android && cmfa）在 init() 里调 SetEmbedMode(true)，会把
	// PUT/PATCH /configs、PATCH /rules、/restart、POST /configs/geo 全部置 405。
	// embedMode 是包级变量、在 router() 构造（ReCreateServer -> start）时读取，
	// 本函数先于 coreStartTun 执行，因此在这里显式关闭即可解除限制。
	// 我们以 GOOS=android 交叉编译 libmihomo.so，但内核由本进程完整托管
	// （TUN fd 由鸿蒙 VpnService 下发、无自升级），并非 mihomo 的 embed 场景。
	route.SetEmbedMode(false)

	if logSub == nil { // 重复连接时幂等：只订阅一次，避免 relay goroutine 泄漏
		logSub = log.Subscribe() // 在 worker 线程首进 Go 后订阅，规避主线程 TLS 问题
		startLogRelay()
	}

	initialized = true
	log.Infoln("[OHOS] mihomo core initialized, home=%s", home)
	return nil
}

// startLogRelay - 把 mihomo 日志转发到 hilog（android_stub 的 __android_log_print
// 映射到 OH_LOG）并追加写入 homeDir/mihomo.log，供真机 hilog 抓取与排障。
func startLogRelay() {
	go func() {
		if logFile == nil {
			if f, err := os.OpenFile(filepath.Join(homeDir, "mihomo.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644); err == nil {
				logFile = f
			}
		}
		for e := range logSub {
			line := fmt.Sprintf("[%s] %s", e.LogLevel.String(), e.Payload)
			hilogPrint(int(e.LogLevel), "mihomo", line)
			if logFile != nil {
				_, _ = logFile.WriteString(line + "\n")
			}
		}
	}()
}

func coreStartTun(fd int, configJson string, overridesJson string) error {
	runLock.Lock()
	defer runLock.Unlock()

	if !initialized {
		return errors.New("mihomoStartTun: core not initialized, call mihomoInit first")
	}
	if tunListener != nil {
		return errors.New("mihomoStartTun: tun already running")
	}
	if fd <= 0 {
		return fmt.Errorf("mihomoStartTun: invalid tun fd %d", fd)
	}

	// 1. 解析 configJson（JSON 或 YAML；JSON 是 YAML 子集，统一走 yaml 解析，
	//    ArkTS 侧既可能传硬编码 JSON 也可能传 rawfile 的 YAML 订阅配置）
	configJson = sanitizeConfigJson(configJson)
	overlay := map[string]any{}
	if configJson != "" {
		if err := yaml.Unmarshal([]byte(configJson), &overlay); err != nil {
			return fmt.Errorf("mihomoStartTun: parse configJson: %w (配置文件编码异常，请在配置页重新导入为 UTF-8)", err)
		}
	}

	// 2. 提取 tun 扩展字段（stack/address/mtu/dns-hijack），其余交给 mihomo
	ext := defaultTunExt()
	if rawTun, ok := overlay["tun"].(map[string]any); ok {
		if v, ok := rawTun["stack"].(string); ok && v != "" {
			ext.stack = v
		}
		if v, ok := rawTun["address"].(string); ok && v != "" {
			ext.address = v
		}
		if v, ok := rawTun["mtu"].(int64); ok && v > 0 {
			ext.mtu = uint32(v)
		}
		if v, ok := rawTun["dns-hijack"].([]any); ok {
			var list []string
			for _, item := range v {
				if s, ok := item.(string); ok && s != "" {
					list = append(list, s)
				}
			}
			if len(list) > 0 {
				ext.dnsHijack = list
			}
		}
		delete(overlay, "tun")
	}

	// 3. 用户覆写（ArkTS 设置页，JSON）：位于 profile overlay 之上、平台必需项之下，
	//    语义 = 用户覆写 > 订阅配置同名键；空串/解析失败时跳过该层
	applyOverrides(overlay, overridesJson)
	// 4. 平台默认值 + ohos 强制约束
	applyPlatformDefaults(overlay)
	// TUN 由 wrapper 用系统 fd 单独管理，绝不让 mihomo 自己创建 tun 设备
	overlay["tun"] = map[string]any{"enable": false}

	// 5. 覆盖到默认配置并解析
	buf, err := yaml.Marshal(overlay)
	if err != nil {
		return fmt.Errorf("mihomoStartTun: marshal overlay: %w", err)
	}
	rawCfg := config.DefaultRawConfig()
	if err := yaml.Unmarshal(buf, rawCfg); err != nil {
		return fmt.Errorf("mihomoStartTun: unmarshal config: %w", err)
	}
	rawCfg.Tun.Enable = false // 双保险

	cfg, err := config.ParseRawConfig(rawCfg)
	if err != nil {
		return fmt.Errorf("mihomoStartTun: parse config: %w", err)
	}
	hub.ApplyConfig(cfg) // 起 mixed-port / dns / external-controller

	// 6. 用系统 tun fd 起 gVisor 入站
	stack, ok := constant.StackTypeMapping[strings.ToLower(ext.stack)]
	if !ok {
		return fmt.Errorf("mihomoStartTun: unknown tun stack %q", ext.stack)
	}
	stack = enforceStack(stack) // ohos 上强制 gVisor（系统栈 TCP 依赖内核回环，鸿蒙 VPN 沙箱没有）

	prefix, err := parseTunPrefix(ext.address)
	if err != nil {
		return fmt.Errorf("mihomoStartTun: bad tun address %q: %w", ext.address, err)
	}

	opts := LC.Tun{
		Enable:              true,
		Device:              "ClashOH",
		Stack:               stack,
		DNSHijack:           ext.dnsHijack,
		AutoRoute:           false, // 鸿蒙沙箱无 root，路由由系统 VpnService 管理
		AutoDetectInterface: false,
		Inet4Address:        []netip.Prefix{prefix},
		MTU:                 ext.mtu,
		FileDescriptor:      fd,
	}
	l, err := sing_tun.New(opts, tunnel.Tunnel)
	if err != nil {
		return fmt.Errorf("mihomoStartTun: start tun: %w", err)
	}
	tunListener = l
	log.Infoln("[OHOS] TUN started fd=%d stack=%s address=%s mtu=%d hijack=%v", fd, stack.String(), ext.address, ext.mtu, ext.dnsHijack)
	return nil
}

// applyOverrides - 把 ArkTS 设置页的用户覆写（JSON）合并进 overlay。
// 合并顺序: profile overlay -> overrides -> 平台必需项，语义 = 用户覆写 > 订阅配置
// 同名键。键映射（ArkTS 驼峰 -> mihomo 配置 kebab）: mixedPort->mixed-port、
// logLevel->log-level、allowLan->allow-lan；ipv6 只用于系统 VpnConfig、不动内核，
// 因此忽略。overridesJson 为空或解析失败时跳过该层（不影响启动）。
func applyOverrides(overlay map[string]any, overridesJson string) {
	if overridesJson == "" {
		log.Infoln("[OHOS] overrides: empty, skipped")
		return
	}
	ov := map[string]any{}
	if err := yaml.Unmarshal([]byte(overridesJson), &ov); err != nil {
		log.Warnln("[OHOS] overrides: parse failed, skipped: %v", err)
		return
	}
	keyMap := map[string]string{
		"mixedPort": "mixed-port",
		"logLevel":  "log-level",
		"allowLan":  "allow-lan",
	}
	for src, dst := range keyMap {
		if v, ok := ov[src]; ok {
			overlay[dst] = v
		}
	}
	log.Infoln("[OHOS] overrides applied: %s", overridesJson)
}

func coreStop() {
	runLock.Lock()
	defer runLock.Unlock()

	if tunListener != nil {
		_ = tunListener.Close()
		tunListener = nil
	}
	// 端口置 0 关闭各 listener（mihomo 无全局 StopListener，这是官方关闭语义）
	listener.ReCreateMixed(0, tunnel.Tunnel)
	listener.ReCreateHTTP(0, tunnel.Tunnel)
	listener.ReCreateSocks(0, tunnel.Tunnel)
	listener.ReCreateRedir(0, tunnel.Tunnel)
	listener.ReCreateTProxy(0, tunnel.Tunnel)
	listener.ReCreateShadowSocks("", tunnel.Tunnel)
	listener.ReCreateVmess("", tunnel.Tunnel)
	MDNS.ReCreateServer("", nil, nil)
	route.ReCreateServer(&route.Config{})
	log.Infoln("[OHOS] mihomo core stopped")
}

// parseTunPrefix - 兼容 "172.19.0.1/30" 与裸地址 "172.19.0.1"（ohos 补 /30，参照 FlClash）
func parseTunPrefix(s string) (netip.Prefix, error) {
	s = strings.TrimSpace(s)
	if !strings.Contains(s, "/") {
		addr, err := netip.ParseAddr(s)
		if err != nil {
			return netip.Prefix{}, err
		}
		if addr.Is6() {
			return netip.PrefixFrom(addr, 126), nil
		}
		return netip.PrefixFrom(addr, 30), nil
	}
	p, err := netip.ParsePrefix(s)
	if err != nil {
		return netip.Prefix{}, err
	}
	return p, nil
}

