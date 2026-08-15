import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0xC1A5;

export namespace Logger {
  export function info(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', msg);
  }

  export function warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
  }

  export function error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
  }
}
