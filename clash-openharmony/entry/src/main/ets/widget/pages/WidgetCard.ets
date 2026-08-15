/*
 * WidgetCard.ets - 鸿蒙服务卡片（2*2）动态开关（QUICK_ACCESS_DESIGN.md §2.1/§2.2）
 * FormBindingData 的 statusText/isOn 由卡片框架注入 @Entry(storage) 的 LocalStorage，
 * 页面经 @LocalStorageProp 响应式渲染；整卡点击 postCardAction('call') 后台拉起 EntryAbility
 * 并调用其 callee 注册的 'toggleVpn' 方法（不开 UI，见 QUICK_ACCESS_DESIGN.md v1.1 问题 2）。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct WidgetCard {
  @LocalStorageProp('statusText') statusText: string = '未连接 · 点按连接';
  @LocalStorageProp('isOn') isOn: boolean = false;
  @LocalStorageProp('formId') formId: string = '';

  /** 状态圆点颜色：已连接 #17A05E（delay_good），未连接系统三级字色 */
  private dotColor(): ResourceColor {
    return this.isOn ? '#17A05E' : $r('sys.color.font_tertiary');
  }

  build() {
    Column({ space: 4 }) {
      Circle()
        .width(8)
        .height(8)
        .fill(this.dotColor())
      Text('ClashOH')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('sys.color.font_primary'))
      Text(this.statusText)
        .fontSize(12)
        .fontColor($r('sys.color.font_secondary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .borderRadius(20)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .onClick(() => {
      // call 事件：params.method 指定 callee 方法，params.formId 为系统注入的卡片标识（官方模式，
      // 被拉起的 Ability 用它即时更新本卡片状态）
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: { method: 'toggleVpn', formId: this.formId }
      });
    })
  }
}
