<div align="center">

# ClashOH

**鸿蒙 NEXT 上的原生 Clash 客户端**

*A native Clash (mihomo) client for HarmonyOS NEXT.*

mihomo 内核 · 纯 ArkTS 界面 · 系统级 VPN 全隧道 · 后台保活 + 实况窗

</div>

---

## 这是什么

ClashOH 把 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash.Meta）内核完整移植进了纯血鸿蒙（HarmonyOS NEXT）：Go 交叉编译的内核动态库经 NAPI 桥接进原生 ArkTS 应用，通过系统 VpnExtensionAbility 建立 TUN 全隧道。不是套壳网页，不是远程控制——内核就跑在你手机里，和手机上的 ClashMetaForAndroid 一个物种。

## ✨ 特性

**代理核心**
- mihomo v1.19.29 内核，TUN 全隧道（gVisor 栈）+ fake-ip DNS
- 规则 / 全局 / 直连三种模式，按应用分流，IPv6 可选
- 订阅 URL / 文件 / 剪贴板导入，自动更新，流量与到期信息展示

**使用体验**
- 首页大圆环一键启停，WebSocket 实时速率，冷启动状态恢复
- 分组两级导航、批量测速、点选切换、组内搜索与排序
- 状态栏实况窗常驻 + 长时任务保活，2×2 桌面服务卡片
- 深色模式、连接与日志实时查看、覆写自定义内核启动参数

## 📱 安装

**先说实话**：鸿蒙不允许侧载未签名应用，且调试签名绑定设备——所以不存在"下载即装"的安装包，每台设备要走一次构建 + 签名流程（全程约 30 分钟，需要你亲手操作的约 10 分钟）。

**但流程是为 AI 设计的**。把本仓库交给任意编码 Agent（Claude Code / Codex / Cursor / …），对它说一句：

> **阅读 AGENTS.md，带我完成安装。**

Agent 会自动完成构建、签名、安装，只在需要你出面的节点（华为账号、证书申请、真机授权、导入订阅）停下来等你。纯人工版步骤见 [INSTALL.md](INSTALL.md)。

你需要准备：**HarmonyOS NEXT 真机 × 1、华为开发者账号 × 1、macOS/Linux 电脑 × 1**。

## 🔨 构建（工具链就绪后）

```bash
source scripts/env.sh       # 路径自动推导
bash scripts/build-core.sh  # mihomo → libmihomo.so
bash scripts/build-hap.sh   # 打包 HAP
bash scripts/sign-agc.sh    # AGC 调试证书签名
bash scripts/install.sh     # 安装到真机
```

全部移植坑位（musl TLS、gVisor 补丁、hvigor 缓存等）记录在 [clash-openharmony/BUILD.md](clash-openharmony/BUILD.md)。

## ❓ 常见问题

**为什么 Release 里没有安装包？**
鸿蒙调试签名绑定设备 UDID，我签的包你装不上；通用发布证书必须上架 AppGallery，本项目不走这条路。所以只发布源码。

**划掉最近任务卡片后 VPN 断了？**
平台设计行为：划卡 = 用户显式终止进程，任何应用都无法阻止。退后台、锁屏不受影响——长时任务 + 实况窗保护的就是这些场景。

**支持模拟器吗？**
不支持，仅真机（HarmonyOS NEXT，最低 HarmonyOS 6.0.1 / API 21——按代码实际使用的系统 API 的 @since 上限核定，覆盖华为官方统计约 99% 的存量设备）。

**自带节点吗？**
不内置任何节点，请自备订阅。

## ⚠️ 声明

仅供学习与技术交流，请遵守当地法律法规与服务条款。本项目与华为、Clash 官方无关。

## License

[GPL-3.0](LICENSE) — 本作品衍生自 GPL-3.0 的 mihomo，按同许可证发布。
感谢 [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) 以及 FlClash、Lxray 的鸿蒙适配探索。
