/*
 * ProfileStore.ets - 配置（订阅）存储
 * 存放于 filesDir/profiles/*.yaml，active.txt 记录当前激活文件名。
 * 主进程下载订阅（本应用已被加入 VPN blockedApplications，走直连）。
 */
import { fileIo } from '@kit.CoreFileKit';
import { http } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Logger } from './Logger';

const TAG = 'profileStore';
const ACTIVE_FILE = 'active.txt';
const META_FILE = 'meta.json';

export interface ProfileMeta {
  file: string;
  name: string;
  size: number;
  mtime: number;
  active: boolean;
}

/** 订阅流量信息（来自 HTTP 响应头 subscription-userinfo） */
export interface SubInfo {
  upload: number;
  download: number;
  total: number;
  expire: number;
}

/** 侧车 meta.json 中单个 profile 的扩展信息 */
export interface ProfileMetaExt {
  origin: string;
  sub: SubInfo;
  updatedAt: number;
}

export namespace ProfileStore {

  function dir(context: common.Context): string {
    return `${context.filesDir}/profiles`;
  }

  function ensureDir(context: common.Context): string {
    const d = dir(context);
    if (!fileIo.accessSync(d)) {
      fileIo.mkdirSync(d, true);
    }
    return d;
  }

  function activePath(context: common.Context): string {
    return `${ensureDir(context)}/${ACTIVE_FILE}`;
  }

  function metaPath(context: common.Context): string {
    return `${ensureDir(context)}/${META_FILE}`;
  }

  /** 读取侧车 meta.json；文件不存在或解析失败返回 {} */
  export function getMeta(context: common.Context): Record<string, ProfileMetaExt> {
    try {
      const p = metaPath(context);
      if (!fileIo.accessSync(p)) {
        return {};
      }
      const raw = fileIo.readTextSync(p);
      if (raw.trim().length === 0) {
        return {};
      }
      return JSON.parse(raw) as Record<string, ProfileMetaExt>;
    } catch (e) {
      Logger.warn(TAG, `getMeta failed: ${JSON.stringify(e)}`);
      return {};
    }
  }

  function writeMeta(context: common.Context, all: Record<string, ProfileMetaExt>): void {
    const p = metaPath(context);
    const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, JSON.stringify(all));
    fileIo.closeSync(f);
  }

  /** 写入/覆盖单个 profile 的 meta 条目 */
  export function setMetaEntry(context: common.Context, file: string, entry: ProfileMetaExt): void {
    try {
      const all = getMeta(context);
      all[file] = entry;
      writeMeta(context, all);
    } catch (e) {
      Logger.warn(TAG, `setMetaEntry ${file} failed: ${JSON.stringify(e)}`);
    }
  }

  /** 删除单个 profile 的 meta 条目（ArkTS 不支持 delete 运算符，重建对象） */
  export function deleteMetaEntry(context: common.Context, file: string): void {
    try {
      const all = getMeta(context);
      if (all[file] === undefined) {
        return;
      }
      const next: Record<string, ProfileMetaExt> = {};
      const keys = Object.keys(all);
      for (const k of keys) {
        if (k !== file) {
          next[k] = all[k];
        }
      }
      writeMeta(context, next);
    } catch (e) {
      Logger.warn(TAG, `deleteMetaEntry ${file} failed: ${JSON.stringify(e)}`);
    }
  }

  /** 解析 subscription-userinfo 响应头（upload=1; download=2; total=3; expire=4，字段可缺失） */
  function parseSubInfo(raw: string): SubInfo {
    const out: SubInfo = { upload: 0, download: 0, total: 0, expire: 0 };
    if (raw.length === 0) {
      return out;
    }
    const parts = raw.split(';');
    for (const part of parts) {
      const eq = part.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const k = part.substring(0, eq).trim();
      const v = Number(part.substring(eq + 1).trim());
      // !(v >= 0) 同时命中 NaN（转换失败）与负数
      if (!(v >= 0)) {
        continue;
      }
      if (k === 'upload') {
        out.upload = v;
      } else if (k === 'download') {
        out.download = v;
      } else if (k === 'total') {
        out.total = v;
      } else if (k === 'expire') {
        out.expire = v;
      }
    }
    return out;
  }

  /** 从 HTTP 响应构造 meta 条目（头键名为小写 subscription-userinfo） */
  function metaEntryFromResp(resp: http.HttpResponse, url: string): ProfileMetaExt {
    let raw = '';
    try {
      const headers = resp.header as Record<string, Object>;
      const v = headers['subscription-userinfo'];
      raw = typeof v === 'string' ? v : '';
    } catch (e) {
      // 无该头，忽略
    }
    return {
      origin: url,
      sub: parseSubInfo(raw),
      updatedAt: Math.floor(Date.now() / 1000)
    };
  }

  export function list(context: common.Context): ProfileMeta[] {
    const d = ensureDir(context);
    const active = getActiveFile(context);
    const out: ProfileMeta[] = [];
    try {
      const names = fileIo.listFileSync(d);
      for (const name of names) {
        if (name === ACTIVE_FILE || (!name.endsWith('.yaml') && !name.endsWith('.yml'))) {
          continue;
        }
        try {
          const st = fileIo.statSync(`${d}/${name}`);
          out.push({
            file: name,
            name: name.replace(/\.(yaml|yml)$/, ''),
            size: st.size,
            mtime: st.mtime,
            active: name === active
          });
        } catch (e) {
          Logger.warn(TAG, `stat ${name} failed: ${JSON.stringify(e)}`);
        }
      }
    } catch (e) {
      Logger.warn(TAG, `listFile failed: ${JSON.stringify(e)}`);
    }
    out.sort((a, b) => b.mtime - a.mtime);
    return out;
  }

  export function getActiveFile(context: common.Context): string {
    try {
      const p = activePath(context);
      if (fileIo.accessSync(p)) {
        return fileIo.readTextSync(p).trim();
      }
    } catch (e) {
      Logger.warn(TAG, `read active failed: ${JSON.stringify(e)}`);
    }
    return '';
  }

  export function setActive(context: common.Context, file: string): void {
    try {
      const p = activePath(context);
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, file);
      fileIo.closeSync(f);
      Logger.info(TAG, `active -> ${file}`);
    } catch (e) {
      Logger.error(TAG, `setActive failed: ${JSON.stringify(e)}`);
    }
  }

  /**
   * 清洗并校验配置文本：
   * 1. 去 UTF-8 BOM
   * 2. 修复旧版导入路径（String.fromCharCode 逐字节映射）造成的 UTF-8 双重编码：
   *    原始字节 b(≥0x80) 被映射成 U+00xx 字符再按 UTF-8 落盘，其中续字节 0x80~0x9F
   *    变成 C1 控制符，内核 yaml 解析报 "control characters are not allowed"。
   *    检测到 C1 控制符且全部码点 ≤0xFF 时，把码点还原为字节并按 UTF-8 解码。
   * 3. 拒绝剩余的非法控制字符（C0 除 \t\n\r、DEL、C1），给出可读错误。
   */
  function sanitizeConfigContent(content: string): string {
    let text = content;
    if (text.charCodeAt(0) === 0xFEFF) {
      text = text.slice(1);
    }
    let hasC1 = false;
    let allLatin1 = true;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c >= 0x80 && c <= 0x9F) {
        hasC1 = true;
      }
      if (c > 0xFF) {
        allLatin1 = false;
      }
    }
    if (hasC1 && allLatin1) {
      const bytes = new Uint8Array(text.length);
      for (let i = 0; i < text.length; i++) {
        bytes[i] = text.charCodeAt(i);
      }
      const fixed = util.TextDecoder.create('utf-8').decodeToString(bytes);
      // 修复结果必须仍含配置特征才采纳，防止误修复
      if (fixed.includes('proxies:') || fixed.includes('proxy-groups:') || fixed.includes('proxy-providers:')) {
        Logger.warn(TAG, `config repaired from byte-flattened UTF-8 (${text.length} -> ${fixed.length} chars)`);
        text = fixed;
      }
    }
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if ((c < 0x20 && c !== 0x09 && c !== 0x0A && c !== 0x0D) || c === 0x7F || (c >= 0x80 && c <= 0x9F)) {
        throw new Error(`配置含非法控制字符(0x${c.toString(16)})，请确认文件为 UTF-8 编码`);
      }
    }
    return text;
  }

  /** 读取激活配置内容；无激活配置返回 null（调用方回退 rawfile/默认）。
   *  读取时执行编码修复：若文件是旧版导入的字节拍平损坏，修复后回写磁盘，
   *  保证后续 PUT /configs 按路径热加载也能解析成功。 */
  export function getActiveContent(context: common.Context): string | null {
    const file = getActiveFile(context);
    if (file.length === 0) {
      return null;
    }
    const p = `${dir(context)}/${file}`;
    try {
      if (fileIo.accessSync(p)) {
        const raw = fileIo.readTextSync(p);
        const fixed = sanitizeConfigContent(raw);
        if (fixed !== raw) {
          const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
          fileIo.writeSync(f.fd, fixed);
          fileIo.closeSync(f);
          Logger.info(TAG, `profile ${file} repaired and written back`);
        }
        return fixed;
      }
    } catch (e) {
      Logger.error(TAG, `read profile ${file} failed: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
    return null;
  }

  export function deleteProfile(context: common.Context, file: string): void {
    try {
      fileIo.unlink(`${dir(context)}/${file}`);
      deleteMetaEntry(context, file);
      try {
        fileIo.unlink(`${dir(context)}/${file}.url`);
      } catch (e) {
        // 无来源记录，忽略
      }
      if (getActiveFile(context) === file) {
        setActive(context, '');
      }
    } catch (e) {
      Logger.error(TAG, `delete ${file} failed: ${JSON.stringify(e)}`);
    }
  }

  export function absPath(context: common.Context, file: string): string {
    return `${dir(context)}/${file}`;
  }

  /** 重命名配置：自动补 .yaml 后缀，迁移 active/.url/meta 记录；返回新文件名，失败抛错 */
  export function renameProfile(context: common.Context, oldFile: string, newName: string): string {
    let target = newName.trim();
    if (target.length === 0) {
      throw new Error('名称不能为空');
    }
    if (target.includes('/') || target.includes('\\')) {
      throw new Error('名称不能包含路径分隔符');
    }
    if (!target.endsWith('.yaml') && !target.endsWith('.yml')) {
      target = `${target}.yaml`;
    }
    if (target === oldFile) {
      return oldFile;
    }
    const d = ensureDir(context);
    const oldPath = `${d}/${oldFile}`;
    const newPath = `${d}/${target}`;
    if (!fileIo.accessSync(oldPath)) {
      throw new Error('配置文件不存在');
    }
    if (fileIo.accessSync(newPath)) {
      throw new Error(`已存在同名配置：${target}`);
    }
    try {
      fileIo.moveFileSync(oldPath, newPath);
    } catch (e) {
      throw new Error(`移动文件失败: ${(e as Error).message ?? JSON.stringify(e)}`);
    }
    // 迁移 URL sidecar（updateFromOrigin 仍从 <file>.url 读来源）
    const oldUrl = `${oldPath}.url`;
    if (fileIo.accessSync(oldUrl)) {
      try {
        fileIo.moveFileSync(oldUrl, `${newPath}.url`);
      } catch (e) {
        Logger.warn(TAG, `move url sidecar failed: ${JSON.stringify(e)}`);
      }
    }
    // 迁移 meta 条目
    const entry = getMeta(context)[oldFile];
    if (entry !== undefined) {
      deleteMetaEntry(context, oldFile);
      setMetaEntry(context, target, entry);
    }
    if (getActiveFile(context) === oldFile) {
      setActive(context, target);
    }
    Logger.info(TAG, `renamed ${oldFile} -> ${target}`);
    return target;
  }

  /** 读取指定配置内容（复用 getActiveContent 的 sanitize 修复逻辑）；文件不存在返回 null */
  export function getProfileContent(context: common.Context, file: string): string | null {
    const p = `${dir(context)}/${file}`;
    try {
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const raw = fileIo.readTextSync(p);
      const fixed = sanitizeConfigContent(raw);
      if (fixed !== raw) {
        const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(f.fd, fixed);
        fileIo.closeSync(f);
        Logger.info(TAG, `profile ${file} repaired and written back`);
      }
      return fixed;
    } catch (e) {
      Logger.error(TAG, `read profile ${file} failed: ${(e as Error).message ?? JSON.stringify(e)}`);
      return null;
    }
  }

  /** 覆盖写配置（编辑页保存）：sanitize + validate，刷新 meta.updatedAt；失败抛错 */
  export function updateProfileContent(context: common.Context, file: string, content: string): void {
    const clean = sanitizeConfigContent(content);
    validateConfig(clean);
    const p = `${ensureDir(context)}/${file}`;
    const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, clean);
    fileIo.closeSync(f);
    const prev = getMeta(context)[file];
    const entry: ProfileMetaExt = {
      origin: prev !== undefined ? prev.origin : '',
      sub: prev !== undefined ? prev.sub : { upload: 0, download: 0, total: 0, expire: 0 },
      updatedAt: Math.floor(Date.now() / 1000)
    };
    setMetaEntry(context, file, entry);
    Logger.info(TAG, `profile ${file} updated (${clean.length} bytes)`);
  }

  /** 订阅来源 URL（用于“更新”），sidecar 文件 <file>.url */
  export function getOrigin(context: common.Context, file: string): string {
    try {
      const p = `${dir(context)}/${file}.url`;
      if (fileIo.accessSync(p)) {
        return fileIo.readTextSync(p).trim();
      }
    } catch (e) {
      // 忽略
    }
    return '';
  }

  function setOrigin(context: common.Context, file: string, url: string): void {
    try {
      const p = `${dir(context)}/${file}.url`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, url);
      fileIo.closeSync(f);
    } catch (e) {
      Logger.warn(TAG, `setOrigin failed: ${JSON.stringify(e)}`);
    }
  }

  /** 从 URL 导入订阅，返回保存的文件名；失败抛错 */
  export async function importFromUrl(context: common.Context, url: string): Promise<string> {
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const raw = typeof resp.result === 'string' ? resp.result : '';
      const content = sanitizeConfigContent(raw);
      validateConfig(content);
      const name = suggestName(url);
      const saved = save(context, name, content);
      setOrigin(context, saved, url);
      setMetaEntry(context, saved, metaEntryFromResp(resp, url));
      Logger.info(TAG, `imported ${name} (${content.length} bytes)`);
      return saved;
    } finally {
      req.destroy();
    }
  }

  /** 从本地文件/剪贴板内容导入；仅记录 updatedAt（origin 为空） */
  export function importContent(context: common.Context, name: string, content: string): string {
    const clean = sanitizeConfigContent(content);
    validateConfig(clean);
    const file = save(context, name, clean);
    setMetaEntry(context, file, {
      origin: '',
      sub: { upload: 0, download: 0, total: 0, expire: 0 },
      updatedAt: Math.floor(Date.now() / 1000)
    });
    return file;
  }

  /** 按来源 URL 重新下载并覆盖原文件 */
  export async function updateFromOrigin(context: common.Context, file: string): Promise<void> {
    const url = getOrigin(context, file);
    if (url.length === 0) {
      throw new Error('该配置无订阅来源（本地导入）');
    }
    const req = http.createHttp();
    try {
      const resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 15000,
        readTimeout: 30000
      });
      if (resp.responseCode !== 200) {
        throw new Error(`HTTP ${resp.responseCode}`);
      }
      const raw = typeof resp.result === 'string' ? resp.result : '';
      const content = sanitizeConfigContent(raw);
      validateConfig(content);
      const p = `${ensureDir(context)}/${file}`;
      const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(f.fd, content);
      fileIo.closeSync(f);
      setMetaEntry(context, file, metaEntryFromResp(resp, url));
    } finally {
      req.destroy();
    }
  }

  function validateConfig(content: string): void {
    if (content.length < 16) {
      throw new Error('内容为空或过短');
    }
    if (!content.includes('proxies:') && !content.includes('proxy-providers:') && !content.includes('proxy-groups:')) {
      throw new Error('不是合法的 mihomo 配置（缺少 proxies/proxy-groups）');
    }
  }

  function suggestName(url: string): string {
    try {
      const seg = url.split('?')[0].split('/').pop() ?? '';
      const clean = seg.replace(/\.(yaml|yml)$/i, '');
      if (clean.length > 0 && clean.length <= 40) {
        return clean;
      }
    } catch (e) {
      // fallthrough
    }
    return `sub_${Date.now()}`;
  }

  function save(context: common.Context, name: string, content: string): string {
    let file = name.endsWith('.yaml') ? name : `${name}.yaml`;
    // 避免路径穿越
    file = file.replace(/[\/\\]/g, '_');
    const p = `${ensureDir(context)}/${file}`;
    const f = fileIo.openSync(p, fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(f.fd, content);
    fileIo.closeSync(f);
    return file;
  }
}
