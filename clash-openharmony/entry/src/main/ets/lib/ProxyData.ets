/*
 * ProxyData.ets - 代理数据统一入口（内核 REST 优先，本地配置解析兜底）
 *
 * 背景：代理页/首页此前只吃内核 REST /proxies，内核没启动时代理 Tab 一片空白。
 * 现在 load() 依次尝试：
 *  1. 内核在线：GET /proxies + GET /configs（实际 mode），source='core'；
 *  2. 内核离线：解析激活配置（ConfigParser），source='local'；
 *  3. 都没有：source='none'。
 * mode 优先级与内核启动逻辑保持一致：用户在首页显式选择过（Settings.mode 非空）>
 * 内核/配置自带 mode > 默认 rule。
 */
import { common } from '@kit.AbilityKit';
import { CoreApi, ProxyInfo } from './CoreApi';
import { ProfileStore } from './ProfileStore';
import { ConfigParser } from './ConfigParser';
import { Settings } from './Settings';

export type ProxySource = 'core' | 'local' | 'none';

export interface ProxyDataResult {
  source: ProxySource;
  mode: string; // 'rule' | 'global' | 'direct'
  proxies: Record<string, ProxyInfo>;
}

/** 页面间共享的当前模式（HomePage 同步内核/用户选择，代理页读取做 GLOBAL 过滤） */
export class ModeBus {
  static mode: string = 'rule';
}

const VALID_MODES: string[] = ['rule', 'global', 'direct'];

export namespace ProxyData {

  export async function load(context: common.Context): Promise<ProxyDataResult> {
    // 1) 内核在线：REST 数据 + /configs 实际 mode
    const proxies = await CoreApi.getProxies();
    if (proxies !== null) {
      let mode: string = ModeBus.mode;
      const cfg = await CoreApi.getConfigs();
      if (cfg !== null) {
        mode = cfg.mode;
      }
      return { source: 'core', mode: normalizeMode(mode), proxies: proxies };
    }
    // 2) 内核离线：解析激活配置
    const content = ProfileStore.getActiveContent(context);
    if (content !== null && content.length > 0) {
      const parsed = ConfigParser.parse(content);
      if (Object.keys(parsed.proxies).length > 0) {
        const s = Settings.load(context);
        const mode = s.mode.length > 0 ? s.mode : parsed.mode;
        return { source: 'local', mode: normalizeMode(mode), proxies: parsed.proxies };
      }
    }
    return { source: 'none', mode: normalizeMode(ModeBus.mode), proxies: {} };
  }

  function normalizeMode(m: string): string {
    return VALID_MODES.indexOf(m) >= 0 ? m : 'rule';
  }
}
