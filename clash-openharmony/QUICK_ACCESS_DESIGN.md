# ClashOH 快捷开关卡片 + 冷启动自动恢复 · 设计稿 v1

> 目标：实现「方案 A：冷启动自动恢复 VPN」+「方案 B：类 ClashMeta 控制中心按钮的折中——动态服务卡片开关」。
> 背景研究结论：HarmonyOS 7 控制中心**不向第三方开放自定义开关**（API 26 SDK 全量检索无 ControlExtensionAbility/磁贴类 API，官方文档亦无此能力），Android QS Tile 无鸿蒙等价物；
> 第三方唯一「系统渲染、应用进程死后仍可点击、点击即拉起并执行动作」的入口是**服务卡片**（官方 postCardAction('router') 带参机制）。
> 另：App Shortcut（长按图标快捷入口，API 20+，@ohos.bundle.shortcutManager）可用，作为后续可选项，本期不做。

---

## 1. 方案 A：冷启动自动恢复

### 1.1 语义
用户主动断开 VPN 前记录「会话曾连接」；应用冷启动（进程重建）时若该标记为 true 且设置「打开应用自动恢复」开启，自动发起 VPN 连接（系统 VPN 授权已记住，不重复弹窗）。划卡杀进程后，用户只要点图标/点卡片，VPN 即自动恢复（3~5 秒）。

### 1.2 状态持久化
- Settings 新增：`autoRestore: boolean = true`（新设置行「打开应用自动恢复」，默认开）、`vpnWasConnected: boolean`（内部标记，不上设置页）。
- 写点：
  - `VpnController.setStatus(Connected)` → 写 vpnWasConnected=true；
  - `VpnController.stop()`（仅用户主动停止路径，在 setStatus(Disconnecting) 前）→ 写 false；
  - 系统原因断开（onDisconnect/onFailed 回调）**不动**该标记（保留 true，下次冷启动可恢复）。

### 1.3 EntryAbility 接入
- `onCreate(want, launchParam)`：
  1. 解析卡片参数（见 §2.4）；若 `action==='toggle'` → 立即 `VpnController.start(this.context)`（用户显式意图，不等延时）；
  2. 否则若 `Settings.load(this.context).autoRestore && vpnWasConnected && VpnController.status===Disconnected` → `setTimeout(1200)` 后 `VpnController.start(this.context)`（延时避开 HomePage 冷启动 recover() 探测窗口；start 内部有 status 非 Disconnected 即忽略的幂等保护，竞态安全）。
- `onNewWant(want, launchParam)`（应用已存活时卡片点按）：`action==='toggle'` → 按 `VpnController.status` 取反：Connected→`stop(context)`；Disconnected→`start(context)`；Connecting/Disconnecting 忽略。
- 参数解析：官方机制为 `want.parameters.params`（JSON 字符串）→ `JSON.parse`；解析失败静默（仅日志）。

---

## 2. 方案 B：动态开关卡片（控制中心按钮折中）

### 2.1 卡片视觉（2×2，鸿蒙 7 设计语言）
- 背景 `sys.color.comp_background_primary`，圆角 20，品牌蓝强调。
- 内容三行：
  1. 状态圆点（8vp 圆）：已连接 `#17A05E`（delay_good）/ 未连接 `sys.color.font_tertiary`；
  2. 主标题「ClashOH」18fp bold；
  3. 副文案（LocalStorage 绑定）：已连接 →「已连接 · 点按断开」；连接中 →「连接中…」；未连接 →「未连接 · 点按连接」。
- 整卡 onClick（唯一交互区）：`postCardAction(this, { action: 'router', abilityName: 'EntryAbility', params: { action: 'toggle' } })`。

### 2.2 数据绑定
- WidgetCard 改为 `let storage = new LocalStorage(); @Entry(storage) @Component struct WidgetCard`，用 `@LocalStorageProp('statusText')` 与 `@LocalStorageProp('isOn')` 渲染；FormBindingData 的键自动注入 LocalStorage。
- FormAbility：
  - `onAddForm(want)`：formId 取自 `want.parameters['ohos.extra.param.key.form_id']`，加入 Settings.cardFormIdsJson（JSON 字符串持久化，共享沙箱）；返回 `formBindingData.createFormBindingData({ statusText, isOn })`（按当前 prefs 状态）。
  - `onRemoveForm(formId)`：从 cardFormIdsJson 移除并持久化。
  - `onUpdateForm(formId)`（系统定时刷新兜底）：按 prefs 状态重建 binding 并 updateForm。

### 2.3 主进程主动刷新（新 lib/CardSync.ets）
- `export namespace CardSync { export async function update(context: common.UIAbilityContext): Promise<void> }`：
  读 Settings.cardFormIdsJson → 对每个 formId `formProvider.updateForm(formId, buildData(...))`（try/catch 静默，卡片未添加时跳过）；buildData 按 `VpnController.status` 组装 {statusText, isOn}。
- 调用点：HomePage 的 `VpnController.onChanged` 监听里，Connected / Disconnected / Connecting 分支各调一次 `CardSync.update(context)`；aboutToAppear 时补一次。

### 2.4 form_config.json
- `updateEnabled: true`、`updateDuration: 30`（单位 30 分钟，即 30 分钟兜底刷新）、`scheduledUpdateTime` 保留。其余不动。

---

## 3. 改动清单

| 文件 | 改动 |
|---|---|
| `lib/Settings.ets` | + `autoRestore=true`、+ `vpnWasConnected=false`、+ `cardFormIdsJson='[]'`（load/save 同步） |
| `lib/VpnController.ets` | setStatus(Connected) 写 vpnWasConnected=true；stop() 写 false |
| `entryability/EntryAbility.ets` | onCreate/onNewWant 参数解析 + 自动恢复/切换逻辑（见 §1.3） |
| `lib/CardSync.ets`（新） | §2.3 |
| `pages/HomePage.ets` | 状态监听回调中调 CardSync.update(context)（Connected/Connecting/Disconnected）；aboutToAppear 补一次 |
| `formability/FormAbility.ets` | formId 持久化 + 状态 binding（§2.2） |
| `widget/pages/WidgetCard.ets` | LocalStorage 绑定 + 状态点 + toggle 点击（§2.1/§2.2） |
| `resources/base/profile/form_config.json` | updateEnabled/updateDuration（§2.4） |
| `pages/SettingsPage.ets` | 新增行「打开应用自动恢复」（toggleKey 'autoRestore'，默认开） |

## 4. 实施要点与约束

- ArkTS 严格模式：命名 interface、显式类型标注、禁 any；catch 后 (e as Error)。
- preferences 存 JSON 字符串（避免数组类型的兼容问题）：cardFormIdsJson = JSON.stringify(string[])，读取用 JSON.parse + try/catch。
- `postCardAction` 在卡片组件内直接可用（全局函数，当前 WidgetCard 已在用）。
- EntryAbility 的 `setTimeout` 句柄存成员变量（避免重复调度）；onCreate 中 `this.context` 即 UIAbilityContext。
- `VpnController.start/stop` 签名不变；自动恢复只调 start（stop 仅由用户操作触发）。
- 日志 tag：`autoRestore` / `cardSync` / `form` / `entry`。
- 禁止改动：core/、scripts/、reference/、AppScope/、module.json5（本设计不新增权限/能力声明）。

## 5. 验收清单（构建 + 真机手动）

1. `bash scripts/build-hap.sh` 编译通过；sign + install 成功。
2. hilog：冷启动 `autoRestore: auto start scheduled/triggered`；卡片点按 `entry: toggle from card`；`cardSync: updated N forms`。
3. 真机手动：
   - 连接 VPN → 状态卡片变「已连接」（实时，无需等 30 分钟）；
   - 点卡片 → 断开；再点 → 连接（应用已存活时走 onNewWant，不重启 UI）；
   - 划卡杀进程 → 点桌面卡片 → 应用冷启动并**自动连接**（toggle 参数）；
   - 点图标冷启动 → 若上次会话连接过 → 1 秒后自动连接；设置页关掉「打开应用自动恢复」→ 冷启动不再自动连；
   - 用户主动断开后冷启动 → 不自动连。

---

## v1.1 修订（2026-08-14 真机问题修复 + 无 UI 开关）

### 问题 1：卡片已连接仍显示未连接（真机复现）

根因（两层）：
1. **表单进程读进程内模块状态**：FormAbility 调用的 buildBinding() 读取 `VpnController.status`，该变量是进程内模块级状态，表单进程（独立进程）中永远为初始值 Disconnected——onAddForm/onUpdateForm 永远渲染「未连接」；
2. **preferences 跨进程缓存**：ArkData preferences 实例为进程内单例缓存，跨进程修改需 dataChange 监听；主进程读不到表单进程写入的 cardFormIdsJson（永远 '[]'），CardSync.update 无卡可刷。

修复：新增 **lib/SharedState.ets**——filesDir 下 shared_state.json 文件（fileIo 无缓存，每次现读；filesDir 跨进程共享已验证：vpn 进程 LAST_ERROR_FILE 先例）。内容：`{ vpnState: 'connected|connecting|disconnected', cardFormIds: string[] }`。
- UI 进程：状态变化时 `CardSync.sync(context)`——把 VpnController.status 写入 vpnState，读 cardFormIds（现读文件）逐个 updateForm；
- 表单进程：onAddForm/onRemoveForm 维护 SharedState.cardFormIds；buildBinding 改为 `buildBindingForState(SharedState.read(context).vpnState)`；
- 文案映射：connected→「已连接 · 点按断开」/true；connecting→「连接中…」/false；其他→「未连接 · 点按连接」/false。

### 问题 2：卡片点击只开后台进程、不打开 UI（类 ClashMeta QS Tile）

官方机制：postCardAction **call 事件**（「卡片拉起应用UIAbility到后台」）——后台启动 UIAbility（冷启动也支持：先 onCreate 注册 callee 再投递方法；不执行 onWindowStageCreate，无窗口无 UI），并调用 `this.callee.on(method, callback)` 注册的方法。前置条件 KEEP_BACKGROUND_RUNNING（已声明）。
- WidgetCard onClick 改为：`postCardAction(this, { action: 'call', abilityName: 'EntryAbility', params: { method: 'toggleVpn' } })`；
- EntryAbility.onCreate 注册 `this.callee.on('toggleVpn', (data: rpc.MessageSequence): rpc.Parcelable => { toggle(); return new EmptyReply(); })`；toggle 逻辑：Disconnected→VpnController.start(this.context)；Connected→stop；过渡态忽略。onDestroy 里 callee.off。EmptyReply = 最小 rpc.Parcelable 实现（marshalling/unmarshalling 返回 true，无字段）；
- **后台态保活闭环**（关键）：无 UI 时 HomePage 不存在，必须把保活/卡片同步挂在进程级——EntryAbility.onCreate 注册一次 VpnController.onChanged 监听：每次状态变化 → `CardSync.sync(this.context)`；Connected → `LiveViewKeeper.start(this.context)`；Disconnected → `LiveViewKeeper.stop(this.context)`（LiveViewKeeper.start 内部幂等且检查 keepAlive 设置，HomePage 原有调用保留无冲突）；
- 保留 router+toggle 解析路径（作为后备，无调用方）；自动恢复逻辑不变。

### 改动清单（v1.1）

| 文件 | 改动 |
|---|---|
| `lib/SharedState.ets`（新） | 文件跨进程共享状态：read/writeVpnState/addFormId/removeFormId |
| `lib/CardSync.ets` | 重写：buildBindingForState(state)、sync(context)（写 vpnState + 刷全部卡片）；删除 addFormId/removeFormId/readFormIds（移入 SharedState） |
| `entryability/EntryAbility.ets` | callee 注册/注销 + EmptyReply；onCreate 注册 VpnController.onChanged（CardSync.sync + LiveViewKeeper.start/stop） |
| `widget/pages/WidgetCard.ets` | onClick 改 call 事件（method toggleVpn） |
| `formability/FormAbility.ets` | SharedState.addFormId/removeFormId + buildBindingForState(SharedState.read) |
| `pages/HomePage.ets` | 删除 onChanged 里的 CardSync.update 三处（改由 EntryAbility 统一）；保留 aboutToAppear 初始 CardSync.sync |

### 验收（v1.1）
- 构建通过 + 安装；
- 真机：连接 VPN 后添加卡片 → 卡片立即显示「已连接」；断开 → 变「未连接」；
- 点卡片：**应用界面不打开**（状态栏胶囊/通知出现即后台模式）；再点 → 断开；
- 划卡杀进程 → 点卡片 → 后台自动恢复连接（无 UI）；
- hilog：`entry: toggle from card call`、`cardSync: updated N forms`、`sharedState: vpnState -> connected`。

---

## v1.2 修订（2026-08-14 卡片不联动问题第二轮修复）

### 真机日志证据（21:52-21:53）
- `toggle from card call` 正常、`sharedState: vpnState -> connecting/connected/disconnected` 正常（UI 进程写共享文件成功）；
- **`cardSync` 标签零日志**：`sync()` 在 writeVpnState 之后未到达结尾的 `updated N forms`（连 `updated 0 forms` 都没有）→ 唯一能挂起的环节是 `await formProvider.updateForm(...)`（formId 列表非空时永不 settle，同步 try/catch 捕不到）。

### 根因
主进程 `formProvider.updateForm` 在本设备（HarmonyOS 7.0.0.100 真机）上存在**永不返回**的调用形态（背景态 IPC 到表单服务的调用可能被挂起；官方最佳实践确认主进程 updateForm 是标准模式，故属设备侧行为差异）。同步卡死 → 后续卡片永不刷新 → 显示与实际状态脱钩。

### 修复（四层保险）
1. **超时护栏**：CardSync.updateOne —— `Promise.race`(updateForm, 3s timeout)，永不挂起；sync 循环逐个调用，单卡失败仅记日志，最后必达 `updated N forms` 日志（下次状态变化自动重试）；
2. **点按即时反馈（官方 call 事件模式补齐）**：卡片把系统注入的 `formId` 作为 call 参数传给 Ability（`@LocalStorageProp('formId')` + `params:{method,formId}`）；callee 回调 `data.readString()` 读取后，在 toggle 的同时对该卡即时推送目标态文案（连接中/未连接，同样走护栏）——点击即反馈，不等状态监听；
3. **表单进程 5 分钟兜底刷新链**：onAddForm 与每次 onUpdateForm 调用 `formProvider.setFormNextRefreshTime(formId, 5)` 续约——系统侧定时器，表单进程被杀也按约唤醒，保证最终一致（主进程推送全失败的最坏情况 ≤5 分钟对齐）；
4. **修复 updateDuration 单位错误**：30 → 1（官方单位为 30 分钟，30 实际是 900 分钟）。

### 诊断增强
sync 开头新增日志 `sync begin state=.. forms=N ids=[...]`（确认共享 formId 列表内容与数量）；updateOne 失败/超时均有 `updateForm failed formId=..` 日志。

### 验收
真机：点卡片 → 卡片**立即**变「连接中…」→ 连接成功后变「已连接」；再点 → 立即变「未连接」；断开后卡片 5 分钟内兜底对齐（若主进程推送仍不可用）。日志关键词：`sync begin`、`updated N forms`、`updateForm failed/timeout`。

---

## v1.3 修订（2026-08-14 真根因定位与修复）

### 决定性证据（22:14/22:16 真机日志，双侧埋点）

1. 表单进程探针：共享文件 `{"vpnState":"disconnected","cardFormIds":[]}` —— **formId 注册表为空**，尽管卡片存活（formId=1520062275）；
2. 表单进程 `updateForm OK`（表单侧更新通道完全正常，5 分钟刷新链正常）；
3. 修复后 6 秒内（升级重绑触发 onUpdateForm）：`cardFormIds:["1520062275"]` —— 自愈注册生效。

### 真根因
**formId 注册表为空导致主进程推送无目标。** 卡片是在 v1.1（preferences 存 formId）时期添加的；v1.2 迁移到共享文件后，**onAddForm 不会为已存在的卡片重跑**（升级只触发 onUpdateForm），新文件里 formId 列表一直为空 → 主进程 sync 读到空列表 → 永不推送 → 卡片只能靠 5 分钟表单侧兜底渲染文件里的旧状态。这同时解释了 v1.1 的「卡死已连接」与 v1.2 的「卡死未连接」——卡片显示的一直是**添加/重绑那一刻的快照**。

### 修复
1. **onUpdateForm 自愈注册**：`SharedState.addFormId(this.context, formId)`——onUpdateForm 由系统按约刷新/升级重绑触发，其 formId 是系统下发的权威值，老卡片无需重新添加即可入册（onAddForm 登记保留、onRemoveForm 移除不变）；
2. **call 参数解析修正**：官方 bpta 文档确认 `readString()` 返回整个 params 的 JSON 字符串，需 `JSON.parse` 后取 formId（v1.2 误把 JSON 串当 formId 用，点按即时反馈全打在了无效 id 上）；
3. **form_config 补 `isDynamic: true`**（官方动态卡片配置项）；
4. 双侧全量埋点保留（probe 文件内容 / updateForm OK/FAILED / sync begin / file after write），用于最终验收与后续问题定位。

### 最终链路（验收时预期）
- 点卡片 → callee 解析出 formId → 即时推送「连接中…」→ 状态监听 sync 写 vpnState=connected → 主进程 updateOne 推送「已连接」（若主进程 updateForm 不可用，tap-time/5min 表单侧兜底保证 ≤5 分钟对齐）；
- 应用内启停 → 监听 → sync → 全卡实时刷新；
- 日志：`sync begin state=connected forms=1 ids=["1520062275"]` + `updateForm OK/FAILED`（两侧均有）。

---

## v1.4 修订（2026-08-16 自愈链不真自愈 + 点击竞态修复）

### 问题 1：UI 进程退出/设备重启后卡片永远停在旧状态

官方规则（VPN 服务生命周期）：调用 startVpnExtensionAbility 的应用进程退出时，系统主动停止 VPN。因此 UI 进程被回收/设备重启后 VPN 实际已断，但 shared_state.json 只有 UI 进程写、停留在旧值（如 connected）；表单进程 5 分钟自愈链只重渲染文件内容 → 卡片永远「已连接」。

修复：表单进程自己校验真实状态——`FormAbility.correctWithProbe()` 用 `CoreApi.isAlive()`（GET /version，127.0.0.1:9090，:vpn 独立进程回环可达）探活内核：活→connected，死→disconnected；与文件不一致时写回 SharedState 并用带 3 秒护栏的 updateOne 推校正渲染。onAddForm 同步返回文件状态 + 异步校正再推；onUpdateForm 快路径渲染 + 异步校正。

### 问题 2：卡片点击拉起新进程时的状态竞态

卡片 call 后台拉起不建 UI，新进程 VpnController.status 恒为 Disconnected；VPN 实际仍在（:vpn 进程回收边缘窗口）时点击会误判重复 start。

修复：`VpnController.recover()` 增加可选完成回调 `onDone(alive)`；`EntryAbility.toggleVpnFromCard()` 先探活再决定 stop/start（过渡态忽略）；`parseToggleAction`（router 后备路径）同样先探活。

### 问题 3：进程重建后 sync 用新进程 Disconnected 误写文件

修复：EntryAbility.onCreate ③ 与 HomePage.aboutToAppear 的 CardSync.sync、autoRestore 调度全部移入 recover 探活回调（探活落定后再写文件/推卡片）；recover 置 Connected 时 onChanged 本就会触发 sync，回调内 sync 为探活失败场景兜底（幂等）。

### 验收（v1.4，真机）
- 连接 → 划卡杀 UI 进程 → 等 5 分钟自愈链 → 卡片变「未连接」（不再永远已连接）；
- 连接 → 杀 UI 进程后边缘窗口点卡片 → 执行断开而非重复连接；
- 断连状态点卡片 → 探活后正常连接；
- 日志：`form: probe formId=.. alive=.. file=.. real=..`、`entry: toggle from card: probing core...`。
