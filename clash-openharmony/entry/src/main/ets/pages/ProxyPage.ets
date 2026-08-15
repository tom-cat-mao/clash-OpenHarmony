/*
 * ProxyPage.ets - 代理页：分组列表（两级导航第一级）
 * 卡片 = 组名 / 类型 / 节点数 / 当前选择；点卡片进分组详情页（ProxyGroupPage）
 */
import { CoreApi, ProxyInfo } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { ProxyGroupBus, ProxyEvents } from './ProxyGroupPage';

const GROUP_TYPES: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance'];

class GroupRow {
  name: string = '';
  type: string = '';
  now: string = '';
  count: number = 0;
  delay: number = 0; // 当前出口节点延迟，0=未测
}

@Component
export struct ProxyPage {
  @Consume('nav') navStack: NavPathStack;
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @Consume('tabJump') tabJump: number;
  @State groups: GroupRow[] = [];
  @State coreDown: boolean = false;
  @State refreshing: boolean = false;

  private eventsRegistered: boolean = false;

  aboutToAppear(): void {
    this.refresh();
    if (!this.eventsRegistered) {
      this.eventsRegistered = true;
      // 详情页选中节点后 → 立即刷新列表（pop 返回时不走 onTabVisible）
      ProxyEvents.onSelected = () => {
        this.refresh();
      };
      VpnController.onChanged((s: VpnStatus) => {
        if (s === VpnStatus.Connected) {
          // 内核刚起，REST 可能要晚几百毫秒；重试几次
          this.refreshWithRetry(5);
        }
      });
    }
  }

  private onTabVisible(): void {
    if (this.currentVisibleTab === 1) {
      this.refresh();
    }
  }

  private async refreshWithRetry(times: number): Promise<void> {
    for (let i = 0; i < times; i++) {
      await this.refresh();
      if (!this.coreDown) {
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 1000));
    }
  }

  private async refresh(): Promise<void> {
    const proxies = await CoreApi.getProxies();
    if (!proxies) {
      this.coreDown = true;
      this.groups = [];
      return;
    }
    this.coreDown = false;
    const rows: GroupRow[] = [];
    const names = Object.keys(proxies);
    for (const name of names) {
      const p: ProxyInfo = proxies[name];
      if (GROUP_TYPES.indexOf(p.type) < 0 || name === 'GLOBAL') {
        continue;
      }
      const g = new GroupRow();
      g.name = name;
      g.type = p.type;
      g.now = p.now;
      g.count = p.all ? p.all.length : 0;
      // 延迟：优先当前出口节点 history 最后一条（>0 才采纳），否则组自身 history 最后一条（>0），否则 0
      const nowProxy = proxies[g.now];
      let delay: number = 0;
      if (nowProxy && nowProxy.history && nowProxy.history.length > 0) {
        const d = nowProxy.history[nowProxy.history.length - 1].delay;
        if (d > 0) {
          delay = d;
        }
      }
      if (delay === 0 && p.history && p.history.length > 0) {
        const d = p.history[p.history.length - 1].delay;
        if (d > 0) {
          delay = d;
        }
      }
      g.delay = delay;
      rows.push(g);
    }
    this.groups = rows;
  }

  private typeLabel(t: string): string {
    if (t === 'Selector') {
      return '选择';
    }
    if (t === 'URLTest') {
      return '自动';
    }
    if (t === 'Fallback') {
      return '自动';
    }
    if (t === 'LoadBalance') {
      return '均衡';
    }
    return t;
  }

  private openGroup(g: GroupRow): void {
    ProxyGroupBus.current = g.name;
    this.navStack.pushPath({ name: 'proxyGroup' });
  }

  private async onPullRefresh(): Promise<void> {
    this.refreshing = true;
    try {
      await this.refresh();
    } finally {
      this.refreshing = false;
    }
  }

  private delayColor(d: number): ResourceColor {
    if (d <= 0) {
      return $r('sys.color.font_tertiary');
    }
    if (d < 200) {
      return $r('app.color.delay_good');
    }
    if (d < 500) {
      return $r('app.color.delay_mid');
    }
    return $r('app.color.delay_bad');
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('代理')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      .width('100%')
      .margin({ top: 8, bottom: 4 })

      if (this.coreDown) {
        Column({ space: 8 }) {
          Text('内核未运行')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
          Text('内核未运行时读不到分组信息')
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
          Text('去首页启动 ›')
            .fontSize(14)
            .fontColor($r('sys.color.brand'))
            .padding(8)
            .onClick(() => {
              this.tabJump = 0;
            })
        }
        .width('100%')
        .margin({ top: 80 })
      } else if (this.groups.length === 0) {
        Column({ space: 10 }) {
          Text('暂无代理分组')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
          Text('当前为内置空配置，全部流量直连')
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
          Text('去导入订阅 ›')
            .fontSize(14)
            .fontColor($r('sys.color.brand'))
            .padding(8)
            .onClick(() => {
              this.tabJump = 2;
            })
        }
        .width('100%')
        .margin({ top: 80 })
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 12 }) {
            ForEach(this.groups, (g: GroupRow) => {
              ListItem() {
                Row() {
                  Column({ space: 4 }) {
                    Text(g.name)
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor($r('sys.color.font_primary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Row({ space: 6 }) {
                      Text(`${this.typeLabel(g.type)} · ${g.count} 节点`)
                        .fontSize(13)
                        .fontColor($r('sys.color.font_tertiary'))
                      if (g.delay > 0) {
                        Text(`${g.delay}ms`)
                          .fontSize(13)
                          .fontColor(this.delayColor(g.delay))
                      }
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)

                  Column({ space: 4 }) {
                    if (g.type !== 'Selector') {
                      Text('自动')
                        .fontSize(11)
                        .fontColor($r('sys.color.brand'))
                        .backgroundColor($r('app.color.chip_bg'))
                        .borderRadius(8)
                        .padding({ top: 2, bottom: 2, left: 8, right: 8 })
                    }
                    Text(g.now)
                      .fontSize(13)
                      .fontColor($r('sys.color.font_secondary'))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .constraintSize({ maxWidth: '42%' })
                  }
                  .alignItems(HorizontalAlign.End)

                  SymbolGlyph($r('sys.symbol.chevron_right'))
                    .fontSize(16)
                    .fontColor([$r('sys.color.font_tertiary')])
                    .margin({ left: 8 })
                }
                .width('100%')
                .padding(14)
                .backgroundColor($r('sys.color.comp_background_primary'))
                .borderRadius(16)
                .stateStyles({
                  pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
                  normal: { .backgroundColor($r('sys.color.comp_background_primary')) }
                })
                .onClick(() => {
                  this.openGroup(g);
                })
              }
            }, (g: GroupRow) => g.name + '|' + g.now + '|' + g.delay)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
        }
        .width('100%')
        .layoutWeight(1)
        .onRefreshing(() => {
          this.onPullRefresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
