/*
 * LogsPage.ets - 内核日志（设置 → 日志）
 * WebSocket /logs?level=debug 订阅全量，本地按等级过滤；暂停/清空。
 * 注意：mihomo /logs 是纯实时流（无历史回放），且内核 log-level=info 只在连接级事件
 * （[TCP] x --> y match RULE using CHAIN）产生日志——页面因此提供两档空态提示：
 * 内核未运行（无流可订）/ 已运行暂无日志（空闲无流量）。
 * 视觉：H7 沉浸光感 — 日志容器玻璃行配方 + 空态图标化 + 顶部品牌弥散光
 */
import { CoreApi, LogMsg } from '../lib/CoreApi';
import { VpnController, VpnStatus } from '../lib/VpnController';

class LogLine {
  level: string = '';
  payload: string = '';
  time: string = '';
}

const LEVELS: string[] = ['全部', 'debug', 'info', 'warning', 'error'];
const MAX_LINES = 500;
/** 模块级监听门闩：NavDestination 每次导航新建页面实例，避免重复注册 onChanged（参考 EntryAbility） */
let statusListenerRegistered: boolean = false;
/** 当前活跃页面实例：回调只写存活实例，避免捕获已销毁组件 */
let activeLogsPage: LogsPage | null = null;

@Component
export struct LogsPage {
  @State lines: LogLine[] = [];
  @State filterIndex: number = 0;
  @State paused: boolean = false;
  @State vpnConnected: boolean = VpnController.status === VpnStatus.Connected;
  private buffer: LogLine[] = [];
  private watcher: CoreApi.StreamWatcher<LogMsg> = new CoreApi.StreamWatcher<LogMsg>();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
    this.vpnConnected = VpnController.status === VpnStatus.Connected;
    activeLogsPage = this;
    if (!statusListenerRegistered) {
      statusListenerRegistered = true;
      VpnController.onChanged((s: VpnStatus) => {
        const page = activeLogsPage;
        if (page !== null) {
          page.vpnConnected = s === VpnStatus.Connected;
        }
      });
    }
    this.watcher.start('/logs?level=debug', (msg: LogMsg) => {
      if (this.paused) {
        return;
      }
      const line = new LogLine();
      line.level = msg.type;
      line.payload = msg.payload;
      line.time = new Date().toLocaleTimeString();
      this.buffer.push(line);
      if (this.buffer.length > MAX_LINES) {
        this.buffer.splice(0, this.buffer.length - MAX_LINES);
      }
      this.applyFilter();
      // 新日志自动滚到底部（实时流语义；暂停时不打扰用户当前位置）
      this.scroller.scrollEdge(Edge.Bottom);
    });
  }

  aboutToDisappear(): void {
    if (activeLogsPage === this) {
      activeLogsPage = null;
    }
    this.watcher.stop();
  }

  private applyFilter(): void {
    const f = LEVELS[this.filterIndex];
    if (f === '全部') {
      this.lines = [...this.buffer];
    } else {
      this.lines = this.buffer.filter((l) => l.level === f);
    }
  }

  private levelColor(level: string): ResourceColor {
    switch (level) {
      case 'error':
        return $r('sys.color.alert');
      case 'warning':
      case 'warn':
        return $r('sys.color.warning');
      case 'debug':
        return $r('sys.color.font_tertiary');
      default:
        return $r('sys.color.font_secondary');
    }
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      Column({ space: 10 }) {
        Row({ space: 8 }) {
          ForEach(LEVELS, (lv: string, index: number) => {
            Text(lv)
              .fontSize(12)
              .fontWeight(this.filterIndex === index ? FontWeight.Medium : FontWeight.Regular)
              .fontColor(this.filterIndex === index ? Color.White : $r('sys.color.font_secondary'))
              .backgroundColor(this.filterIndex === index ? $r('sys.color.brand') : $r('sys.color.comp_background_secondary'))
              .borderRadius(8)
              .padding({ top: 4, bottom: 4, left: 10, right: 10 })
              .stateStyles({
                pressed: { .opacity(0.6) },
                normal: { .opacity(1.0) }
              })
              .onClick(() => {
                this.filterIndex = index;
                this.applyFilter();
              })
          }, (lv: string) => lv)
          Blank()
          Text(this.paused ? '继续' : '暂停')
            .fontSize(13)
            .fontColor($r('sys.color.brand'))
            .padding({ top: 6, bottom: 6, left: 4, right: 4 })
            .stateStyles({
              pressed: { .opacity(0.6) },
              normal: { .opacity(1.0) }
            })
            .onClick(() => {
              this.paused = !this.paused;
            })
          Text('清空')
            .fontSize(13)
            .fontColor($r('sys.color.brand'))
            .padding({ top: 6, bottom: 6, left: 4, right: 4 })
            .stateStyles({
              pressed: { .opacity(0.6) },
              normal: { .opacity(1.0) }
            })
            .onClick(() => {
              this.buffer = [];
              this.lines = [];
            })
        }
        .width('100%')

        if (!this.vpnConnected) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.bolt'))
              .fontSize(36)
              .fontColor([$r('sys.color.font_tertiary')])
            Text('内核未运行')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
            Text('日志是实时流：启动内核并产生流量后，这里会显示连接级内核日志（如 [TCP] 域名 --> 节点 match 规则）')
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .margin({ top: 64 })
        } else if (this.lines.length === 0) {
          Column({ space: 12 }) {
            SymbolGlyph($r('sys.symbol.doc_plaintext'))
              .fontSize(36)
              .fontColor([$r('sys.color.font_tertiary')])
            Text('暂无日志')
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('sys.color.font_secondary'))
            Text('内核已运行，空闲时没有日志产生；去刷刷网页/应用，新连接日志会实时出现在这里')
              .fontSize(13)
              .fontColor($r('sys.color.font_tertiary'))
              .textAlign(TextAlign.Center)
          }
          .width('100%')
          .margin({ top: 64 })
        } else {
          List({ space: 0, scroller: this.scroller }) {
            ForEach(this.lines, (l: LogLine, index: number) => {
              ListItem() {
                Column({ space: 2 }) {
                  Row({ space: 8 }) {
                    Text(l.level)
                      .fontSize(12)
                      .fontColor(this.levelColor(l.level))
                    Text(l.time)
                      .fontSize(11)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                  .alignItems(VerticalAlign.Center)
                  Text(l.payload)
                    .fontSize(11)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(3)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                }
                .alignItems(HorizontalAlign.Start)
                .width('100%')
                .padding({ top: 6, bottom: 6, left: 12, right: 12 })
              }
            }, (l: LogLine, index: number) => `${index}_${l.time}_${l.level}`)
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .backgroundColor($r('app.color.glass_row'))
          .borderRadius(16)
          .border({ width: 1, color: $r('app.color.glass_border') })
        }
      }
      .width('100%')
      .height('100%')
      .padding({ left: 16, right: 16, top: 8 })
      // 顶部品牌弥散光：8% 主色自上而下弥散（H7_DESIGN §3），纯视觉叠加、不拦截触摸
      Column()
        .width('100%')
        .height(200)
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.glow_brand'), 1.0], [$r('app.color.glow_brand'), 0.0]]
        })
        .position({ x: 0, y: 0 })
        .hitTestBehavior(HitTestMode.Transparent)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
