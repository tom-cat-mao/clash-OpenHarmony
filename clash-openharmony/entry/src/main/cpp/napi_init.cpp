/*
 * napi_init.cpp - NAPI 模块入口，向 ArkTS 暴露内核桥接接口（libentry.so）
 *
 * 导出函数:
 *   initCore(homeDir: string) -> Promise<string>    初始化，resolve 错误串或空串
 *   startTun(fd: number, configJson: string, overridesJson?: string) -> Promise<string>
 *   stopCore() -> Promise<void>
 *   getBridgeStatus() -> BridgeStatus
 *
 * 安全说明: 所有进 Go 的调用最终都进入 bridge 的专用 worker 线程，与调用线程
 * 无关，因此经 napi async work 在任何线程发起都是安全的（鸿蒙 musl TLS 限制）。
 */
#include "napi/native_api.h"
#include "bridge.h"
#include "vpn_log.h"

#include <string>

namespace {

struct CoreContext {
    napi_async_work work = nullptr;
    napi_deferred deferred = nullptr;
    // init / startTun 共用：错误串（空 = 成功）
    std::string err;
    // startTun 参数
    int fd = -1;
    std::string homeDir;
    std::string configJson;
    std::string overridesJson; // 用户设置覆写（JSON，可为空串，兼容两参调用）
    // 操作类型
    int op = 0; // 0=init, 1=startTun, 2=stop
};

bool GetStringArg(napi_env env, napi_value arg, std::string &out) {
    size_t len = 0;
    if (napi_get_value_string_utf8(env, arg, nullptr, 0, &len) != napi_ok) {
        return false;
    }
    out.resize(len + 1);
    size_t copied = 0;
    if (napi_get_value_string_utf8(env, arg, &out[0], len + 1, &copied) != napi_ok) {
        return false;
    }
    out.resize(copied);
    return true;
}

void CoreExecute(napi_env env, void *data) {
    auto *ctx = static_cast<CoreContext *>(data);
    switch (ctx->op) {
        case 0:
            ctx->err = bridge::Init(ctx->homeDir);
            break;
        case 1:
            ctx->err = bridge::StartTun(ctx->fd, ctx->configJson, ctx->overridesJson);
            break;
        case 2:
            bridge::Stop();
            break;
    }
}

void CoreComplete(napi_env env, napi_status status, void *data) {
    auto *ctx = static_cast<CoreContext *>(data);
    napi_value result;
    if (ctx->op == 2) {
        napi_get_undefined(env, &result);
    } else {
        napi_create_string_utf8(env, ctx->err.c_str(), ctx->err.size(), &result);
    }
    napi_resolve_deferred(env, ctx->deferred, result);
    napi_delete_async_work(env, ctx->work);
    delete ctx;
}

napi_value InitCore(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, "BAD_PARAMS", "initCore(homeDir) requires 1 argument");
        return nullptr;
    }
    auto *ctx = new CoreContext();
    ctx->op = 0;
    if (!GetStringArg(env, args[0], ctx->homeDir)) {
        delete ctx;
        napi_throw_error(env, "BAD_PARAMS", "homeDir must be a string");
        return nullptr;
    }
    napi_value resourceName;
    napi_create_string_utf8(env, "CoreInit", NAPI_AUTO_LENGTH, &resourceName);
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_create_async_work(env, nullptr, resourceName, CoreExecute, CoreComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value StartTun(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, "BAD_PARAMS", "startTun(fd, configJson[, overridesJson]) requires 2 or 3 arguments");
        return nullptr;
    }
    auto *ctx = new CoreContext();
    ctx->op = 1;
    int64_t fd = -1;
    if (napi_get_value_int64(env, args[0], &fd) != napi_ok || fd <= 0) {
        delete ctx;
        napi_throw_error(env, "BAD_PARAMS", "fd must be a positive number");
        return nullptr;
    }
    ctx->fd = static_cast<int>(fd);
    if (!GetStringArg(env, args[1], ctx->configJson)) {
        delete ctx;
        napi_throw_error(env, "BAD_PARAMS", "configJson must be a string");
        return nullptr;
    }
    // 第三参可选（缺省空串），兼容旧的两参调用
    if (argc >= 3) {
        napi_valuetype t;
        if (napi_typeof(env, args[2], &t) == napi_ok && t == napi_string) {
            if (!GetStringArg(env, args[2], ctx->overridesJson)) {
                delete ctx;
                napi_throw_error(env, "BAD_PARAMS", "overridesJson must be a string");
                return nullptr;
            }
        }
    }
    napi_value resourceName;
    napi_create_string_utf8(env, "CoreStartTun", NAPI_AUTO_LENGTH, &resourceName);
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_create_async_work(env, nullptr, resourceName, CoreExecute, CoreComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value StopCore(napi_env env, napi_callback_info info) {
    auto *ctx = new CoreContext();
    ctx->op = 2;
    napi_value resourceName;
    napi_create_string_utf8(env, "CoreStop", NAPI_AUTO_LENGTH, &resourceName);
    napi_value promise;
    napi_create_promise(env, &ctx->deferred, &promise);
    napi_create_async_work(env, nullptr, resourceName, CoreExecute, CoreComplete, ctx, &ctx->work);
    napi_queue_async_work(env, ctx->work);
    return promise;
}

napi_value GetBridgeStatus(napi_env env, napi_callback_info info) {
    bridge::Status st = bridge::GetStatus();
    napi_value obj;
    napi_create_object(env, &obj);
    napi_value v;
    napi_get_boolean(env, st.loaded, &v);
    napi_set_named_property(env, obj, "loaded", v);
    napi_create_string_utf8(env, st.libPath.c_str(), NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, obj, "libPath", v);
    napi_create_string_utf8(env, st.lastError.c_str(), NAPI_AUTO_LENGTH, &v);
    napi_set_named_property(env, obj, "lastError", v);
    napi_create_int64(env, st.callCount, &v);
    napi_set_named_property(env, obj, "callCount", v);
    napi_create_int64(env, st.failCount, &v);
    napi_set_named_property(env, obj, "failCount", v);
    return obj;
}

EXTERN_C_START
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"initCore", nullptr, InitCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startTun", nullptr, StartTun, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stopCore", nullptr, StopCore, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBridgeStatus", nullptr, GetBridgeStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    VPN_LOGI("clashoh core bridge napi module registered");
    return exports;
}
EXTERN_C_END

napi_module clashohBridgeModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "entry",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterEntryModule(void) {
    napi_module_register(&clashohBridgeModule);
}

} // namespace
