/*
 * ProxyGroupPage.ets - 分组详情页（两级导航第二级）
 * 节点网格点选（选中后自动返回）；搜索/排序/长按详情；子组卡片；自动组只读
 */
import { CoreApi } from '../lib/CoreApi';
import { promptAction } from '@kit.ArkUI';
import { Logger } from '../lib/Logger';

const TAG = 'proxyGroup';
const TEST_URL = 'https://www.gstatic.com/generate_204';
const TEST_TIMEOUT = 3000;
const GROUP_TYPES: string[] = ['Selector', 'URLTest', 'Fallback', 'LoadBalance'];

/** 页面间传参总线：列表页 push 前写入，详情页 aboutToAppear 读取 */
export class ProxyGroupBus {
  static current: string = '';
}

/** 选择事件总线：详情页选中后回调列表页刷新（跨 Navigation 边界不走 Provide/Consume） */
export class ProxyEvents {
  static onSelected: () => void = () => {};
}

class NodeView {
  name: string = '';
  type: string = '';
  delay: number = 0; // 0=未测, -1=超时
  selected: boolean = false;
  isGroup: boolean = false;
  groupNow: string = ''; // 子组当前选中项
}

@Component
export struct ProxyGroupPage {
  @Consume('nav') navStack: NavPathStack;
  @State groupType: string = '';
  @State now: string = '';
  @State nodes: NodeView[] = [];
  @State testing: boolean = false;
  @State loadFailed: boolean = false;
  @State keyword: string = '';
  @State sortMode: number = 0; // 0=按名称, 1=按延迟升序
  @State cols: number = 2; // 宽屏(>=600vp) 3 列
  @State detailShow: boolean = false;
  @State detailLoading: boolean = false;
  @State detailName: string = '';
  @State detailType: string = '';
  @State detailUdp: boolean = false;
  @State detailDelay: number = 0;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    const proxies = await CoreApi.getProxies();
    if (!proxies) {
      this.loadFailed = true;
      return;
    }
    const g = proxies[ProxyGroupBus.current];
    if (!g) {
      this.loadFailed = true;
      return;
    }
    this.loadFailed = false;
    this.groupType = g.type;
    this.now = g.now;
    const list: NodeView[] = [];
    if (g.all) {
      for (const childName of g.all) {
        const child = proxies[childName];
        const nv = new NodeView();
        nv.name = childName;
        nv.type = child ? child.type : '';
        nv.isGroup = child ? GROUP_TYPES.indexOf(child.type) >= 0 : false;
        nv.selected = childName === g.now;
        if (nv.isGroup && child) {
          nv.groupNow = child.now;
        }
        if (child && child.history && child.history.length > 0) {
          const d = child.history[child.history.length - 1].delay;
          nv.delay = d > 0 ? d : -1;
        }
        list.push(nv);
      }
    }
    this.nodes = list;
  }

  private typeLabel(): string {
    if (this.groupType === 'Selector') {
      return '手动选择';
    }
    if (this.groupType === 'URLTest') {
      return '自动测速';
    }
    if (this.groupType === 'Fallback') {
      return '自动回退';
    }
    if (this.groupType === 'LoadBalance') {
      return '负载均衡';
    }
    return this.groupType;
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

  private delayText(d: number): string {
    if (d < 0) {
      return '超时';
    }
    if (d === 0) {
      return '未测';
    }
    return d + 'ms';
  }

  /** 过滤 + 排序后的可见节点（build 中调用，随 @State 变化重算） */
  private visibleNodes(): NodeView[] {
    let list = this.nodes;
    const kw = this.keyword.trim().toLowerCase();
    if (kw.length > 0) {
      list = list.filter((n: NodeView): boolean => n.name.toLowerCase().includes(kw));
    }
    if (this.sortMode === 1) {
      const w = (n: NodeView): number => n.delay > 0 ? n.delay : 999999;
      list = [...list].sort((a: NodeView, b: NodeView): number => w(a) - w(b));
    }
    return list;
  }

  private onNodeTap(node: NodeView): void {
    // 子组与普通节点一视同仁：点按 = 选为本组出口并返回（进入子组的入口在第一级组列表）
    if (this.groupType !== 'Selector') {
      promptAction.showToast({ message: '该分组为自动选择，不支持手动切换', duration: 1800 });
      return;
    }
    if (node.selected) {
      this.navStack.pop();
      return;
    }
    CoreApi.selectProxy(ProxyGroupBus.current, node.name).then((ok: boolean) => {
      if (ok) {
        Logger.info(TAG, ProxyGroupBus.current + ' -> ' + node.name);
        ProxyEvents.onSelected();
        this.navStack.pop();
      } else {
        promptAction.showToast({ message: '切换失败', duration: 1500 });
      }
    });
  }

  private openDetail(node: NodeView): void {
    this.detailName = node.name;
    this.detailType = node.type;
    this.detailUdp = false;
    this.detailDelay = node.delay;
    this.detailLoading = true;
    this.detailShow = true;
    CoreApi.getProxyDetail(node.name).then((p) => {
      if (p) {
        this.detailType = p.type;
        this.detailUdp = p.udp;
        if (p.history && p.history.length > 0) {
          const d = p.history[p.history.length - 1].delay;
          if (d > 0) {
            this.detailDelay = d;
          }
        }
      }
      this.detailLoading = false;
    });
  }

  private async testGroup(): Promise<void> {
    if (this.testing) {
      return;
    }
    this.testing = true;
    try {
      const result = await CoreApi.groupDelayTest(ProxyGroupBus.current, TEST_URL, TEST_TIMEOUT);
      if (result) {
        for (const node of this.nodes) {
          if (node.isGroup) {
            continue;
          }
          const d = result[node.name];
          node.delay = d !== undefined && d > 0 ? d : -1;
        }
        this.nodes = [...this.nodes];
      }
    } finally {
      this.testing = false;
    }
  }

  @Builder
  DetailRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor($r('sys.color.font_secondary'))
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: '70%' })
    }
    .width('100%')
  }

  @Builder
  NodeDetailSheet() {
    Column({ space: 12 }) {
      Text(this.detailName)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
      if (this.detailLoading) {
        LoadingProgress()
          .width(28)
          .height(28)
          .margin({ top: 6, bottom: 6 })
      } else {
        this.DetailRow('类型', this.detailType.length > 0 ? this.detailType : '未知')
        this.DetailRow('UDP', this.detailUdp ? '支持' : '不支持')
        this.DetailRow('最近延迟', this.delayText(this.detailDelay))
      }
      Text('长按节点卡片可查看详情')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(20)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text(this.typeLabel() + ' · ' + this.nodes.length + ' 节点')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
        Blank()
        if (this.testing) {
          LoadingProgress()
            .width(16)
            .height(16)
            .margin({ right: 8 })
        } else {
          SymbolGlyph($r('sys.symbol.bolt'))
            .fontSize(16)
            .fontColor([$r('sys.color.brand')])
            .margin({ right: 4 })
        }
        Text('测速')
          .fontSize(14)
          .fontColor(this.testing ? $r('sys.color.font_tertiary') : $r('sys.color.brand'))
          .padding(8)
          .stateStyles({
            pressed: { .opacity(0.6) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.testGroup();
          })
        Row({ space: 4 }) {
          SymbolGlyph($r('sys.symbol.sort'))
            .fontSize(16)
            .fontColor([$r('sys.color.brand')])
          Text(this.sortMode === 0 ? '名称' : '延迟')
            .fontSize(13)
            .fontColor($r('sys.color.brand'))
        }
        .padding({ top: 8, bottom: 8, left: 10, right: 10 })
        .stateStyles({
          pressed: { .opacity(0.6) },
          normal: { .opacity(1.0) }
        })
        .onClick(() => {
          this.sortMode = this.sortMode === 0 ? 1 : 0;
        })
      }
      .width('100%')

      Search({ value: $$this.keyword, placeholder: '搜索节点' })
        .width('100%')
        .height(40)

      if (this.loadFailed) {
        Text('分组信息加载失败，请返回重试')
          .fontSize(14)
          .fontColor($r('sys.color.font_secondary'))
          .margin({ top: 60 })
      } else {
        Grid() {
          ForEach(this.visibleNodes(), (node: NodeView) => {
            GridItem() {
              Column({ space: 4 }) {
                Row({ space: 4 }) {
                  if (node.isGroup) {
                    SymbolGlyph($r('sys.symbol.folder'))
                      .fontSize(12)
                      .fontColor([$r('sys.color.brand')])
                  }
                  Text(node.name)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_primary'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                }
                .width('100%')
                Text(node.isGroup ? '当前: ' + node.groupNow : this.delayText(node.delay))
                  .fontSize(11)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(node.isGroup ? $r('sys.color.brand') : this.delayColor(node.delay))
              }
              .alignItems(HorizontalAlign.Start)
              .padding(10)
              .width('100%')
              .backgroundColor(node.selected ? $r('sys.color.comp_background_secondary') : $r('sys.color.comp_background_primary'))
              .borderRadius(12)
              .border({
                width: node.selected ? 1.5 : 0,
                color: node.selected ? $r('sys.color.brand') : Color.Transparent
              })
              .stateStyles({
                pressed: { .opacity(0.6) },
                normal: { .opacity(1.0) }
              })
              .onClick(() => {
                this.onNodeTap(node);
              })
              .gesture(LongPressGesture().onAction(() => {
                this.openDetail(node);
              }))
            }
          }, (node: NodeView) => node.name + '|' + node.delay + '|' + node.selected)
        }
        .columnsTemplate(this.cols === 3 ? '1fr 1fr 1fr' : '1fr 1fr')
        .columnsGap(8)
        .rowsGap(8)
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
    .onSizeChange((_o: SizeOptions, n: SizeOptions) => {
      this.cols = Number(n.width) >= 600 ? 3 : 2;
    })
    .bindSheet($$this.detailShow, this.NodeDetailSheet(), { height: SheetSize.MEDIUM })
  }
}
