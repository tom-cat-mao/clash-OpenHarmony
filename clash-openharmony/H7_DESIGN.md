# ClashOH 鸿蒙 7「沉浸光感」视觉规范（v2，基于官方文档与实机截图调研）

> 调研来源（2026-08，实机浏览器截图取证）：
> - 设计指南「沉浸光感」: developer.huawei.com/consumer/cn/doc/design-guides/immersivelight-0000002612101053
> - 开发指南「沉浸光感」: harmonyos-guides/arkts-immersive-light-sense 及 -faq
> - 「圆角参数」「间隔参数」「色彩」设计指南
> - 官方场景示例图（相册 Before/After、强/均衡/弱三档、五档材质厚度）
>
> 与 v1（已 revert）的本质区别：**全部使用 API 26 原生系统材质（uiMaterial.ImmersiveMaterial）
> 与原生悬浮底栏（Tabs.barFloatingStyle）**，不手写模糊/玻璃模拟。材质效果随系统
> 「沉浸光感」强弱设置（强/均衡/弱）与设备算力自动分档，与系统观感一致。

## 0. 兼容性

- 目标机：HarmonyOS 7.0.0（API 26）。`targetSdkVersion: 26.0.0` 已满足。
- 门槛：所有 API 26 能力经 `lib/H7.ets` 的 `H7` 常量（deviceInfo.sdkApiVersion >= 26）判定，
  旧设备传入 undefined/走旧样式分支。**注意**：`.systemMaterial()`/`.barFloatingStyle()` 等方法
  调用本身在 API<26 设备上可能不存在——当前只保证 API 26+ 设备运行（本项目为侧载自用）。

## 1. 官方场景规范 → ClashOH 映射

| 官方场景 | 材质档位 | ClashOH 落点 |
|---|---|---|
| 底部悬浮区域（+渐变蒙层延展内容） | THIN | 底部 TabBar（barFloatingStyle + ImmersiveMaterial(THIN)） |
| 顶部悬浮区域（+渐变模糊延展） | ULTRA_THIN | 首页模式胶囊容器 |
| 通用容器/卡片 | REGULAR / THIN | 首页主卡（REGULAR）、信息卡（THIN，interactive+lightEffect） |
| 半模态、弹出框 | ULTRA_THICK | 全部 bindSheet（4 处） |
| 菜单/任意位置弹出 | THICK | （ENABLE 模式下菜单/ActionSheet 自动） |

应用级开关：module.json5（entry）metadata `ohos.arkui.UIMaterial.state = enable`
→ Dialog/Toast/Toggle/Slider/Select/SegmentButton/Chip/bindSheet 等系统组件默认开材质，
弹窗弹出自动带空间动效（高算力设备）。

## 2. 材质使用规则（FAQ 硬性约束）

1. 材质层在 backgroundColor **之下**：组件背景必须透明（Color.Transparent），否则材质被盖住。
2. `.systemMaterial()` 放在其他样式属性**之后**。
3. `applyShadow` 默认 true，材质自带阴影优先于自定义 shadow；需要自定义 shadow 时设 false。
4. materialColor 必须带透明度，纯不透明色会完全遮挡材质。
5. 列表密集行**不**逐个上材质（官方：材质面向悬浮/交叠层；密集列表保持实体卡片，保帧率）。

## 3. 圆角（官方圆角参数）

- 8：标签/chip/小容器（节点网格卡 12 ≈ 小容器，保持）
- 16：内容卡片/列表行/通知卡片（设置分组卡 12→16、配置列表卡 12→16、信息卡 12→16）
- 20：主卡/选项卡容器（首页主卡、模式胶囊容器）
- 32：半模态/弹出层（sheet 系统容器自带，内容根容器 H7 下透明+0 圆角）

## 4. 色彩/排版

- 品牌色保持宇宙蓝 #0A59F7；深色对齐官方深色宇宙蓝 #317AF7（原 #4A8CFF 偏亮）。
- 文本/背景沿用 sys.color.* 四级 token（与官方 font_primary~font_fourth 一致）。
- 页面左右 margin 16vp（间隔参数·手机），卡片间距 12vp，4/8 栅格。
- 首页速率数字 22fp Medium；一级页标题保持 26fp Bold（系统大标题量级）。
- 首页顶部品牌弥散光（glow_soft 6~8% 蓝 → 透明，约 220vp 高）营造空间感。
- 连接中大圆环：品牌色发光投影（brand_glow）= 光感；连接中呼吸动画保留。

## 5. 验收

- 底栏：悬浮玻璃胶囊、内容滚动透出、选中弹跳（BounceSymbolEffect）。
- 首页：主卡/信息卡材质、模式胶囊材质、圆环发光。
- 设置页 Toggle、ActionSheet、四处 bindSheet：系统材质+弹出动效（ENABLE 自动）。
- 深浅色双模式；旧设备无材质但布局不错乱。
