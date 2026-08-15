/*
 * LiveViewKeeper.ets - dataTransfer 长时任务 + 系统实况窗常驻通知（后台保活）
 * VPN 连接成功且设置「后台运行」开启时申请 dataTransfer 长时任务
 * （MODE_DATA_TRANSFER + SUBMODE_LIVE_VIEW_NOTIFICATION），系统代理创建
 * "上传下载"实况窗（typeCode 8）；每 60s publish 更新（10 分钟不更新任务被取消），
 * 每 5min 对出口节点延迟测速（真实心跳流量，防"低速取消"+ 延迟展示）。
 * 数据面全走 REST 单次请求；日志 tag 'liveview'。
 * 取代 lib/BackgroundKeeper.ets（经典 BackgroundMode.DATA_TRANSFER 通知方案）。
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, common } from '@kit.AbilityKit';
import { notificationManager } from '@kit.NotificationKit';
import { CoreApi, TrafficMsg, ProxyInfo, formatRate } from './CoreApi';
import { Settings } from './Settings';
import { VpnController, VpnStatus } from './VpnController';
import { Logger } from './Logger';

const TAG = 'liveview';

/** 实况窗刷新周期：60s（系统硬性规则：10 分钟不更新即取消） */
const UPDATE_INTERVAL_MS = 60 * 1000;
/** 心跳（出口延迟测速）周期：5min */
const HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000;
/** 系统取消后的自愈重申请延迟 */
const REAPPLY_DELAY_MS = 30 * 1000;
/** 每小时最多自愈重申请次数，超出等前台 ensure */
const MAX_REAPPLY_PER_HOUR = 3;
/** 节点/模式名显示截断长度 */
const MAX_NAME_LEN = 18;
/** 胶囊品牌蓝（ARGB） */
const CAPSULE_BG = '#FF0A59F7';
/** 实况窗类型：上传下载 */
const LIVE_VIEW_TYPE_CODE = 8;

/** downloadTemplate 模板数据（ArkTS 严格模式：命名 interface 显式标注，extends Record 满足 data 类型） */
interface TemplateDataExt extends Record<string, Object> {
  title: string;
  fileName: string;
  progressValue: number;
}

export namespace LiveViewKeeper {
  let running: boolean = false;
  /** start() 进行中门闩：防止 onCoreUp 与 ensure() 并发触发重复申请任务 */
  let starting: boolean = false;
  /** 用户主动取消（划掉实况窗/关闭任务）：不再自动重建，等前台 ensure */
  let userStopped: boolean = false;
  let notificationId: number = -1;
  let continuousTaskId: number = -1;
  /** VPN 连接时刻（实况窗正计时起点；自愈重申请不清零） */
  let connectedAt: number = 0;
  let timerId: number = -1;
  let hbTimerId: number = -1;
  let lastContext: common.UIAbilityContext | null = null;
  let eventsRegistered: boolean = false;
  /** 上次累计流量采样（差分求速率） */
  let lastSample: TrafficMsg | null = null;
  let lastSampleAt: number = 0;
  let lastUpBps: number = 0;
  let lastDownBps: number = 0;
  /** 出口节点/模式名缓存（每 5min 心跳刷新） */
  let exitNode: string = '';
  let modeName: string = '';
  /** 最近一次成功测速延迟 ms（-1 = 无） */
  let lastDelay: number = -1;
  /** 自愈重申请时间戳（1 小时窗口内最多 3 次） */
  const reapplyLog: number[] = [];

  /** 申请 dataTransfer 长时任务 + 发布实况窗 + 启动 60s/5min 定时器 + 注册事件监听。幂等。 */
  export async function start(context: common.UIAbilityContext): Promise<boolean> {
    if (running) {
      return true;
    }
    if (starting) {
      return true;
    }
    if (!Settings.load(context).keepAlive) {
      return false;
    }
    starting = true;
    try {
      const agent = await wantAgent.getWantAgent({
        wants: [{ bundleName: context.applicationInfo.name, abilityName: 'EntryAbility' }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      });
      const request = new backgroundTaskManager.ContinuousTaskRequest();
      request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_DATA_TRANSFER];
      request.backgroundTaskSubmodes = [backgroundTaskManager.BackgroundTaskSubmode.SUBMODE_LIVE_VIEW_NOTIFICATION];
      request.wantAgent = agent;
      const res = await backgroundTaskManager.startBackgroundRunning(context, request);
      notificationId = res.notificationId;
      continuousTaskId = res.continuousTaskId !== undefined ? res.continuousTaskId : -1;
      if (connectedAt === 0) {
        connectedAt = Date.now();
      }
      lastContext = context;
      running = true;
      registerEvents();
      Logger.info(TAG, 'task started notificationId=' + notificationId + ' continuousTaskId=' + continuousTaskId);
      await refreshMeta();
      await publishLiveView();
      timerId = setInterval(() => {
        updateTick().catch((e: Object) => {
          Logger.warn(TAG, 'update tick error: ' + errMsg(e));
        });
      }, UPDATE_INTERVAL_MS);
      hbTimerId = setInterval(() => {
        doHeartbeat().catch((e: Object) => {
          Logger.warn(TAG, 'heartbeat error: ' + errMsg(e));
        });
      }, HEARTBEAT_INTERVAL_MS);
      return true;
    } catch (e) {
      Logger.error(TAG, 'start failed: ' + errMsg(e));
      await reset(true, context);
      return false;
    } finally {
      starting = false;
    }
  }

  /** 前台兜底：VPN Connected && keepAlive && 无任务 && !userStopped → start() */
  export function ensure(context: common.UIAbilityContext): void {
    if (VpnController.status !== VpnStatus.Connected) {
      return;
    }
    if (running || starting || userStopped) {
      return;
    }
    if (!Settings.load(context).keepAlive) {
      return;
    }
    start(context).then((ok: boolean) => {
      if (!ok) {
        Logger.warn(TAG, 'ensure: start returned false');
      }
    }).catch((e: Object) => {
      Logger.warn(TAG, 'ensure error: ' + errMsg(e));
    });
  }

  /** 停止定时器/监听，取消实况窗通知，stopBackgroundRunning（优先带 continuousTaskId）。幂等。 */
  export async function stop(context: common.UIAbilityContext): Promise<void> {
    await reset(true, context);
  }

  export function isRunning(): boolean {
    return running;
  }

  /** 复位全部状态与资源。stopTask=true 时额外执行 stopBackgroundRunning。 */
  async function reset(stopTask: boolean, context?: common.UIAbilityContext): Promise<void> {
    if (timerId >= 0) {
      clearInterval(timerId);
      timerId = -1;
    }
    if (hbTimerId >= 0) {
      clearInterval(hbTimerId);
      hbTimerId = -1;
    }
    if (notificationId >= 0) {
      try {
        await notificationManager.cancel(notificationId);
      } catch (e) {
        Logger.warn(TAG, 'cancel notification failed: ' + errMsg(e));
      }
    }
    if (eventsRegistered) {
      try {
        backgroundTaskManager.off('continuousTaskCancel');
        backgroundTaskManager.off('continuousTaskSuspend');
        backgroundTaskManager.off('continuousTaskActive');
      } catch (e) {
        Logger.warn(TAG, 'off events failed: ' + errMsg(e));
      }
      eventsRegistered = false;
    }
    if (stopTask) {
      const ctx = context !== undefined ? context : lastContext;
      if (ctx !== null) {
        try {
          if (continuousTaskId >= 0) {
            await backgroundTaskManager.stopBackgroundRunning(ctx, continuousTaskId);
          } else {
            await backgroundTaskManager.stopBackgroundRunning(ctx);
          }
          Logger.info(TAG, 'continuous task stopped');
        } catch (e) {
          Logger.warn(TAG, 'stopBackgroundRunning failed: ' + errMsg(e));
        }
      }
    }
    running = false;
    userStopped = false;
    notificationId = -1;
    continuousTaskId = -1;
    connectedAt = 0;
    lastSample = null;
    lastSampleAt = 0;
    lastUpBps = 0;
    lastDownBps = 0;
    exitNode = '';
    modeName = '';
    lastDelay = -1;
  }

  function registerEvents(): void {
    if (eventsRegistered) {
      return;
    }
    try {
      backgroundTaskManager.on('continuousTaskCancel', (info: backgroundTaskManager.ContinuousTaskCancelInfo) => {
        handleCancel(info).catch((e: Object) => {
          Logger.warn(TAG, 'cancel handler error: ' + errMsg(e));
        });
      });
      backgroundTaskManager.on('continuousTaskSuspend', (info: backgroundTaskManager.ContinuousTaskSuspendInfo) => {
        Logger.info(TAG, 'task suspended id=' + info.continuousTaskId);
      });
      backgroundTaskManager.on('continuousTaskActive', (info: backgroundTaskManager.ContinuousTaskActiveInfo) => {
        Logger.info(TAG, 'task active id=' + info.id);
      });
      eventsRegistered = true;
    } catch (e) {
      Logger.warn(TAG, 'register events failed: ' + errMsg(e));
    }
  }

  /**
   * 系统取消事件分类自愈：
   * - 用户主动（reason=USER_CANCEL / USER_CANCEL_REMOVE_NOTIFICATION 或 detailedReason=3）：userStopped，仅日志；
   * - 其他系统原因且内核仍活（GET /version 通）：30s 后重申请，每小时最多 3 次，超出等前台 ensure。
   */
  async function handleCancel(info: backgroundTaskManager.ContinuousTaskCancelInfo): Promise<void> {
    const reason = info.reason;
    const detailed = info.detailedReason;
    // ContinuousTaskDetailedCancelReason 为 API 26+ 枚举：低版本系统上枚举对象可能不存在，
    // 需先判空再取值，避免 API 24/25 设备上取消事件处理整体抛错。
    const detailedEnum = backgroundTaskManager.ContinuousTaskDetailedCancelReason;
    const userCancel = reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL ||
      reason === backgroundTaskManager.ContinuousTaskCancelReason.USER_CANCEL_REMOVE_NOTIFICATION ||
      (detailedEnum !== undefined && detailed === detailedEnum.USER_CANCEL_REMOVE_NOTIFICATION);
    if (userCancel) {
      userStopped = true;
      Logger.info(TAG, 'task canceled by user reason=' + reason + ' detailed=' + detailed);
      await reset(false);
      return;
    }
    Logger.warn(TAG, 'task canceled reason=' + reason + ' detailed=' + detailed);
    await reset(false);
    if (lastContext === null) {
      return;
    }
    if (!(await CoreApi.isAlive())) {
      Logger.warn(TAG, 'cancel: core not alive, wait foreground ensure');
      return;
    }
    const now = Date.now();
    while (reapplyLog.length > 0 && now - reapplyLog[0] > 60 * 60 * 1000) {
      reapplyLog.shift();
    }
    if (reapplyLog.length >= MAX_REAPPLY_PER_HOUR) {
      Logger.warn(TAG, 'cancel: reapply rate limit reached, wait foreground ensure');
      return;
    }
    reapplyLog.push(now);
    const ctx = lastContext;
    setTimeout(() => {
      if (userStopped || ctx === null) {
        return;
      }
      if (VpnController.status !== VpnStatus.Connected) {
        Logger.info(TAG, 'reapply skipped: vpn not connected');
        return;
      }
      start(ctx).then((ok: boolean) => {
        Logger.info(TAG, 'reapply ' + (ok ? 'ok' : 'failed'));
      }).catch((e: Object) => {
        Logger.warn(TAG, 'reapply error: ' + errMsg(e));
      });
    }, REAPPLY_DELAY_MS);
    Logger.info(TAG, 'cancel: reapply scheduled in 30s');
  }

  /** 60s 周期：取累计流量差分求速率，publish 更新实况窗 */
  async function updateTick(): Promise<void> {
    const t = await CoreApi.getTraffic();
    if (t !== null) {
      const now = Date.now();
      if (lastSample !== null && lastSampleAt > 0) {
        const elapsedSec = (now - lastSampleAt) / 1000;
        if (elapsedSec > 0) {
          lastDownBps = Math.max(0, t.down - lastSample.down) / elapsedSec;
          lastUpBps = Math.max(0, t.up - lastSample.up) / elapsedSec;
        }
      }
      lastSample = t;
      lastSampleAt = now;
    }
    await publishLiveView();
    Logger.info(TAG, 'live view updated rate=' + Math.round(lastDownBps + lastUpBps) + ' progress=' + progressValue());
  }

  /** 5min 心跳：刷新出口节点/模式缓存 + 出口延迟测速（真实代理流量） */
  async function doHeartbeat(): Promise<void> {
    let node: string = '';
    let delayMs: number = -1;
    const proxies = await CoreApi.getProxies();
    if (proxies !== null) {
      let group: string = '';
      if (lastContext !== null) {
        group = Settings.load(lastContext).mainGroup;
      }
      let sel: ProxyInfo | null = null;
      if (group.length > 0 && group !== 'GLOBAL' && proxies[group] !== undefined &&
        proxies[group].type === 'Selector') {
        sel = proxies[group];
      } else {
        const names = Object.keys(proxies);
        for (const name of names) {
          const p = proxies[name];
          if (p.type === 'Selector' && name !== 'GLOBAL') {
            sel = p;
            group = name;
            break;
          }
        }
        if (sel !== null && lastContext !== null) {
          const s = Settings.load(lastContext);
          s.mainGroup = group;
          Settings.save(lastContext, s);
        }
      }
      if (sel !== null) {
        node = sel.now;
        if (node !== 'DIRECT' && node !== 'REJECT') {
          const d = await CoreApi.delayTest(node);
          if (d !== null && d >= 0) {
            lastDelay = d;
            delayMs = d;
          }
        }
      }
    }
    const cfg = await CoreApi.getConfigs();
    if (cfg !== null) {
      modeName = cfg.mode;
    }
    if (node.length > 0) {
      exitNode = node === 'DIRECT' || node === 'REJECT' ? '直连' : node;
    }
    if (delayMs >= 0) {
      Logger.info(TAG, 'heartbeat delay=' + delayMs + 'ms');
    } else {
      Logger.info(TAG, 'heartbeat skipped');
    }
  }

  /** 刷新出口节点/模式名缓存（启动时调用一次，让首帧文案准确） */
  async function refreshMeta(): Promise<void> {
    const proxies = await CoreApi.getProxies();
    if (proxies !== null) {
      let group: string = '';
      if (lastContext !== null) {
        group = Settings.load(lastContext).mainGroup;
      }
      let sel: ProxyInfo | null = null;
      if (group.length > 0 && group !== 'GLOBAL' && proxies[group] !== undefined &&
        proxies[group].type === 'Selector') {
        sel = proxies[group];
      } else {
        const names = Object.keys(proxies);
        for (const name of names) {
          const p = proxies[name];
          if (p.type === 'Selector' && name !== 'GLOBAL') {
            sel = p;
            group = name;
            break;
          }
        }
        if (sel !== null && lastContext !== null) {
          const s = Settings.load(lastContext);
          s.mainGroup = group;
          Settings.save(lastContext, s);
        }
      }
      if (sel !== null) {
        const now = sel.now;
        exitNode = now === 'DIRECT' || now === 'REJECT' ? '直连' : now;
      }
    }
    const cfg = await CoreApi.getConfigs();
    if (cfg !== null) {
      modeName = cfg.mode;
    }
  }

  /** 按当前状态发布/更新实况窗（§2 状态文案表） */
  async function publishLiveView(): Promise<void> {
    if (notificationId < 0) {
      return;
    }
    const status = VpnController.status;
    let capsuleTitle: string = 'ClashOH · 代理已连接';
    let mainTitle: string = 'ClashOH 系统代理';
    let text: string = '已连接 · 无活动流量';
    let fileName: string = '规则模式';
    const modePart = truncateName(modeName.length > 0 ? modeName : '规则') + '模式';
    if (status === VpnStatus.Connecting) {
      capsuleTitle = 'ClashOH · 连接中…';
      mainTitle = 'ClashOH 正在连接';
      text = '正在建立 VPN 隧道…';
      fileName = modePart;
    } else if (status === VpnStatus.Disconnecting) {
      capsuleTitle = 'ClashOH · 断开中…';
      mainTitle = 'ClashOH 正在断开';
      text = '正在释放隧道…';
      fileName = modePart;
    } else {
      fileName = exitNode.length > 0 ? modePart + ' · 出口 ' + truncateName(exitNode) : modePart;
      if (lastDownBps > 0 || lastUpBps > 0) {
        text = '↓ ' + formatRate(lastDownBps) + ' · ↑ ' + formatRate(lastUpBps) + ' · 已运行 ' + formatUptime();
      } else {
        text = '已连接 · 无活动流量';
      }
      if (lastDelay >= 0) {
        text = text + ' · 延迟 ' + lastDelay + ' ms';
      }
    }
    const capsule: notificationManager.NotificationCapsule = {
      title: capsuleTitle,
      backgroundColor: CAPSULE_BG
    };
    const time: notificationManager.NotificationTime = {
      initialTime: connectedAt,
      isCountDown: false
    };
    const lv: notificationManager.NotificationSystemLiveViewContent = {
      typeCode: LIVE_VIEW_TYPE_CODE,
      title: mainTitle,
      text: text,
      capsule: capsule,
      time: time
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_SYSTEM_LIVE_VIEW,
      systemLiveView: lv
    };
    const templateData: TemplateDataExt = {
      title: mainTitle,
      fileName: fileName,
      progressValue: progressValue()
    };
    const template: notificationManager.NotificationTemplate = {
      name: 'downloadTemplate',
      data: templateData
    };
    const request: notificationManager.NotificationRequest = {
      id: notificationId,
      content: content,
      notificationSlotType: notificationManager.SlotType.LIVE_VIEW,
      template: template
    };
    try {
      await notificationManager.publish(request);
    } catch (e) {
      Logger.warn(TAG, 'publish failed: ' + errMsg(e));
    }
  }

  /** 流量活跃度：avgBps / 1MB/s × 100，钳制 0-100（§3） */
  function progressValue(): number {
    const avgBps = lastDownBps + lastUpBps;
    const pct = Math.round((avgBps / (1024 * 1024)) * 100);
    return Math.min(100, Math.max(0, pct));
  }

  /** 运行时长 HH:MM:SS（正计时） */
  function formatUptime(): string {
    const sec = Math.max(0, Math.floor((Date.now() - connectedAt) / 1000));
    const h = Math.floor(sec / 3600);
    const m = Math.floor((sec % 3600) / 60);
    const s = sec % 60;
    const hh = h.toString().padStart(2, '0');
    const mm = m.toString().padStart(2, '0');
    const ss = s.toString().padStart(2, '0');
    return hh + ':' + mm + ':' + ss;
  }

  /** 节点/模式名超 18 字符截断加省略号 */
  function truncateName(name: string): string {
    if (name.length <= MAX_NAME_LEN) {
      return name;
    }
    return name.substring(0, MAX_NAME_LEN - 1) + '…';
  }

  function errMsg(e: Object): string {
    const err = e as Error;
    if (err !== null && typeof err.message === 'string' && err.message.length > 0) {
      return err.message;
    }
    return JSON.stringify(e);
  }
}

