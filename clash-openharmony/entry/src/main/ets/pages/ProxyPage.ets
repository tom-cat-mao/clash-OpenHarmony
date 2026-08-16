/*
 * ProxyPage.ets - 代理页：分组列表（两级导航第一级）
 * 卡片 = 组名 / 类型 / 节点数 / 当前选择；点卡片进分组详情页（ProxyGroupPage）
 * 数据源（ProxyData）：内核在线走 REST；内核离线解析激活配置展示（只读）。
 * 按模式过滤：全局模式只展示 GLOBAL 组（内核唯一使用的组）；规则模式隐藏 GLOBAL；
 * 直连模式不展示节点（流量不经过任何代理组）。
 */
import { CoreApi, ProxyInfo } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { ProxyGroupBus, ProxyEvents } from './ProxyGroupPage';
import { ProxyData } from '../lib/ProxyData';
import { ProfileStore } from '../lib/ProfileStore';
import { common } from '@kit.AbilityKit';

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
  @State source: string = 'none'; // 'core' | 'local' | 'none'
  @State mode: string = 'rule'; // 'rule' | 'global' | 'direct'
  @State hasActive: boolean = false;
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
      if (this.source === 'core') {
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 1000));
    }
  }

  private async refresh(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const r = await ProxyData.load(context);
    this.source = r.source;
    this.mode = r.mode;
    this.hasActive = ProfileStore.getActiveFile(context).length > 0;
    if (r.source === 'none') {
      this.groups = [];
      return;
    }
    const proxies = r.proxies;
    const rows: GroupRow[] = [];
    const names = Object.keys(proxies);
    for (const name of names) {
      const p: ProxyInfo = proxies[name];
      if (GROUP_TYPES.indexOf(p.type) < 0) {
        continue;
      }
      // 全局模式：内核只用 GLOBAL 组；规则/直连模式：GLOBAL 不参与展示
      if (this.mode === 'global') {
        if (name !== 'GLOBAL') {
          continue;
        }
      } else if (name === 'GLOBAL') {
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
      if (nowProxy !== undefined && nowProxy.history && nowProxy.history.length > 0) {
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
    // 恢复配置文件的组顺序（内核 REST 的 Go map 序列化按字典序，会把「微软服务」排到「节点选择」前面；
    // 组名不在顺序表里的（如合成的 GLOBAL）保持原相对位置排在最后）
    if (r.groupOrder.length > 0) {
      rows.sort((a: GroupRow, b: GroupRow): number => {
        const ia = r.groupOrder.indexOf(a.name);
        const ib = r.groupOrder.indexOf(b.name);
        if (ia < 0 && ib < 0) {
          return 0;
        }
        if (ia < 0) {
          return 1;
        }
        if (ib < 0) {
          return -1;
        }
        return ia - ib;
      });
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

  @Builder
  EmptyState(title: string, sub: string, actionLabel: string, actionTab: number) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(15)
        .fontColor($r('sys.color.font_secondary'))
      Text(sub)
        .fontSize(13)
        .fontColor($r('sys.color.font_tertiary'))
        .textAlign(TextAlign.Center)
      if (actionLabel.length > 0) {
        Text(actionLabel)
          .fontSize(14)
          .fontColor($r('sys.color.brand'))
          .padding(8)
          .onClick(() => {
            this.tabJump = actionTab;
          })
      }
    }
    .width('100%')
    .margin({ top: 80 })
  }

  @Builder
  LocalBanner() {
    Row({ space: 6 }) {
      SymbolGlyph($r('sys.symbol.info_circle'))
        .fontSize(14)
        .fontColor([$r('sys.color.font_tertiary')])
      Text('内核未启动 · 展示激活配置中的节点，启动后可切换与测速')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 8, bottom: 8, left: 12, right: 12 })
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(10)
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

      if (this.mode === 'direct') {
        // 直连模式：所有流量直连，节点列表无意义
        this.EmptyState('直连模式', '所有流量直连，不使用代理节点\n在首页切换到「规则」或「全局」模式后查看节点', '', 0)
      } else if (this.source === 'none') {
        if (!this.hasActive) {
          this.EmptyState('暂无代理分组', '还没有导入配置\n导入订阅后这里会展示分组与节点', '去导入订阅 ›', 2)
        } else {
          this.EmptyState('未读取到代理分组', '内核未启动，且激活配置中未能解析出分组\n请到「配置」页检查配置内容', '去配置页 ›', 2)
        }
      } else if (this.groups.length === 0) {
        if (this.source === 'core') {
          this.EmptyState('暂无代理分组', '当前配置没有定义代理组，全部流量直连', '去导入订阅 ›', 2)
        } else {
          this.EmptyState('暂无代理分组', '激活配置中没有定义代理组', '去配置页 ›', 2)
        }
      } else {
        Column({ space: 10 }) {
          if (this.source === 'local') {
            this.LocalBanner()
          }
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
                      } else if (this.mode === 'global' && g.name === 'GLOBAL') {
                        Text('全局出口')
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
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
