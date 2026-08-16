/*
 * FormAbility.ets - 鸿蒙服务卡片 FormExtensionAbility（QUICK_ACCESS_DESIGN.md §2.2 + v1.1 + v1.2）
 * 表单进程读不到 UI 进程的模块级 VpnController.status，formId 列表与 VPN 状态统一走
 * SharedState（filesDir 共享文件）：onAddForm/onRemoveForm 维护 cardFormIds；
 * 渲染一律 buildBindingForState(SharedState.read().vpnState)。
 *
 * v1.2 自愈修复（文件状态可能陈旧）：
 * 官方规则（VPN应用开发指南-服务生命周期，https://developer.huawei.com/consumer/cn/doc/harmonyos-guides/net-vpnextension）：
 * 「当调用 startVpnExtensionAbility 接口的应用进程退出时」「当VPN服务进程销毁时」，系统会主动停止 VPN 连接。
 * 因此 UI 进程被系统回收/设备重启后，VPN 实际已断，但 shared_state.json 停留在旧值（如 connected），
 * 表单进程 5 分钟自愈链（onUpdateForm，最短间隔 5 分钟，见 formProvider.setFormNextRefreshTime：
 * https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-app-form-formprovider）
 * 若只重渲染文件内容，卡片会永远显示「已连接」。修复：表单进程自己用 CoreApi.isAlive()
 * （GET /version，127.0.0.1:9090，:vpn 独立进程，回环跨进程可达）探测内核真实存活——
 * 内核活 = VPN 隧道活（connected），内核死 = VPN 已断（disconnected）；与文件不一致时
 * 以真实状态渲染并写回 SharedState（writeVpnState 值未变自动跳过写盘）。
 */
import { formBindingData, formProvider, FormExtensionAbility } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../lib/Logger';
import { CardSync } from '../lib/CardSync';
import { CoreApi } from '../lib/CoreApi';
import { SharedState } from '../lib/SharedState';

const TAG = 'form';
/** 系统注入卡片 formId 的 want 参数键 */
const FORM_ID_KEY = 'ohos.extra.param.key.form_id';
/** 与 SharedState/CardSync 保持一致的状态字符串 */
const STATE_CONNECTED = 'connected';
const STATE_DISCONNECTED = 'disconnected';

export default class FormAbility extends FormExtensionAbility {
  /** 诊断：打印共享文件路径/存在性/原始内容 + 当前读取状态（定位跨进程状态断点用） */
  private probeSharedFile(): string {
    try {
      const p = this.context.filesDir + '/shared_state.json';
      const exists = fileIo.accessSync(p);
      const raw = exists ? fileIo.readTextSync(p) : '(missing)';
      Logger.info(TAG, 'probe path=' + p + ' exists=' + exists + ' raw=' + raw.substring(0, 200));
      const state = SharedState.read(this.context).vpnState;
      Logger.info(TAG, 'probe parsed vpnState=' + state);
      return state;
    } catch (e) {
      Logger.error(TAG, 'probe failed: ' + ((e as Error).message ?? JSON.stringify(e)));
      return SharedState.read(this.context).vpnState;
    }
  }

  onAddForm(want: Want): formBindingData.FormBindingData {
    let formId: string = '';
    const parameters = want.parameters;
    if (parameters !== undefined && parameters !== null) {
      const raw = parameters[FORM_ID_KEY];
      if (raw !== undefined && raw !== null) {
        formId = raw as string;
      }
    }
    if (formId.length > 0) {
      SharedState.addFormId(this.context, formId);
      Logger.info(TAG, 'onAddForm formId=' + formId);
      // 系统侧 5 分钟兜底刷新链：每次渲染后预约下一次，进程被杀也由系统按约唤醒（保证最终一致）。
      // 官方：setFormNextRefreshTime 的 minute 参数 >= 5（最短 5 分钟）
      // （https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-app-form-formprovider）
      formProvider.setFormNextRefreshTime(formId, 5).catch((e: Object) => {
        Logger.warn(TAG, 'setFormNextRefreshTime failed: ' + JSON.stringify(e));
      });
    } else {
      Logger.warn(TAG, 'onAddForm: missing form id');
    }
    // 返回共享状态 binding（跨进程：表单进程读 SharedState 而非 VpnController）。
    // onAddForm 的返回值是同步的（官方 FormExtensionAbility.onAddForm 签名：
    // onAddForm(want): FormBindingData），故先按文件状态渲染，异步探活校正结果走 updateForm 再推一次
    // （https://developer.huawei.com/consumer/cn/doc/harmonyos-references/js-apis-app-form-formextensionability）
    const state = SharedState.read(this.context).vpnState;
    if (formId.length > 0) {
      this.correctWithProbe(formId, state);
    }
    return CardSync.buildBindingForState(state);
  }

  onRemoveForm(formId: string): void {
    Logger.info(TAG, 'onRemoveForm formId=' + formId);
    SharedState.removeFormId(this.context, formId);
  }

  onUpdateForm(formId: string): void {
    Logger.info(TAG, 'onUpdateForm formId=' + formId);
    // 自愈注册：onUpdateForm 只在系统按约刷新/升级重绑时触发，老卡片（升级前添加）不会重走
    // onAddForm，这里用系统下发的权威 formId 补登记，保证主进程推送列表永远包含存活卡片
    SharedState.addFormId(this.context, formId);
    const state = this.probeSharedFile();
    // 先按文件状态渲染（快路径，保证立刻有内容），随后异步探活校正真实状态再推一次
    CardSync.updateOne(formId, state).catch((e: Object) => {
      Logger.warn(TAG, 'updateOne failed formId=' + formId + ': ' + JSON.stringify(e));
    });
    // v1.2：异步探活校正（文件状态可能陈旧——UI 进程退出/设备重启后系统主动断开 VPN，见类头注释）
    this.correctWithProbe(formId, state);
    // 续期 5 分钟兜底刷新链（系统按约唤醒，进程被杀不影响；minute >= 5 见官方 formProvider 文档）
    formProvider.setFormNextRefreshTime(formId, 5)
      .then(() => {
        Logger.info(TAG, 'refresh scheduled +5min formId=' + formId);
      })
      .catch((e: Object) => {
        Logger.warn(TAG, 'setFormNextRefreshTime failed: ' + JSON.stringify(e));
      });
  }

  /**
   * 异步探活校正（v1.2 自愈修复）：CoreApi.isAlive() 探测内核真实存活——
   * 内核活 = VPN 隧道活 → connected；内核死（连接被拒/超时）→ disconnected。
   * 探活结果与文件状态不一致时：写回 SharedState（writeVpnState 值未变自动跳过写盘，
   * 向后兼容：两进程共用同一方法，语义不变）+ 带 3 秒护栏 updateForm 推校正渲染。
   * CoreApi 失败静默（返回 null → isAlive=false），此处不抛异常；探活结果只有
   * true/false 两态，无第三种「不确定」分支。
   */
  private correctWithProbe(formId: string, fileState: string): void {
    CoreApi.isAlive().then((alive: boolean) => {
      const real = alive ? STATE_CONNECTED : STATE_DISCONNECTED;
      Logger.info(TAG, 'probe formId=' + formId + ' alive=' + alive +
        ' file=' + fileState + ' real=' + real);
      if (real !== fileState) {
        SharedState.writeVpnState(this.context, real);
        CardSync.updateOne(formId, real).catch((e: Object) => {
          Logger.warn(TAG, 'probe update failed formId=' + formId + ': ' + JSON.stringify(e));
        });
      }
    });
  }

  onFormEvent(formId: string, message: string): void {
    // 卡片点击切换 VPN 由 WidgetCard 的 postCardAction({action:'call'}) 直接投递到
    // EntryAbility 的 callee 方法（后台无 UI 切换）；此回调只承接 'message' 类事件（当前无）。
    Logger.info(TAG, 'FormAbility.onFormEvent formId=' + formId + ' message=' + message);
  }
}
