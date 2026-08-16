# ClashOH 鸿蒙 7「空间美学 · 沉浸光感」视觉改造规范（H7_DESIGN）

> 依据：HarmonyOS 7 官方设计语言「空间美学」+ 材质体系「沉浸光感」（华为开发者官网设计指南，
> 详见 QUICK 调研结论；官方不使用“液态玻璃”一词，媒体类比）。本规范给出 ClashOH 的落地决策
> 与可直接抄用的 ArkUI 写法。兼容下限：compatible SDK 6.0.1（API 21），所列 API 全部 ≤21 可用。

## 0. 材质分层总原则（性能红线）

- **真玻璃（模糊）只用于悬浮层**：底部 TabBar、一级页顶部主卡、半模态/弹层。实现二选一：
  `.backgroundBlurStyle(BlurStyle.COMPONENT_THICK)` 或 `.backgroundEffect({ radius: 24, saturation: 1.7, brightness: 1.06, color: $r('app.color.glass_bg') })`。
- **列表行/密集网格一律不用模糊**：用半透明 token（app.color.glass_row）+ 1px 发丝线描边（app.color.glass_border）。每行都开 blur 会掉帧。
- 页面背景保持 sys.color.background_secondary（≈官方 #F1F3F5/#191A1C），顶部可加一层品牌弥散光渐变（见 §3）。

## 1. Token（已写入 resources 的 base/dark color.json，直接引用即可）

| token | base(浅) | dark(深) | 用途 |
|---|---|---|---|
| app.color.brand | #0A59F7 | #317AF7 | 主色（官方宇宙蓝） |
| app.color.glass_bg | #B3FFFFFF | #B3202224 | 玻璃卡片底色（70%） |
| app.color.glass_bg_strong | #E6FFFFFF | #E6202224 | TabBar/弹层底色（90%） |
| app.color.glass_row | #80FFFFFF | #80202224 | 列表行底色（50%） |
| app.color.glass_border | #1A000000 | #1FFFFFFF | 发丝线描边 |
| app.color.glow_brand | #140A59F7 | #14317AF7 | 弥散光/渐变收尾色 |
| app.color.chip_bg | #1A0A59F7 | #1A317AF7 | 「自动/全局出口」浅 chip 底 |
| app.color.delay_good/mid/bad | 沿用现值 | 沿用现值 | 延迟语义色 |

文本/背景一律继续用 sys.color.*（与官方 4 级文本 token 一致）。阴影颜色用 #1F000000（深色 #8C000000，代码内按 ColorMode 不敏感时统一浅值即可）。

## 2. 排版与间距（ClashOH 映射）

- 一级页大标题：30fp Bold（Title_L），下方副标题 12fp tertiary；标题块上 margin 8、下 margin 4。
- 卡片标题 16fp Medium；正文 14 Regular；说明/时间 12 tertiary；大数字（首页速率等）32~48 Light。
- 页面左右 margin 16vp；卡片间距 12vp；卡片内 padding 14~16；控件间 8vp。
- 圆角：主卡片/弹层 20vp（顶层悬浮 32vp）；列表行圆角 16vp；chip 8vp；组内节点卡 12vp（保持）。
- 底部：页面根容器 padding bottom 至少 76（TabBar 48 悬浮 + 系统导航条 28 避让）。

## 3. 标准配方（直接抄用）

**页面根（一级页）**：根 Column 加 .expandSafeArea？不必要；保持 .width('100%').height('100%').padding({left:16,right:16}).backgroundColor(sys.background_secondary)。顶部弥散光（可选，首页必须）：在标题块上叠一个绝对定位渐变层：
```
Stack() { Column(){...内容...} }
// 弥散光：高度 ~200vp，从 brand 8% 淡到全透明
Column().width('100%').height(200).linearGradient({ angle: 180, colors: [[$r('app.color.glow_brand'), 1.0], [$r('app.color.glow_brand'), 0.0]] })
```

**玻璃主卡**（首页状态卡等悬浮层）：
```
Column(){...}
.backgroundEffect({ radius: 24, saturation: 1.7, brightness: 1.06, color: $r('app.color.glass_bg') })
.borderRadius(20)
.border({ width: 1, color: $r('app.color.glass_border') })
.shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 6 })
```
（backgroundEffect @since 11，参数名 radius/saturation/brightness/color 必查 d.ts；若该重载报错则退回 .backgroundColor($r('app.color.glass_bg')).backdropBlur(24)）

**列表行**：
```
.backgroundColor($r('app.color.glass_row')).borderRadius(16).border({ width: 1, color: $r('app.color.glass_border') })
```

**底部 TabBar（官方「平铺式」玻璃形态）**：Index.ets 的 Tabs 改为：
```
Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
  ... TabContent().tabBar(this.TabBarItem(...)) ...
}
.barOverlap(true)
.barHeight(48)
.barBackgroundColor($r('app.color.glass_bg_strong'))
.barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
```
TabBarItem：SymbolGlyph 22 + 标签 11fp；未选中 icon_secondary/font_secondary，选中 brand + 加
`.symbolEffect(new BounceSymbolEffect().direction(EffectDirection.DOWN))...`（@since 12，写法查 d.ts symbolglyph.d.ts；不可用则省略）并用
`animateTo({ duration: 250, curve: curves.springMotion(0.555, 0.53) }, ...)` 驱动字号/颜色变化。四个 Tab 保持「首页/代理/配置/设置」。

**按压反馈（所有可点元素统一）**：
```
.stateStyles({ pressed: { .scale({x:0.96,y:0.96}).opacity(0.9) }, normal: { .opacity(1) } })
```
（stateStyles 内 scale 写法若报错，退化为 backgroundColor 变化，参照现有代码。）

**模式胶囊（首页 规则/全局/直连）**：容器 borderRadius 20、背景 comp_background_secondary/玻璃行色；选中项 brand 底白字、非选中 font_secondary；切换加 250ms springMotion 过渡（可省略）。

**半模态（节点详情 bindSheet）**：sheet 内容容器 .backgroundColor($r('app.color.glass_bg_strong')).borderRadius({topLeft:32,topRight:32})（bindSheet 支持 borderRadius 传四角对象，报错则整体 32）。

**二级页（NavDestination）**：保持系统标题栏；页面内卡片/行按上述列表行配方。

## 4. 禁止事项

- 不改任何业务逻辑/状态/数据流/路由/文案语义（空态提示文案可保留原意微调，不得删功能）；
- 不碰 resources（token 已就绪）、lib/*、vpnability、entryability、core、scripts；
- 只用分配的页面文件；ArkTS 严格子集；API 必须 ≤21（对 @since 有疑问就 grep 本机 SDK：
  /Users/bytedance/harmony-mihomo/command-line-tools/sdk/default/openharmony/ets/component/*.d.ts）；
- 不 commit、不构建（主 agent 统一构建验收）；ForEach key 保持稳定唯一。

## 5. 验收关注点（主 agent）

- 首页：弥散光 + 玻璃主卡 + 大数字 Light + 胶囊模式切换 + 玻璃 TabBar；
- 各列表页：标题 30 Bold、行玻璃化、空态文案保留、所有交互路径不变；
- 构建通过、无明显 @since 告警（18+ 重载的 Optional 告警可容忍）。
