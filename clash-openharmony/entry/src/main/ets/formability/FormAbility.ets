/*
 * FormAbility.ets - 鸿蒙服务卡片 FormExtensionAbility（QUICK_ACCESS_DESIGN.md §2.2 + v1.1）
 * 表单进程读不到 UI 进程的模块级 VpnController.status，formId 列表与 VPN 状态统一走
 * SharedState（filesDir 共享文件）：onAddForm/onRemoveForm 维护 cardFormIds；
 * 渲染一律 buildBindingForState(SharedState.read().vpnState)。
 */
import { formBindingData, formProvider, FormExtensionAbility } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from '../lib/Logger';
import { CardSync } from '../lib/CardSync';
import { SharedState } from '../lib/SharedState';

const TAG = 'form';
/** 系统注入卡片 formId 的 want 参数键 */
const FORM_ID_KEY = 'ohos.extra.param.key.form_id';

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
      // 系统侧 5 分钟兜底刷新链：每次渲染后预约下一次，进程被杀也由系统按约唤醒（保证最终一致）
      formProvider.setFormNextRefreshTime(formId, 5).catch((e: Object) => {
        Logger.warn(TAG, 'setFormNextRefreshTime failed: ' + JSON.stringify(e));
      });
    } else {
      Logger.warn(TAG, 'onAddForm: missing form id');
    }
    // 返回共享状态 binding（跨进程：表单进程读 SharedState 而非 VpnController）
    return CardSync.buildBindingForState(SharedState.read(this.context).vpnState);
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
    formProvider.updateForm(formId, CardSync.buildBindingForState(state))
      .then(() => {
        Logger.info(TAG, 'updateForm OK formId=' + formId + ' state=' + state);
      })
      .catch((e: Object) => {
        const err = e as Error;
        Logger.error(TAG, 'updateForm FAILED formId=' + formId + ': ' +
          (err.message ?? JSON.stringify(e)));
      });
    // 续期 5 分钟兜底刷新链（系统按约唤醒，进程被杀不影响）
    formProvider.setFormNextRefreshTime(formId, 5)
      .then(() => {
        Logger.info(TAG, 'refresh scheduled +5min formId=' + formId);
      })
      .catch((e: Object) => {
        Logger.warn(TAG, 'setFormNextRefreshTime failed: ' + JSON.stringify(e));
      });
  }

  onFormEvent(formId: string, message: string): void {
    // 卡片点击切换 VPN 由 WidgetCard 的 postCardAction({action:'call'}) 直接投递到
    // EntryAbility 的 callee 方法（后台无 UI 切换）；此回调只承接 'message' 类事件（当前无）。
    Logger.info(TAG, 'FormAbility.onFormEvent formId=' + formId + ' message=' + message);
  }
}
