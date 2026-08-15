# ClashOH 构建复原指南（Build & Recovery Guide）

本仓库包含完整源码。按本指南可在全新环境重建并真机跑通 M1+（mihomo v1.19.29 内核 +
NAPI 桥接 + 系统 TUN 全隧道）可用的工程。本指南按实际重建过程撰写，所有命令均可用
绝对路径直接执行（脚本内部已自行定位，不依赖 shell 当前目录）。

## 1. 环境前置

| 依赖 | 版本 | 说明 |
|------|------|------|
| HarmonyOS Command Line Tools | 26.0.0.621 Beta2 | `command-line-tools/`，布局见下；不含 DevEco Studio 也能全流程构建 |
| Node.js | 22.x | hvigor（Node 脚本）运行所需，`node -v` 确认 |
| Go 工具链 | 1.26+ | 交叉编译 libmihomo.so（mihomo v1.19.29 go.mod 要求 1.20+） |
| JDK | 任意（含 keytool） | hap-sign-tool.jar 签名 |
| 真机 | HarmonyOS NEXT 授权设备 | 已开开发者模式、`hdc list targets` 可见、hdc 已授权 |

CLT 目录布局（mac-arm64）：

```
command-line-tools/
├── bin/hvigorw                    # hvigor 构建入口（Node 脚本）
├── sdk/default/openharmony/       # HarmonyOS SDK（API 26 Beta2）
│   ├── native/                    # NDK：llvm/bin/aarch64-unknown-linux-ohos-clang + sysroot
│   ├── toolchains/hdc             # 真机调试桥
│   └── toolchains/lib/hap-sign-tool.jar  # HAP 签名工具
├── hvigor/  ohpm/  codelinter/  hstack/
└── version.txt                    # 版本 26.0.0.621（releaseType: beta）
```

构建前必须 `source scripts/env.sh`（设置 SDK 路径与 npm 源；路径全部自动推导，无需修改）。
env.sh 已内置 `npm_config_registry=https://registry.npmjs.org`，保证 ohpm/hvigor
拉依赖走公网源，不受本机私有 registry 配置干扰。
**换机器重建时**：把 HarmonyOS Command Line Tools 解压到仓库根的 `command-line-tools/`
即可；装在别处则 `export HARMONYOS_CLT_ROOT=<路径>` 后再 source env.sh。

## 2. 目录结构

```
harmony-mihomo/
├── core/                          # Go 内核封装（独立 module，交叉编译为 libmihomo.so）
│   ├── main.go                    # c-shared 导出: mihomoInit / mihomoStartTun / mihomoStop / mihomoFree
│   ├── engine.go                  # 生命周期: coreInit -> 配置解析 -> hub.ApplyConfig -> gVisor TUN
│   │                              #   coreInit 里 route.SetEmbedMode(false) 解除 REST embed 限制（见 4.6）
│   ├── platform_ohos.go           # ohos build tag: 强制 gVisor、注入默认 external-controller/dns/find-process-mode
│   ├── platform_other.go          # 非 ohos（本地编译测试用）
│   ├── hilog.go                   # cgo 调 android_stub 的 __android_log_print 转发日志到 hilog
│   ├── hilog_stub.go              # 非鸿蒙平台日志 stub
│   └── third_party/android_stub/  # android/log.h -> hilog 映射 + 空 liblog.a（见 4.2）
├── scripts/
│   ├── env.sh                     # 环境变量（SDK 路径 + npm registry 覆盖）
│   ├── build-core.sh              # 交叉编译 libmihomo.so（含 android_stub 与 gvisor patch）
│   ├── patch-gvisor-tun-fd.sh     # gVisor fdbased Fstat 补丁（幂等，改 GOMODCACHE）
│   ├── build-hap.sh               # hvigorw assembleHap 打包 HAP
│   ├── sign-agc.sh                # AGC 调试证书签名（零售机必须，见 3.3）
│   ├── sign-demo.sh               # SDK OpenHarmony demo 证书签名（仅模拟器/授权机，见 4.7）
│   ├── install.sh                 # hdc 安装 + aa start 启动
│   └── logs.sh                    # hilog 过滤 ClashOH 相关日志
└── clash-openharmony/             # Stage 模型应用（bundleName com.clash.dev）
    ├── AppScope/app.json5         # 应用级配置
    ├── entry/src/main/module.json5      # 模块配置（EntryAbility + ClashVpnAbility(vpn 扩展)）
    ├── entry/src/main/cpp/        # NAPI 桥（libentry.so）
    │   ├── CMakeLists.txt         # 链接 libace_napi.z.so / libhilog_ndk.z.so / dl
    │   ├── bridge.cpp             # Go c-shared 桥接：专用 worker 线程 + 串行队列（musl TLS 规避，见 4.4）
    │   ├── bridge.h               # bridge::Init / StartTun / Stop / GetStatus 声明
    │   ├── napi_init.cpp          # NAPI 模块入口：initCore/startTun/stopCore/getBridgeStatus（async work）
    │   ├── vpn_log.h              # hilog 打印宏
    │   └── types/libentry/        # Index.d.ts + oh-package.json5（ArkTS 侧类型声明）
    ├── entry/src/main/ets/
    │   ├── entryability/EntryAbility.ets  # 应用入口，加载主框架
    │   ├── vpnability/ClashVpnAbility.ets  # VPN 扩展（独立进程 :vpn）：建 TUN -> initCore/startTun/stopCore
    │   ├── lib/CoreApi.ets        # mihomo REST 控制面客户端（http + WebSocket 订阅 /traffic /logs）
    │   ├── lib/VpnController.ets  # 主进程 VPN 启停状态机（系统授权弹窗 + 连接扩展 + 配置下发）
    │   ├── lib/ProfileStore.ets   # 订阅配置存储（filesDir/profiles/*.yaml + active.txt）
    │   ├── lib/Settings.ets       # 设置持久化（preferences KV，下次启动合并进内核配置）
    │   ├── lib/Logger.ets         # hilog 封装
    │   ├── pages/Index.ets        # 主框架：底部 Tabs（首页/代理/配置/设置）
    │   ├── pages/HomePage.ets     # 首页：大圆环启停 + WS /traffic 实时速率 + 模式切换
    │   ├── pages/ProxyPage.ets    # 代理页：GET /proxies、PUT /proxies/{group} 切节点、测速
    │   ├── pages/ProfilePage.ets  # 配置页：Profile 列表 + 新建入口
    │   └── pages/SettingsPage.ets # 设置页
    ├── entry/src/main/resources/rawfile/override.yaml  # 完整订阅配置（内核启动时下发）
    ├── entry/libs/arm64-v8a/      # libmihomo.so/.h（build-core.sh 产出，.gitignore 忽略）
    └── BUILD.md                   # 本文件
```

## 3. 构建流程（四步）

```bash
# 0. 每次构建前（在仓库根目录）
source scripts/env.sh

# 1. 交叉编译内核（约 2-5 分钟，产出 entry/libs/arm64-v8a/libmihomo.so 64M）
bash scripts/build-core.sh

# 2. 打包 HAP（自动编译 NAPI 桥 libentry.so）
#    注意：改动 core/ 或 entry/src/main/resources 后必须 clean 再打（见坑位①）
bash scripts/build-hap.sh
#    等价手写:
#    cd clash-openharmony && <CLT>/bin/hvigorw clean --no-daemon && <CLT>/bin/hvigorw assembleHap --no-daemon

# 3. 签名（AGC 调试证书；材料在 .signing/，勿提交勿读取）
bash scripts/sign-agc.sh

# 4. 安装并启动（真机需已授权、屏幕解锁）
bash scripts/install.sh
```

### 3.1 内核构建（scripts/build-core.sh 全流程）

1. **工具链检查**：`$OHOS_SDK_HOME/native/llvm/bin/aarch64-unknown-linux-ohos-clang` 与
   sysroot 下 `libhilog_ndk.z.so` 必须存在。
2. **android_stub 准备**（`core/third_party/android_stub/`，首次自动生成）：
   - `android/log.h`：把 `__android_log_print` 等映射到 `OH_LOG_VPrint`（domain 0x3200）——
     顺带让内核日志进 hilog（`hdc shell hilog` 可 grep）。
   - 空 `liblog.a`：`GOOS=android` 时 Go/cgo 隐式链接 `-llog`，鸿蒙没有 liblog，打桩满足链接。
3. **gVisor 补丁**：`go mod download github.com/metacubex/gvisor` 后调
   `patch-gvisor-tun-fd.sh`（幂等，见 4.3）。
4. **交叉编译**：
   ```bash
   CGO_ENABLED=1 GOOS=android GOARCH=arm64
   CC=$NDK/llvm/bin/aarch64-unknown-linux-ohos-clang
   CGO_CFLAGS="--target=aarch64-linux-ohos --sysroot=$SYSROOT -D__MUSL__ -I$STUB_INCLUDE -I$SYSROOT/usr/include"
   CGO_LDFLAGS="--target=aarch64-linux-ohos -fuse-ld=lld -L$STUB_LIB -lhilog_ndk.z"
   go build -buildvcs=false -tags "netgo ohos cmfa with_gvisor" -ldflags "-w" \
     -buildmode=c-shared -o entry/libs/arm64-v8a/libmihomo.so .
   ```
   各 tag 的作用：
   | tag | 作用 | 缺失后果 |
   |-----|------|---------|
   | `netgo` | 纯 Go DNS 解析，规避 musl 下 net/cgo 类型冲突 | 链接/运行期冲突 |
   | `ohos` | 本仓库平台 tag：强制 gVisor 栈、默认 127.0.0.1:9090 等 | TUN 可能用 system 栈导致 TCP 全丢 |
   | `cmfa` | mihomo android 路径走 server_notandroid.go（buildAndroidRules 变 no-op），绕开 ohos 沙箱不存在的 android PackageManager binder | sing_tun.New 初始化 PackageManager 失败，TUN 起不来 |
   | `with_gvisor` | 把 gVisor 栈编进 sing-tun（默认只有 system 栈） | 报 `gVisor is not included in this build` |

   `-ldflags "-w"`：去掉 DWARF 但保留符号表，便于 addr2line 定位崩溃。
5. **产物**：`clash-openharmony/entry/libs/arm64-v8a/libmihomo.so`（64M）+ `libmihomo.h`。

### 3.2 HAP 构建（scripts/build-hap.sh）

`hvigorw assembleHap --no-daemon`（debug；release 用 `-p buildMode=release`）。hvigor 会
自动跑 Native 编译（`entry/src/main/cpp/` 的 CMake 构建 libentry.so）、把 `entry/libs/arm64-v8a/`
的 libmihomo.so 打进 HAP。产物：
`entry/build/default/outputs/default/entry-default-unsigned.hap`。

**改 core/ 或 rawfile 资源后必须 `hvigorw clean --no-daemon` 再 assembleHap**，否则
`CacheNativeLibs` 任务缓存旧 so，装到真机的还是旧内核（见坑位①）。

### 3.3 签名（scripts/sign-agc.sh，零售机必须）

用 AGC 调试证书（`.signing/clashoh-debug.p12/.cer/.p7b`）经 `hap-sign-tool.jar sign-app`
本地签名。**零售机（正式版系统）只认 AGC 证书**：SDK 自带 OpenHarmony demo 证书签的包
安装会报错误码 **9568257**（证书未授权）。`sign-demo.sh`（路线 A）仅用于模拟器或
OpenHarmony 授权设备。签名产物：`dist/clashoh-signed.hap`。

### 3.4 安装（scripts/install.sh）

```bash
$HDC list targets                 # 确认设备在册
$HDC install -r dist/clashoh-signed.hap
$HDC shell aa start -b com.clash.dev -a EntryAbility
```

## 4. 关键技术点（改动过的部分，升级时别覆盖）

### 4.1 内核启动流程（core/engine.go）

1. `mihomoInit(homeDir)`：`constant.SetHomeDir` + 订阅 mihomo 日志转发 hilog/文件。
2. `mihomoStartTun(fd, configJson)`：
   - configJson（JSON/YAML，ArkTS 从 rawfile/override.yaml 读出）覆盖
     `config.DefaultRawConfig()`，YAML 解码；
   - `applyPlatformDefaults`：external-controller 默认 `127.0.0.1:9090`、dns.listen
     非特权端口 1053、find-process-mode off；
   - 强制 `tun.enable=false`（TUN 由 wrapper 用系统 fd 单独管理）；
   - `hub.ApplyConfig`：起 mixed-port / dns / external-controller；
   - 用 fd 起 `sing_tun.New`（stack=gVisor、AutoRoute=false、DNSHijack 含 0.0.0.0:53）。
3. `mihomoStop()`：关 TUN，各 listener 端口置 0 重载，关 DNS 与 route server
   （v1.19.29 无全局 StopListener；**不能 dlclose**——Go runtime 不可安全卸载）。

### 4.2 android_stub 打桩（GOOS=android 的链接依赖）

`GOOS=android` 时 Go/cgo 自动链接 `-llog` 并引用 `android/log.h`，鸿蒙没有：
- `core/third_party/android_stub/android/log.h`：`__android_log_print` 等映射到
  `OH_LOG_VPrint`（domain 0x3200）——**顺带让内核日志进 hilog**，真机
  `hdc shell "hilog -x -e mihomo"` 可抓。
- 空 `liblog.a`（stub.c 编译产物）满足 `-llog`；链接 `-lhilog_ndk.z`（sysroot 自带真库）。

### 4.3 gVisor fdbased 补丁（scripts/patch-gvisor-tun-fd.sh，幂等）

gVisor `fdbased.New()` 调 `isSocketFD(fd) -> unix.Fstat(fd)` 决定走 recvmmsg(socket)
还是 readv(tun) 路径。鸿蒙沙箱对 VPN tun fd 的 Fstat 返回 **EPERM**，导致 gVisor 栈
起不来 -> TCP 全丢（UDP/DNS 正常）。补丁把 Fstat 失败改为回退非 socket 路径（tun fd
永远不可能是 socket）。脚本直接改 GOMODCACHE 里的
`github.com/metacubex/gvisor@*/pkg/tcpip/link/fdbased/endpoint.go`，以注释
`OHOS: VPN tun fd is not Fstat-able` 为标记幂等。build-core.sh 每次构建前自动调用。
升级 gvisor 版本后需重新验证该行存在（脚本对内容漂移会 FATAL 退出而不是静默跳过）。

### 4.4 鸿蒙 musl TLS 限制（架构约束）

鸿蒙 musl 主线程 TLS 布局与 pthread 线程不同，Go c-shared 在主线程进入会
SIGSEGV。**所有进 Go 的调用必须经 bridge.cpp 的专用 worker 线程**
（pthread_create 单 worker + 队列串行化），NAPI 侧用 async work 保证不阻塞
UI 线程。不要改成主线程直调。

### 4.5 鸿蒙平台默认值（platform_ohos.go）

- `external-controller` 默认 `127.0.0.1:9090`（M1 验收入口，由 `applyPlatformDefaults`
  在每次 VPN 启动时注入 configJson；**不要**把 external-controller 写进
  override.yaml，保持平台注入单一来源）
- `find-process-mode` 默认 off（/proc 进程解析在沙箱不可靠且拖慢首包）
- DNS listen 默认 `0.0.0.0:1053`（非特权端口）；`dns-hijack` 必须含 `0.0.0.0:53`
- **sniffer 平台默认（applySnifferDefaults，2026-08-14 增）**：订阅嗅探开启时，
  为 TLS(443/8443)/HTTP(80/8080-8880)/QUIC(443) 补 `override-destination: true`
  （嗅探到 SNI 后按域名重新拨号，修复鸿蒙浏览器自有 HTTPDNS 拿污染 IP 导致的
  "proxy connection failed"/YouTube 无网络）；并补 `skip-dst-address` 私网段
  （10/8、172.16/12、192.168/16、127/8、100.64/10、169.254/16、::1、fc00::/7、
  fe80::/10，保住订阅内 IP-CIDR 内网直连规则）。订阅显式配置的字段一律以订阅为准
  （只填空缺）；订阅显式 `sniffer.enable=false` 或不含 sniffer 块时不动。

### 4.6 REST embed 模式（android patch 与 SetEmbedMode(false)）

mihomo `hub/route/patch_android.go`（`//go:build android && cmfa`）在 init() 里调
`SetEmbedMode(true)`。以 GOOS=android 交叉编译时 embedMode=true，REST 控制面
PUT/PATCH `/configs`、PATCH `/rules`、`/restart`、POST `/configs/geo` 全部 405。
`core/engine.go` 的 `coreInit()` 里显式调 `route.SetEmbedMode(false)` 覆盖：
embedMode 是包级变量、在 `router()` 构造（`ReCreateServer -> start`）时读取，
coreInit 先于 coreStartTun 执行，时机安全。本内核由进程完整托管（TUN fd 由鸿蒙
VpnService 下发、无自升级），并非 mihomo 的 embed 场景。真机已验证 PATCH/PUT
/configs、PATCH /rules、POST /configs/geo 全部解除 405。

### 4.7 签名路线对比

| 路线 | 脚本 | 证书 | 适用 |
|------|------|------|------|
| A | sign-demo.sh | SDK OpenHarmony demo p12（密码 123456） | 模拟器 / OpenHarmony 授权设备；零售机报 9568257 |
| B | sign-agc.sh | AGC 调试证书（.signing/） | **零售机必须**（本项目用这条） |

## 5. 真机验证（M1 验收金标准）

```bash
HDC=/path/to/command-line-tools/sdk/default/openharmony/toolchains/hdc

# 1. 启动 VPN（应用内首页大圆环；无 root 时用 uitest dumpLayout 拿按钮 bounds，
#    uinput -T -c <x> <y> 点击。屏幕锁定先 power-shell wakeup）
$HDC shell "uinput -T -c 564 570"

# 2. 金标准日志（hilog 必须带 -x 一次性输出，见坑位④）：
$HDC shell "hilog -x -e 'TUN handed over|core started'"
#   应看到:
#   [OHOS] mihomo core initialized, home=/data/storage/el2/base/haps/entry/files
#   mihomo core started, TUN handed over

# 3. 控制面（hdc fport 转发 REST，断连后需重建）:
$HDC fport tcp:19090 tcp:9090
curl http://127.0.0.1:19090/version        # -> {"meta":true,"version":"1.10.0"}

# 4. 混合代理出墙冒烟（mixed-port 7897）:
$HDC fport tcp:17897 tcp:7897
curl -x http://127.0.0.1:17897 https://www.google.com/generate_204   # -> HTTP 204
```

REST 控制面完整冒烟（embed 解除后）：

```bash
curl -X PATCH http://127.0.0.1:19090/configs -d '{"mode":"global"}'      # 204
curl http://127.0.0.1:19090/configs                                       # "mode":"global"
curl -X PATCH http://127.0.0.1:19090/configs -d '{"mode":"rule"}'         # 204 切回
# 注意: shell 单引号内 \n 是字面量，下面的 PUT 请用本节末尾的 python3 生成法发 payload，
# 勿直接复制此处的 \n 写法
curl -X PUT 'http://127.0.0.1:19090/configs?force=true' \
  -d '{"payload":"mixed-port: 7897\nexternal-controller: 127.0.0.1:9090\nmode: rule\n"}'  # 204
curl -X POST http://127.0.0.1:19090/configs/geo                           # 204（geo 更新约 18s）
```

恢复完整配置：PUT 一个只含 `{"payload":"<override.yaml 全文>"}` 的请求（payload 用
`python3 -c 'import json;print(json.dumps({"payload":open("override.yaml").read()}))'`
生成后 `curl --data-binary @file` 发送，避免 shell 转义踩坑）。override.yaml 不含
external-controller——恢复后平台注入的 127.0.0.1:9090 不受影响，REST 保持可用。

## 6. 坑位清单（按踩坑顺序）

| # | 现象 | 原因 | 解决 |
|---|------|------|------|
| ① | 改了 core/ 重新构建后真机行为没变 | hvigor `CacheNativeLibs` 缓存旧 so | 改 core/ 或 rawfile 后必须 `hvigorw clean --no-daemon` 再 assembleHap |
| ② | PUT/PATCH /configs、PATCH /rules、/restart、POST /configs/geo 全部 405 | android build tag 的 patch_android.go 默认 SetEmbedMode(true) | coreInit 里 `route.SetEmbedMode(false)`（见 4.6） |
| ③ | 主线程直进 Go c-shared SIGSEGV | 鸿蒙 musl 主线程 TLS 布局不同 | 全部经 bridge.cpp 专用 worker 线程（见 4.4） |
| ④ | `hdc shell hilog` 卡住刷屏/超时 | hilog 是流式输出 | 用 `hilog -x -e '<regex>'`（打印后退出）；看日志脚本用 logs.sh |
| ⑤ | 想用 hdc 往应用沙盒写文件失败 | 沙盒文件系统不对 hdc 开放 | 数据走应用自身逻辑（VpnService 授权后的 fd、filesDir）；hdc 只做 fport/hilog/点击 |
| ⑥ | 全新脚手架工程安装报 9568322 拒装 | 缺系统资源声明 | 本仓库工程不受影响；只有重新脚手架新工程踩到时才需在 AppScope 级补 harmonyos.conf 的 cpustat 段 |
| ⑦ | `startTun failed: unmarshal config: cannot unmarshal !!str 7890 into int` | json.Number 经 yaml.Marshal 变字符串 | engine.go 解析统一走 yaml（JSON 是 YAML 子集），勿回退 |
| ⑧ | `gVisor is not included in this build` | 缺 `with_gvisor` tag | build-core.sh 的 tags 四个全带上 |
| ⑨ | 建 TUN 报 PackageManager 类错误 | android 路径调 binder 服务 | `cmfa` tag（server_notandroid.go） |
| ⑩ | TCP 全丢、UDP 正常 | 用了 system/mixed 栈（内核回环不存在） | 强制 `tun.stack=gvisor`（ohos tag 已强制，勿改） |
| ⑪ | Fstat EPERM 起不了 gVisor | 沙箱拒绝 fstat tun fd | patch-gvisor-tun-fd.sh（构建时自动） |
| ⑫ | `[TUN] get tun name failed for fd 32, fallback to ClashOH` | TUNGETIFF ioctl 失败（鸿蒙沙箱） | 无害告警，忽略 |
| ⑬ | ArkTS 编译错 `arkts-no-obj-literals-as-types` / `arkts-no-untyped-obj-literals` | 严格模式禁止对象字面量做类型/无类型字面量 | 嵌套结构抽命名 interface；配置对象声明 interface |
| ⑭ | 安装后 aa start 失败 10106102 | 屏幕锁定（开发者模式不解锁） | `hdc shell power-shell wakeup` 后重试 |
| ⑮ | `import core from 'libentry.so'` 编译失败 | oh-package.json5 缺依赖 | entry/oh-package.json5 的 dependencies 加 `"libentry.so": "file:./src/main/cpp/types/libentry"` |

## 7. 已知限制（M1 边界）

- `/version` 返回的 version 是 mihomo 源码内置开发号（1.10.0），release 应用
  `-X` ldflags 注入真实版本
- **`/restart` 在鸿蒙不可用**：mihomo 的 restart 实现是 `executor.Shutdown()` +
  `syscall.Exec(os.Executable())`。鸿蒙沙箱里 `os.Executable()` 返回宿主
  `/system/bin/appspawn`，exec 后 :vpn 进程直接退出（实测 hilog：
  `restarting: "/system/bin/appspawn" []`）。路由本身已随 embed 解除挂载（POST 返回
  200 `{"status":"ok"}`），但不要真调；需要重载配置用 PUT /configs?force=true。
- Go runtime 常驻不可卸载，`mihomoStop` 只停业务不停进程；扩展进程随 VPN 会话
  由系统回收
- `hdc fport` 的转发在 hdc 断开或 :vpn 进程重启后失效，需重新建立
- IPv6-only 节点不可用属正常：手机无 IPv6，选 IPv4 节点（如日本节点）
- 版本号与 mihomo 升级：升级 mihomo/gvisor 后，重新核对
  `endpoint.go` 的 Fstat 行、`sing_tun.New` 签名、`server_notandroid.go` 的
  build tag（cmfa 语义可能变化）、`patch_android.go` 的 embed 逻辑

## 8. 已排除（不随源码上传/不提交）

- 签名材料（.signing/ 下的 p12/cer/p7b——**勿读取勿提交**）
- 构建产物（entry/libs/*.so、entry/build、entry/.cxx、dist/）
- 本机配置（local.properties、oh_modules、.hvigor）
- reference/（同构项目参考，只读勿动）
