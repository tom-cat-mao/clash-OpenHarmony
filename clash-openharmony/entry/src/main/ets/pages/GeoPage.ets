/*
 * GeoPage.ets - GeoX 数据（设置 → GeoX 数据）
 * 更新 geoip/geosite 数据库，供规则分流使用。路由 'geo' 由集成侧统一注册。
 */
import { promptAction } from '@kit.ArkUI';
import { CoreApi } from '../lib/CoreApi';

@Component
export struct GeoPage {
  @Consume('nav') navStack: NavPathStack;
  @State updating: boolean = false;
  @State lastResult: string = '';

  private async onUpdateTap(): Promise<void> {
    if (this.updating) {
      return;
    }
    this.updating = true;
    const ok = await CoreApi.updateGeoDatabases();
    if (ok) {
      this.lastResult = `最近更新：${this.nowText()}`;
      promptAction.showToast({ message: '更新已开始', duration: 1500 });
    } else {
      this.lastResult = '内核未运行，请先启动 VPN';
      promptAction.showToast({ message: '内核未运行，请先启动 VPN', duration: 1500 });
    }
    this.updating = false;
  }

  private nowText(): string {
    const d = new Date();
    const pad = (n: number): string => n.toString().padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text('GeoX 数据库（geoip/geosite）用于规则分流')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Text(`当前状态：${this.lastResult.length > 0 ? this.lastResult : '尚未更新'}`)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.glass_row'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.glass_border') })

      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.cloud_and_arrow_down'))
          .fontSize(20)
          .fontColor([$r('sys.color.brand')])
        Text(this.updating ? '更新中…' : '立即更新')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.brand'))
      }
      .justifyContent(FlexAlign.Center)
      .width('100%')
      .padding(16)
      .backgroundColor($r('app.color.glass_row'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.glass_border') })
      .stateStyles({
        pressed: { .opacity(0.6) },
        normal: { .opacity(1) }
      })
      .onClick(() => {
        this.onUpdateTap();
      })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
