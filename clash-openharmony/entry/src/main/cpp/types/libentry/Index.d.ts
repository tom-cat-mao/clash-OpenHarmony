export interface BridgeStatus {
  loaded: boolean;
  libPath: string;
  lastError: string;
  callCount: number;
  failCount: number;
}

/**
 * 初始化 mihomo 内核（homeDir 为应用 filesDir）。
 * resolve 值为错误串，空串表示成功。
 */
export const initCore: (homeDir: string) => Promise<string>;

/**
 * 用系统下发的 tun fd 启动内核（configJson 为最小 mihomo 配置，JSON 格式；
 * overridesJson 为用户设置覆写，JSON 格式，可选）。
 * resolve 值为错误串，空串表示成功。
 */
export const startTun: (fd: number, configJson: string, overridesJson?: string) => Promise<string>;

/** 停止内核（关 TUN 与全部 listener）。 */
export const stopCore: () => Promise<void>;

/** 桥接层状态（库是否加载、调用计数等）。 */
export const getBridgeStatus: () => BridgeStatus;
