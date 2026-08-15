# ClashOH 安装指南（INSTALL）

从零到真机运行的完整流程。本文档同时面向两类读者：

- **人类用户**：按步骤顺序执行即可。标记 🧑 的步骤只能由你完成（涉及账号、网页操作、真机）。
- **AI Agent**：本文件就是你的执行手册。标记 🤖 的步骤你应直接执行；标记 🧑 的步骤**不要尝试自动化**（无浏览器/账号权限时应停下来，把指引原样转达给用户，等用户完成后继续）。每步都有 `验证` 命令与预期输出，先执行再验证，失败先查文末故障表和 `clash-openharmony/BUILD.md`。

**全程不要修改 `scripts/*.sh` 的逻辑来"绕过"检查**——检查项对应真实的平台约束。

## 流程总览

| # | 步骤 | 执行者 | 产出 |
|---|------|--------|------|
| 0 | 构建机依赖检查 | 🤖 | node/go/java 可用 |
| 1 | 注册华为开发者账号 | 🧑 | 可登录 AGC |
| 2 | 下载命令行工具链并解压 | 🧑 下载 / 🤖 验证 | `command-line-tools/bin/hvigorw` |
| 3 | 克隆仓库，source 环境 | 🤖 | `hdc` 在 PATH 中 |
| 4 | AGC 创建应用 + 调试证书 + 调试 profile | 🧑 网页 / 🤖 生成 CSR、校验材料 | `clash-openharmony/.signing/` 三件 + `store_pw` |
| 5 | 真机开开发者模式并授权 hdc | 🧑 | `hdc list targets` 见设备 |
| 6 | 构建 → 签名 → 安装 | 🤖 | 手机桌面出现 ClashOH |
| 7 | App 内导入订阅并启动 | 🧑 | VPN 连通 |

---

## 0. 构建机依赖检查 🤖

需要 macOS 或 Linux（Apple Silicon 验证过），约 8GB 空闲磁盘。

```bash
node -v    # 需要 22.x
go version # 需要 1.26+
java -version && keytool --help >/dev/null  # 任意 JDK，签名用 keytool
python3 --version  # sign-demo.sh 用（可选路线）
```

缺什么装什么（macOS 建议 `brew install node@22 go openjdk`）。

## 1. 注册华为开发者账号 🧑

1. 打开 <https://developer.huawei.com/consumer/cn/>，注册并完成**实名认证**（下载工具链和创建证书都要求实名）。
2. 验证：能登录 <https://developer.huawei.com/consumer/cn/service/josp/agc/index.html>（AppGallery Connect，下称 AGC）。

> Agent 提示语：「请注册并完成华为开发者实名认证，完成后告诉我。」

## 2. 下载命令行工具链（Command Line Tools）🧑 下载 / 🤖 验证

工具链约 6GB，下载需登录华为账号，因此**必须由人类下载**，解压与验证可由 Agent 完成。

1. 🧑 打开 <https://developer.huawei.com/consumer/cn/download/>，找到 **Command Line Tools**（HarmonyOS NEXT / API 26，本项目用 **26.0.0.621 Beta2** 构建），下载对应平台（mac-arm64 或 linux-x64）压缩包。
2. 🤖/🧑 解压到**仓库根目录**，使布局为 `<仓库根>/command-line-tools/bin/hvigorw`。
   若解压到别处：`export HARMONYOS_CLT_ROOT=/你的路径/command-line-tools`（每次新开 shell 都要）。
3. 🤖 验证：

```bash
source scripts/env.sh   # 通过则静默；找不到工具链会明确报错
command -v hvigorw hdc
cat "$CLT_ROOT/version.txt"   # 预期 26.0.0.xxx
ls "$OHOS_SDK_HOME/native/llvm/bin/aarch64-unknown-linux-ohos-clang"  # 交叉编译器存在
```

> 华为有时要求先"申请开通"NEXT 工具链下载权限（填写用途，通常很快通过）。若页面提示申请，按页面指引操作后稍等再下。

## 3. 克隆仓库与环境 🤖

```bash
git clone <本仓库地址> && cd harmony-mihomo   # 或你 fork 的地址
source scripts/env.sh
```

预期：无报错，`echo $OHOS_SDK_HOME` 指向 `command-line-tools/sdk/default/openharmony`。

## 4. 签名材料（零售真机必须）🧑 网页 / 🤖 辅助

鸿蒙零售机只安装「调试证书 + 调试 profile」签名的包。材料准备分四小步：

### 4.1 生成本地 keystore 与 CSR 🤖

```bash
cd clash-openharmony && mkdir -p .signing && cd .signing
# 让 Agent 生成一个随机口令 PW，或你自己定一个。口令稍后写入 store_pw，勿入库。
keytool -genkeypair -alias clashoh-debug -keyalg EC -groupname secp256r1 \
  -sigalg SHA256withECDSA -dname "C=CN,O=clashoh,OU=clashoh,CN=clashoh-debug" \
  -keypass "$PW" -keystore clashoh-debug.p12 -storepass "$PW" -storetype PKCS12 -validity 3650
keytool -certreq -alias clashoh-debug -keystore clashoh-debug.p12 \
  -storetype PKCS12 -storepass "$PW" -file clashoh-debug.csr
printf '%s' "$PW" > store_pw && chmod 600 store_pw   # scripts/sign-agc.sh 自动读取
cd ../..
```

### 4.2 AGC 创建应用 🧑

1. AGC →「我的项目」→ 新建项目 → 新建应用，类型选 **HarmonyOS 应用**。
2. 包名填 `com.clash.dev`。
   - 若提示包名已被占用：改用你自己的包名（如 `com.<你的名字>.clashoh`），并同步修改：
     - `clash-openharmony/AppScope/app.json5` 的 `bundleName`
     - `scripts/install.sh` 里 `aa start -b com.clash.dev` 的包名
     - `scripts/sign-demo.sh` 里 profile JSON 的 `bundle-name`（可选路线才用）

### 4.3 AGC 创建调试证书 🧑

1. AGC 左侧「用户与访问」→「证书管理」→「新增证书」，类型选**调试证书**。
2. 上传 4.1 生成的 `clashoh-debug.csr`，下载得到 **`clashoh-debug.cer`**，放入 `clash-openharmony/.signing/`。

### 4.4 注册设备 UDID + 创建调试 profile 🧑

1. 真机连上电脑（先做完第 5 步的 hdc 授权也可回来再做），🤖 执行：
   ```bash
   hdc shell bm get --udid
   ```
2. AGC「用户与访问」→「设备管理」→ 添加设备，粘贴 UDID。
3. AGC「我的项目」→ 你的项目 → 你的应用 →「HarmonyOS 应用 → HAP Provision Profile（调试）」→ 新建，勾选：**应用、调试证书、已注册设备**，下载得到 **`clashoh-debug.p7b`**（文件名任意，重命名后放入 `clash-openharmony/.signing/`）。

### 4.5 校验材料 🤖

```bash
ls clash-openharmony/.signing/   # 预期: clashoh-debug.p12 clashoh-debug.cer clashoh-debug.p7b store_pw
```

> AGC 网页文案可能随版本微调（"证书管理/设备管理/Provision Profile"），核心概念不变：**应用 + 调试证书 + 设备 UDID → 调试 profile**。Agent 应按概念引导，不要死扣按钮名。

## 5. 真机开发者模式与 hdc 授权 🧑

1. 手机：`设置 → 关于本机`，连续点击「软件版本/版本号」直到提示开发者模式已开启。
2. `设置 → 开发者选项`（或搜索"开发者"）→ 打开 **USB 调试**。
3. USB 连电脑，手机弹「是否允许调试」→ 允许。
4. 🤖 验证：`hdc list targets` 输出设备序列号（空列表 = 未完成授权）。

## 6. 构建、签名、安装 🤖

```bash
source scripts/env.sh
bash scripts/build-core.sh    # ① 内核 → entry/libs/arm64-v8a/libmihomo.so（约 2-5 分钟，64M）
bash scripts/build-hap.sh     # ② 打包 → entry/build/.../entry-default-unsigned.hap
bash scripts/sign-agc.sh      # ③ 签名 → dist/clashoh-signed.hap（自动读 .signing/store_pw）
bash scripts/install.sh       # ④ 安装并拉起；预期 hdc install 成功、桌面出现 ClashOH
```

- ① 会自动生成 android_stub 并打 gVisor 补丁（幂等）。**改动 `core/` 或 resources 后必须先 `hvigorw clean`**（`cd clash-openharmony && hvigorw clean --no-daemon`），否则 hvigor 缓存会打包旧内核。
- 报错一律先查 `clash-openharmony/BUILD.md` 第 4 节坑位清单。

## 7. 导入订阅并启动 🧑

1. 打开 ClashOH →「配置」Tab → ＋ →「从 URL 导入」，粘贴你的订阅链接（或文件/剪贴板导入）。
2. 回到「首页」点大圆环启动，首次会弹系统 VPN 授权 → 允许。
3. 🤖 可验证：`bash scripts/logs.sh` 或 `hdc shell hilog | grep -i clash` 看内核日志；`curl -x` 不适用（TUN 全隧道），直接用手机浏览器访问外网验证。

---

## 故障速查

| 现象 | 原因与处置 |
|------|-----------|
| `env.sh: 未找到 Command Line Tools` | 第 2 步未完成或解压位置不对；或设 `HARMONYOS_CLT_ROOT` |
| `hdc list targets` 为空 | 开发者模式/USB 调试/授权弹窗未完成（第 5 步）；换线换口 |
| 安装报错 `9568257` | 用 demo 证书签的包不能装零售机；必须走第 4 步 AGC 调试证书 |
| 安装报签名/profile 校验失败 | bundleName、设备 UDID、证书三者必须与 AGC profile 一致（4.2/4.4） |
| `ohpm/hvigor` 拉依赖失败 | env.sh 已固定 npmjs 公网源；检查本机代理或公司私有源残留配置 |
| 启动即断 / TUN 不起 | 查 `bash scripts/logs.sh`；多为改代码后未 clean 重打，见 BUILD.md 坑位① |
| Fstat EPERM / gVisor 相关 | `scripts/patch-gvisor-tun-fd.sh` 已幂等内置进 build-core.sh；细节见 BUILD.md 4.3 |
| 后台被划卡杀掉 | 鸿蒙平台设计行为（用户显式终止意图），应用侧无法阻止，属正常现象 |

更深层的移植细节（musl TLS、gVisor 补丁原理、REST 控制面限制等）都在 `clash-openharmony/BUILD.md`。
