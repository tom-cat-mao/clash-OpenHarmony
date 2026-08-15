/*
 * bridge.cpp - ArkTS(NAPI) 与 Go c-shared 内核库(libmihomo.so) 的桥接层
 *
 * 职责:
 *   1. 延迟加载 libmihomo.so (dlopen), 解析 mihomoInit/mihomoStartTun/mihomoStop 符号
 *   2. 所有进 Go 的调用均在专用 worker 线程上执行
 *      [关键] 鸿蒙 musl 主线程 TLS 布局与 pthread_create 线程不同, Go runtime 的
 *      inittls 探测的 TLS 偏移只对标准 pthread 线程有效; 在主线程直接进入 Go
 *      会读到错误的 g 导致 SIGSEGV, 因此必须经 worker 线程
 *   3. 调用串行化: Go 侧内核非并发安全, 单 worker 天然保证串行
 *   4. 启动时将 stderr 重定向到文件, 捕获 Go runtime 的致命错误输出
 *
 * 线程模型:
 *   调用方(napi async work) -> 队列 -> 单个 worker pthread -> mihomo*()
 *   调用方阻塞等待结果(condvar), 异步语义由 napi async work 提供
 */
#include "bridge.h"
#include "vpn_log.h"

#include <dlfcn.h>
#include <pthread.h>
#include <chrono>
#include <condition_variable>
#include <deque>
#include <fcntl.h>
#include <memory>
#include <mutex>
#include <unistd.h>

namespace bridge {

typedef char *(*MihomoInitFn)(const char *);
typedef char *(*MihomoStartTunFn)(int, const char *, const char *);
typedef void (*MihomoStopFn)();
typedef void (*MihomoFreeFn)(char *);

static void *gHandle = nullptr;
static MihomoInitFn gInit = nullptr;
static MihomoStartTunFn gStartTun = nullptr;
static MihomoStopFn gStop = nullptr;
static MihomoFreeFn gFree = nullptr;
static std::mutex gMutex;
static Status gStatus = {false, "libmihomo.so", "", 0, 0};
static bool gStderrRedirected = false;

enum class Op { Init, StartTun, Stop };

struct Job {
    Op op;
    int fd = -1;
    std::string arg;       // homeDir / configJson
    std::string overrides; // 用户设置覆写（JSON，可为空串）
    std::string result;
    bool done = false;
    std::condition_variable cv;
};

static std::mutex gQueueMutex;
static std::condition_variable gQueueCv;
static std::deque<std::shared_ptr<Job>> gQueue;
static pthread_t gWorker;
static bool gWorkerStarted = false;

static void redirectStderrOnce() {
    if (gStderrRedirected) {
        return;
    }
    gStderrRedirected = true;
    const char *path = "/data/storage/el2/base/haps/entry/files/go_stderr.log";
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        VPN_LOGW("stderr redirect open failed: %{public}d", errno);
        return;
    }
    if (dup2(fd, STDERR_FILENO) < 0) {
        VPN_LOGW("stderr redirect dup2 failed: %{public}d", errno);
        close(fd);
        return;
    }
    close(fd);
    VPN_LOGI("stderr redirected to go_stderr.log");
}

static bool ensureLoaded() {
    if (gHandle != nullptr && gInit != nullptr) {
        return true;
    }
    redirectStderrOnce();
    dlerror();
    void *h = dlopen("libmihomo.so", RTLD_NOW | RTLD_GLOBAL);
    if (h == nullptr) {
        const char *err = dlerror();
        gStatus.lastError = err != nullptr ? err : "unknown dlopen error";
        gStatus.loaded = false;
        VPN_LOGE("dlopen libmihomo.so failed: %{public}s", gStatus.lastError.c_str());
        return false;
    }
    gInit = reinterpret_cast<MihomoInitFn>(dlsym(h, "mihomoInit"));
    gStartTun = reinterpret_cast<MihomoStartTunFn>(dlsym(h, "mihomoStartTun"));
    gStop = reinterpret_cast<MihomoStopFn>(dlsym(h, "mihomoStop"));
    gFree = reinterpret_cast<MihomoFreeFn>(dlsym(h, "mihomoFree"));
    if (gInit == nullptr || gStartTun == nullptr || gStop == nullptr || gFree == nullptr) {
        const char *err = dlerror();
        gStatus.lastError = std::string("dlsym failed: ") + (err != nullptr ? err : "symbol not found");
        gStatus.loaded = false;
        dlclose(h);
        gHandle = nullptr;
        VPN_LOGE("%{public}s", gStatus.lastError.c_str());
        return false;
    }
    gHandle = h;
    gStatus.loaded = true;
    gStatus.lastError = "";
    VPN_LOGI("libmihomo.so loaded");
    return true;
}

static void *workerMain(void *) {
    VPN_LOGI("bridge worker thread started");
    while (true) {
        std::shared_ptr<Job> job;
        {
            std::unique_lock<std::mutex> lock(gQueueMutex);
            gQueueCv.wait(lock, [] { return !gQueue.empty(); });
            job = gQueue.front();
            gQueue.pop_front();
        }
        switch (job->op) {
            case Op::Init: {
                char *raw = gInit(job->arg.c_str());
                if (raw != nullptr) {
                    job->result = raw;
                    gFree(raw);
                }
                break;
            }
            case Op::StartTun: {
                char *raw = gStartTun(job->fd, job->arg.c_str(), job->overrides.c_str());
                if (raw != nullptr) {
                    job->result = raw;
                    gFree(raw);
                }
                break;
            }
            case Op::Stop: {
                gStop();
                break;
            }
        }
        {
            std::lock_guard<std::mutex> lock(gQueueMutex);
            job->done = true;
        }
        job->cv.notify_all();
    }
    return nullptr;
}

static bool ensureWorker() {
    std::lock_guard<std::mutex> lock(gMutex);
    if (gWorkerStarted) {
        return true;
    }
    if (pthread_create(&gWorker, nullptr, workerMain, nullptr) != 0) {
        gStatus.lastError = "pthread_create failed";
        VPN_LOGE("bridge worker pthread_create failed");
        return false;
    }
    pthread_detach(gWorker);
    gWorkerStarted = true;
    return true;
}

// submit - 入队并阻塞等待 worker 执行完成
static std::string submit(const std::shared_ptr<Job> &job) {
    {
        std::lock_guard<std::mutex> lock(gMutex);
        if (!ensureLoaded()) {
            gStatus.failCount++;
            return gStatus.lastError;
        }
    }
    if (!ensureWorker()) {
        std::lock_guard<std::mutex> lock(gMutex);
        gStatus.failCount++;
        return gStatus.lastError;
    }
    {
        std::lock_guard<std::mutex> lock(gQueueMutex);
        gQueue.push_back(job);
    }
    gQueueCv.notify_one();
    {
        std::unique_lock<std::mutex> lock(gQueueMutex);
        job->cv.wait(lock, [&job] { return job->done; });
    }
    return job->result;
}

std::string Init(const std::string &homeDir) {
    auto job = std::make_shared<Job>();
    job->op = Op::Init;
    job->arg = homeDir;
    std::string err = submit(job);
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gStatus.callCount++;
        if (!err.empty()) {
            gStatus.failCount++;
        }
    }
    return err;
}

std::string StartTun(int fd, const std::string &configJson, const std::string &overridesJson) {
    // dup 一份 fd 交给 Go：Go 侧 sing_tun.Close() 会关闭它持有的 fd，
    // 而系统 VpnConnection.destroy() 会关闭原始 fd——共用同一数值会在
    // 停止时 double-close（且可能误伤被复用的描述符）
    int goFd = dup(fd);
    if (goFd < 0) {
        std::lock_guard<std::mutex> lock(gMutex);
        gStatus.failCount++;
        gStatus.lastError = "dup(tun fd) failed";
        VPN_LOGE("dup(tun fd %{public}d) failed: %{public}d", fd, errno);
        return gStatus.lastError;
    }
    auto job = std::make_shared<Job>();
    job->op = Op::StartTun;
    job->fd = goFd;
    job->arg = configJson;
    job->overrides = overridesJson;
    std::string err = submit(job);
    if (!err.empty()) {
        // Go 侧失败路径不接管 fd（sing-tun 对 FileDescriptor 直接持有、
        // New 失败也不关闭），由这里回收，避免泄漏
        close(goFd);
    }
    {
        std::lock_guard<std::mutex> lock(gMutex);
        gStatus.callCount++;
        if (!err.empty()) {
            gStatus.failCount++;
        }
    }
    return err;
}

void Stop() {
    auto job = std::make_shared<Job>();
    job->op = Op::Stop;
    submit(job); // 忽略结果，stop 无返回
}

Status GetStatus() {
    std::lock_guard<std::mutex> lock(gMutex);
    return gStatus;
}

} // namespace bridge
