/*
 * ProfileEditPage.ets - 配置编辑页（二级导航，路由名 'profileEdit'，NavDestination 标题 '编辑配置' 由集成注册）
 * 编辑当前配置文本；保存后立即生效（运行中热重载）；支持另存为新配置
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { ProfileStore } from '../lib/ProfileStore';
import { CoreApi } from '../lib/CoreApi';
import { Logger } from '../lib/Logger';

const TAG = 'profileEdit';

/** 页面间传参总线：列表页 push 前写入，编辑页 aboutToAppear 读取 */
export class ProfileEditBus {
  static current: string = '';
}

@Component
export struct ProfileEditPage {
  @Consume('nav') navStack: NavPathStack;
  @State text: string = '';
  @State dirty: boolean = false;
  @State loadFailed: boolean = false;
  @State showSaveAsSheet: boolean = false;
  @State saveAsInput: string = '';

  aboutToAppear(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, ProfileEditBus.current);
    if (content === null) {
      this.loadFailed = true;
      return;
    }
    this.loadFailed = false;
    this.text = content;
    this.dirty = false;
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private async save(): Promise<void> {
    if (this.loadFailed) {
      this.toast('配置文件读取失败，无法保存');
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    const file = ProfileEditBus.current;
    if (file.length === 0) {
      this.toast('目标配置不存在');
      return;
    }
    try {
      ProfileStore.updateProfileContent(context, file, this.text);
      this.dirty = false;
      this.toast('已保存');
      // 若编辑的是当前激活配置且内核运行中，热重载立即生效
      if (ProfileStore.getActiveFile(context) === file && await CoreApi.isAlive()) {
        const ok = await CoreApi.reloadConfig(ProfileStore.absPath(context, file));
        if (!ok) {
          this.toast('保存成功，热重载失败（重启 VPN 生效）');
        }
      }
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `save failed: ${msg}`);
      this.toast(`保存失败: ${msg}`);
    }
  }

  private saveAs(): void {
    const input = this.saveAsInput.trim();
    this.showSaveAsSheet = false;
    this.saveAsInput = '';
    if (input.length === 0) {
      this.toast('名称不能为空');
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const file = ProfileStore.importContent(context, input, this.text);
      this.toast(`已另存为 ${file}`);
    } catch (e) {
      this.toast(`另存失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  @Builder
  HeaderButton(symbol: Resource, color: ResourceColor, enabled: boolean, onTap: () => void) {
    SymbolGlyph(symbol)
      .fontSize(22)
      .fontColor([color])
      .padding(8)
      .enabled(enabled)
      .stateStyles({
        pressed: { .opacity(0.6) },
        normal: { .opacity(1.0) }
      })
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  SaveAsSheet() {
    Column({ space: 14 }) {
      Text('另存为新配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      TextInput({ placeholder: '新配置名称（自动补 .yaml）' })
        .width('100%')
        .onChange((v: string) => {
          this.saveAsInput = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.showSaveAsSheet = false;
            this.saveAsInput = '';
          })
        Button('保存副本')
          .layoutWeight(1)
          .onClick(() => {
            this.saveAs();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  build() {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 2 }) {
          Text(`编辑中：${ProfileEditBus.current}`)
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.dirty) {
            Text('未保存')
              .fontSize(12)
              .fontColor($r('sys.color.brand'))
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        this.HeaderButton($r('sys.symbol.doc_filled_on_doc'), $r('sys.color.font_secondary'), !this.loadFailed, () => {
          this.showSaveAsSheet = true;
        })
        this.HeaderButton($r('sys.symbol.checkmark'), $r('sys.color.brand'), !this.loadFailed, () => {
          this.save();
        })
      }
      .width('100%')
      .margin({ top: 8 })

      if (this.loadFailed) {
        Column({ space: 8 }) {
          Text('配置文件读取失败')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
          Text('文件可能已被删除，请返回配置页重试')
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        TextArea({ text: $$this.text })
          .width('100%')
          .layoutWeight(1)
          .fontSize(13)
          .fontFamily('HarmonyOS Sans Mono')
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(12)
          .padding(12)
          .onChange((v: string) => {
            this.dirty = true;
          })
      }

      Text('保存后立即生效（运行中热重载）')
        .fontSize(12)
        .fontColor($r('sys.color.font_tertiary'))
        .width('100%')
        .margin({ bottom: 8 })
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
    .bindSheet($$this.showSaveAsSheet, this.SaveAsSheet(), { height: SheetSize.MEDIUM })
  }
}
