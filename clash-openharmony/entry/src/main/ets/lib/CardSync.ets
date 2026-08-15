/*
 * CardSync.ets - 服务卡片状态同步（QUICK_ACCESS_DESIGN.md v1.1）
 * - buildBindingForState(state)：按共享状态字符串组装卡片 binding——跨进程可用：
 *   表单进程读不到本进程 VpnController.status（永远 Disconnected），状态改由
 *   SharedState 文件承载（UI 进程写入 vpnState，表单进程现读）。
 * - sync(context)：① 把本进程 VpnController.status 映射写入 SharedState.vpnState；
 *   ② 现读共享 cardFormIds；③ 逐个 formProvider.updateForm（单卡失败静默）。
 * 系统定时刷新（form_config updateDuration）仅作兜底。日志 tag 'cardSync'。
 */
import { formBindingData, formProvider } from '@kit.FormKit';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { SharedState } from './SharedState';
import { VpnController, VpnStatus } from './VpnController';
import { Logger } from './Logger';

const TAG = 'cardSync';

const STATE_CONNECTED = 'connected';
const STATE_CONNECTING = 'connecting';
const STATE_DISCONNECTED = 'disconnected';
/** 单次 updateForm 超时护栏：真机观察到主进程 updateForm 可能永不返回，超时后放弃本次更新（下次状态变化再试） */
const UPDATE_FORM_TIMEOUT_MS = 3000;

/** VpnStatus → 共享状态字符串（Disconnecting 过渡态归入 disconnected） */
function stateString(): string {
  const status = VpnController.status;
  if (status === VpnStatus.Connected) {
    return STATE_CONNECTED;
  }
  if (status === VpnStatus.Connecting) {
    return STATE_CONNECTING;
  }
  return STATE_DISCONNECTED;
}

export namespace CardSync {
  /** 状态字符串 → 卡片绑定数据（文案映射：connected→已连接·点按断开/isOn=true；connecting→连接中…/false；其他→未连接·点按连接/false） */
  export function buildBindingForState(state: string): formBindingData.FormBindingData {
    if (state === STATE_CONNECTED) {
      return formBindingData.createFormBindingData({ statusText: '已连接 · 点按断开', isOn: true });
    }
    if (state === STATE_CONNECTING) {
      return formBindingData.createFormBindingData({ statusText: '连接中…', isOn: false });
    }
    return formBindingData.createFormBindingData({ statusText: '未连接 · 点按连接', isOn: false });
  }

  /** 带超时护栏的单卡更新：返回 true=成功、false=失败或超时（永不挂起） */
  export async function updateOne(formId: string, state: string): Promise<boolean> {
    try {
      await Promise.race<void>([
        formProvider.updateForm(formId, buildBindingForState(state)),
        new Promise<void>((_resolve, reject) => {
          setTimeout(() => {
            reject(new Error('timeout'));
          }, UPDATE_FORM_TIMEOUT_MS);
        })
      ]);
      return true;
    } catch (e) {
      Logger.warn(TAG, 'updateForm failed formId=' + formId + ': ' + ((e as Error).message ?? JSON.stringify(e)));
      return false;
    }
  }

  /** 主进程主动刷新：写 vpnState → 读共享 formId 列表 → 逐个带护栏更新（单卡失败静默跳过） */
  export async function sync(context: common.UIAbilityContext): Promise<void> {
    const state = stateString();
    SharedState.writeVpnState(context, state);
    const data = SharedState.read(context);
    // 诊断：回读文件内容，确认主进程写入持久化成功（与表单进程 probe 对照定位断点）
    try {
      const p = context.filesDir + '/shared_state.json';
      if (fileIo.accessSync(p)) {
        Logger.info(TAG, 'file after write: ' + fileIo.readTextSync(p).substring(0, 200));
      } else {
        Logger.warn(TAG, 'file missing after write: ' + p);
      }
    } catch (e) {
      Logger.warn(TAG, 'file verify failed: ' + ((e as Error).message ?? JSON.stringify(e)));
    }
    Logger.info(TAG, 'sync begin state=' + state + ' forms=' + data.cardFormIds.length +
      ' ids=' + JSON.stringify(data.cardFormIds));
    let updated = 0;
    for (const formId of data.cardFormIds) {
      if (await updateOne(formId, state)) {
        updated++;
      }
    }
    Logger.info(TAG, 'updated ' + updated + ' forms');
  }
}
