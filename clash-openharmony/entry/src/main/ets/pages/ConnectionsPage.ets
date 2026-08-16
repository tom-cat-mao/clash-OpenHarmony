/*
 * ConnectionsPage.ets - 活跃连接（设置 → 连接）
 * 轮询 GET /connections，支持单条关闭与全部关闭
 */
import { CoreApi, ConnectionItem, formatBytes } from '../lib/CoreApi';
import { promptAction } from '@kit.ArkUI';

@Component
export struct ConnectionsPage {
  @State items: ConnectionItem[] = [];
  @State upTotal: string = '0 B';
  @State downTotal: string = '0 B';
  @State coreDown: boolean = false;
  @State refreshing: boolean = false;
  private timer: number = -1;

  aboutToAppear(): void {
    this.poll();
    this.timer = setInterval(() => this.poll(), 2000);
  }

  aboutToDisappear(): void {
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private async poll(): Promise<void> {
    const resp = await CoreApi.getConnections();
    if (!resp) {
      this.coreDown = true;
      this.items = [];
      return;
    }
    this.coreDown = false;
    this.upTotal = formatBytes(resp.uploadTotal);
    this.downTotal = formatBytes(resp.downloadTotal);
    this.items = (resp.connections ?? []).slice(0, 200);
  }

  private async refresh(): Promise<void> {
    await this.poll();
    this.refreshing = false;
  }

  private hostOf(c: ConnectionItem): string {
    const m = c.metadata;
    if (m.host && m.host.length > 0) {
      return m.host;
    }
    return m.destinationIP;
  }

  @Builder
  ConnRow(c: ConnectionItem) {
    Column({ space: 4 }) {
      Row() {
        Text(this.hostOf(c) + ':' + c.metadata.destinationPort)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row() {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(16)
            .fontColor([$r('sys.color.font_tertiary')])
        }
        .width(40)
        .height(40)
        .justifyContent(FlexAlign.Center)
        .margin({ left: 8 })
        .stateStyles({
          pressed: { .opacity(0.6) },
          normal: { .opacity(1.0) }
        })
        .onClick(async () => {
          await CoreApi.closeConnection(c.id);
          this.poll();
        })
      }
      Text(`${c.chains.join(' → ')} · ${c.rule}${c.rulePayload.length > 0 ? ' ' + c.rulePayload : ''}`)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(`↑${formatBytes(c.upload)} ↓${formatBytes(c.download)} · ${c.metadata.network.toUpperCase()}`)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ top: 2, bottom: 2, left: 14, right: 6 })
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(`↑${this.upTotal} ↓${this.downTotal} · ${this.items.length} 条`)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Blank()
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.trash'))
            .fontSize(16)
            .fontColor([$r('app.color.delay_bad')])
          Text('全部关闭')
            .fontSize(13)
            .fontColor($r('app.color.delay_bad'))
        }
        .padding({ top: 10, bottom: 10, left: 8, right: 8 })
        .stateStyles({
          pressed: { .opacity(0.6) },
          normal: { .opacity(1.0) }
        })
        .onClick(async () => {
          await CoreApi.closeAllConnections();
          promptAction.showToast({ message: '已关闭全部连接', duration: 1500 });
          this.poll();
        })
      }
      .width('100%')
      .padding({ left: 4, right: 4 })

      if (this.coreDown) {
        Text('内核未运行')
          .fontSize(14)
          .fontColor($r('sys.color.font_tertiary'))
          .margin({ top: 60 })
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0 }) {
            ForEach(this.items, (c: ConnectionItem, index: number) => {
              ListItem() {
                Column() {
                  this.ConnRow(c)
                  if (index < this.items.length - 1) {
                    Divider().color($r('sys.color.comp_divider')).margin({ left: 14 })
                  }
                }
              }
            }, (c: ConnectionItem) => c.id + '|' + c.upload + '|' + c.download)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(12)
        }
        .layoutWeight(1)
        .width('100%')
        .onRefreshing(() => {
          this.refresh();
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
