# ClashOH

[mihomo](https://github.com/MetaCubeX/mihomo)（Clash.Meta）内核的**鸿蒙原生客户端**。
纯血鸿蒙 / HarmonyOS NEXT，API 26 工具链构建，最低兼容 API 24（6.1.1）。

纯 ArkTS UI + VpnExtensionAbility + Go 交叉编译内核（NAPI 桥接，强制 gVisor 数据面）。
不上架 AppGallery，侧载分发。

> ⚠️ 本项目仅供学习与技术交流。使用请遵守当地法律法规与服务条款。

## 功能

- **首页**：大圆环启停、WebSocket 实时速率、规则/全局/直连模式切换、运行时长、冷启动状态恢复
- **代理**：两级导航（分组 → 节点）、真实延迟测速（单个/批量）、点选切换、组内搜索与排序、节点详情
- **配置**：订阅 URL / 文件 / 剪贴板导入、激活热切换、订阅信息（流量/到期）、自动更新（12–72h）、编辑/重命名/导出
- **设置**：按应用分流、IPv6、覆写（三层合并进内核启动配置）、连接管理、日志（WS /logs）、GeoX 数据更新
- **系统能力**：后台保活（长时任务 + 状态栏实况窗）、2×2 服务卡片、深色模式
- **内核**：mihomo v1.19.29，TUN 全隧道（gVisor 栈）、REST + WebSocket 控制面、fake-ip DNS

## 运行与构建门槛（先说清楚）

这不是一个"下载 APK 装上就用"的项目。你需要：

1. 一台**真机**（HarmonyOS NEXT / 纯血鸿蒙，已开开发者模式）——模拟器不在支持范围
2. 一个**华为开发者账号**（用于下载命令行工具链 + 在 AGC 创建调试签名证书）
3. 一台 macOS 或 Linux 构建机（Node 22+、Go 1.26+、JDK、约 8GB 磁盘）

**好消息：整个安装流程是为 AI Agent 设计的。**
把本仓库交给任意编码 Agent（Claude Code / Codex / Cursor / …），对它说：

> **"阅读 AGENTS.md，然后带我完成安装。"**

Agent 会独立完成所有可自动化的步骤，并在需要账号、证书、真机操作的节点停下来明确引导你。
人工主线见 [INSTALL.md](INSTALL.md)。

## 仓库结构

```
├── AGENTS.md                # AI Agent 入口（先读这个）
├── INSTALL.md               # 从零到真机运行的完整安装指南（人机共读）
├── core/                    # Go 内核封装：mihomo → libmihomo.so（c-shared，NAPI 桥）
├── clash-openharmony/       # Stage 模型应用工程（bundleName com.clash.dev）
│   ├── BUILD.md             # 构建复原指南 + 全部移植坑位清单（遇错先查这里）
│   ├── DESIGN.md            # 前端设计文档
│   └── entry/src/main/      # ArkTS UI / NAPI C++ 桥 / VpnExtensionAbility
└── scripts/                 # 纯命令行流水线：env → build-core → build-hap → sign → install
```

`command-line-tools/`（6GB 工具链）、`.signing/`（签名材料）、订阅配置等均不入库，获取方式见 INSTALL.md。

## 快速开始（已有工具链与签名材料时）

```bash
source scripts/env.sh        # 路径自动推导；工具链在别处则先 export HARMONYOS_CLT_ROOT=...
bash scripts/build-core.sh   # mihomo → entry/libs/arm64-v8a/libmihomo.so
bash scripts/build-hap.sh    # → entry-default-unsigned.hap
bash scripts/sign-agc.sh     # → dist/clashoh-signed.hap
bash scripts/install.sh      # hdc 安装 + 启动
```

## 许可证

[GPL-3.0](LICENSE)。本作品动态链接 mihomo（GPL-3.0），按同许可证发布。

## 致谢

- [MetaCubeX/mihomo](https://github.com/MetaCubeX/mihomo) — 内核
- 开发过程中参考了 FlClash 的鸿蒙适配与 Lxray 的 ArkTS+Xray 同构方案
