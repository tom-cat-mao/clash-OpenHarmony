# ClashOH 实况窗常驻通知 · 设计稿 v1

> 范围：HarmonyOS 7 真机（min API 24 / target 26）。保活载体 = **dataTransfer 长时任务**；
> 常驻通知形态 = **系统"上传下载"实况窗**（typeCode 8，downloadTemplate）。
> 动态服务卡片本期不做。Live View Kit 场景化实况窗不使用（需 AGC 权益 + 场景准入，VPN 不在准入列表）。
>
> 依据：官方《长时任务开发指南》DATA_TRANSFER 约束（进度须以实况窗形态持续更新，首次更新超 10 分钟任务被取消）、
> API 26 SDK（`backgroundTaskManager.ContinuousTaskRequest` / `NotificationSystemLiveViewContent` / `downloadTemplate`）、
> 实况窗设计规范（胶囊/卡片/锁屏三端、文本超长截断）。

---

## 1. 总览

连接 VPN 且「后台运行」开关开启时：

1. 以 API 21+ 方式申请 dataTransfer 长时任务（`MODE_DATA_TRANSFER` + `SUBMODE_LIVE_VIEW_NOTIFICATION`），系统代理创建实况窗，返回 `notificationId` 与 `continuousTaskId`；
2. 应用以同一 `notificationId` 持续发布（publish 即更新）实况窗内容：实时速率、出口节点、运行时长、流量活跃度；
3. 每 60s 更新一次（硬性规则：10 分钟不更新 → 任务被系统取消）；
4. 每 5 分钟做一次出口节点延迟测速——既是真实心跳流量（防"传输速率低"取消），又提供「延迟」展示；
5. 监听系统取消/暂停事件做分类自愈；
6. 断开 VPN 或用户关闭开关 → 停止任务、撤销通知。

## 2. 展示形态（系统按"上传下载"模板渲染，三端一致数据）

| 位置 | 内容 |
|---|---|
| 状态栏胶囊 | 应用图标 + 胶囊标题 + 进度（活跃度） |
| 锁屏胶囊 | 同状态栏（无流量/锁屏时依旧展示） |
| 通知中心卡片 | 大标题 · fileName 行 · 进度条+百分比 · text 行 · 时间 |

### 字段 → 内容映射（设计核心）

| 平台字段 | 约束 | 设计内容 | 示例值 |
|---|---|---|---|
| `systemLiveView.typeCode` | 固定 8 | 上传下载类型 | `8` |
| `systemLiveView.title` | 卡面主标题 | 会话主标题 | `ClashOH 系统代理` |
| `systemLiveView.text` | 副文本 | 实时速率 + 运行时长 | `↓ 2.4 MB/s · ↑ 86 KB/s · 已运行 01:23:45` |
| `systemLiveView.capsule.title` | ≤200 字节 | 胶囊短句（**不含速率**，防截断） | `ClashOH · 代理已连接` |
| `systemLiveView.capsule.backgroundColor` | ARGB 字符串 | 品牌蓝 `#0A59F7` | `#FF0A59F7` |
| `systemLiveView.time` | 可选 | 正计时运行时长 | `initialTime=连接时刻, isCountDown=false` |
| `template.name` | 固定 | 进度条模板 | `downloadTemplate` |
| `template.data.title` | 必填 | 卡面标题（与 systemLiveView.title 一致） | `ClashOH 系统代理` |
| `template.data.fileName` | 必填 | 语义复用为「模式 · 出口节点」 | `规则模式 · 出口 香港 01` |
| `template.data.progressValue` | 0–100 | **流量活跃度**（见 §4） | `42` |

### 各状态文案（全量清单）

| 状态 | capsule.title | systemLiveView.title | text | fileName |
|---|---|---|---|---|
| 已连接（有流量） | `ClashOH · 代理已连接` | `ClashOH 系统代理` | `↓ {D} · ↑ {U} · 已运行 {T}` | `{模式}模式 · 出口 {节点}` |
| 已连接（无流量） | 同上 | 同上 | `已连接 · 无活动流量` | 同上 |
| 连接中 | `ClashOH · 连接中…` | `ClashOH 正在连接` | `正在建立 VPN 隧道…` | `{模式}模式` |
| 断开中 | `ClashOH · 断开中…` | `ClashOH 正在断开` | `正在释放隧道…` | `{模式}模式` |

- 速率格式复用首页 `formatRate`（B/s、KB/s、MB/s，1000 进制）。
- 运行时长格式 `HH:MM:SS`。
- 节点名/模式名超 18 字符截断加 `…`。

## 3. 进度条语义：流量活跃度（而非下载进度）

`progressValue = clamp(round(avgBps / 1MB/s × 100), 0, 100)`，`avgBps` = 最近 60s（上下行合计）平均字节/秒。

- 设计理由：VPN 没有"完成"概念，进度条做**活跃度仪表**才诚实；有流量时随速率呼吸（1MB/s 即满格），空闲归零但文案明确"已连接"。
- 配合 5 分钟心跳：测速流量会让进度条周期性跳动，同时满足系统"进度有更新"的观测。

## 4. 更新节奏与平台规则闭环

| 节奏 | 动作 | 对应平台规则 |
|---|---|---|
| 每 60s | REST `GET /traffic` 取累计值算速率 → publish 更新实况窗 | 10 分钟不更新即取消（`SYSTEM_CANCEL_DATA_TRANSFER_NOT_UPDATE=12`） |
| 每 5 min | `GET /proxies/{出口节点}/delay` 测速（真实代理流量） | 防低速取消（`SYSTEM_CANCEL_DATA_TRANSFER_LOW_SPEED=4`） |
| 每 5 min | 刷新 `GET /proxies` 缓存出口节点名 + `GET /configs` 模式名 | 展示准确性 |

数据面全走 REST 单次请求（不依赖 WS；后台进程被保活后 60s 定时器正常工作）。

## 5. 点击交互

- 点击胶囊/卡片 → 通过长时任务 `wantAgent`（START_ABILITY + UPDATE_PRESENT_FLAG）拉起 EntryAbility 首页。
- **用户划掉实况窗 = 用户主动停止**（取消原因 `USER_CANCEL_REMOVE_NOTIFICATION=3`）：不再自动重建；用户回到前台且 VPN 仍连接时经 `ensure()` 恢复。

## 6. 自愈策略（continuousTaskCancel / Suspend 事件）

监听 `backgroundTaskManager.on('continuousTaskCancel')`（API 15+，`detailedReason` 为 26+ 可选字段）：

| 事件 | 处理 |
|---|---|
| `detailedReason=3` 或 `reason=USER_CANCEL` | `userStopped=true`，停止自动重申请，记录日志 |
| `detailedReason=4/12` 或其他系统原因 | VPN 仍活（`GET /version` 通）→ 30s 后重新申请；每小时最多重试 3 次，超出则等下个前台时机 |
| `continuousTaskSuspend` / `continuousTaskActive` | 仅日志；suspend 期间继续按 60s 节奏 publish（若系统仍接受） |

`ensure(context)`：前台调用——VPN Connected && keepAlive && 无任务 && !userStopped → start()。VPN 重新连接时清 `userStopped`。

## 7. 实现契约

### 新模块 `entry/src/main/ets/lib/LiveViewKeeper.ets`（取代 BackgroundKeeper）

```ts
export namespace LiveViewKeeper {
  // 申请 dataTransfer 长时任务 + 发布实况窗 + 启动 60s/5min 定时器 + 注册事件监听。幂等。
  export function start(context: common.UIAbilityContext): Promise<boolean>;
  // 前台兜底：满足条件且无任务时补 start()
  export function ensure(context: common.UIAbilityContext): void;
  // 停止定时器/监听，取消实况窗通知，stopBackgroundRunning（优先带 continuousTaskId）
  export function stop(context: common.UIAbilityContext): Promise<void>;
  export function isRunning(): boolean;
}
```

内部结构要点：

- 任务申请：`new backgroundTaskManager.ContinuousTaskRequest()`，`backgroundTaskModes=[MODE_DATA_TRANSFER]`，`backgroundTaskSubmodes=[SUBMODE_LIVE_VIEW_NOTIFICATION]`，`wantAgent` 指向 EntryAbility；`startBackgroundRunning(context, request)` → `{ notificationId, continuousTaskId? }`。
- 通知更新（ArkTS 严格模式：命名 interface 后显式标注）：
  ```ts
  const content: notificationManager.NotificationContent = {
    notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
    systemLiveView: { typeCode: 8, title, text, capsule: { title: capsuleTitle, backgroundColor: '#FF0A59F7' }, time: { initialTime: connectedAt, isCountDown: false } }
  };
  const tmpl: notificationManager.NotificationTemplate = { name: 'downloadTemplate', data: { title: ..., fileName: ..., progressValue: ... } };
  const req: notificationManager.NotificationRequest = { id: notificationId, content: content, notificationSlotType: notificationManager.SlotType.LIVE_VIEW, template: tmpl };
  await notificationManager.publish(req);
  ```
- 速率采样：`CoreApi.getTraffic()`（新增单次 `GET /traffic`，返回 `{up,down}` 累计字节），与上次采样差分求 `avgBps`；首采样直接展示 0。
- 心跳：`CoreApi.delayTest(nodeName)`（新增 `GET /proxies/{name}/delay?timeout=3000&url=<gstatic 204>`，返回延迟 ms 或 null）；节点名取 `Settings.mainGroup` 记忆或缓存的首个非 GLOBAL Selector 当前出口；失败静默。延迟值写入 text（`· 延迟 {ms} ms`）。
- 停止：`notificationManager.cancel(notificationId)` + `stopBackgroundRunning(context, continuousTaskId)`（`continuousTaskId` 缺省时用无参重载）+ `off` 事件 + 清定时器与状态。

### 其余改动

| 文件 | 改动 |
|---|---|
| `lib/BackgroundKeeper.ets` | **删除**（逻辑并入 LiveViewKeeper） |
| `lib/CoreApi.ets` | 新增 `getTraffic(): Promise<TrafficMsg | null>`、`delayTest(name: string): Promise<number | null>` |
| `lib/Settings.ets` | `keepAlive` 默认值 `false` → `true`（`AppSettings` 与 `load()` 回退值同步改） |
| `pages/HomePage.ets` | `onCoreUp`: `LiveViewKeeper.start(context)`（取代 BackgroundKeeper）；`onVpnDown`: `LiveViewKeeper.stop(context)`；`aboutToAppear`/回前台: `LiveViewKeeper.ensure(context)`；删除 BackgroundKeeper 引用 |
| `pages/SettingsPage.ets` | 开关改调 LiveViewKeeper（start/stop/ensure）；副标题改为「关窗后保持内核存活（状态栏实况窗常驻）」 |
| `module.json5` | 无需改动（`backgroundModes: ["dataTransfer"]` 与 KEEP_BACKGROUND_RUNNING 已声明） |

## 8. 验收标准

### 构建验收（我来做）
1. `bash scripts/build-hap.sh` 编译通过；
2. `bash scripts/sign-agc.sh` 签名、`bash scripts/install.sh` 安装成功；
3. hilog 检查点（tag `liveview`）：
   - 任务申请成功：`task started notificationId=.. continuousTaskId=..`
   - 60s 周期：`live view updated rate=.. progress=..`
   - 5min 心跳：`heartbeat delay=..ms` / `heartbeat skipped`
   - 取消事件：`task canceled reason=.. detailed=..` 及自愈重申请日志。

### 真机手动验收（用户来做）
1. 设置页「后台运行」开启（新装默认开）→ 连接 VPN → 状态栏出现胶囊「ClashOH · 代理已连接」+ 进度；
2. 锁屏可见胶囊；通知中心卡片文案正确，速率每 60s 刷新；
3. 点击胶囊/卡片 → 拉起首页且状态显示"已连接"；
4. 划掉实况窗 → 任务停止（无循环骚扰）；
5. 关屏闲置 ≥ 15 分钟 → VPN 不中断（核心目标）；期间有后台 App 流量时胶囊进度有变化；
6. 断开 VPN → 胶囊/卡片消失。

---

## 附：实施指引（供实现 subagent 使用）

### 必读文件
设计稿本体 + `entry/src/main/ets/lib/BackgroundKeeper.ets`、`pages/HomePage.ets`、`pages/SettingsPage.ets`、`lib/Settings.ets`、`lib/CoreApi.ets`、`lib/VpnController.ets`、`lib/Logger.ets`。

### 改动清单
1. 新建 `entry/src/main/ets/lib/LiveViewKeeper.ets`（按 §7 契约与下文要点实现）。
2. 删除 `entry/src/main/ets/lib/BackgroundKeeper.ets`。
3. `lib/CoreApi.ets`：新增导出
   - `getTraffic(): Promise<TrafficMsg | null>`：GET '/traffic'，JSON.parse 取 up/down。
   - `delayTest(name: string): Promise<number | null>`：GET '/proxies/' + encodeURIComponent(name) + '/delay?timeout=3000&url=' + encodeURIComponent('http://www.gstatic.com/generate_204')，解析 {delay:number}，失败返回 null。
4. `lib/Settings.ets`：keepAlive 默认 false → true（AppSettings 初始值与 load() fallback 同步改）。
5. `pages/HomePage.ets`：BackgroundKeeper → LiveViewKeeper；onCoreUp 调 start；onVpnDown 调 stop；aboutToAppear（VpnController.recover() 之后）与 onTabVisible 调 ensure；删除 BackgroundKeeper import。
6. `pages/SettingsPage.ets`：onKeepAliveChange 改调 LiveViewKeeper（on→start、off→stop，toast 保留）；「后台运行」行 sub 改为「关窗后保持内核存活（状态栏实况窗常驻）」。
7. 禁止改动：`module.json5`、`core/`、`scripts/`、`reference/`、`AppScope/`。

### LiveViewKeeper 实现要点
- namespace + 模块级状态（参考旧 BackgroundKeeper 写法）：running、userStopped、notificationId、continuousTaskId、connectedAt、timerId（60s）、hbTimerId（5min）、reapplyLog: number[]、事件注册标记。
- `start(context: common.UIAbilityContext): Promise<boolean>`：
  1. running 幂等返回 true；`Settings.load(context).keepAlive` 为 false 返回 false。
  2. `wantAgent.getWantAgent({ wants: [{ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility' }], operationType: wantAgent.OperationType.START_ABILITY, requestCode: 0, actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG] })`。
  3. `const request = new backgroundTaskManager.ContinuousTaskRequest()`；`request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER]`；`request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION]`；`request.wantAgent = agent`。
  4. `const res = await backgroundTaskManager.startBackgroundRunning(context, request)` → 取 `res.notificationId` 与可选 `res.continuousTaskId`。
  5. 首次启动 `connectedAt = Date.now()`；自愈重申请不清零。
  6. 注册 `backgroundTaskManager.on('continuousTaskCancel', cb)` / `on('continuousTaskSuspend', cb)` / `on('continuousTaskActive', cb)`（cb 入参类型 `backgroundTaskManager.ContinuousTaskCancelInfo` 等，含 reason、id、detailedReason?）。只注册一次（标记位）。
  7. 立即 `publishLiveView(...)` 一次（已连接态文案），随后 `timerId = setInterval(...)` 60s 刷新、`hbTimerId = setInterval(...)` 5min 心跳。句柄为 number。
  8. 失败路径：捕获后复位状态，Logger.error，返回 false。
- `stop(context)`：幂等；clearInterval 两个句柄；try/catch `notificationManager.cancel(notificationId)`；`continuousTaskId` 有值 → `backgroundTaskManager.stopBackgroundRunning(context, continuousTaskId)`，否则无参重载；off 三个事件；复位状态（running=false、userStopped=false、notificationId=-1）。
- `ensure(context)`：`VpnController.status === VpnStatus.Connected && Settings.load(context).keepAlive && !running && !userStopped` → `start(context)`（fire-and-forget，catch 日志）。
- 发布函数 publishLiveView 的 ArkTS 严格写法：先声明命名 interface（SystemLiveViewExt/CapsuleExt/TimeExt/TemplateDataExt），再以显式标注构造 `notificationManager.NotificationContent`（notificationContentType = ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW；systemLiveView = { typeCode: 8, title, text, capsule: { title, backgroundColor: '#FF0A59F7' }, time: { initialTime: connectedAt, isCountDown: false } }）、`NotificationTemplate`（name 'downloadTemplate'，data 为 Record<string, Object>：title/fileName/progressValue）、`NotificationRequest`（id = notificationId、notificationSlotType = SlotType.LIVE_VIEW、template），最后 `await notificationManager.publish(req)`。文案严格按 §2 状态文案表；速率用 `CoreApi.formatRate`；时长 HH:MM:SS；节点/模式名超 18 字符截断加省略号；progressValue 按 §3（相邻两次 getTraffic 差分求 avgBps，首采样 0）。
- 心跳：getProxies() 取出口（优先 Settings.mainGroup 组 now；组失效取第一个非 GLOBAL Selector 的 now 并回写 mainGroup；now 为 DIRECT/REJECT 跳过），delayTest 成功把「 · 延迟 {ms} ms」拼入 text；失败静默；同步用 getConfigs().mode 刷新模式名缓存。
- 自愈 cb：`info.detailedReason === 3` 或 `info.reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL` → userStopped=true 仅日志；其他系统原因且 `await CoreApi.isAlive()` → 清理 reapplyLog 中 1 小时前记录、条数 <3 时记录并 setTimeout 30s 后 start(lastContext)，否则仅日志。
- 日志 tag 统一 'liveview'；禁止 any；catch (e) 后 (e as Error) 或 JSON.stringify(e)。

### 构建验证
`bash scripts/build-hap.sh`（约 1-3 分钟，仓库根目录执行），编译错误逐个修复到通过；随后 `git status --short` 确认改动面（不得出现 core/、scripts/、module.json5、AppScope 改动）。

### 报告格式（中文）
1. 改动文件清单；2. 状态机与自愈逻辑简述；3. 构建结果（hap 路径/大小）；4. 偏离设计稿之处及理由；5. 风险点与真机验证建议。
