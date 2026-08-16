/*
 * H7.ets - HarmonyOS 7（API 26）「沉浸光感」材质助手（H7_DESIGN.md §0/§1）
 * 全部材质工厂在 API<26 设备返回 undefined：调用方以 H7 判定走新旧两套样式。
 * 场景档位依据官方设计指南「沉浸光感」：底部悬浮 THIN / 顶部悬浮 ULTRA_THIN /
 * 通用卡片 REGULAR·THIN / 半模态 ULTRA_THICK。
 */
import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

/** 沉浸光感（沉浸式系统材质）是否可用：仅 HarmonyOS 7 / API 26+ */
export const H7: boolean = deviceInfo.sdkApiVersion >= 26;

/** 底部悬浮区域（TabBar）：THIN */
export function matTabBar(): uiMaterial.ImmersiveMaterial | undefined {
  if (!H7) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.THIN });
}

/** 顶部悬浮/胶囊容器：ULTRA_THIN */
export function matFloat(): uiMaterial.ImmersiveMaterial | undefined {
  if (!H7) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THIN });
}

/** 页面主卡：REGULAR */
export function matHero(): uiMaterial.ImmersiveMaterial | undefined {
  if (!H7) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.REGULAR });
}

/** 可点信息卡：THIN + 交互形变 + 光感反馈 */
export function matCard(): uiMaterial.ImmersiveMaterial | undefined {
  if (!H7) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({
    style: uiMaterial.ImmersiveStyle.THIN,
    interactive: true,
    lightEffect: {}
  });
}

/** 半模态/弹出框：ULTRA_THICK */
export function matSheet(): uiMaterial.ImmersiveMaterial | undefined {
  if (!H7) {
    return undefined;
  }
  return new uiMaterial.ImmersiveMaterial({ style: uiMaterial.ImmersiveStyle.ULTRA_THICK });
}

/** 底部 TabBar 悬浮样式（Tabs.barFloatingStyle）：悬浮胶囊 + 系统渐变蒙层 */
export function tabBarFloating(): FloatingTabBarStyle | undefined {
  if (!H7) {
    return undefined;
  }
  return { systemMaterial: matTabBar() };
}

/** 半模态统一配置：H7 透明底 + ULTRA_THICK 材质；旧设备保持原样 */
export function sheetOptions(): SheetOptions {
  if (H7) {
    return {
      height: SheetSize.MEDIUM,
      backgroundColor: Color.Transparent,
      systemMaterial: matSheet()
    };
  }
  return { height: SheetSize.MEDIUM };
}

/** 内容区底部避让（barOverlap 后悬浮底栏遮挡）：列表尾部留白 */
export function tabBarSafePad(): number {
  return H7 ? 88 : 0;
}
