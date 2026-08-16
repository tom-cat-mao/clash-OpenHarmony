/*
 * NetworkSettingsPage.ets - 网络设置（设置 → 网络设置）
 * IPv6 / 按应用分流（模式 + 手动名单）。改动在下次 VPN 启动时生效。
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings } from '../lib/Settings';
import { H7, sheetOptions } from '../lib/H7';

const ACCESS_MODES: string[] = ['全部应用', '仅选中应用', '排除选中应用'];
const ACCESS_VALUES: string[] = ['all', 'white', 'black'];

@Component
export struct NetworkSettingsPage {
  @State ipv6: boolean = false;
  @State accessIndex: number = 0;
  @State accessList: string[] = [];
  @State inputPkg: string = '';
  @State showAddDialog: boolean = false;

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    this.ipv6 = s.ipv6;
    this.accessList = s.accessList;
    const idx = ACCESS_VALUES.indexOf(s.accessMode);
    this.accessIndex = idx >= 0 ? idx : 0;
  }

  private persist(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.ipv6 = this.ipv6;
    s.accessMode = ACCESS_VALUES[this.accessIndex];
    s.accessList = this.accessList;
    Settings.save(context, s);
  }

  private changedHint(): void {
    promptAction.showToast({ message: '已保存，下次启动 VPN 生效', duration: 1500 });
  }

  @Builder
  ToggleRow(title: string, sub: string, isOn: boolean, onFlip: (v: boolean) => void) {
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
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .onChange((v: boolean) => onFlip(v))
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
  }

  @Builder
  AddPkgDialog() {
    Column({ space: 14 }) {
      Text('添加应用包名')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      TextInput({ placeholder: '如 com.example.app' })
        .width('100%')
        .onChange((v: string) => {
          this.inputPkg = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.showAddDialog = false;
          })
        Button('添加')
          .layoutWeight(1)
          .onClick(() => {
            const pkg = this.inputPkg.trim();
            if (pkg.length > 0 && this.accessList.indexOf(pkg) < 0) {
              this.accessList = [...this.accessList, pkg];
              this.persist();
              this.changedHint();
            }
            this.inputPkg = '';
            this.showAddDialog = false;
          })
      }
      .width('100%')
    }
    .padding(20)
    // 鸿蒙7：sheet 内容根容器透明，露出底层 ULTRA_THICK 系统材质
    .backgroundColor(H7 ? Color.Transparent : $r('sys.color.comp_background_primary'))
    .borderRadius(H7 ? 0 : 16)
  }

  build() {
    Column({ space: 12 }) {
      Column() {
        this.ToggleRow('IPv6', '接管 IPv6 流量（网络不支持时保持关闭）', this.ipv6, (v: boolean) => {
          this.ipv6 = v;
          this.persist();
          this.changedHint();
        })
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(16)

      Column({ space: 0 }) {
        Row() {
          Text('按应用分流')
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
          Blank()
        }
        .width('100%')
        .padding({ top: 13, bottom: 6, left: 14, right: 14 })

        Row({ space: 0 }) {
          ForEach(ACCESS_MODES, (label: string, index: number) => {
            Text(label)
              .fontSize(12)
              .fontWeight(this.accessIndex === index ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.accessIndex === index ? Color.White : $r('sys.color.font_secondary'))
              .backgroundColor(this.accessIndex === index ? $r('sys.color.brand') : Color.Transparent)
              .borderRadius(14)
              .padding({ top: 6, bottom: 6, left: 14, right: 14 })
              .stateStyles({
                pressed: { .opacity(0.6) },
                normal: { .opacity(1.0) }
              })
              .onClick(() => {
                this.accessIndex = index;
                this.persist();
                this.changedHint();
              })
          }, (label: string) => label)
        }
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius(16)
        .padding(2)
        .margin({ left: 14, right: 14, bottom: 8 })

        if (this.accessIndex > 0) {
          ForEach(this.accessList, (pkg: string) => {
            Row() {
              Text(pkg)
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .fontColor($r('sys.color.font_primary'))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
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
              .onClick(() => {
                this.accessList = this.accessList.filter((x) => x !== pkg);
                this.persist();
              })
            }
            .width('100%')
            .padding({ top: 2, bottom: 2, left: 14, right: 6 })
          }, (pkg: string) => pkg)

          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.plus'))
              .fontSize(14)
              .fontColor([$r('sys.color.brand')])
            Text('添加包名')
              .fontSize(14)
              .fontColor($r('sys.color.brand'))
          }
          .width('100%')
          .padding({ top: 10, bottom: 14, left: 14, right: 14 })
          .stateStyles({
            pressed: { .opacity(0.6) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.showAddDialog = true;
          })
        }
      }
      .width('100%')
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(16)

      Text('鸿蒙不允许普通应用枚举已安装列表，故按应用分流使用手动包名名单。本应用自身始终直连。')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
        .padding({ left: 4 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor($r('sys.color.background_secondary'))
    .bindSheet($$this.showAddDialog, this.AddPkgDialog(), sheetOptions())
  }
}
