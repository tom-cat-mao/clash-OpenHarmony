/*
 * Settings.ets - 应用设置持久化（preferences KV）
 * 覆写类设置在下次 VPN 启动时由 ClashVpnAbility 合并进内核配置。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Logger } from './Logger';

const TAG = 'settings';
const STORE = 'clashoh_settings';

export class AppSettings {
  keepAlive: boolean = true;
  ipv6: boolean = false;
  allowLan: boolean = true;
  logLevel: string = 'info';
  mixedPort: number = 7890;
  /** 按应用分流: all=全部走VPN, white=仅名单走(trusted), black=名单外走(blocked) */
  accessMode: string = 'all';
  accessList: string[] = [];
  /** 首页主分组（用户从首页进入/自动判定的 Selector 名） */
  mainGroup: string = '';
  /** 内核运行模式 rule|global|direct；空串=未显式选择，沿用激活配置自带 mode */
  mode: string = '';
  /** 订阅自动更新开关 */
  autoUpdate: boolean = false;
  /** 自动更新间隔（小时） */
  autoUpdateIntervalHours: number = 24;
  /** 打开应用自动恢复：冷启动时若上次会话曾连接则自动重连（默认开） */
  autoRestore: boolean = true;
  /** 内部标记：上次会话是否曾成功连接（用户主动断开时清 false，不上设置页） */
  vpnWasConnected: boolean = false;
  /** 已添加服务卡片 formId 列表（JSON 字符串持久化，避免数组类型兼容问题） */
  cardFormIdsJson: string = '[]';
  /** 代理组排序方式记忆：Map<组名, 0|1>（0=按名称, 1=按延迟升序）的 JSON 字符串 */
  proxySortJson: string = '{}';
  /** 内核日志是否写入应用沙箱 mihomo.log（默认开；关闭后仅进系统 hilog，下次启动内核生效） */
  logToFile: boolean = true;
}

export namespace Settings {
  let store: preferences.Preferences | null = null;

  function getStore(context: common.Context): preferences.Preferences {
    if (!store) {
      store = preferences.getPreferencesSync(context, { name: STORE });
    }
    return store;
  }

  export function load(context: common.Context): AppSettings {
    const p = getStore(context);
    const s = new AppSettings();
    try {
      s.keepAlive = p.getSync('keepAlive', true) as boolean;
      s.ipv6 = p.getSync('ipv6', false) as boolean;
      s.allowLan = p.getSync('allowLan', true) as boolean;
      s.logLevel = p.getSync('logLevel', 'info') as string;
      s.mixedPort = p.getSync('mixedPort', 7890) as number;
      s.accessMode = p.getSync('accessMode', 'all') as string;
      s.accessList = p.getSync('accessList', [] as string[]) as string[];
      s.mainGroup = p.getSync('mainGroup', '') as string;
      s.mode = p.getSync('mode', '') as string;
      s.autoUpdate = p.getSync('autoUpdate', false) as boolean;
      s.autoUpdateIntervalHours = p.getSync('autoUpdateIntervalHours', 24) as number;
      s.autoRestore = p.getSync('autoRestore', true) as boolean;
      s.vpnWasConnected = p.getSync('vpnWasConnected', false) as boolean;
      s.cardFormIdsJson = p.getSync('cardFormIdsJson', '[]') as string;
      s.proxySortJson = p.getSync('proxySortJson', '{}') as string;
      s.logToFile = p.getSync('logToFile', true) as boolean;
    } catch (e) {
      Logger.error(TAG, `load failed: ${JSON.stringify(e)}`);
    }
    return s;
  }

  export function save(context: common.Context, s: AppSettings): void {
    const p = getStore(context);
    try {
      p.putSync('keepAlive', s.keepAlive);
      p.putSync('ipv6', s.ipv6);
      p.putSync('allowLan', s.allowLan);
      p.putSync('logLevel', s.logLevel);
      p.putSync('mixedPort', s.mixedPort);
      p.putSync('accessMode', s.accessMode);
      p.putSync('accessList', s.accessList);
      p.putSync('mainGroup', s.mainGroup);
      p.putSync('mode', s.mode);
      p.putSync('autoUpdate', s.autoUpdate);
      p.putSync('autoUpdateIntervalHours', s.autoUpdateIntervalHours);
      p.putSync('autoRestore', s.autoRestore);
      p.putSync('vpnWasConnected', s.vpnWasConnected);
      p.putSync('cardFormIdsJson', s.cardFormIdsJson);
      p.putSync('proxySortJson', s.proxySortJson);
      p.putSync('logToFile', s.logToFile);
      p.flush();
    } catch (e) {
      Logger.error(TAG, `save failed: ${JSON.stringify(e)}`);
    }
  }
}
