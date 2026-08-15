/*
 * HomePage.ets - 首页仪表盘（DESIGN.md §3）
 * 大圆环启停（VpnController）+ 实时速率（WS /traffic）+ 模式切换 + 当前节点/配置
 */
import { common } from '@kit.AbilityKit';
import { promptAction } from '@kit.ArkUI';
import { vibrator } from '@kit.SensorServiceKit';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CoreApi, TrafficMsg, ProxyInfo, formatRate } from '../lib/CoreApi';
import { ProfileStore } from '../lib/ProfileStore';
import { ProxyGroupBus } from './ProxyGroupPage';
import { Settings } from '../lib/Settings';
import { LiveViewKeeper } from '../lib/LiveViewKeeper';
import { AutoUpdater } from '../lib/AutoUpdater';
import { CardSync } from '../lib/CardSync';
import { Logger } from '../lib/Logger';

const TAG = 'home';

const MODE_LABELS: string[] = ['规则', '全局', '直连'];
const MODE_VALUES: string[] = ['rule', 'global', 'direct'];

interface InfoCardParams {
  title: string;
  value: string;
  sub: string;
  /** 标题行前缀符号（可选） */
  symbol?: Resource;
  onTap?: () => void;
}

@Component
export struct HomePage {
  @Consume('tab') @Watch('onTabVisible') currentVisibleTab: number;
  @Consume('tabJump') tabJump: number;
  @Consume('nav') navStack: NavPathStack;
  @State mainGroup: string = '';
  @State hasProfile: boolean = true;
  @State status: VpnStatus = VpnController.status;
  @State upRate: string = '—';
  @State downRate: string = '—';
  @State modeIndex: number = 0;
  @State currentNode: string = '—';
  @State profileName: string = '默认配置';
  @State uptime: string = '';
  /** 圆环呼吸动画缩放（1=静止） */
  @State pulse: number = 1;
  private trafficWatcher: CoreApi.StreamWatcher<TrafficMsg> = new CoreApi.StreamWatcher<TrafficMsg>();
  private connectedAt: number = 0;
  private uptimeTimer: number = -1;
  private listenerRegistered: boolean = false;

  aboutToAppear(): void {
    if (!this.listenerRegistered) {
      this.listenerRegistered = true;
      VpnController.onChanged((s: VpnStatus) => {
        this.status = s;
        if (s === VpnStatus.Connected || s === VpnStatus.Disconnected) {
          this.buzz();
        }
        if (s === VpnStatus.Connecting) {
          this.startPulse();
        } else {
          this.stopPulse();
        }
        if (s === VpnStatus.Connected) {
          this.onCoreUp();
        } else if (s === VpnStatus.Disconnected) {
          // 真正断开：先收 UI 资源，再释放保活资源
          this.onVpnDown();
        } else {
          // Connecting/Disconnecting 过渡态：只收 UI 资源，保留保活
          this.onCoreDown();
        }
        if (s === VpnStatus.Disconnected) {
          const msg = VpnController.consumeLastStartError();
          if (msg.length > 0) {
            promptAction.showToast({ message: `启动失败：${msg}`, duration: 3000 });
          }
        }
        // v1.1：卡片同步改由 EntryAbility 进程级 VpnController.onChanged 统一执行
        // （无 UI 后台态也保证刷新），此处不再重复调用 CardSync
      });
    }
    VpnController.recover();
    LiveViewKeeper.ensure(getContext(this) as common.UIAbilityContext);
    if (this.status === VpnStatus.Connected) {
      this.onCoreUp();
    }
    const context = getContext(this) as common.UIAbilityContext;
    const active = ProfileStore.getActiveFile(context);
    this.hasProfile = active.length > 0;
    this.profileName = this.hasProfile ? active.replace(/\.(yaml|yml)$/, '') : '未导入';
    // 卡片状态初次同步（进程重建后卡片可能停留在旧文案；sync 会顺带刷新共享文件状态）
    CardSync.sync(context).catch(() => {
      // 卡片同步失败不影响主流程
    });
  }

  aboutToDisappear(): void {
    // 划掉最近任务卡片时系统只移除任务卡片、保留进程（官方文档：调用 startVpnExtensionAbility
    // 的应用进程退出时，系统会主动断开 VPN）。此处仅释放 UI 资源：若同时停掉长时任务/周期更新，
    // 系统会判定应用彻底退出并断开 VPN；保活资源由 onVpnDown 在 VPN 真正断开时释放。
    this.onCoreDown();
  }

  /** 连接/断开轻触觉反馈；失败静默（非关键体验） */
  private buzz(): void {
    try {
      vibrator.startVibration({ type: 'time', duration: 10 }, { id: 0, usage: 'touch' });
    } catch (e) {
      // 无权限/不支持时忽略
    }
  }

  private onCoreUp(): void {
    this.connectedAt = Date.now();
    this.startTraffic();
    this.refreshConfigs();
    this.refreshNode();
    this.startUptimeTimer();
    const context = getContext(this) as common.UIAbilityContext;
    LiveViewKeeper.start(context).catch((e: Object) => {
      Logger.warn(TAG, 'liveview start failed: ' + JSON.stringify(e));
    });
    // 订阅自动更新：启动周期检查 + 立即补一轮（fire-and-forget）
    AutoUpdater.start(context);
    AutoUpdater.checkAndRun(context).catch(() => {
      Logger.warn(TAG, 'auto update check failed');
    });
  }
  private onCoreDown(): void {
    this.trafficWatcher.stop();
    this.upRate = '—';
    this.downRate = '—';
    this.uptime = '';
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
      this.uptimeTimer = -1;
    }
    this.stopPulse();
  }

  /** VPN 真正断开才释放保活资源（长时任务/周期更新） */
  private onVpnDown(): void {
    this.onCoreDown();
    LiveViewKeeper.stop(getContext(this) as common.UIAbilityContext);
    AutoUpdater.stop();
  }

  /** 连接中圆环呼吸：无限交替动画；由 stopPulse 的短动画打断复位 */
  private startPulse(): void {
    this.getUIContext().animateTo({
      duration: 800,
      iterations: -1,
      playMode: PlayMode.Alternate,
      curve: Curve.EaseInOut
    }, () => {
      this.pulse = 1.06;
    });
  }

  private stopPulse(): void {
    if (this.pulse === 1) {
      return;
    }
    this.getUIContext().animateTo({ duration: 200, curve: Curve.EaseInOut }, () => {
      this.pulse = 1;
    });
  }

  private startTraffic(): void {
    this.trafficWatcher.start('/traffic', (msg: TrafficMsg) => {
      this.upRate = formatRate(msg.up);
      this.downRate = formatRate(msg.down);
    });
  }

  private startUptimeTimer(): void {
    if (this.uptimeTimer >= 0) {
      clearInterval(this.uptimeTimer);
    }
    this.uptimeTimer = setInterval(() => {
      const sec = Math.floor((Date.now() - this.connectedAt) / 1000);
      const h = Math.floor(sec / 3600);
      const m = Math.floor((sec % 3600) / 60);
      const s = sec % 60;
      this.uptime = h > 0 ?
        `${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}` :
        `${m.toString().padStart(2, '0')}:${s.toString().padStart(2, '0')}`;
    }, 1000);
  }

  private async refreshConfigs(): Promise<void> {
    const cfg = await CoreApi.getConfigs();
    if (cfg) {
      const idx = MODE_VALUES.indexOf(cfg.mode);
      if (idx >= 0) {
        this.modeIndex = idx;
      }
    }
  }

  private async refreshNode(): Promise<void> {
    for (let attempt = 0; attempt < 5; attempt++) {
      const proxies = await CoreApi.getProxies();
      if (proxies) {
        const context = getContext(this) as common.UIAbilityContext;
        const names = Object.keys(proxies);
        // 主分组判定（三级优先级，命中后回写 Settings 覆盖旧记忆）：
        // 1) 名字匹配：组名包含「节点选择/手动选择/节点」的非 GLOBAL Selector；
        // 2) Settings 记忆的组：非空、仍存在、Selector 且非 GLOBAL；
        // 3) 兜底：第一个非 GLOBAL 的 Selector。
        const s = Settings.load(context);
        const nameHits: string[] = ['节点选择', '手动选择', '节点'];
        let chosen: string = '';
        for (const name of names) {
          const p: ProxyInfo = proxies[name];
          if (p.type === 'Selector' && name !== 'GLOBAL') {
            let matched: boolean = false;
            for (const hit of nameHits) {
              if (name.indexOf(hit) >= 0) {
                matched = true;
                break;
              }
            }
            if (matched) {
              chosen = name;
              break;
            }
          }
        }
        if (chosen.length === 0 && s.mainGroup.length > 0) {
          const saved = proxies[s.mainGroup];
          if (saved && saved.type === 'Selector' && s.mainGroup !== 'GLOBAL') {
            chosen = s.mainGroup;
          }
        }
        if (chosen.length === 0) {
          for (const name of names) {
            const p: ProxyInfo = proxies[name];
            if (p.type === 'Selector' && name !== 'GLOBAL') {
              chosen = name;
              break;
            }
          }
        }
        if (chosen.length > 0) {
          this.mainGroup = chosen;
          s.mainGroup = chosen;
          Settings.save(context, s);
          const now = proxies[chosen].now;
          this.currentNode = now === 'DIRECT' || now === 'REJECT' ? '直连' : now;
        } else {
          this.mainGroup = '';
          this.currentNode = '直连';
        }
        return;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 1000));
    }
  }

  private onTabVisible(): void {
    LiveViewKeeper.ensure(getContext(this) as common.UIAbilityContext);
    if (this.currentVisibleTab === 0 && this.status === VpnStatus.Connected) {
      this.refreshNode();
      this.refreshConfigs();
      const context = getContext(this) as common.UIAbilityContext;
      const active = ProfileStore.getActiveFile(context);
      this.hasProfile = active.length > 0;
      this.profileName = this.hasProfile ? active.replace(/\.(yaml|yml)$/, '') : '未导入';
    }
  }

  private statusLabel(): string {
    switch (this.status) {
      case VpnStatus.Connecting:
        return '连接中…';
      case VpnStatus.Connected:
        return '已连接';
      case VpnStatus.Disconnecting:
        return '断开中…';
      default:
        return '未连接';
    }
  }

  private ringColor(): ResourceColor {
    if (this.status === VpnStatus.Disconnected) {
      return $r('sys.color.comp_background_tertiary');
    }
    return $r('sys.color.brand');
  }

  private onRingClick(): void {
    const context = getContext(this) as common.UIAbilityContext;
    if (this.status === VpnStatus.Disconnected) {
      VpnController.start(context);
    } else if (this.status === VpnStatus.Connected) {
      VpnController.stop(context);
    }
  }

  private async onModeChange(index: number): Promise<void> {
    this.modeIndex = index;
    const ok = await CoreApi.patchMode(MODE_VALUES[index]);
    if (!ok) {
      Logger.warn(TAG, 'patchMode failed');
    }
  }

  @Builder
  InfoCard(params: InfoCardParams) {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        if (params.symbol !== undefined) {
          SymbolGlyph(params.symbol)
            .fontSize(16)
            .fontColor([$r('sys.color.font_secondary')])
        }
        Text(params.title)
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))
      }
      .alignItems(VerticalAlign.Center)
      Text(params.value)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      if (params.sub.length > 0) {
        Text(params.sub)
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .padding(14)
    .width('100%')
    .backgroundColor($r('sys.color.comp_background_primary'))
    .borderRadius(12)
    .stateStyles({
      pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
      normal: { .backgroundColor($r('sys.color.comp_background_primary')) }
    })
    .onClick(() => {
      if (params.onTap) {
        params.onTap();
      }
    })
  }

  build() {
    Column({ space: 12 }) {
      Column({ space: 4 }) {
        Text('ClashOH')
          .fontSize(26)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('sys.color.font_primary'))
        Text('mihomo 内核 · 纯血鸿蒙')
          .fontSize(12)
          .fontColor($r('sys.color.font_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .margin({ top: 8, bottom: 4 })

      Column({ space: 14 }) {
        Stack() {
          Circle()
            .width(148)
            .height(148)
            .fill(this.ringColor())
            .opacity(this.status === VpnStatus.Disconnected ? 0.5 : 1)
          SymbolGlyph($r('sys.symbol.power'))
            .fontSize(48)
            .fontColor([Color.White])
        }
        .width(148)
        .height(148)
        .scale({ x: this.pulse, y: this.pulse })
        .stateStyles({
          pressed: { .opacity(0.6) },
          normal: { .opacity(1) }
        })
        .onClick(() => this.onRingClick())

        Text(this.statusLabel())
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
          .fontColor($r('sys.color.font_primary'))
        Text(this.status === VpnStatus.Connected ?
          `${MODE_LABELS[this.modeIndex]}模式 · ${this.uptime.length > 0 ? this.uptime : '运行中'}` : '轻点圆环启动')
          .fontSize(13)
          .fontColor($r('sys.color.font_secondary'))

        // 模式切换
        Row({ space: 0 }) {
          ForEach(MODE_LABELS, (label: string, index: number) => {
            Text(label)
              .fontSize(13)
              .fontColor(this.modeIndex === index ? Color.White : $r('sys.color.font_secondary'))
              .backgroundColor(this.modeIndex === index ? $r('sys.color.brand') : Color.Transparent)
              .borderRadius(14)
              .padding({ top: 6, bottom: 6, left: 20, right: 20 })
              .stateStyles({
                pressed: { .opacity(0.6) },
                normal: { .opacity(1) }
              })
              .onClick(() => {
                this.onModeChange(index);
              })
          }, (label: string, index: number) => label + (this.modeIndex === index ? '|on' : '|off'))
        }
        .backgroundColor($r('sys.color.comp_background_secondary'))
        .borderRadius(16)
        .padding(2)
      }
      .width('100%')
      .padding({ top: 20, bottom: 20 })
      .backgroundColor($r('sys.color.comp_background_primary'))
      .borderRadius(16)

      Row({ space: 12 }) {
        Column() {
          this.InfoCard({ title: '上行', value: this.upRate, sub: '', symbol: $r('sys.symbol.arrow_up') })
        }
        .layoutWeight(1)
        Column() {
          this.InfoCard({ title: '下行', value: this.downRate, sub: '', symbol: $r('sys.symbol.arrow_down') })
        }
        .layoutWeight(1)
      }
      .width('100%')

      this.InfoCard({
        title: '代理节点',
        value: this.currentNode,
        sub: this.mainGroup.length > 0 ? `${this.mainGroup} · 点击切换` : '代理 Tab 中切换',
        onTap: () => {
          // 跳到代理 Tab 并直达主分组的节点选择页；记忆本次进入的主分组
          this.tabJump = 1;
          if (this.mainGroup.length > 0) {
            const context = getContext(this) as common.UIAbilityContext;
            const s = Settings.load(context);
            s.mainGroup = this.mainGroup;
            Settings.save(context, s);
            ProxyGroupBus.current = this.mainGroup;
            this.navStack.pushPath({ name: 'proxyGroup' });
          }
        }
      })
      if (this.hasProfile) {
        this.InfoCard({
          title: '当前配置',
          value: this.profileName,
          sub: '点击管理',
          onTap: () => {
            this.tabJump = 2;
          }
        })
      } else {
        Column({ space: 6 }) {
          Text('还没有订阅配置')
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor($r('sys.color.font_primary'))
          Text('点这里去「配置」页导入（订阅 URL / 本地文件）')
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .alignItems(HorizontalAlign.Start)
        .padding(14)
        .width('100%')
        .backgroundColor($r('sys.color.comp_background_primary'))
        .borderRadius(12)
        .stateStyles({
          pressed: { .backgroundColor($r('sys.color.comp_background_secondary')) },
          normal: { .backgroundColor($r('sys.color.comp_background_primary')) }
        })
        .onClick(() => {
          this.tabJump = 2;
        })
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: 16, right: 16 })
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
