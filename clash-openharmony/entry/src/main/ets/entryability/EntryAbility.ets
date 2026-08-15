/*
 * EntryAbility.ets - 应用入口（QUICK_ACCESS_DESIGN.md §1.3/§2.4 + v1.1 问题 2 修复）
 * - 卡片 call 事件（v1.1）：postCardAction action:'call' 后台拉起本 Ability（无窗口无 UI，
 *   不执行 onWindowStageCreate）。onCreate 先注册 callee 方法 'toggleVpn'（Disconnected→start，
 *   Connected→stop，过渡态忽略），再投递方法；onDestroy 注销。
 * - 进程级状态监听（v1.1）：无 UI 时 HomePage 不存在，保活/卡片同步必须挂在进程级——
 *   onCreate 注册一次 VpnController.onChanged（模块级布尔门闩防重复）：每次状态变化
 *   CardSync.sync + Connected→LiveViewKeeper.start / Disconnected→LiveViewKeeper.stop。
 * - 卡片 router 参数（§2.4，后备路径，无调用方）：action==='toggle' 冷启动立即连接；
 *   应用存活（onNewWant）按状态取反。
 * - 冷启动自动恢复：autoRestore && vpnWasConnected && 未连接 → 延时 1200ms 后自动连接。
 */
import { AbilityConstant, UIAbility, Want, common } from '@kit.AbilityKit';
import { rpc } from '@kit.IPCKit';
import { window } from '@kit.ArkUI';
import { Logger } from '../lib/Logger';
import { Settings } from '../lib/Settings';
import { VpnController, VpnStatus } from '../lib/VpnController';
import { CardSync } from '../lib/CardSync';
import { LiveViewKeeper } from '../lib/LiveViewKeeper';

const TAG = 'entry';
const TAG_AUTORESTORE = 'autoRestore';
/** 卡片参数载体：postCardAction 的 params 以 JSON 字符串存于 want.parameters['params'] */
const PARAMS_KEY = 'params';
const ACTION_TOGGLE = 'toggle';
/** 卡片 call 事件方法名（WidgetCard postCardAction action:'call' 的 params.method） */
const METHOD_TOGGLE_VPN = 'toggleVpn';
/** 冷启动自动恢复延时：避开 HomePage 冷启动 recover() 探测窗口 */
const AUTO_RESTORE_DELAY_MS = 1200;
/** 进程级状态监听门闩：每进程只注册一次（onCreate 可能重复：卡片 call 后台启动/前台再拉起） */
let statusListenerRegistered: boolean = false;
/** 进程级监听/同步使用的当前 Ability 上下文：每次 onCreate 刷新，避免闭包持有已销毁实例的旧 context */
let entryContext: common.UIAbilityContext | null = null;

/** 最小 rpc.Parcelable 应答：无字段，marshalling/unmarshalling 直接成功 */
class EmptyReply implements rpc.Parcelable {
  marshalling(dataOut: rpc.MessageSequence): boolean {
    return true;
  }

  unmarshalling(dataIn: rpc.MessageSequence): boolean {
    return true;
  }
}

/** 解析卡片参数（JSON 字符串），返回是否携带 action==='toggle'；解析失败静默（仅日志） */
function parseToggleAction(want: Want): boolean {
  const parameters = want.parameters;
  if (parameters === undefined || parameters === null) {
    return false;
  }
  const raw = parameters[PARAMS_KEY];
  if (raw === undefined || raw === null) {
    return false;
  }
  try {
    const parsed = JSON.parse(raw as string) as Record<string, Object>;
    return parsed['action'] === ACTION_TOGGLE;
  } catch (e) {
    Logger.warn(TAG, 'parse card params failed: ' + ((e as Error).message ?? JSON.stringify(e)));
  }
  return false;
}

export default class EntryAbility extends UIAbility {
  /** 自动恢复定时器句柄（避免重复调度） */
  private autoRestoreTimer: number = -1;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'EntryAbility.onCreate');
    entryContext = this.context;
    // ① 注册卡片 call 事件方法（错误码 16200004 = 方法已注册：进程内重复 onCreate 时仅日志）
    try {
      this.callee.on(METHOD_TOGGLE_VPN, (data: rpc.MessageSequence): rpc.Parcelable => {
        Logger.info(TAG, 'toggle from card call');
        const ctx = entryContext !== null ? entryContext : this.context;
        // call 参数：readString() 返回整个 params 的 JSON 字符串（官方 bpta 文档模式），
        // 需 JSON.parse 后取 formId（由卡片框架注入）
        let cardFormId: string = '';
        try {
          const rawParams: string = data.readString();
          const callParams = JSON.parse(rawParams) as Record<string, Object>;
          const fid = callParams['formId'];
          if (typeof fid === 'string') {
            cardFormId = fid;
          }
          Logger.info(TAG, 'call params raw=' + rawParams.substring(0, 120) + ' formId=' + cardFormId);
        } catch (e2) {
          Logger.warn(TAG, 'parse call params failed: ' + ((e2 as Error).message ?? JSON.stringify(e2)));
        }
        const status = VpnController.status;
        if (status === VpnStatus.Disconnected) {
          VpnController.start(ctx);
          // 即时反馈：目标态文案直接推给被点击的卡片（护栏防挂起；后续状态监听会继续校准）
          if (cardFormId.length > 0) {
            CardSync.updateOne(cardFormId, 'connecting').catch((e2: Object) => {
              Logger.warn(TAG, 'tap-time card update failed: ' + JSON.stringify(e2));
            });
          }
        } else if (status === VpnStatus.Connected) {
          VpnController.stop(ctx);
          if (cardFormId.length > 0) {
            CardSync.updateOne(cardFormId, 'disconnected').catch((e2: Object) => {
              Logger.warn(TAG, 'tap-time card update failed: ' + JSON.stringify(e2));
            });
          }
        } else {
          // Connecting/Disconnecting 过渡态：忽略
          Logger.info(TAG, 'toggle ignored, status=' + VpnStatus[status]);
        }
        return new EmptyReply();
      });
    } catch (e) {
      Logger.warn(TAG, 'callee.on toggleVpn failed: ' + ((e as Error).message ?? JSON.stringify(e)));
    }
    // ② 进程级状态监听（模块级门闩防重复）：无 UI 后台态也保证卡片同步 + 保活闭环
    if (!statusListenerRegistered) {
      statusListenerRegistered = true;
      VpnController.onChanged((s: VpnStatus) => {
        const ctx = entryContext;
        if (ctx === null) {
          return;
        }
        CardSync.sync(ctx).catch((e: Object) => {
          Logger.warn(TAG, 'CardSync.sync failed: ' + JSON.stringify(e));
        });
        if (s === VpnStatus.Connected) {
          LiveViewKeeper.start(ctx).catch((e: Object) => {
            Logger.warn(TAG, 'LiveViewKeeper.start failed: ' + JSON.stringify(e));
          });
        } else if (s === VpnStatus.Disconnected) {
          LiveViewKeeper.stop(ctx).catch((e: Object) => {
            Logger.warn(TAG, 'LiveViewKeeper.stop failed: ' + JSON.stringify(e));
          });
        }
      });
    }
    // ③ 冷启动立即补一次同步：把共享文件状态刷新成真实状态（进程重建后卡片可能停在旧文案）
    CardSync.sync(this.context).catch((e: Object) => {
      Logger.warn(TAG, 'CardSync.sync failed: ' + JSON.stringify(e));
    });
    if (parseToggleAction(want)) {
      // 卡片显式意图：立即连接（用户点卡片即是要开 VPN）
      Logger.info(TAG, 'toggle from card: start');
      VpnController.start(this.context);
      return;
    }
    const s = Settings.load(this.context);
    if (s.autoRestore && s.vpnWasConnected && VpnController.status === VpnStatus.Disconnected) {
      this.scheduleAutoRestore();
    }
  }

  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    Logger.info(TAG, 'EntryAbility.onNewWant');
    if (!parseToggleAction(want)) {
      return;
    }
    Logger.info(TAG, 'toggle from card');
    const status = VpnController.status;
    if (status === VpnStatus.Connected) {
      VpnController.stop(this.context);
    } else if (status === VpnStatus.Disconnected) {
      VpnController.start(this.context);
    } else {
      // Connecting/Disconnecting 过渡态：忽略
      Logger.info(TAG, 'toggle ignored, status=' + VpnStatus[status]);
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.error(TAG, 'loadContent failed: ' + JSON.stringify(err));
        return;
      }
      Logger.info(TAG, 'loadContent succeeded');
    });
  }

  onDestroy(): void {
    Logger.info(TAG, 'EntryAbility.onDestroy');
    try {
      this.callee.off(METHOD_TOGGLE_VPN);
    } catch (e) {
      Logger.warn(TAG, 'callee.off failed: ' + ((e as Error).message ?? JSON.stringify(e)));
    }
  }

  /** 冷启动自动恢复：延时后 start（start 内部有状态幂等保护，竞态安全） */
  private scheduleAutoRestore(): void {
    if (this.autoRestoreTimer >= 0) {
      clearTimeout(this.autoRestoreTimer);
      this.autoRestoreTimer = -1;
    }
    this.autoRestoreTimer = setTimeout(() => {
      this.autoRestoreTimer = -1;
      if (VpnController.status !== VpnStatus.Disconnected) {
        Logger.info(TAG_AUTORESTORE, 'auto start skipped, status=' + VpnStatus[VpnController.status]);
        return;
      }
      Logger.info(TAG_AUTORESTORE, 'auto start triggered');
      VpnController.start(this.context);
    }, AUTO_RESTORE_DELAY_MS);
    Logger.info(TAG_AUTORESTORE, 'auto start scheduled');
  }
}
