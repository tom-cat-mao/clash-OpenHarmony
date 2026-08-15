/*
 * AutoUpdater.ets - 订阅自动更新（按设置周期拉取激活配置的来源 URL）
 * 仅对激活配置生效；本地导入（无来源 URL）自动跳过。
 * 周期检查由 HomePage onCoreUp() 启动、onCoreDown() 停止；
 * 上次成功时间戳与 Settings 同 store（clashoh_settings）不同 key，互不影响。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Settings } from './Settings';
import { CoreApi } from './CoreApi';
import { ProfileStore } from './ProfileStore';
import { Logger } from './Logger';

const TAG = 'autoUpdater';
const STORE = 'clashoh_settings';
const KEY_LAST_AUTO_UPDATE = 'lastAutoUpdateMs';
/** 定时检查周期：每 60 分钟 */
const CHECK_INTERVAL_MS = 60 * 60 * 1000;

export namespace AutoUpdater {
  let timerId: number = -1;

  /** 启动周期检查（幂等：重复调用先 stop） */
  export function start(context: common.Context): void {
    stop();
    timerId = setInterval(() => {
      checkAndRun(context).catch(() => {
        // fire-and-forget：单轮失败忽略，等下一轮
      });
    }, CHECK_INTERVAL_MS);
    Logger.info(TAG, 'auto updater started');
  }

  /** 停止周期检查 */
  export function stop(): void {
    if (timerId >= 0) {
      clearInterval(timerId);
      timerId = -1;
      Logger.info(TAG, 'auto updater stopped');
    }
  }

  /** 单轮检查：开关/内核/间隔/来源都满足才真正更新 */
  export async function checkAndRun(context: common.Context): Promise<void> {
    const s = Settings.load(context);
    if (!s.autoUpdate) {
      return;
    }
    if (!(await CoreApi.isAlive())) {
      return;
    }
    const p = preferences.getPreferencesSync(context, { name: STORE });
    let last = 0;
    try {
      last = p.getSync(KEY_LAST_AUTO_UPDATE, 0) as number;
    } catch (e) {
      Logger.warn(TAG, `read lastAutoUpdateMs failed: ${JSON.stringify(e)}`);
    }
    const now = Date.now();
    if (last !== 0 && now - last < s.autoUpdateIntervalHours * 3600 * 1000) {
      return;
    }
    const active = ProfileStore.getActiveFile(context);
    if (active.length === 0) {
      return;
    }
    if (ProfileStore.getOrigin(context, active).length === 0) {
      return;
    }
    try {
      await ProfileStore.updateFromOrigin(context, active);
      try {
        p.putSync(KEY_LAST_AUTO_UPDATE, now);
        p.flush();
      } catch (e) {
        Logger.warn(TAG, `write lastAutoUpdateMs failed: ${JSON.stringify(e)}`);
      }
      if (await CoreApi.isAlive()) {
        await CoreApi.reloadConfig(ProfileStore.absPath(context, active));
      }
      Logger.info(TAG, `auto update done: ${active}`);
    } catch (e) {
      const msg = (e as Error).message ?? JSON.stringify(e);
      Logger.warn(TAG, `auto update failed: ${msg}`);
    }
  }
}
