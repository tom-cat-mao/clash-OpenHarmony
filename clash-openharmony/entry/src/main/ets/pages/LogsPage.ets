/*
 * LogsPage.ets - 内核日志（设置 → 日志）
 * WebSocket /logs?level=debug 订阅全量，本地按等级过滤；暂停/清空
 */
import { CoreApi, LogMsg } from '../lib/CoreApi';

class LogLine {
  level: string = '';
  payload: string = '';
  time: string = '';
}

const LEVELS: string[] = ['全部', 'debug', 'info', 'warning', 'error'];
const MAX_LINES = 500;

@Component
export struct LogsPage {
  @State lines: LogLine[] = [];
  @State filterIndex: number = 0;
  @State paused: boolean = false;
  private buffer: LogLine[] = [];
  private watcher: CoreApi.StreamWatcher<LogMsg> = new CoreApi.StreamWatcher<LogMsg>();
  private scroller: Scroller = new Scroller();

  aboutToAppear(): void {
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
    });
  }

  aboutToDisappear(): void {
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
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(12)
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16, top: 8 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
