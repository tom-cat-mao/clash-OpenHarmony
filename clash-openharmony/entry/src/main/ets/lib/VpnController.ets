/*
 * VpnController.ets - 主进程 VPN 启停(M0 最小状态机)
 *
 * start: startVpnExtensionAbility(触发系统授权弹窗) -> connectServiceExtensionAbility(带 VPN_CONFIG)
 * stop:  disconnectServiceExtensionAbility -> stopVpnExtensionAbility
 */
import { vpnExtension, connection } from '@kit.NetworkKit';
import { common, Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { Logger } from './Logger';
import { CoreApi } from './CoreApi';
import { Settings } from './Settings';

const TAG = 'vpnCtrl';
const VPN_ABILITY_NAME = 'ClashVpnAbility';
// 与 vpnability/ClashVpnAbility.ets 的 LAST_ERROR_FILE 一致（同一应用沙箱共享 filesDir）
const LAST_ERROR_FILE = 'last_start_error.txt';

export enum VpnStatus {
  Disconnected = 0,
  Connecting = 1,
  Connected = 2,
  Disconnecting = 3
}

type StatusListener = (s: VpnStatus) => void;

/**
 * 构建 VpnConfig.routes（FlClash 实证方案）：
 * 1. 显式默认路由 0.0.0.0/0（IPv6 开启时追加 ::/0）——保证 VPN 成为应用的解析网络，
 *    系统 DNS（fake-ip 链路）正确传播；
 * 2. 华为 HTTPDNS 引导服务器（139.9.98.98/139.9.99.99，/32）与边缘段
 *    （139.9/16、49.4/16、121.36/16、125.88/16、119.147/16、183.61/16）
 *    标记为排除路由（isExcludedRoute）——ArkWeb 浏览器的 HTTPDNS/静默代理
 *    （SilentProxy）直连运营商网络完成解析，不再被隧道送到境外节点导致
 *    空代理（x.x.x）解析失败 → ERR_PROXY_CONNECTION_FAILED；
 *    后续内容连接仍走隧道，由内核 SNI 嗅探（override-destination）修正目标。
 */
function buildVpnRoutes(ipv6: boolean): connection.RouteInfo[] {
  const routes: connection.RouteInfo[] = [];
  routes.push({
    interface: 'vpn-tun',
    destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
    gateway: { address: '', family: 1 },
    hasGateway: false,
    isDefaultRoute: true
  });
  const bootstrap: string[] = ['139.9.98.98', '139.9.99.99'];
  for (const ip of bootstrap) {
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: ip, family: 1 }, prefixLength: 32 },
      gateway: { address: '', family: 1 },
      hasGateway: false,
      isDefaultRoute: false,
      isExcludedRoute: true
    });
  }
  const excludedCidrs: string[] = ['139.9.0.0/16', '49.4.0.0/16', '121.36.0.0/16',
    '125.88.0.0/16', '119.147.0.0/16', '183.61.0.0/16'];
  for (const cidr of excludedCidrs) {
    const parts: string[] = cidr.split('/');
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: parts[0], family: 1 }, prefixLength: Number(parts[1]) },
      gateway: { address: '', family: 1 },
      hasGateway: false,
      isDefaultRoute: false,
      isExcludedRoute: true
    });
  }
  if (ipv6) {
    routes.push({
      interface: 'vpn-tun',
      destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
      gateway: { address: '', family: 2 },
      hasGateway: false,
      isDefaultRoute: true
    });
  }
  return routes;
}

/** 读取 :vpn 进程写入的最近一次启动失败原因（空串=无失败） */
function readLastStartError(context: common.UIAbilityContext): string {
  try {
    const p = `${context.filesDir}/${LAST_ERROR_FILE}`;
    if (fileIo.accessSync(p)) {
      return fileIo.readTextSync(p).trim();
    }
  } catch (e) {
    // 忽略
  }
  return '';
}

export namespace VpnController {
  export let status: VpnStatus = VpnStatus.Disconnected;
  /** 最近一次内核启动失败原因（空串=正常）。UI 读取后调用 consumeLastStartError 清空。 */
  export let lastStartError: string = '';
  let serviceId: number = 0;
  const listeners: StatusListener[] = [];

  export function onChanged(cb: StatusListener): void {
    listeners.push(cb);
  }

  export function consumeLastStartError(): string {
    const msg = lastStartError;
    lastStartError = '';
    return msg;
  }

  /** 冷启动恢复：UI 进程重建后探测内核是否仍在（REST 通则 VPN 活着） */
  export function recover(): void {
    if (status !== VpnStatus.Disconnected) {
      return;
    }
    CoreApi.isAlive().then((alive: boolean) => {
      if (alive && status === VpnStatus.Disconnected) {
        Logger.info(TAG, 'recover: core alive, status -> Connected');
        setStatus(VpnStatus.Connected);
      }
    });
  }

  function setStatus(s: VpnStatus): void {
    if (status === s) {
      return;
    }
    status = s;
    Logger.info(TAG, `status -> ${VpnStatus[s]}`);
    for (const cb of listeners) {
      cb(s);
    }
  }

  export function start(context: common.UIAbilityContext): void {
    if (status !== VpnStatus.Disconnected) {
      Logger.warn(TAG, `start ignored, status=${VpnStatus[status]}`);
      return;
    }
    setStatus(VpnStatus.Connecting);
    const want: Want = { bundleName: context.applicationInfo.name, abilityName: VPN_ABILITY_NAME };
    Logger.info(TAG, 'startVpnExtensionAbility...');
    vpnExtension.startVpnExtensionAbility(want).then(() => {
      connectService(context, want);
    }).catch((e: Object) => {
      Logger.error(TAG, `startVpnExtensionAbility failed: ${JSON.stringify(e)}`);
      setStatus(VpnStatus.Disconnected);
    });
  }

  function connectService(context: common.UIAbilityContext, want: Want): void {
    const linkAddr: connection.LinkAddress = {
      address: { address: '172.19.0.1', family: 1 },
      prefixLength: 30
    };
    // 按应用分流（设置→网络设置）：all=全部走 VPN（仅自身排除）；
    // white=仅名单内走；black=名单内不走。本应用始终直连（订阅下载/REST 不绕路）。
    const s = Settings.load(context);
    const self = context.applicationInfo.name;
    const blocked: string[] = [self];
    const trusted: string[] = [];
    if (s.accessMode === 'black') {
      for (const pkg of s.accessList) {
        if (pkg !== self) {
          blocked.push(pkg);
        }
      }
    } else if (s.accessMode === 'white') {
      for (const pkg of s.accessList) {
        if (pkg !== self) {
          trusted.push(pkg);
        }
      }
    }
    const vpnConfig: vpnExtension.VpnConfig = {
      addresses: [linkAddr],
      // 与内核 gVisor 栈 MTU（core/engine.go defaultTunExt 9000）保持一致，
      // 避免 gVisor 产出 9KB 帧打进 1500 MTU 设备被丢弃
      mtu: 9000,
      dnsAddresses: ['223.5.5.5', '8.8.8.8'],
      // 显式默认路由 + 华为 HTTPDNS 排除路由（FlClash 方案，修复 ArkWeb 浏览器
      // 空代理 x.x.x → ERR_PROXY_CONNECTION_FAILED）
      routes: buildVpnRoutes(s.ipv6),
      blockedApplications: blocked,
      isIPv6Accepted: s.ipv6
    };
    // 仅白名单模式且名单非空时才下发 trustedApplications；
    // 空数组会被系统当作有效配置，干扰 excluded 路由（实证：:vpn 进程直连被断）
    if (trusted.length > 0) {
      vpnConfig.trustedApplications = trusted;
    }
    const params: Record<string, Object> = { 'VPN_CONFIG': vpnConfig };
    const connectWant: Want = {
      bundleName: want.bundleName,
      abilityName: want.abilityName,
      parameters: params
    };
    try {
      serviceId = context.connectServiceExtensionAbility(connectWant, {
        onConnect: () => {
          Logger.info(TAG, 'service connected');
          lastStartError = '';
          setStatus(VpnStatus.Connected);
          // 会话曾连接标记：供冷启动自动恢复判定（仅用户主动断开时清 false）
          const s = Settings.load(context);
          s.vpnWasConnected = true;
          Settings.save(context, s);
        },
        onDisconnect: () => {
          Logger.warn(TAG, 'service disconnected unexpectedly');
          lastStartError = readLastStartError(context);
          setStatus(VpnStatus.Disconnected);
        },
        onFailed: (code: number) => {
          Logger.error(TAG, `service connect failed: ${code}`);
          lastStartError = readLastStartError(context);
          setStatus(VpnStatus.Disconnected);
        }
      });
    } catch (e) {
      Logger.error(TAG, `connectServiceExtensionAbility threw: ${JSON.stringify(e)}`);
      setStatus(VpnStatus.Disconnected);
    }
  }

  export function stop(context: common.UIAbilityContext): void {
    if (status !== VpnStatus.Connected && status !== VpnStatus.Connecting) {
      Logger.warn(TAG, `stop ignored, status=${VpnStatus[status]}`);
      return;
    }
    // 用户主动停止：清除「会话曾连接」标记（冷启动不再自动恢复）
    const s = Settings.load(context);
    s.vpnWasConnected = false;
    Settings.save(context, s);
    // 用户主动停止：清除残留失败信息，避免断开回调误报
    lastStartError = '';
    setStatus(VpnStatus.Disconnecting);
    const want: Want = { bundleName: context.applicationInfo.name, abilityName: VPN_ABILITY_NAME };
    if (serviceId > 0) {
      context.disconnectServiceExtensionAbility(serviceId).catch((e: Object) => {
        Logger.error(TAG, `disconnectServiceExtensionAbility failed: ${JSON.stringify(e)}`);
      }).finally(() => {
        vpnExtension.stopVpnExtensionAbility(want);
        serviceId = 0;
        setStatus(VpnStatus.Disconnected);
      });
    } else {
      vpnExtension.stopVpnExtensionAbility(want);
      setStatus(VpnStatus.Disconnected);
    }
  }
}
