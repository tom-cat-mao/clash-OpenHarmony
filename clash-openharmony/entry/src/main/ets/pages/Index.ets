/*
 * Index.ets - 应用主框架（DESIGN.md §2，H7_DESIGN.md §3）
 * Navigation（二级页路由）+ 底部 Tabs：首页 / 代理 / 配置 / 设置
 * H7 视觉：底部 Tabs 改为官方「平铺式」玻璃形态（悬浮 + 强玻璃底 + 组件级模糊）
 */
import { curves } from '@kit.ArkUI';
import { HomePage } from './HomePage';
import { ProxyPage } from './ProxyPage';
import { ProfilePage } from './ProfilePage';
import { SettingsPage } from './SettingsPage';
import { ConnectionsPage } from './ConnectionsPage';
import { LogsPage } from './LogsPage';
import { NetworkSettingsPage } from './NetworkSettingsPage';
import { OverridePage } from './OverridePage';
import { AboutPage } from './AboutPage';
import { ProxyGroupPage, ProxyGroupBus } from './ProxyGroupPage';
import { ProfileEditPage } from './ProfileEditPage';
import { GeoPage } from './GeoPage';

@Entry
@Component
struct Index {
  @State currentTab: number = 0;
  @Provide('nav') navStack: NavPathStack = new NavPathStack();
  @Provide('tab') currentVisibleTab: number = 0;
  @Provide('tabJump') @Watch('onTabJump') tabJump: number = -1;

  private onTabJump(): void {
    if (this.tabJump >= 0) {
      this.currentTab = this.tabJump;
      this.tabJump = -1;
    }
  }

  @Builder
  PageMap(name: string) {
    if (name === 'connections') {
      NavDestination() {
        ConnectionsPage()
      }
      .title('连接')
    } else if (name === 'logs') {
      NavDestination() {
        LogsPage()
      }
      .title('日志')
    } else if (name === 'network') {
      NavDestination() {
        NetworkSettingsPage()
      }
      .title('网络设置')
    } else if (name === 'override') {
      NavDestination() {
        OverridePage()
      }
      .title('覆写')
    } else if (name === 'about') {
      NavDestination() {
        AboutPage()
      }
      .title('关于')
    } else if (name === 'proxyGroup') {
      NavDestination() {
        ProxyGroupPage()
      }
      .title(ProxyGroupBus.current)
    } else if (name === 'profileEdit') {
      NavDestination() {
        ProfileEditPage()
      }
      .title('编辑配置')
    } else if (name === 'geo') {
      NavDestination() {
        GeoPage()
      }
      .title('GeoX 数据')
    }
  }

  @Builder
  TabBarItem(symbol: Resource, symbolActive: Resource, label: string, index: number) {
    Column({ space: 3 }) {
      SymbolGlyph(this.currentTab === index ? symbolActive : symbol)
        .fontSize(22)
        .fontColor(this.currentTab === index ? [$r('sys.color.brand')] : [$r('sys.color.icon_secondary')])
        // H7：选中时符号弹性跳动（BounceSymbolEffect @since 12，方向默认向下）
        .symbolEffect(new BounceSymbolEffect(), this.currentTab === index)
      Text(label)
        .fontSize(11)
        .fontColor(this.currentTab === index ? $r('sys.color.brand') : $r('sys.color.font_secondary'))
        .fontWeight(this.currentTab === index ? FontWeight.Medium : FontWeight.Regular)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Navigation(this.navStack) {
      Tabs({ barPosition: BarPosition.End, index: this.currentTab }) {
        TabContent() {
          HomePage()
        }
        .tabBar(this.TabBarItem($r('sys.symbol.house'), $r('sys.symbol.house_fill'), '首页', 0))

        TabContent() {
          ProxyPage()
        }
        .tabBar(this.TabBarItem($r('sys.symbol.bolt'), $r('sys.symbol.bolt_fill'), '代理', 1))

        TabContent() {
          ProfilePage()
        }
        .tabBar(this.TabBarItem($r('sys.symbol.doc_plaintext'), $r('sys.symbol.doc_plaintext_fill'), '配置', 2))

        TabContent() {
          SettingsPage()
        }
        .tabBar(this.TabBarItem($r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'), '设置', 3))
      }
      .width('100%')
      .height('100%')
      // H7：平铺式玻璃 TabBar —— 悬浮于内容之上、48 高、强玻璃底 + 组件级模糊（barOverlap @since 10，barBackgroundBlurStyle @since 11）
      .barHeight(48)
      .barOverlap(true)
      .barBackgroundColor($r('app.color.glass_bg_strong'))
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .animationDuration(0)
      .scrollable(false)
      .onChange((index: number) => {
        // H7：选中态颜色弹性切换（springMotion @since 9，250ms，纯视觉）
        this.getUIContext().animateTo({
          duration: 250,
          curve: curves.springMotion(0.555, 0.53)
        }, () => {
          this.currentTab = index;
          this.currentVisibleTab = index;
        });
      })
    }
    .hideTitleBar(true)
    .navDestination(this.PageMap)
  }
}
