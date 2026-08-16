/*
 * AboutPage.ets - 关于（设置 → 关于）
 */
import { CoreApi } from '../lib/CoreApi';

@Component
export struct AboutPage {
  @State kernelVersion: string = '未连接内核';

  aboutToAppear(): void {
    CoreApi.isAlive().then(async (alive) => {
      if (alive) {
        const s = await CoreApi.getConfigs();
        if (s) {
          this.kernelVersion = '运行中';
        }
      }
    });
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 6 }) {
        Text('ClashOH')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('mihomo 内核 v1.19.29 · HarmonyOS NEXT')
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding(20)
      .backgroundEffect({ radius: 24, saturation: 1.7, brightness: 1.06, color: $r('app.color.glass_bg') })
      .borderRadius(20)
      .border({ width: 1, color: $r('app.color.glass_border') })
      .shadow({ radius: 16, color: '#1F000000', offsetX: 0, offsetY: 6 })

      Column({ space: 0 }) {
        Row() {
          Text('内核状态')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Blank()
          Text(this.kernelVersion)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .width('100%')
        .padding({ top: 14, bottom: 14, left: 16, right: 16 })

        Divider()
          .color($r('sys.color.comp_divider'))
          .margin({ left: 16 })

        Column({ space: 6 }) {
          Text('开源组件')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .width('100%')
          Text('mihomo (Clash.Meta) — GPL-3.0\ngVisor (netstack) — Apache-2.0\nsing-tun — MIT')
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
            .lineHeight(18)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(16)
      }
      .width('100%')
      .backgroundColor($r('app.color.glass_row'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.glass_border') })

      Text('仅供学习交流。侧载分发，不上架。')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
        .padding({ left: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
