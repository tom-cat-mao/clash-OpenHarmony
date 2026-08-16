/*
 * ConfigParser.ets - 内核未启动时本地解析 mihomo YAML 配置（代理页/首页兜底数据源）
 *
 * 背景：代理数据此前只来自内核 REST（/proxies），内核没启动时代理 Tab 什么都看不到，
 *       即使激活了订阅配置也一样。本模块把激活配置里的 proxies / proxy-groups 解析成
 *       与 CoreApi.getProxies() 兼容的 Record<string, ProxyInfo>，让页面在内核离线时
 *       也能展示分组与节点（history 恒为空，延迟一律 0=未测）。
 *
 * 只解析展示所需的最小字段，兼容两种常见写法：
 *  - proxies 内联 map：- {name: "HK 01", type: ss, server: ...}
 *  - proxies 块状：    - name: HK 01
 *                        type: ss
 *  - 组内联列表：      proxies: [DIRECT, REJECT, ⚡ 自动选择]
 *  - 组块状列表：      proxies:
 *                        - 节点A
 *                        - 节点B
 *  - use: [provider] 与 include-all-proxies: true 均支持（provider 内容内核运行时才知道，
 *    本地以 provider 名占位，type 记为 Provider）。
 * 同时合成 mihomo 内置节点 DIRECT/REJECT 与内置的 GLOBAL 选择组（配置里没显式定义时）。
 * 局限：不解析 rules / dns / 各协议参数，也不校验 YAML 深层结构；解析失败静默跳过对应条目。
 */
import { ProxyInfo } from './CoreApi';

export interface ParsedConfig {
  mode: string;
  proxies: Record<string, ProxyInfo>;
  /** 分组名按配置文件出现顺序（用于恢复内核 REST 丢失的配置顺序） */
  groupOrder: string[];
}

interface LocalProxy {
  name: string;
  type: string;
}

interface LocalGroup {
  name: string;
  type: string;
  all: string[];
  includeAll: boolean;
}

/** name/type 成对收集器（fillFromBlock 填充） */
class NameType {
  name: string = '';
  type: string = '';
}

/** 归一化组/内置类型（YAML 里是小写 kebab，REST 里是大写驼峰） */
function normType(t: string): string {
  const map: Record<string, string> = {
    'select': 'Selector',
    'url-test': 'URLTest',
    'fallback': 'Fallback',
    'load-balance': 'LoadBalance',
    'relay': 'Relay',
    'direct': 'Direct',
    'reject': 'Reject',
    'compatible': 'Compatible',
    'pass': 'Pass'
  };
  return map[t.toLowerCase()] ?? t;
}

function indentOf(line: string): number {
  let i = 0;
  while (i < line.length && line.charAt(i) === ' ') {
    i++;
  }
  return i;
}

function isComment(line: string): boolean {
  const t = line.trim();
  return t.length === 0 || t.startsWith('#');
}

/** 去首尾空白与包裹引号 */
function cleanValue(s: string): string {
  let t = s.trim();
  if (t.length >= 2 && ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'")))) {
    t = t.substring(1, t.length - 1);
  }
  return t;
}

/** `key: value` 行取 value（行首必须就是该 key，未命中返回 null） */
function fieldValue(line: string, key: string): string | null {
  const t = line.trim();
  if (!t.startsWith(key + ':')) {
    return null;
  }
  return cleanValue(t.substring(key.length + 1));
}

/**
 * 内联 map（{...}）中取 key 的值。前置锚点限定 key 前只能是 { 或 ,（避免嵌套
 * map 里的同名键误命中）；值支持双引号/单引号/无引号标量。
 */
function inlineField(text: string, key: string): string | null {
  const anchor = '(?:^\\s*\\{\\s*|,\\s*)';
  let re = new RegExp(anchor + key + '\\s*:\\s*"([^"]*)"');
  let m = re.exec(text);
  if (m !== null) {
    return m[1];
  }
  re = new RegExp(anchor + key + '\\s*:\\s*\'([^\']*)\'');
  m = re.exec(text);
  if (m !== null) {
    return m[1];
  }
  re = new RegExp(anchor + key + '\\s*:\\s*([^,\'{}\\n]+)');
  m = re.exec(text);
  if (m !== null) {
    return m[1].trim();
  }
  return null;
}

/** 内联列表字段：proxies: [a, b] / use: [p1, p2]（键名足够特异，无需锚点） */
function inlineListField(text: string, key: string): string[] {
  const re = new RegExp(key + '\\s*:\\s*\\[([^\\]]*)\\]');
  const m = re.exec(text);
  if (m === null) {
    return [];
  }
  const out: string[] = [];
  const parts = m[1].split(',');
  for (const p of parts) {
    const v = cleanValue(p);
    if (v.length > 0) {
      out.push(v);
    }
  }
  return out;
}

/** 内联布尔字段：include-all-proxies: true */
function inlineBoolField(text: string, key: string): boolean {
  const re = new RegExp(key + '\\s*:\\s*(true|false)');
  const m = re.exec(text);
  return m !== null && m[1] === 'true';
}

/** 段内条目切分：按列表项行（统一缩进的 '- ' 开头）切成条目行块（含其字段行） */
function splitEntries(lines: string[], start: number, end: number): string[][] {
  const entries: string[][] = [];
  let entryIndent = -1;
  let cur: string[] | null = null;
  for (let i = start; i < end; i++) {
    const line = lines[i];
    if (isComment(line)) {
      continue;
    }
    const ind = indentOf(line);
    const t = line.substring(ind).trim();
    const isEntry = t.startsWith('-');
    if (isEntry && entryIndent < 0) {
      entryIndent = ind;
    }
    if (isEntry && ind === entryIndent) {
      if (cur !== null) {
        entries.push(cur);
      }
      cur = [line];
    } else if (cur !== null && ind > entryIndent) {
      cur.push(line);
    }
  }
  if (cur !== null) {
    entries.push(cur);
  }
  return entries;
}

/** 条目行块里逐行补 name/type（块状写法缺字段时） */
function fillFromBlock(block: string[], entryIndent: number, nt: NameType): void {
  for (const line of block) {
    if (indentOf(line) <= entryIndent) {
      continue;
    }
    if (nt.name.length === 0) {
      const v = fieldValue(line, 'name');
      if (v !== null) {
        nt.name = v;
      }
    }
    if (nt.type.length === 0) {
      const v = fieldValue(line, 'type');
      if (v !== null) {
        nt.type = v;
      }
    }
    if (nt.name.length > 0 && nt.type.length > 0) {
      break;
    }
  }
}

export namespace ConfigParser {

  /** 定位顶层段落：返回段落起始行（缩进 0 的 'xxx:' 行），不存在返回 -1 */
  function sectionStart(lines: string[], key: string): number {
    for (let i = 0; i < lines.length; i++) {
      if (isComment(lines[i])) {
        continue;
      }
      if (indentOf(lines[i]) === 0 && lines[i].trim() === key + ':') {
        return i;
      }
    }
    return -1;
  }

  /** 解析 proxies 段条目（仅 name/type） */
  function parseProxies(lines: string[], start: number, end: number): LocalProxy[] {
    const out: LocalProxy[] = [];
    const blocks = splitEntries(lines, start, end);
    for (const block of blocks) {
      const nt = new NameType();
      const entryIndent = indentOf(block[0]);
      const rest = block[0].substring(entryIndent).trim().substring(1).trim();
      const braceIdx = rest.indexOf('{');
      if (braceIdx >= 0) {
        // 内联 map（可能带 &anchor 前缀）
        const mapText = rest.substring(braceIdx);
        nt.name = inlineField(mapText, 'name') ?? '';
        nt.type = inlineField(mapText, 'type') ?? '';
      } else if (rest.startsWith('name:')) {
        nt.name = fieldValue(rest, 'name') ?? '';
      }
      fillFromBlock(block, entryIndent, nt);
      if (nt.name.length === 0 || nt.type.length === 0) {
        continue; // YAML 锚点别名等无法本地解析的条目：跳过
      }
      out.push({ name: nt.name, type: nt.type });
    }
    return out;
  }

  /** 解析 proxy-groups 段条目 */
  function parseGroups(lines: string[], start: number, end: number): LocalGroup[] {
    const out: LocalGroup[] = [];
    const blocks = splitEntries(lines, start, end);
    for (const block of blocks) {
      const nt = new NameType();
      let all: string[] = [];
      let includeAll = false;
      const entryIndent = indentOf(block[0]);
      const rest = block[0].substring(entryIndent).trim().substring(1).trim();
      const braceIdx = rest.indexOf('{');
      if (braceIdx >= 0) {
        const mapText = rest.substring(braceIdx);
        nt.name = inlineField(mapText, 'name') ?? '';
        nt.type = inlineField(mapText, 'type') ?? '';
        all = inlineListField(mapText, 'proxies');
        includeAll = inlineBoolField(mapText, 'include-all-proxies');
        const use = inlineListField(mapText, 'use');
        for (const u of use) {
          if (all.indexOf(u) < 0) {
            all.push(u);
          }
        }
      } else if (rest.startsWith('name:')) {
        nt.name = fieldValue(rest, 'name') ?? '';
      }
      fillFromBlock(block, entryIndent, nt);
      if (nt.name.length === 0 || nt.type.length === 0) {
        continue;
      }
      // 块状字段扫描：include-all-proxies、proxies/use 的块状列表
      for (let k = 1; k < block.length; k++) {
        const line = block[k];
        if (isComment(line)) {
          continue;
        }
        const ind = indentOf(line);
        if (ind <= entryIndent) {
          continue;
        }
        const t = line.trim();
        const iav = fieldValue(line, 'include-all-proxies');
        if (iav !== null && iav === 'true') {
          includeAll = true;
          continue;
        }
        if (t.startsWith('proxies:') || t.startsWith('use:')) {
          const isUse = t.startsWith('use:');
          const inlineItems = inlineListField(t, isUse ? 'use' : 'proxies');
          if (inlineItems.length > 0) {
            for (const item of inlineItems) {
              if (all.indexOf(item) < 0) {
                all.push(item);
              }
            }
          } else {
            // 块状列表：收集更深缩进的 '- item'
            const fieldIndent = ind;
            for (let j = k + 1; j < block.length; j++) {
              const il = block[j];
              if (isComment(il)) {
                continue;
              }
              const iind = indentOf(il);
              if (iind <= fieldIndent) {
                break;
              }
              const it = il.substring(iind).trim();
              if (it.startsWith('-')) {
                const v = cleanValue(it.substring(1));
                if (v.length > 0 && all.indexOf(v) < 0) {
                  all.push(v);
                }
              }
            }
          }
        }
      }
      out.push({ name: nt.name, type: nt.type, all: all, includeAll: includeAll });
    }
    return out;
  }

  /** 入口：解析配置文本 -> 与 REST /proxies 兼容的 map + mode + 配置顺序 */
  export function parse(content: string): ParsedConfig {
    const result: ParsedConfig = { mode: 'rule', proxies: {}, groupOrder: [] };
    if (content.length === 0) {
      return result;
    }
    const lines = content.split('\n');
    const n = lines.length;

    // 顶层 mode（缩进 0 的 'mode:' 行）
    for (let i = 0; i < n; i++) {
      if (isComment(lines[i]) || indentOf(lines[i]) !== 0) {
        continue;
      }
      const v = fieldValue(lines[i], 'mode');
      if (v !== null && v.length > 0) {
        result.mode = v;
        break;
      }
    }

    const pStart = sectionStart(lines, 'proxies');
    const gStart = sectionStart(lines, 'proxy-groups');
    // 段落边界：以先出现的另一个段落为界（两段顺序不固定）
    let pEnd = n;
    if (pStart >= 0 && gStart > pStart) {
      pEnd = gStart;
    }
    let gEnd = n;
    if (gStart >= 0 && pStart > gStart) {
      gEnd = pStart;
    }
    const proxies = pStart >= 0 ? parseProxies(lines, pStart + 1, pEnd) : [];
    const groups = gStart >= 0 ? parseGroups(lines, gStart + 1, gEnd) : [];

    const proxyNames: string[] = [];
    for (const p of proxies) {
      if (result.proxies[p.name] !== undefined) {
        continue; // 重名防御：首个生效
      }
      proxyNames.push(p.name);
      result.proxies[p.name] = {
        name: p.name,
        type: normType(p.type),
        now: '',
        all: [],
        history: [],
        udp: true
      };
    }
    // mihomo 内置节点
    const builtinNames: string[] = ['DIRECT', 'REJECT'];
    const builtinTypes: Record<string, string> = { 'DIRECT': 'Direct', 'REJECT': 'Reject' };
    for (const b of builtinNames) {
      if (result.proxies[b] === undefined) {
        result.proxies[b] = {
          name: b,
          type: builtinTypes[b] ?? b,
          now: '',
          all: [],
          history: [],
          udp: false
        };
      }
    }

    // 组名先收集：组内成员引用另一组（子组）时不能被误判为 provider 占位；
    // 同时保留配置文件中的出现顺序（内核 REST 的 map 序列化按字典序，顺序在此恢复）
    const groupNames: string[] = [];
    for (const g of groups) {
      groupNames.push(g.name);
    }
    result.groupOrder = groupNames.slice();

    // provider 名占位（use 引用的具体节点内核运行时才有；排除组名）
    const providerNames: string[] = [];
    for (const g of groups) {
      for (const m of g.all) {
        if (m.length > 0 && result.proxies[m] === undefined && groupNames.indexOf(m) < 0) {
          result.proxies[m] = { name: m, type: 'Provider', now: '', all: [], history: [], udp: false };
          providerNames.push(m);
        }
      }
    }

    for (const g of groups) {
      const members: string[] = [];
      for (const m of g.all) {
        if (members.indexOf(m) < 0) {
          members.push(m);
        }
      }
      if (g.includeAll) {
        for (const pn of proxyNames) {
          if (members.indexOf(pn) < 0) {
            members.push(pn);
          }
        }
        for (const pn of providerNames) {
          if (members.indexOf(pn) < 0) {
            members.push(pn);
          }
        }
      }
      result.proxies[g.name] = {
        name: g.name,
        type: normType(g.type),
        now: members.length > 0 ? members[0] : '',
        all: members,
        history: [],
        udp: false
      };
    }

    // mihomo 内置 GLOBAL 选择组（配置未显式定义时合成；COMPATIBLE 不含 Pass/PassRule）
    if (groupNames.indexOf('GLOBAL') < 0) {
      const all: string[] = [];
      for (const pn of proxyNames) {
        all.push(pn);
      }
      for (const gn of groupNames) {
        all.push(gn);
      }
      for (const b of builtinNames) {
        all.push(b);
      }
      result.proxies['GLOBAL'] = {
        name: 'GLOBAL',
        type: 'Selector',
        now: all.length > 0 ? all[0] : '',
        all: all,
        history: [],
        udp: false
      };
    }
    return result;
  }
}
