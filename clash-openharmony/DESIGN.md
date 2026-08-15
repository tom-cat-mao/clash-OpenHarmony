# ClashOH 前端设计（HarmonyOS NEXT / 鸿蒙 7 设计语言）

> 原则：功能对标 ClashMetaForAndroid，形态完全跟随鸿蒙设计语言——
> 底部 Tabs、大标题、卡片化、系统色、SymbolGlyph 图标、深浅色自适应、少即是多。
> 不照搬 Material Design（CMFA 的侧滑抽屉、FAB、顶部 Tab 在鸿蒙里都不是一等公民）。

## 1. 设计语言基线（ArkUI 实现映射）

| 元素 | 规范 | ArkUI 落地 |
|---|---|---|
| 导航 | 底部 Tabs，2~4 个一级入口 | Tabs { barPosition: End } + 自定义 TabBar（SymbolGlyph 线/面双态） |
| 二级导航 | 层级导航 ≤3 层，标题栏带返回 | Navigation + NavPathStack + NavDestination |
| 页面标题 | 一级页大标题 26fp/bold；二级页系统标题栏 | 页面内标题行 + .title() |
| 内容容器 | 卡片圆角 16（小卡/网格项 12、chip 8），卡片间距 12，页面左右 16 | borderRadius 统一 token |
| 色彩 | 品牌色 + 延迟语义色，全部走资源 token，深浅色双份 | app.color.* + sys.color.*，禁止硬编码 |
| 图标 | 系统 SymbolGlyph 24vp 标准（行尾 16vp），禁止文本符号冒充 | SymbolGlyph($r('sys.symbol.*')) |
| 字体 | HarmonyOS Sans，主 15/medium、副 13、三级 12，长文本省略号 | fontSize/fontWeight/maxLines/textOverflow |
| 操作反馈 | 按压态 stateStyles；开关用系统 Toggle | stateStyles({pressed,normal}) |
| 连接主操作 | 居中大圆形按钮（参考系统 VPN/运动健康大圆环） | Circle + sys.symbol.power + 状态动画 |

### 设计 token（resources/base/element/color.json + resources/dark/element/color.json）

| token | 亮色 | 暗色 | 用途 |
|---|---|---|---|
| brand | #0A59F7 | #4A8CFF | 品牌主色、强调操作 |
| delay_good | #17A05E | #2BD58A | 延迟 <200ms |
| delay_mid | #E6A23C | #F0B74F | 延迟 <500ms |
| delay_bad | #D93026 | #F2637B | 延迟 ≥500ms / 超时 |
| chip_bg | #1A0A59F7 | #1A4A8CFF | "自动"等浅色 chip 背景 |

其余一律使用 sys.color.* 系统语义色（font_primary/secondary/tertiary、comp_background_*、icon_* 等）。

## 2. 信息架构（4 个一级 Tab）

首页 (Dashboard)：大圆环启停 / 状态卡（模式、上下行、时长）/ 模式切换 / 当前节点卡（主分组语义+记忆）/ 当前 Profile 卡。
代理 (Proxies)：分组列表（组名/类型/节点数/当前选择+延迟+自动chip、批量测速结果落行）→ 组内节点页（搜索/排序/测速/长按详情/子组卡/宽屏3列）；下拉刷新。
配置 (Profiles)：Profile 列表（激活标记/订阅信息/行内更新/更多菜单）；＋菜单（URL/文件/剪贴板导入）；编辑页（文本编辑器、保存热重载、另存为）；重命名/导出/复制订阅URL/删除；下拉刷新。
设置 (Settings)：网络设置 / 覆写 / 连接 / 日志（二级页）；订阅分组（自动更新订阅 Toggle + 更新间隔 12/24/48/72h）；GeoX 数据二级页；后台运行开关；关于。

服务卡片（FormExtensionAbility，2×2）：ClashOH 状态卡，点按唤起主 Ability。

## 3. 代理页（信息密度升级后的目标形态）

分组列表行（双行结构）：
- 主行：组名（15/medium）；副行：类型 · N 节点 · 312ms（延迟着色）
- 右侧：当前选择（13/secondary，42% 截断）+ 自动组 chip「自动」+ chevron_right

顶部操作：bolt 批量测速——结果直接写回各分组行（不再是无效按钮）。

组内节点页：
- 搜索框（magnifyingglass 前缀）过滤节点；排序按钮循环「按名称/按延迟」；
- 节点卡：名称 + 延迟（着色）；选中态主色描边；子组卡 folder 图标 + 「当前: xxx」；
- 长按节点 → 底部详情 sheet（类型/UDP/最近延迟）；
- 组测速结果实时着色；宽屏（≥600vp）网格 2→3 列。

## 4. 配置页

- ＋ → 半屏菜单：从 URL 导入 / 从文件导入 / 从剪贴板导入；
- 行：激活 checkmark_circle_fill + 名称 + 订阅信息（流量/剩余天数，解析 subscription-userinfo 头）+ 行内更新按钮 + 更多菜单（编辑/重命名/导出/复制订阅URL/删除）；
- 编辑页（二级路由）：TextArea 全文编辑，保存即热重载，支持另存为新配置；
- 下拉刷新 = 更新激活订阅并热重载。

## 5. 设置页

- 网络设置 / 覆写 / 连接 / 日志（二级页，统一设计语言）；
- 订阅分组：自动更新订阅 Toggle + 更新间隔；
- GeoX 数据二级页（立即更新 + 状态反馈）；
- 后台运行 Toggle、关于。

## 6. CMFA 功能映射与取舍

| CMFA 功能 | ClashOH 落点 | 说明 |
|---|---|---|
| 启停/模式切换 | 首页大圆环 + 模式卡 | 视觉中心 |
| 代理组/节点/测速 | 代理 Tab（延迟落行/搜索/排序/节点详情） | 全量保留 |
| Profile 订阅/文件/更新/编辑/订阅信息 | 配置 Tab | 全量保留 |
| 自动更新订阅 | 设置→订阅 | 间隔更新 + 热重载 |
| Override 覆写 | 设置→覆写二级页 | 全量保留 |
| 按应用分流/DNS/IPv6 | 设置→网络设置 | 保留 |
| 连接查看/关闭 | 设置→连接 | 保留 |
| 日志 | 设置→日志 | 保留 |
| GeoX 更新 | 设置→GeoX 二级页 | 保留 |
| 快捷磁贴 TileService | 服务卡片(FormExtensionAbility) | 鸿蒙对应物 |
| 系统代理开关 | 砍掉 | 鸿蒙无全局 HTTP 代理 API |
| TUN 栈选择器 | 砍掉（固定 gVisor） | 鸿蒙沙箱限制 |
| find-process-mode | 砍掉（固定 off） | 沙箱拿不到进程信息 |

## 7. 交互与状态规范

- ForEach 键值必须包含行内所有会变化的显示字段（ArkUI 键值复用机制，防列表不刷新）；
- 所有可点元素提供 pressed 态；重要结果（连接成功/失败）可选触觉反馈；
- 列表页支持下拉刷新（Refresh）；长列表 maxLines+Ellipsis；
- 主分组判定：持久化用户进入的主分组，fallback 第一个非 GLOBAL Selector（不依赖名字约定）。

## 8. 主题

- 主色：品牌蓝（#0A59F7 档），深浅色自动切换（token 双份）；
- 连接态语义色：未连=灰 / 连接中=品牌色脉冲 / 已连=品牌色常亮（失败才用红）；
- 全部颜色走 app.color.* + sys.color.*，不硬编码。
