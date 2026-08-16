/*
 * OverridePage.ets - 覆写（设置 → 覆写）
 * 合并进内核配置的本地覆写项，下次 VPN 启动生效
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings } from '../lib/Settings';

const LOG_LEVELS: string[] = ['silent', 'error', 'warning', 'info', 'debug'];

@Component
export struct OverridePage {
  @State mixedPort: string = '7890';
  @State logLevel: string = 'info';
  @State allowLan: boolean = true;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.mixedPort = String(s.mixedPort);
    this.logLevel = s.logLevel;
    this.allowLan = s.allowLan;
  }

  private persist(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    const port = Number(this.mixedPort);
    s.mixedPort = Number.isInteger(port) && port > 0 && port < 65536 ? port : 7890;
    s.logLevel = this.logLevel;
    s.allowLan = this.allowLan;
    Settings.save(context, s);
    promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
  }

  @Builder
  RowShell(title: string, sub: string) {
    Row() {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        if (sub.length > 0) {
          Text(sub)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 0 }) {
        Row() {
          Text('混合代理端口')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          TextInput({ text: this.mixedPort })
            .width(110)
            .height(36)
            .textAlign(TextAlign.End)
            .backgroundColor($r('sys.color.comp_background_secondary'))
            .borderRadius(8)
            .onChange((v: string) => {
              this.mixedPort = v;
            })
            .onBlur(() => this.persist())
        }
        .width('100%')
        .padding({ top: 8, bottom: 8, left: 14, right: 14 })

        Divider().color($r('sys.color.comp_divider')).margin({ left: 14 })

        Row() {
          Text('允许局域网连接')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.allowLan })
            .onChange((v: boolean) => {
              this.allowLan = v;
              this.persist();
            })
        }
        .width('100%')
        .padding({ top: 13, bottom: 13, left: 14, right: 14 })

        Divider().color($r('sys.color.comp_divider')).margin({ left: 14 })

        Column({ space: 8 }) {
          Text('日志等级')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
            .width('100%')
          Row({ space: 6 }) {
            ForEach(LOG_LEVELS, (lv: string) => {
              Text(lv)
                .fontSize(12)
                .fontWeight(this.logLevel === lv ? FontWeight.Medium : FontWeight.Regular)
                .fontColor(this.logLevel === lv ? Color.White : $r('sys.color.font_secondary'))
                .backgroundColor(this.logLevel === lv ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
                .borderRadius(8)
                .padding({ top: 4, bottom: 4, left: 12, right: 12 })
                .stateStyles({
                  pressed: { .opacity(0.6) },
                  normal: { .opacity(1.0) }
                })
                .onClick(() => {
                  this.logLevel = lv;
                  this.persist();
                })
            }, (lv: string) => lv)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ top: 13, bottom: 13, left: 14, right: 14 })
      }
      .width('100%')
      .backgroundColor($r('app.color.glass_row'))
      .borderRadius(16)
      .border({ width: 1, color: $r('app.color.glass_border') })

      Text('覆写项会在下次启动 VPN 时合并进内核配置；订阅配置自带的同名键以覆写为准。')
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
