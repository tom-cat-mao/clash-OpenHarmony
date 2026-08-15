/*
 * SharedState.ets - 文件跨进程共享状态（QUICK_ACCESS_DESIGN.md v1.1 问题 1 修复）
 * 背景：FormAbility 运行在表单进程，读不到 UI 进程的模块级 VpnController.status；
 *       preferences 实例为进程内单例缓存，跨进程读写不可靠（主进程永远读到空列表）。
 * 方案：filesDir 下 shared_state.json 文件——fileIo 无缓存、每次现读；filesDir 跨进程
 *       共享已验证（vpn 进程 LAST_ERROR_FILE 先例）。结构：
 *       { vpnState: 'connected|connecting|disconnected', cardFormIds: string[] }
 * 日志 tag 'sharedState'。
 */
import { fileIo } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'sharedState';
const FILE_NAME = 'shared_state.json';
const STATE_DISCONNECTED = 'disconnected';

/** 跨进程共享状态（文件持久化，无进程内缓存） */
export interface SharedStateData {
  vpnState: string;
  cardFormIds: string[];
}

export namespace SharedState {
  /** 每次现读文件；文件缺失/损坏/解析失败一律返回默认值（不抛错） */
  export function read(context: common.Context): SharedStateData {
    const filePath = context.filesDir + '/' + FILE_NAME;
    try {
      const text = fileIo.readTextSync(filePath);
      const parsed = JSON.parse(text) as SharedStateData;
      const ids: string[] = Array.isArray(parsed.cardFormIds) ? parsed.cardFormIds : [];
      const state: string = typeof parsed.vpnState === 'string' && parsed.vpnState.length > 0
        ? parsed.vpnState : STATE_DISCONNECTED;
      const data: SharedStateData = { vpnState: state, cardFormIds: ids };
      return data;
    } catch (e) {
      Logger.warn(TAG, 'read failed: ' + ((e as Error).message ?? JSON.stringify(e)));
      const data: SharedStateData = { vpnState: STATE_DISCONNECTED, cardFormIds: [] };
      return data;
    }
  }

  /** 写入 VPN 状态字符串（值未变化时跳过写盘，避免无谓 IO） */
  export function writeVpnState(context: common.Context, state: string): void {
    const data = read(context);
    if (data.vpnState === state) {
      return;
    }
    data.vpnState = state;
    writeFile(context, data);
    Logger.info(TAG, 'vpnState -> ' + state);
  }

  /** 登记已添加卡片 formId（去重后写盘） */
  export function addFormId(context: common.Context, formId: string): void {
    const data = read(context);
    if (data.cardFormIds.indexOf(formId) >= 0) {
      return;
    }
    data.cardFormIds.push(formId);
    writeFile(context, data);
  }

  /** 移除卡片 formId（不存在时静默） */
  export function removeFormId(context: common.Context, formId: string): void {
    const data = read(context);
    const next: string[] = [];
    for (const id of data.cardFormIds) {
      if (id !== formId) {
        next.push(id);
      }
    }
    if (next.length === data.cardFormIds.length) {
      return;
    }
    data.cardFormIds = next;
    writeFile(context, data);
  }

  /** 整文件覆写：openSync(READ_WRITE|CREATE|TRUNC) + writeSync + closeSync（失败仅日志） */
  function writeFile(context: common.Context, data: SharedStateData): void {
    const filePath = context.filesDir + '/' + FILE_NAME;
    try {
      const f = fileIo.openSync(filePath,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      try {
        fileIo.writeSync(f.fd, JSON.stringify(data));
      } finally {
        fileIo.closeSync(f);
      }
    } catch (e) {
      Logger.error(TAG, 'write failed: ' + ((e as Error).message ?? JSON.stringify(e)));
    }
  }
}
