/*
 * CoreApi.ets - mihomo REST 控制面客户端（主进程 -> :vpn 进程 127.0.0.1:9090）
 * REST 用 http 模块；/traffic 与 /logs 是流式端点，用 WebSocket 订阅。
 * 所有方法失败返回 null/空，不抛异常（VPN 未启动时内核不在）。
 */
import { http, webSocket } from '@kit.NetworkKit';
import { Logger } from './Logger';
import { util } from '@kit.ArkTS';

const TAG = 'coreApi';
const BASE = 'http://127.0.0.1:9090';
const WS_BASE = 'ws://127.0.0.1:9090';
const TIMEOUT = 8000;

export interface DelayHistory {
  time: string;
  delay: number;
}

export interface ProxyInfo {
  name: string;
  type: string;
  now: string;
  all: string[];
  history: DelayHistory[];
  udp: boolean;
}

export interface ProxiesResp {
  proxies: Record<string, ProxyInfo>;
}

export interface ConfigsResp {
  mode: string;
  'mixed-port': number;
  'allow-lan': boolean;
  'log-level': string;
}

export interface ConnectionMetadata {
  network: string;
  type: string;
  host: string;
  destinationIP: string;
  destinationPort: string;
  sourceIP: string;
  sourcePort: string;
  process: string;
}

export interface ConnectionItem {
  id: string;
  metadata: ConnectionMetadata;
  chains: string[];
  rule: string;
  rulePayload: string;
  start: string;
  upload: number;
  download: number;
}

export interface ConnectionsResp {
  downloadTotal: number;
  uploadTotal: number;
  memory: number;
  connections: ConnectionItem[];
}

export interface TrafficMsg {
  up: number;
  down: number;
}

export interface LogMsg {
  type: string;
  payload: string;
}

export namespace CoreApi {

  async function request(method: http.RequestMethod, path: string, body?: string): Promise<string | null> {
    const req = http.createHttp();
    try {
      const resp = await req.request(BASE + path, {
        method: method,
        header: { 'Content-Type': 'application/json' },
        extraData: body,
        connectTimeout: TIMEOUT,
        readTimeout: TIMEOUT
      });
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        return typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      }
      Logger.warn(TAG, `${method} ${path} -> ${resp.responseCode}`);
      return null;
    } catch (e) {
      Logger.warn(TAG, `${method} ${path} error: ${JSON.stringify(e)}`);
      return null;
    } finally {
      req.destroy();
    }
  }

  export async function isAlive(): Promise<boolean> {
    return (await request(http.RequestMethod.GET, '/version')) !== null;
  }

  export async function getConfigs(): Promise<ConfigsResp | null> {
    const s = await request(http.RequestMethod.GET, '/configs');
    if (s === null) {
      return null;
    }
    try {
      return JSON.parse(s) as ConfigsResp;
    } catch (e) {
      return null;
    }
  }

  export async function patchMode(mode: string): Promise<boolean> {
    const s = await request(http.RequestMethod.PATCH, '/configs', JSON.stringify({ mode: mode }));
    return s !== null;
  }

  export async function getProxies(): Promise<Record<string, ProxyInfo> | null> {
    const s = await request(http.RequestMethod.GET, '/proxies');
    if (s === null) {
      return null;
    }
    try {
      return (JSON.parse(s) as ProxiesResp).proxies;
    } catch (e) {
      return null;
    }
  }

  /** 节点/分组详情：GET /proxies/{name}；失败返回 null */
  export async function getProxyDetail(name: string): Promise<ProxyInfo | null> {
    const s = await request(http.RequestMethod.GET, `/proxies/${encodeURIComponent(name)}`);
    if (s === null) {
      return null;
    }
    try {
      return JSON.parse(s) as ProxyInfo;
    } catch (e) {
      return null;
    }
  }

  export async function selectProxy(group: string, name: string): Promise<boolean> {
    const s = await request(http.RequestMethod.PUT, `/proxies/${encodeURIComponent(group)}`,
      JSON.stringify({ name: name }));
    return s !== null;
  }

  /** 返回 name->delay(ms) map；超时的节点不会出现在 map 里 */
  export async function groupDelayTest(group: string, url: string, timeout: number): Promise<Record<string, number> | null> {
    const s = await request(http.RequestMethod.GET,
      `/group/${encodeURIComponent(group)}/delay?url=${encodeURIComponent(url)}&timeout=${timeout}`);
    if (s === null) {
      return null;
    }
    try {
      return JSON.parse(s) as Record<string, number>;
    } catch (e) {
      return null;
    }
  }

  export async function nodeDelayTest(name: string, url: string, timeout: number): Promise<number> {
    const s = await request(http.RequestMethod.GET,
      `/proxies/${encodeURIComponent(name)}/delay?url=${encodeURIComponent(url)}&timeout=${timeout}`);
    if (s === null) {
      return -1;
    }
    try {
      const r = JSON.parse(s) as Record<string, number>;
      return r['delay'] ?? -1;
    } catch (e) {
      return -1;
    }
  }

  /**
   * 单次 REST 取累计流量（LiveViewKeeper 差分采样用）。
   * 注意：/traffic 是无限流式端点（mihomo 每 1s tick 持续输出，REST 单次请求永不结束），
   * 故改取 /connections 的累计总量实现同语义：up=uploadTotal, down=downloadTotal。
   */
  export async function getTraffic(): Promise<TrafficMsg | null> {
    const s = await request(http.RequestMethod.GET, '/connections');
    if (s === null) {
      return null;
    }
    try {
      const r = JSON.parse(s) as ConnectionsResp;
      const t: TrafficMsg = { up: r.uploadTotal, down: r.downloadTotal };
      return t;
    } catch (e) {
      return null;
    }
  }

  /** 出口节点延迟测速：GET /proxies/{name}/delay（gstatic 204 探针）；失败返回 null */
  export async function delayTest(name: string): Promise<number | null> {
    const s = await request(http.RequestMethod.GET,
      `/proxies/${encodeURIComponent(name)}/delay?timeout=3000&url=${encodeURIComponent('http://www.gstatic.com/generate_204')}`);
    if (s === null) {
      return null;
    }
    try {
      const r = JSON.parse(s) as Record<string, number>;
      const d = r['delay'];
      return typeof d === 'number' ? d : null;
    } catch (e) {
      return null;
    }
  }

  export async function getConnections(): Promise<ConnectionsResp | null> {
    const s = await request(http.RequestMethod.GET, '/connections');
    if (s === null) {
      return null;
    }
    try {
      return JSON.parse(s) as ConnectionsResp;
    } catch (e) {
      return null;
    }
  }

  export async function closeConnection(id: string): Promise<boolean> {
    const s = await request(http.RequestMethod.DELETE, `/connections/${encodeURIComponent(id)}`);
    return s !== null;
  }

  export async function closeAllConnections(): Promise<boolean> {
    const s = await request(http.RequestMethod.DELETE, '/connections');
    return s !== null;
  }

  export async function updateGeoDatabases(): Promise<boolean> {
    const s = await request(http.RequestMethod.POST, '/configs/geo');
    return s !== null;
  }

  /** 热切换配置：PUT /configs?force=true {"path": 绝对路径}（路径须在 mihomo homeDir 下） */
  export async function reloadConfig(absPath: string): Promise<boolean> {
    const s = await request(http.RequestMethod.PUT, '/configs?force=true', JSON.stringify({ path: absPath }));
    return s !== null;
  }

  /** 通用流订阅（/traffic /logs）：mihomo 流端点支持 WebSocket upgrade */
  export class StreamWatcher<T> {
    private ws: webSocket.WebSocket | null = null;
    private cb: (msg: T) => void = () => {};
    private path: string = '';
    private stopped: boolean = true;
    private gotFirst: boolean = false;
    private reconnectPending: boolean = false;

    start(path: string, cb: (msg: T) => void): void {
      if (!this.stopped && this.ws !== null) {
        return; // 幂等：已在运行不重复开
      }
      this.stop();
      this.stopped = false;
      this.path = path;
      this.cb = cb;
      this.connect();
    }

    private connect(): void {
      if (this.stopped) {
        return;
      }
      const ws = webSocket.createWebSocket();
      this.ws = ws;
      ws.on('open', () => {
        Logger.info(TAG, `ws open ${this.path}`);
      });
      ws.on('message', (_err: Object, value: string | ArrayBuffer) => {
        try {
          let text = '';
          if (typeof value === 'string') {
            text = value;
          } else if (value instanceof ArrayBuffer) {
            text = util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(value));
          }
          if (text.length > 0) {
            if (!this.gotFirst) {
              this.gotFirst = true;
              Logger.info(TAG, `ws first msg ${this.path}: ${text.substring(0, 80)}`);
            }
            this.cb(JSON.parse(text) as T);
          }
        } catch (e) {
          // 忽略单条坏消息
        }
      });
      const reconnect = (): void => {
        if (this.stopped || this.reconnectPending) {
          return;
        }
        this.reconnectPending = true;
        setTimeout(() => {
          this.reconnectPending = false;
          this.connect();
        }, 3000);
      };
      ws.on('close', reconnect);
      ws.on('error', (err: Object) => {
        Logger.warn(TAG, `ws error ${this.path}: ${JSON.stringify(err)}`);
        reconnect();
      });
      ws.connect(WS_BASE + this.path).catch((e: Object) => {
        Logger.warn(TAG, `ws connect failed ${this.path}: ${JSON.stringify(e)}`);
        reconnect();
      });
    }

    stop(): void {
      this.stopped = true;
      if (this.ws) {
        try {
          this.ws.off('close');
          this.ws.off('error');
          this.ws.close();
        } catch (e) {
          Logger.warn(TAG, `ws close error: ${JSON.stringify(e)}`);
        }
        this.ws = null;
      }
    }
  }
}

export function formatRate(bytesPerSec: number): string {
  if (bytesPerSec < 1024) {
    return `${bytesPerSec} B/s`;
  }
  if (bytesPerSec < 1024 * 1024) {
    return `${(bytesPerSec / 1024).toFixed(1)} KB/s`;
  }
  return `${(bytesPerSec / 1024 / 1024).toFixed(2)} MB/s`;
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`;
}
