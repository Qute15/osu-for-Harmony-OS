// M0 尖刀：验证 .NET NativeAOT 产物（Hello.so）能在 OHOS 应用进程里加载并执行托管代码。
//
// 链路：本模块（libaotsample.so）→ dlopen("Hello.so")（打进 HAP 的 libs/arm64-v8a）
//      → dlsym("ohos_hello")（[UnmanagedCallersOnly] 导出）→ 调用 → 返回 21*2+42=84 即通。
//
// Hello.so 的构建（全部在 Windows 本机完成，不需要 Linux）：
//   1. dotnet publish -r linux-musl-arm64 -p:DisableUnsupportedError=true
//      （ILCompiler 在 Windows 上产出 aarch64 ELF 的 Hello.o，"跨 OS 不支持"只是个软门）
//   2. DevEco 的 OHOS clang 手工链接（clang.exe --target=aarch64-linux-ohos
//      + OHOS musl sysroot + nuget runtime 包里的 .a + libclang_rt.builtins.a）
//   产物 DT_NEEDED 只有 libc.so，正好对上 OHOS 的 musl。
//
// M0 通过后本文件可删，换成真正的 osu.Framework.OHOS 桥接层。

#define LOG_DOMAIN 0x0F0F
#define LOG_TAG "OSU-AOT"
#include <hilog/log.h>
#include <napi/native_api.h>

#include <dlfcn.h>

#include <string>

namespace {

typedef int (*ohos_hello_fn)(int);

// ---------------- M1a：SDL3 官方 OHOS 后端加载验证 ----------------
// 只用最稳定的 C ABI 入口（SDL_version.h / SDL_platform.h / SDL_init.h）：
//   int SDL_GetVersion(void);
//   const char *SDL_GetPlatform(void);
//   bool SDL_Init(SDL_InitFlags flags);
//   void SDL_Quit(void);
// 不创建窗口、不碰 EGL，避免在没有 XComponent 的 Gate 阶段触碰 UI。
typedef int (*sdl_get_version_fn)(void);
typedef const char *(*sdl_get_platform_fn)(void);
typedef bool (*sdl_init_fn)(unsigned int);
typedef void (*sdl_quit_fn)(void);
typedef const char *(*sdl_get_error_fn)(void);

napi_value Hello(napi_env env, napi_callback_info info)
{
    // 文件名不带 lib 前缀也能被 dlopen 找到：应用私有 lib 目录在搜索路径里
    void *handle = dlopen("Hello.so", RTLD_NOW);
    if (handle == nullptr) {
        OH_LOG_ERROR(LOG_APP, "dlopen Hello.so failed: %{public}s", dlerror());
        napi_throw_error(env, "AOT_LOAD", "dlopen Hello.so failed");
        return nullptr;
    }

    ohos_hello_fn fn = reinterpret_cast<ohos_hello_fn>(dlsym(handle, "ohos_hello"));
    if (fn == nullptr) {
        OH_LOG_ERROR(LOG_APP, "dlsym ohos_hello failed: %{public}s", dlerror());
        napi_throw_error(env, "AOT_SYM", "dlsym ohos_hello failed");
        return nullptr;
    }

    int result = fn(21);
    OH_LOG_INFO(LOG_APP, "ohos_hello(21) = %{public}d (expect 84)", result);

    napi_value out = nullptr;
    napi_create_int32(env, result, &out);
    return out;
}

napi_value SdlGate(napi_env env, napi_callback_info info)
{
    // libSDL3.so 已随 HAP 打进 entry/libs/<abi>/；dlopen 会触发它的 constructor
    // SDL_RegisterNativeInterfaces（注册 nm_modname="SDL3" 的 NAPI 模块）。
    void *handle = dlopen("libSDL3.so", RTLD_NOW | RTLD_LOCAL);
    if (handle == nullptr) {
        OH_LOG_ERROR(LOG_APP, "SDL3 GATE FAIL dlopen: %{public}s", dlerror());
        napi_throw_error(env, "SDL_LOAD", "dlopen libSDL3.so failed");
        return nullptr;
    }

    auto getVersion = reinterpret_cast<sdl_get_version_fn>(dlsym(handle, "SDL_GetVersion"));
    auto getPlatform = reinterpret_cast<sdl_get_platform_fn>(dlsym(handle, "SDL_GetPlatform"));
    auto initSdl = reinterpret_cast<sdl_init_fn>(dlsym(handle, "SDL_Init"));
    auto quitSdl = reinterpret_cast<sdl_quit_fn>(dlsym(handle, "SDL_Quit"));
    auto getError = reinterpret_cast<sdl_get_error_fn>(dlsym(handle, "SDL_GetError"));
    if (!getVersion || !getPlatform || !initSdl || !quitSdl || !getError) {
        OH_LOG_ERROR(LOG_APP, "SDL3 GATE FAIL dlsym missing: %{public}s", dlerror());
        napi_throw_error(env, "SDL_SYM", "SDL3 symbol missing");
        return nullptr;
    }

    int version = getVersion();
    const char *platform = getPlatform();
    const char *revision = reinterpret_cast<const char *(*)(void)>(dlsym(handle, "SDL_GetRevision"))();
    bool initOk = initSdl(0);  // 0 = 不启用任何子系统，纯验证运行时可用
    const char *err = initOk ? "" : getError();
    quitSdl();

    // 实测：SDL3 的 OHOS 后端强制走 SDL_RunApp() -> dlopen("libmain.so") -> SDL_main
    // 启动链（SDL_sysmain_runapp.c:54）。从 NAPI 里直接调 SDL_Init() 会被 SDL_main
    // 守卫拒绝并报 "did you include SDL_main.h..."，这是设计约束而非加载失败。
    // 所以 M1a 的 PASS 判据只看「库可加载 + 版本 + 平台」，不做直接 SDL_Init。
    bool pass = version >= 3000000 && platform != nullptr &&
                std::string(platform).find("Harmony") != std::string::npos;

    OH_LOG_INFO(LOG_APP,
        "SDL3 GATE %{public}s ver=%{public}d platform=%{public}s rev=%{public}s direct_init=%{public}d (SDL_RunApp guard expected)",
        pass ? "PASS" : "FAIL", version, platform ? platform : "(null)",
        revision ? revision : "(null)", initOk ? 1 : 0);
    OH_LOG_INFO(LOG_APP, "SDL3 GATE NOTE app entry = libmain.so exporting SDL_main; direct_init_err=%{public}s", err);
    OH_LOG_INFO(LOG_APP, "SDL3 GATE NOTE XComponent OnSurfaceCreated -> SDL_OpenHarmonyMainSurfaceCreated -> SDL_RunApp");

    std::string summary = std::string(pass ? "SDL3 GATE PASS " : "SDL3 GATE FAIL ") +
                          "ver=" + std::to_string(version) +
                          " platform=" + (platform ? platform : "(null)");

    napi_value out = nullptr;
    napi_create_string_utf8(env, summary.c_str(), summary.size(), &out);
    return out;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        { "hello", nullptr, Hello, nullptr, nullptr, nullptr, napi_default, nullptr },
        { "sdlGate", nullptr, SdlGate, nullptr, nullptr, nullptr, napi_default, nullptr }
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

} // namespace

static napi_module g_aotSampleModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "aotsample",
    .nm_priv = nullptr,
    .reserved = { 0 },
};

extern "C" __attribute__((constructor)) void RegisterAotSampleModule(void)
{
    napi_module_register(&g_aotSampleModule);
}
