/*
 * Index.ets - 应用主框架（DESIGN.md §2）
 * Navigation（二级页路由）+ 底部 Tabs：首页 / 代理 / 配置 / 设置
 */
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
      .barHeight(56)
      .animationDuration(0)
      .scrollable(false)
      .onChange((index: number) => {
        this.currentTab = index;
        this.currentVisibleTab = index;
      })
    }
    .hideTitleBar(true)
    .navDestination(this.PageMap)
  }
}
