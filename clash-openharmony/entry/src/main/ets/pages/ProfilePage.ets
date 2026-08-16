/*
 * ProfilePage.ets - 配置页（DESIGN.md §5 左）
 * Profile 列表（激活/更新/编辑/重命名/导出/删除）+ 订阅导入（URL/文件/剪贴板，入口在右上 ＋ 半屏菜单）
 * 激活=写入 active 标记；若内核运行中则 PUT /configs 热切换，无需重启 VPN
 */
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { promptAction } from '@kit.ArkUI';
import { pasteboard } from '@kit.BasicServicesKit';
import { ProfileStore, ProfileMeta, ProfileMetaExt } from '../lib/ProfileStore';
import { CoreApi } from '../lib/CoreApi';
import { Logger } from '../lib/Logger';
import { ProfileEditBus } from './ProfileEditPage';

const TAG = 'profile';

/** 半屏 sheet 内容切换 */
const SHEET_NONE = 0;
const SHEET_IMPORT = 1;
const SHEET_URL = 2;
const SHEET_RENAME = 3;

@Component
export struct ProfilePage {
  @Consume('nav') navStack: NavPathStack;
  @State profiles: ProfileMeta[] = [];
  @State metas: Record<string, ProfileMetaExt> = {};
  @State importing: boolean = false;
  @State updatingFile: string = '';
  @State refreshing: boolean = false;
  @State showSheet: boolean = false;
  @State sheetMode: number = SHEET_NONE;
  @State inputUrl: string = '';
  @State renameTarget: string = '';
  @State renameInput: string = '';

  aboutToAppear(): void {
    this.refresh();
  }

  private refresh(): void {
    const context = getContext(this) as common.UIAbilityContext;
    this.profiles = ProfileStore.list(context);
    this.metas = ProfileStore.getMeta(context);
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg, duration: 1800 });
  }

  private metaStamp(file: string): number {
    const m = this.metas[file];
    return m !== undefined ? m.updatedAt : 0;
  }

  private isUrlProfile(file: string): boolean {
    const context = getContext(this) as common.UIAbilityContext;
    return ProfileStore.getOrigin(context, file).length > 0;
  }

  /** 流量格式化：GB 一位小数，否则 MB 一位小数 */
  private fmtTraffic(bytes: number): string {
    if (bytes >= 1024 * 1024 * 1024) {
      return `${(bytes / 1024 / 1024 / 1024).toFixed(1)} GB`;
    }
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }

  private daysLeft(expire: number): number {
    return Math.max(0, Math.ceil((expire - Date.now() / 1000) / 86400));
  }

  private subText(p: ProfileMeta): string {
    const m = this.metas[p.file];
    if (m !== undefined && (m.sub.expire > 0 || m.sub.total > 0)) {
      const used = m.sub.upload + m.sub.download;
      if (m.sub.total > 0) {
        if (m.sub.expire > 0) {
          return `流量 ${this.fmtTraffic(used)}/${this.fmtTraffic(m.sub.total)} · 剩 ${this.daysLeft(m.sub.expire)} 天`;
        }
        return `流量 ${this.fmtTraffic(used)}/${this.fmtTraffic(m.sub.total)}`;
      }
      if (m.sub.expire > 0) {
        return `流量 ${this.fmtTraffic(used)} · 剩 ${this.daysLeft(m.sub.expire)} 天`;
      }
      return `流量 ${this.fmtTraffic(used)}`;
    }
    return `${(p.size / 1024).toFixed(1)} KB · ${new Date(p.mtime * 1000).toLocaleDateString()}`;
  }

  private async activate(p: ProfileMeta): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    ProfileStore.setActive(context, p.file);
    // 激活前触发一次读取：编码损坏的文件在此被修复并回写磁盘，
    // 保证热加载（PUT /configs 按路径读文件）拿到干净内容
    try {
      ProfileStore.getActiveContent(context);
    } catch (e) {
      Logger.warn(TAG, `activate precheck: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
    const alive = await CoreApi.isAlive();
    if (alive) {
      const ok = await CoreApi.reloadConfig(ProfileStore.absPath(context, p.file));
      this.toast(ok ? `已切换到「${p.name}」` : '热切换失败，重启 VPN 生效');
    } else {
      this.toast(`已激活「${p.name}」，启动 VPN 后生效`);
    }
    this.refresh();
  }

  private actions(p: ProfileMeta): void {
    const context = getContext(this) as common.UIAbilityContext;
    const hasOrigin = ProfileStore.getOrigin(context, p.file).length > 0;
    const sheets: SheetInfo[] = [
      {
        title: '编辑',
        action: () => {
          ProfileEditBus.current = p.file;
          this.navStack.pushPath({ name: 'profileEdit' });
        }
      },
      {
        title: '重命名',
        action: () => {
          this.renameTarget = p.file;
          this.renameInput = p.name;
          this.sheetMode = SHEET_RENAME;
          this.showSheet = true;
        }
      },
      {
        title: '导出',
        action: () => {
          this.exportProfile(p);
        }
      }
    ];
    if (hasOrigin) {
      sheets.push({
        title: '复制订阅 URL',
        action: () => {
          this.copyOrigin(context, p.file);
        }
      });
    }
    ActionSheet.show({
      title: p.name,
      message: hasOrigin ? '来源：URL 订阅' : '来源：本地导入',
      confirm: {
        value: '删除',
        action: () => {
          ProfileStore.deleteProfile(context, p.file);
          this.refresh();
          this.toast('已删除');
        }
      },
      sheets: sheets
    });
  }

  private async updateProfile(p: ProfileMeta): Promise<void> {
    if (this.updatingFile.length > 0) {
      return;
    }
    const context = getContext(this) as common.UIAbilityContext;
    this.updatingFile = p.file;
    try {
      await ProfileStore.updateFromOrigin(context, p.file);
      this.toast('已更新');
      if (p.active && await CoreApi.isAlive()) {
        await CoreApi.reloadConfig(ProfileStore.absPath(context, p.file));
      }
      this.refresh();
    } catch (e) {
      this.toast(`更新失败: ${(e as Error).message}`);
    } finally {
      this.updatingFile = '';
    }
  }

  private async copyOrigin(context: common.UIAbilityContext, file: string): Promise<void> {
    const origin = ProfileStore.getOrigin(context, file);
    if (origin.length === 0) {
      return;
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, origin);
      await pasteboard.getSystemPasteboard().setData(data);
      this.toast('订阅 URL 已复制');
    } catch (e) {
      Logger.warn(TAG, `copyOrigin: ${JSON.stringify(e)}`);
      this.toast('复制失败');
    }
  }

  private doRename(): void {
    const context = getContext(this) as common.UIAbilityContext;
    const target = this.renameTarget;
    const input = this.renameInput.trim();
    this.showSheet = false;
    this.sheetMode = SHEET_NONE;
    this.renameTarget = '';
    this.renameInput = '';
    if (target.length === 0 || input.length === 0) {
      return;
    }
    try {
      const renamed = ProfileStore.renameProfile(context, target, input);
      this.toast(`已重命名为 ${renamed.replace(/\.(yaml|yml)$/, '')}`);
      this.refresh();
    } catch (e) {
      this.toast(`重命名失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
  }

  private async exportProfile(p: ProfileMeta): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    const content = ProfileStore.getProfileContent(context, p.file);
    if (content === null) {
      this.toast('读取配置失败');
      return;
    }
    try {
      const docPicker = new picker.DocumentViewPicker(context);
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`${p.name}.yaml`];
      opt.fileSuffixChoices = ['YAML 配置|.yaml'];
      const uris = await docPicker.save(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
      fileIo.closeSync(f);
      this.toast('已导出');
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `export: ${msg}`);
      this.toast(`导出失败: ${msg}`);
    }
  }

  private async importUrl(): Promise<void> {
    const url = this.inputUrl.trim();
    if (url.length === 0) {
      return;
    }
    this.importing = true;
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const file = await ProfileStore.importFromUrl(context, url);
      this.toast(`已导入 ${file}`);
      this.showSheet = false;
      this.sheetMode = SHEET_NONE;
      this.inputUrl = '';
      this.refresh();
    } catch (e) {
      this.toast(`导入失败: ${(e as Error).message}`);
    } finally {
      this.importing = false;
    }
  }

  private async importFile(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    try {
      const docPicker = new picker.DocumentViewPicker(context);
      const uris = await docPicker.select({
        maxSelectNumber: 1,
        selectMode: picker.DocumentSelectMode.FILE,
        fileSuffixFilters: ['.yaml', '.yml']
      });
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      const f = fileIo.openSync(uri, fileIo.OpenMode.READ_ONLY);
      // 循环读完整文件（readSync 单次可能短读，也避免固定 2MB 上限截断大订阅）
      const chunks: Uint8Array[] = [];
      let total = 0;
      while (true) {
        const buf = new ArrayBuffer(1024 * 1024);
        const len = fileIo.readSync(f.fd, buf);
        if (len <= 0) {
          break;
        }
        chunks.push(new Uint8Array(buf.slice(0, len)));
        total += len;
        if (total > 32 * 1024 * 1024) {
          fileIo.closeSync(f);
          throw new Error('配置文件超过 32MB 上限');
        }
      }
      fileIo.closeSync(f);
      const merged = new Uint8Array(total);
      let off = 0;
      for (const c of chunks) {
        merged.set(c, off);
        off += c.length;
      }
      const content = util.TextDecoder.create('utf-8').decodeToString(merged);
      const seg = uri.split('/').pop() ?? `file_${Date.now()}`;
      const name = decodeURIComponent(seg).replace(/\.(yaml|yml)$/i, '');
      ProfileStore.importContent(context, name, content);
      this.toast(`已导入 ${name}`);
      this.refresh();
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `importFile: ${msg}`);
      this.toast(`导入失败: ${msg}`);
    }
  }

  private async importClipboard(): Promise<void> {
    const context = getContext(this) as common.UIAbilityContext;
    let text = '';
    try {
      const data = await pasteboard.getSystemPasteboard().getData();
      text = data.getPrimaryText().trim();
    } catch (e) {
      Logger.warn(TAG, `clipboard read failed: ${JSON.stringify(e)}`);
      // 普通应用无 READ_PASTEBOARD（system_basic 级权限），跨应用内容读不到：
      // 回退到 URL 导入表单，让用户手动粘贴
      this.toast('无法自动读取剪贴板，请手动粘贴链接');
      this.sheetMode = SHEET_URL;
      this.showSheet = true;
      return;
    }
    if (text.length === 0) {
      this.toast('剪贴板为空');
      return;
    }
    try {
      if (text.includes('proxies:') || text.includes('proxy-groups:') || text.includes('proxy-providers:')) {
        const name = `clipboard_${Date.now()}`;
        const file = ProfileStore.importContent(context, name, text);
        this.toast(`已导入 ${file}`);
      } else {
        const file = await ProfileStore.importFromUrl(context, text);
        this.toast(`已导入 ${file}`);
      }
      this.refresh();
    } catch (e) {
      this.toast(`导入失败: ${(e as Error).message}`);
    }
  }

  /** 下拉刷新：激活配置为 URL 源时重新下载并热重载 */
  private async onPullRefresh(): Promise<void> {
    this.refreshing = true;
    try {
      const context = getContext(this) as common.UIAbilityContext;
      const active = ProfileStore.getActiveFile(context);
      if (active.length > 0 && this.isUrlProfile(active)) {
        try {
          await ProfileStore.updateFromOrigin(context, active);
          if (await CoreApi.isAlive()) {
            await CoreApi.reloadConfig(ProfileStore.absPath(context, active));
          }
        } catch (e) {
          Logger.warn(TAG, `pull refresh update failed: ${(e as Error).message ?? JSON.stringify(e)}`);
          this.toast(`更新失败: ${(e as Error).message}`);
        }
      }
      this.refresh();
    } finally {
      this.refreshing = false;
    }
  }

  @Builder
  ProfileRow(p: ProfileMeta) {
    Row() {
      if (p.active) {
        SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
          .fontSize(20)
          .fontColor([$r('sys.color.brand')])
          .margin({ right: 6 })
      } else {
        Row()
          .width(20)
          .height(1)
          .margin({ right: 6 })
      }
      Column({ space: 4 }) {
        Text(p.name)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.subText(p))
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Row({ space: 4 }) {
        if (this.isUrlProfile(p.file)) {
          if (this.updatingFile === p.file) {
            LoadingProgress()
              .width(18)
              .height(18)
              .padding(8)
          } else {
            SymbolGlyph($r('sys.symbol.arrow_clockwise'))
              .fontSize(22)
              .fontColor([$r('sys.color.font_secondary')])
              .padding(8)
              .stateStyles({
                pressed: { .opacity(0.6) },
                normal: { .opacity(1.0) }
              })
              .onClick(() => {
                this.updateProfile(p);
              })
          }
        }
        SymbolGlyph($r('sys.symbol.ellipsis_circle'))
          .fontSize(22)
          .fontColor([$r('sys.color.font_secondary')])
          .padding(8)
          .stateStyles({
            pressed: { .opacity(0.6) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.actions(p);
          })
      }
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding({ top: 12, bottom: 12, left: 14, right: 14 })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick(() => {
      this.activate(p);
    })
  }

  @Builder
  ImportEntry(icon: Resource, label: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([$r('sys.color.font_secondary')])
      Text(label)
        .fontSize(15)
        .fontColor($r('sys.color.font_primary'))
        .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(16)
        .fontColor([$r('sys.color.font_tertiary')])
    }
    .width('100%')
    .padding({ top: 14, bottom: 14, left: 20, right: 20 })
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
      normal: { .backgroundColor(Color.Transparent) }
    })
    .onClick(() => {
      onTap();
    })
  }

  @Builder
  ImportMenuSheet() {
    Column({ space: 0 }) {
      Text('导入配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .width('100%')
        .padding({ top: 20, left: 20, right: 20, bottom: 8 })
      this.ImportEntry($r('sys.symbol.link'), '从 URL 导入', () => {
        this.sheetMode = SHEET_URL;
      })
      this.ImportEntry($r('sys.symbol.folder'), '从文件导入', () => {
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
        this.importFile();
      })
      this.ImportEntry($r('sys.symbol.text_clipboard'), '从剪贴板导入', () => {
        this.showSheet = false;
        this.sheetMode = SHEET_NONE;
        this.importClipboard();
      })
      Row()
        .height(16)
    }
    .width('100%')
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  @Builder
  UrlImportDialog() {
    Column({ space: 14 }) {
      Text('从 URL 导入订阅')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      TextInput({ placeholder: 'https://example.com/sub.yaml' })
        .width('100%')
        .onChange((v: string) => {
          this.inputUrl = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.showSheet = false;
            this.sheetMode = SHEET_NONE;
            this.inputUrl = '';
          })
        Button(this.importing ? '导入中…' : '导入')
          .layoutWeight(1)
          .enabled(!this.importing)
          .onClick(() => this.importUrl())
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  @Builder
  RenameSheet() {
    Column({ space: 14 }) {
      Text('重命名配置')
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
      TextInput({ placeholder: '新名称（自动补 .yaml）', text: this.renameInput })
        .width('100%')
        .onChange((v: string) => {
          this.renameInput = v;
        })
      Row({ space: 12 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor($r('sys.color.comp_background_tertiary'))
          .fontColor($r('sys.color.font_primary'))
          .onClick(() => {
            this.showSheet = false;
            this.sheetMode = SHEET_NONE;
            this.renameTarget = '';
            this.renameInput = '';
          })
        Button('确定')
          .layoutWeight(1)
          .onClick(() => {
            this.doRename();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(16)
  }

  @Builder
  MainSheet() {
    if (this.sheetMode === SHEET_IMPORT) {
      this.ImportMenuSheet()
    } else if (this.sheetMode === SHEET_URL) {
      this.UrlImportDialog()
    } else if (this.sheetMode === SHEET_RENAME) {
      this.RenameSheet()
    }
  }

  build() {
    Column({ space: 12 }) {
      Row() {
        Text('配置')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Blank()
        SymbolGlyph($r('sys.symbol.plus'))
          .fontSize(24)
          .fontColor([$r('sys.color.brand')])
          .padding(8)
          .stateStyles({
            pressed: { .opacity(0.6) },
            normal: { .opacity(1.0) }
          })
          .onClick(() => {
            this.sheetMode = SHEET_IMPORT;
            this.showSheet = true;
          })
      }
      .width('100%')
      .margin({ top: 8, bottom: 4 })

      if (this.profiles.length === 0) {
        Column({ space: 8 }) {
          Text('还没有配置')
            .fontSize(15)
            .fontColor($r('sys.color.font_secondary'))
          Text('点右上角按钮从 URL、文件或剪贴板导入 mihomo 配置')
            .fontSize(13)
            .fontColor($r('sys.color.font_tertiary'))
        }
        .width('100%')
        .margin({ top: 60 })
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          List({ space: 0 }) {
            ForEach(this.profiles, (p: ProfileMeta, index: number) => {
              ListItem() {
                Column() {
                  this.ProfileRow(p)
                  if (index < this.profiles.length - 1) {
                    Divider()
                      .color($r('sys.color.comp_divider'))
                      .margin({ left: 14 })
                  }
                }
              }
            }, (p: ProfileMeta) => p.file + '|' + (p.active ? '1' : '0') + '|' + this.metaStamp(p.file))
          }
          .width('100%')
          .backgroundColor($r('sys.color.comp_background_primary'))
          .borderRadius(12)
        }
        .onRefreshing(() => {
          this.onPullRefresh();
        })
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
    .bindSheet($$this.showSheet, this.MainSheet(), { height: SheetSize.MEDIUM })
  }
}
