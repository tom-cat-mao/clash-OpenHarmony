/*
 * SettingsPage.ets - 设置页（DESIGN.md §5 右）
 * 分组卡片列表（运行/连接/自动化/诊断/关于，每组带标题）
 * 二级页导航（Navigation pushPath）+ Toggle（保活/自动恢复/订阅自动更新/内核日志落盘）
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { Settings, AppSettings } from '../lib/Settings';
import { LiveViewKeeper } from '../lib/LiveViewKeeper';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { AutoUpdater } from '../lib/AutoUpdater';
import { tabBarSafePad } from '../lib/H7';

/** 订阅自动更新可选间隔（小时） */
const INTERVAL_OPTIONS: number[] = [12, 24, 48, 72];

class SettingRow {
  title: string = '';
  sub: string = '';
  hasToggle: boolean = false;
  dest: string = '';
  action: string = '';
  /** 开关绑定：'keepAlive' | 'autoUpdate' | 'autoRestore' | 'logToFile' */
  toggleKey: string = '';
}

class SettingGroup {
  /** 分组标题（卡片上方 caption） */
  title: string = '';
  rows: SettingRow[] = [];
}

@Component
export struct SettingsPage {
  @Consume('nav') navStack: NavPathStack;
  @State keepAlive: boolean = false;
  @State autoUpdate: boolean = false;
  @State autoRestore: boolean = false;
  @State autoUpdateIntervalHours: number = 24;
  @State logToFile: boolean = true;

  private groups: SettingGroup[] = [
    {
      title: '运行',
      rows: [
        { title: '打开应用自动恢复', sub: '冷启动时自动恢复上次 VPN 会话', hasToggle: true, dest: '', action: '', toggleKey: 'autoRestore' },
        { title: '后台运行', sub: '关窗后保持内核存活（状态栏实况窗常驻）', hasToggle: true, dest: '', action: '', toggleKey: 'keepAlive' }
      ]
    },
    {
      title: '连接',
      rows: [
        { title: '网络设置', sub: '按应用分流 · IPv6', hasToggle: false, dest: 'network', action: '', toggleKey: '' },
        { title: '覆写', sub: '端口 · 日志等级 · 局域网', hasToggle: false, dest: 'override', action: '', toggleKey: '' }
      ]
    },
    {
      title: '自动化',
      rows: [
        { title: '自动更新订阅', sub: '内核运行期间按周期拉取激活订阅来源', hasToggle: true, dest: '', action: '', toggleKey: 'autoUpdate' },
        { title: '更新间隔', sub: '自动更新订阅的检查周期', hasToggle: false, dest: '', action: 'interval', toggleKey: '' }
      ]
    },
    {
      title: '诊断',
      rows: [
        { title: '连接', sub: '活跃连接查看与关闭', hasToggle: false, dest: 'connections', action: '', toggleKey: '' },
        { title: '日志', sub: '内核日志 · 等级过滤', hasToggle: false, dest: 'logs', action: '', toggleKey: '' },
        { title: '记录内核日志到文件', sub: '关闭后内核日志仅写入系统 hilog，不再占用应用存储（下次启动内核生效）', hasToggle: true, dest: '', action: '', toggleKey: 'logToFile' },
        { title: 'GeoX 数据', sub: '更新 geoip / geosite 数据库', hasToggle: false, dest: 'geo', action: '', toggleKey: '' }
      ]
    },
    {
      title: '关于',
      rows: [
        { title: '关于', sub: '版本 · 开源许可', hasToggle: false, dest: 'about', action: '', toggleKey: '' }
      ]
    }
  ];

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const s: AppSettings = Settings.load(context);
    this.keepAlive = s.keepAlive;
    this.autoUpdate = s.autoUpdate;
    this.autoRestore = s.autoRestore;
    this.autoUpdateIntervalHours = s.autoUpdateIntervalHours;
    this.logToFile = s.logToFile;
  }

  private async onKeepAliveChange(on: boolean): Promise<void> {
    this.keepAlive = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.keepAlive = on;
    Settings.save(context, s);
    if (on && VpnController.status === VpnStatus.Connected) {
      const ok = await LiveViewKeeper.start(context);
      promptAction.showToast({ message: ok ? '已开启后台运行' : '授权失败，无法开启', duration: 1500 });
    } else if (!on) {
      await LiveViewKeeper.stop(context);
    }
  }

  private async onAutoUpdateChange(on: boolean): Promise<void> {
    this.autoUpdate = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.autoUpdate = on;
    Settings.save(context, s);
    if (on) {
      promptAction.showToast({ message: '已开启', duration: 1500 });
      // 立即补一轮检查（内核未运行/间隔未到时内部自动跳过）
      AutoUpdater.checkAndRun(context).catch(() => {
        // fire-and-forget：忽略单轮失败
      });
    }
  }

  private onIntervalTap(): void {
    const sheets: SheetInfo[] = [];
    for (const h of INTERVAL_OPTIONS) {
      sheets.push({
        title: `${h} 小时`,
        action: () => {
          this.autoUpdateIntervalHours = h;
          const context = getContext(this) as common.UIAbilityContext;
          const s = Settings.load(context);
          s.autoUpdateIntervalHours = h;
          Settings.save(context, s);
        }
      });
    }
    ActionSheet.show({
      title: '更新间隔',
      message: '自动更新订阅的检查周期',
      sheets: sheets
    });
  }

  private toggleValue(row: SettingRow): boolean {
    if (row.toggleKey === 'autoUpdate') {
      return this.autoUpdate;
    }
    if (row.toggleKey === 'autoRestore') {
      return this.autoRestore;
    }
    if (row.toggleKey === 'logToFile') {
      return this.logToFile;
    }
    return this.keepAlive;
  }

  private onToggleChange(row: SettingRow, on: boolean): void {
    if (row.toggleKey === 'autoUpdate') {
      this.onAutoUpdateChange(on);
    } else if (row.toggleKey === 'autoRestore') {
      this.onAutoRestoreChange(on);
    } else if (row.toggleKey === 'logToFile') {
      this.onLogToFileChange(on);
    } else {
      this.onKeepAliveChange(on);
    }
  }

  private onAutoRestoreChange(on: boolean): void {
    this.autoRestore = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.autoRestore = on;
    Settings.save(context, s);
  }

  private onLogToFileChange(on: boolean): void {
    this.logToFile = on;
    const context = getContext(this) as common.UIAbilityContext;
    const s = Settings.load(context);
    s.logToFile = on;
    Settings.save(context, s);
    promptAction.showToast({ message: '下次启动内核生效', duration: 1500 });
  }

  private onRowTap(row: SettingRow): void {
    if (row.dest.length > 0) {
      this.navStack.pushPath({ name: row.dest });
      return;
    }
    if (row.action === 'interval') {
      this.onIntervalTap();
    }
  }

  @Builder
  RowItem(row: SettingRow) {
    Row() {
      Column({ space: 4 }) {
        Text(row.title)
          .fontSize(15)
          .fontColor($r('sys.color.font_primary'))
        if (row.sub.length > 0) {
          Text(row.sub)
            .fontSize(12)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (row.hasToggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.toggleValue(row) })
          .onChange((isOn: boolean) => {
            this.onToggleChange(row, isOn);
          })
      } else {
        if (row.action === 'interval') {
          Text(`${this.autoUpdateIntervalHours} 小时`)
            .fontSize(13)
            .fontColor($r('sys.color.font_secondary'))
            .margin({ right: 4 })
        }
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([$r('sys.color.font_tertiary')])
      }
    }
    .width('100%')
    .padding({ top: 13, bottom: 13, left: 14, right: 14 })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick(() => {
      if (!row.hasToggle) {
        this.onRowTap(row);
      }
    })
  }

  @Builder
  GroupCard(group: SettingGroup) {
    Column() {
      ForEach(group.rows, (row: SettingRow, index: number) => {
        Column() {
          this.RowItem(row)
          if (index < group.rows.length - 1) {
            Divider()
              .color($r('sys.color.comp_divider'))
              .margin({ left: 14 })
          }
        }
      }, (row: SettingRow) => row.title)
    }
    .width('100%')
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('设置')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
      }
      .width('100%')
      .height(40)
      .alignItems(VerticalAlign.Center)
      .margin({ top: 8, bottom: 4 })

      List({ space: 12 }) {
        ForEach(this.groups, (group: SettingGroup) => {
          ListItem() {
            Column({ space: 7 }) {
              Text(group.title)
                .fontSize(13)
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
                .margin({ left: 4 })
              this.GroupCard(group)
            }
          }
        }, (group: SettingGroup) => group.title)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 鸿蒙7：悬浮底栏遮挡避让
      .contentEndOffset(tabBarSafePad())
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
