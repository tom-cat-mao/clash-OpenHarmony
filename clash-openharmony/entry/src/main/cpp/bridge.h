/*
 * bridge.h - NAPI 与 libmihomo.so（Go c-shared 内核）的桥接层接口
 *
 * 线程模型与鸿蒙 TLS 约束详见 bridge.cpp 头部注释。
 */
#ifndef CLASHOH_BRIDGE_H
#define CLASHOH_BRIDGE_H

#include <string>

namespace bridge {

struct Status {
    bool loaded;          // libmihomo.so 是否已加载
    std::string libPath;  // 库路径（dlopen 名称）
    std::string lastError;
    long long callCount;
    long long failCount;
};

// 以下三个函数都经专用 worker 线程进入 Go（鸿蒙 musl 主线程 TLS 布局不同，
// 主线程直进 Go c-shared 会 SIGSEGV）。返回错误串，空串 = 成功。
std::string Init(const std::string &homeDir);
std::string StartTun(int fd, const std::string &configJson, const std::string &overridesJson);
void Stop();
Status GetStatus();

} // namespace bridge

#endif
