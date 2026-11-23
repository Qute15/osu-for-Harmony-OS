#include <ace/xcomponent/native_interface_xcomponent.h>
// hilog 的 domain/tag 默认是 0/NULL，那样日志在 hilog 缓冲区里查不到，必须在 include 前定义
#define LOG_DOMAIN 0x0F0F
#define LOG_TAG "OSU-NAPI"
#include <hilog/log.h>
#include <napi/native_api.h>
#include <native_vsync/native_vsync.h>
#include <native_window/external_window.h>

#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>

#include "audio/audio_engine.h"
#include "osu_scene.h"
#include "render/egl_core.h"
#include "render/sprite_renderer.h"

namespace {

constexpr const char *kTag = "osu-napi";
constexpr const char *kModuleName = "osu";

osu::EglCore g_egl;
osu::SpriteRenderer g_renderer;
osu::OsuScene g_scene;
osu::AudioEngine g_audio;

OH_NativeXComponent *g_component = nullptr;
void *g_window = nullptr;
OH_NativeVSync *g_vsync = nullptr;

std::atomic<bool> g_loopActive{false};
std::atomic<bool> g_surfaceReady{false};
std::atomic<bool> g_destroyRequested{false};
std::atomic<bool> g_paused{false};

std::atomic<int> g_surfaceWidth{0};
std::atomic<int> g_surfaceHeight{0};
std::atomic<uint64_t> g_frameCount{0};
std::atomic<int> g_fps{0};
std::atomic<int> g_drawCalls{0};
/** vsync 周期（ms）。系统若把屏幕降到 60Hz，这里会变成 16.67 */
std::atomic<double> g_vsyncPeriodMs{0.0};
/** SetExpectedFrameRateRange 的返回值，定位"为什么没上高刷"时先看它 */
std::atomic<int> g_frameRateRangeResult{-1};

std::chrono::steady_clock::time_point g_clockStart = std::chrono::steady_clock::now();
std::chrono::steady_clock::time_point g_fpsSampleStart = std::chrono::steady_clock::now();
uint64_t g_framesSinceSample = 0;

double g_timeMs = 0.0;

/** 上一帧耗时（ms），用于定位掉帧 */
std::atomic<double> g_frameMs{0.0};

/**
 * 每帧绘制指令（ArkTS 侧算好、native 只负责画）。
 *
 * 每条指令 16 个 float：
 *   [type, x, y, w, h, rotation, r, g, b, a, param1, param2, u0, v0, u1, v1]
 *   type 0=矩形 1=圆 2=圆环(param1=环厚px) 3=线段(等价矩形，w=长 h=线宽)
 *        4=皮肤贴图(u0..v1 是图集归一化 UV)
 *
 * 为什么把几何放在 ArkTS：玩法/判定逻辑已经在 ArkTS 且被 106 项断言验证过，
 * native 保持"哑光栅化器"角色，避免同一套数值在两边漂移。
 */
std::mutex g_commandMutex;
std::vector<float> g_commands;
std::atomic<int> g_commandCount{0};

constexpr int kFloatsPerCommand = 16;

/**
 * 待上传的皮肤图集。
 *
 * glTexImage2D 必须在 GL 上下文所在线程（vsync 回调线程）调用，
 * 而 uploadAtlas 是从 UI 线程进来的，所以这里只存数据、打标记，
 * 真正的上传放到 RenderFrame 里做。
 */
std::mutex g_atlasMutex;
std::vector<unsigned char> g_atlasPending;
int g_atlasWidth = 0;
int g_atlasHeight = 0;
std::atomic<bool> g_atlasDirty{false};
std::atomic<int> g_atlasUploaded{0};

/**
 * 待上传的谱面封面。
 *
 * 和皮肤图集同样的道理：解码在 ArkTS（image 模块），
 * glTexImage2D 在渲染线程。单独一份队列 + 单独一张纹理，
 * 因为封面是彩色图，混进图集会污染纯色图元的采样。
 */
std::mutex g_bgMutex;
std::vector<unsigned char> g_bgPending;
int g_bgWidth = 0;
int g_bgHeight = 0;
std::atomic<bool> g_bgDirty{false};
std::atomic<bool> g_bgClear{false};
std::atomic<int> g_bgUploaded{0};
/** 上一帧收到的纹理(SPRITE)指令条数 —— 用来区分"没收到指令"和"收到但没画出来" */
std::atomic<int> g_spriteCommands{0};

double ElapsedMs()
{
    const auto now = std::chrono::steady_clock::now();
    const auto diff = std::chrono::duration_cast<std::chrono::microseconds>(now - g_clockStart);
    return static_cast<double>(diff.count()) / 1000.0;
}

/**
 * 告诉系统"我要高刷"。
 *
 * 不做这件事，LTPO 屏幕会按"静态内容"把刷新率降到 60Hz —— 实测
 * RenderService 的 activeMode.refreshRate=60、expectedRefreshRate=-1，
 * 而屏幕本身支持 120Hz。表现为 FPS 卡在 60，看着像我们渲染慢，其实一帧只要 1~2ms。
 *
 * 必须在 OH_NativeVSync_RequestFrame 之后调用：周期只在收到回调后才刷新。
 */
void ApplyExpectedFrameRate()
{
    if (g_vsync == nullptr) {
        return;
    }
    OH_NativeVSync_ExpectedRateRange range;
    range.min = 60;
    range.max = 120;
    range.expected = 120;
    const int ret = OH_NativeVSync_SetExpectedFrameRateRange(g_vsync, &range);
    g_frameRateRangeResult.store(ret);
    if (ret != 0) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] SetExpectedFrameRateRange failed: %{public}d", kTag, ret);
    }
}

void UpdateVsyncPeriod()
{
    if (g_vsync == nullptr) {
        return;
    }
    long long period = 0;
    if (OH_NativeVSync_GetPeriod(g_vsync, &period) == 0 && period > 0) {
        // period 单位是纳秒
        g_vsyncPeriodMs.store(static_cast<double>(period) / 1000000.0);
    }
}

/**
 * 渲染一帧。
 *
 * 注意：EGL 上下文是在这个函数里（vsync 线程）第一次创建的，
 * 不能在 UI 线程的 OnSurfaceCreated 里创建——否则上下文会绑在错误线程上。
 */
void RenderFrame()
{
    if (!g_surfaceReady.load()) {
        return;
    }

    if (!g_egl.IsValid()) {
        if (!g_egl.Init(g_window)) {
            return;
        }
        if (!g_renderer.Init()) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] renderer init failed", kTag);
            return;
        }
        OH_LOG_INFO(LOG_APP, "[%{public}s] first frame: egl=%{public}dx%{public}d", kTag,
                    g_egl.Width(), g_egl.Height());
    }

    g_egl.UpdateSize();
    int width = g_egl.Width() > 0 ? g_egl.Width() : g_surfaceWidth.load();
    int height = g_egl.Height() > 0 ? g_egl.Height() : g_surfaceHeight.load();

    const auto frameStart = std::chrono::steady_clock::now();

    // 先清屏再做尺寸检查：即使尺寸暂时拿不到，也应该把画面刷成场地底色，
    // 而不是留一个未初始化的黑 buffer。
    glClearColor(7.0f / 255.0f, 7.0f / 255.0f, 9.0f / 255.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);

    if (width <= 0 || height <= 0) {
        static int warned = 0;
        if (warned < 3) {
            warned++;
            OH_LOG_WARN(LOG_APP, "[%{public}s] skip draw, size=%{public}dx%{public}d", kTag, width, height);
        }
        g_egl.SwapBuffers();
        return;
    }

    if (!g_paused.load()) {
        g_timeMs = ElapsedMs();
    }

    g_renderer.Begin(width, height);

    // 皮肤图集：ArkTS 侧解好 PNG 塞进来，这里在 GL 线程真正上传
    if (g_atlasDirty.exchange(false)) {
        std::vector<unsigned char> pixels;
        int aw = 0;
        int ah = 0;
        {
            std::lock_guard<std::mutex> lock(g_atlasMutex);
            pixels.swap(g_atlasPending);
            aw = g_atlasWidth;
            ah = g_atlasHeight;
        }
        if (!pixels.empty() && aw > 0 && ah > 0) {
            g_renderer.SetAtlas(aw, ah, pixels.data());
            g_atlasUploaded.store(1);
            OH_LOG_INFO(LOG_APP, "[%{public}s] atlas store uploaded=1 @%{public}p",
                        kTag, static_cast<void *>(&g_atlasUploaded));
        }
    }

    // 谱面封面：先卸掉上一张（换谱时不能残留），再上传本次的
    if (g_bgClear.exchange(false)) {
        g_renderer.ClearBackground();
        g_bgUploaded.store(0);
    }
    if (g_bgDirty.exchange(false)) {
        std::vector<unsigned char> bgPixels;
        int bw = 0;
        int bh = 0;
        {
            std::lock_guard<std::mutex> lock(g_bgMutex);
            bgPixels.swap(g_bgPending);
            bw = g_bgWidth;
            bh = g_bgHeight;
        }
        if (!bgPixels.empty() && bw > 0 && bh > 0) {
            g_renderer.SetBackground(bw, bh, bgPixels.data());
            g_bgUploaded.store(1);
        }
    }
    // 封面必须在本帧所有图元之前画：它自己提交一次 draw call，
    // 之后滑条/判定圈/皮肤贴图都叠在它上面。
    if (g_bgUploaded.load() != 0) {
        g_renderer.DrawBackground(width, height, 0.30f);
    }

    int commandCount = g_commandCount.load();
    int spritesSeen = 0;
    static int dbgSprite = 0;
    std::vector<float> snapshot;
    int total = 0;
    if (commandCount > 0) {
        {
            std::lock_guard<std::mutex> lock(g_commandMutex);
            snapshot = g_commands;
        }
        const int limit = commandCount * kFloatsPerCommand;
        total = static_cast<int>(snapshot.size()) < limit ? static_cast<int>(snapshot.size()) : limit;
        for (int i = 0; i + kFloatsPerCommand - 1 < total; i += kFloatsPerCommand) {
            const int type = static_cast<int>(snapshot[i]);
            const float x = snapshot[i + 1];
            const float y = snapshot[i + 2];
            const float w = snapshot[i + 3];
            const float h = snapshot[i + 4];
            const float rot = snapshot[i + 5];
            const osu::Color color{snapshot[i + 6], snapshot[i + 7], snapshot[i + 8], snapshot[i + 9]};
            const float p1 = snapshot[i + 10];
            const float u0 = snapshot[i + 12];
            const float v0 = snapshot[i + 13];
            const float u1 = snapshot[i + 14];
            const float v1 = snapshot[i + 15];

            switch (type) {
                case 0:
                case 3:
                    g_renderer.AddRect(x, y, w, h, rot, color);
                    break;
                case 1:
                    g_renderer.AddCircle(x, y, w * 0.5f, color);
                    break;
                case 2:
                    g_renderer.AddRing(x, y, w * 0.5f, p1, color);
                    break;
                case 4:
                    g_renderer.AddSprite(x, y, w * 0.5f, h * 0.5f, rot, u0, v0, u1, v1, color);
                    spritesSeen++;
                    break;
                default:
                    break;
            }
        }
    } else {
        // 还没收到指令时给个提示色，避免"全黑 = 不知道是没数据还是没渲染"
        g_renderer.AddRect(width * 0.5f, height * 0.5f, static_cast<float>(width) * 0.5f, 4.0f, 0.0f,
                           osu::Color{1.0f, 0.4f, 0.1f, 0.8f});
    }

    g_renderer.End();
    g_spriteCommands.store(spritesSeen);

    g_egl.SwapBuffers();

    g_frameCount.fetch_add(1);
    g_drawCalls.store(g_renderer.DrawCalls());

    // vsync 周期只在收到回调后才有效，这里每 60 帧刷一次即可
    if ((g_frameCount.load() % 60) == 0) {
        UpdateVsyncPeriod();
        ApplyExpectedFrameRate();
    }

    const auto frameEnd = std::chrono::steady_clock::now();
    g_frameMs.store(std::chrono::duration<double, std::milli>(frameEnd - frameStart).count());

    // FPS 统计：每 500ms 结算一次
    g_framesSinceSample++;
    const auto sinceSample = std::chrono::duration_cast<std::chrono::milliseconds>(frameEnd - g_fpsSampleStart).count();
    if (sinceSample >= 500) {
        g_fps.store(static_cast<int>(g_framesSinceSample * 1000 / static_cast<uint64_t>(sinceSample)));
        g_framesSinceSample = 0;
        g_fpsSampleStart = frameEnd;
    }
}

void OnVSync(long long /*timestamp*/, void * /*data*/)
{
    if (g_destroyRequested.exchange(false)) {
        g_renderer.Destroy();
        g_egl.Destroy();
        g_loopActive.store(false);
        return;
    }

    RenderFrame();

    if (g_loopActive.load() && g_vsync != nullptr) {
        OH_NativeVSync_RequestFrame(g_vsync, OnVSync, nullptr);
    }
}

// ----------------------------------------------------------- XComponent 回调

void OnSurfaceCreated(OH_NativeXComponent *component, void *window)
{
    g_component = component;
    g_window = window;
    g_destroyRequested.store(false);

    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    g_surfaceWidth.store(static_cast<int>(width));
    g_surfaceHeight.store(static_cast<int>(height));

    // 必须显式告诉窗口缓冲区多大，否则部分机型上 EGL 表面尺寸是 0x0，
    // 于是 glViewport(0,0,0,0) → 画面永远是黑的，而且一路不报错。
    if (width > 0 && height > 0) {
        int32_t ret = OH_NativeWindow_NativeWindowHandleOpt(reinterpret_cast<OHNativeWindow *>(window),
                                                           SET_BUFFER_GEOMETRY,
                                                           static_cast<int>(width),
                                                           static_cast<int>(height));
        if (ret != 0) {
            OH_LOG_WARN(LOG_APP, "[%{public}s] SET_BUFFER_GEOMETRY failed: %{public}d", kTag, ret);
        }
    }

    g_surfaceReady.store(true);

    if (g_vsync == nullptr) {
        const char *name = "osu-render";
        g_vsync = OH_NativeVSync_Create(name, static_cast<unsigned int>(std::strlen(name)));
        if (g_vsync == nullptr) {
            OH_LOG_ERROR(LOG_APP, "[%{public}s] OH_NativeVSync_Create failed", kTag);
        }
    }

    ApplyExpectedFrameRate();

    if (!g_loopActive.exchange(true) && g_vsync != nullptr) {
        OH_NativeVSync_RequestFrame(g_vsync, OnVSync, nullptr);
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] surface created %{public}dx%{public}d", kTag,
                g_surfaceWidth.load(), g_surfaceHeight.load());
}

void OnSurfaceChanged(OH_NativeXComponent *component, void *window)
{
    uint64_t width = 0;
    uint64_t height = 0;
    OH_NativeXComponent_GetXComponentSize(component, window, &width, &height);
    g_surfaceWidth.store(static_cast<int>(width));
    g_surfaceHeight.store(static_cast<int>(height));
    OH_LOG_INFO(LOG_APP, "[%{public}s] surface changed %{public}dx%{public}d", kTag,
                g_surfaceWidth.load(), g_surfaceHeight.load());
}

void OnSurfaceDestroyed(OH_NativeXComponent * /*component*/, void * /*window*/)
{
    OH_LOG_INFO(LOG_APP, "[%{public}s] surface destroyed", kTag);
    g_surfaceReady.store(false);
    g_destroyRequested.store(true);
    g_loopActive.store(false);

    if (g_vsync != nullptr) {
        OH_NativeVSync_Destroy(g_vsync);
        g_vsync = nullptr;
    }
    g_window = nullptr;
}

void DispatchTouchEvent(OH_NativeXComponent * /*component*/, void * /*window*/)
{
    // 输入接入放到 P1 的下一步：把 OH_NativeXComponent_TouchEvent
    // 转成虚拟场坐标后送 ArkTS 的 OsuPlayfield.press/move/release。
}

// ----------------------------------------------------------------- NAPI API

napi_value GetFps(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_fps.load(), &result);
    return result;
}

napi_value GetFrameCount(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int64(env, static_cast<int64_t>(g_frameCount.load()), &result);
    return result;
}

napi_value GetSurfaceWidth(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_surfaceWidth.load(), &result);
    return result;
}

napi_value GetSurfaceHeight(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_surfaceHeight.load(), &result);
    return result;
}

napi_value GetFrameTime(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_double(env, g_frameMs.load(), &result);
    return result;
}

napi_value GetDrawCalls(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_drawCalls.load(), &result);
    return result;
}

/** vsync 实际周期（ms）。16.67 = 屏幕跑在 60Hz，8.33 = 120Hz */
napi_value GetVsyncPeriod(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_double(env, g_vsyncPeriodMs.load(), &result);
    return result;
}

/** SetExpectedFrameRateRange 的返回值，0 表示接受 */
napi_value GetFrameRateRangeResult(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_frameRateRangeResult.load(), &result);
    return result;
}

napi_value SetPaused(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    bool paused = false;
    if (argc >= 1 && napi_get_value_bool(env, args[0], &paused) == napi_ok) {
        g_paused.store(paused);
    }

    napi_value result = nullptr;
    napi_get_boolean(env, g_paused.load(), &result);
    return result;
}

/**
 * 诊断用状态码：
 *  0 = 没收到 XComponent 表面（回调没触发 / 模块没被调用）
 *  1 = 收到表面，但 EGL 还没就绪
 *  2 = EGL 就绪，但一帧都没出来
 *  3 = 正在出帧
 */
napi_value GetStatus(napi_env env, napi_callback_info /*info*/)
{
    int status = 0;
    if (g_frameCount.load() > 0) {
        status = 3;
    } else if (g_egl.IsValid()) {
        status = 2;
    } else if (g_surfaceReady.load()) {
        status = 1;
    }

    napi_value result = nullptr;
    napi_create_int32(env, status, &result);
    return result;
}

/**
 * ArkTS 侧在 XComponent.onLoad 里主动调一次。
 * XComponent 的自动回调在某些版本/机型上不会触发，这条是保底触发路径。
 */
napi_value StartRender(napi_env env, napi_callback_info /*info*/)
{
    const bool ready = g_surfaceReady.load() && g_window != nullptr;

    if (ready && g_vsync == nullptr) {
        const char *name = "osu-render";
        g_vsync = OH_NativeVSync_Create(name, static_cast<unsigned int>(std::strlen(name)));
    }
    if (ready && g_vsync != nullptr && !g_loopActive.exchange(true)) {
        OH_NativeVSync_RequestFrame(g_vsync, OnVSync, nullptr);
    }
    if (ready) {
        ApplyExpectedFrameRate();
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] startRender called, surfaceReady=%{public}d", kTag, ready ? 1 : 0);

    napi_value result = nullptr;
    napi_get_boolean(env, ready, &result);
    return result;
}

void RegisterCallbacks(OH_NativeXComponent *nativeXComponent)
{
    if (nativeXComponent == nullptr) {
        return;
    }
    static OH_NativeXComponent_Callback callback;
    callback.OnSurfaceCreated = OnSurfaceCreated;
    callback.OnSurfaceChanged = OnSurfaceChanged;
    callback.OnSurfaceDestroyed = OnSurfaceDestroyed;
    callback.DispatchTouchEvent = DispatchTouchEvent;

    OH_NativeXComponent_RegisterCallback(nativeXComponent, &callback);
    g_component = nativeXComponent;
    OH_LOG_INFO(LOG_APP, "[%{public}s] xcomponent callbacks registered", kTag);
}

/**
 * ArkTS 在 XComponent.onLoad 里把 context 传进来。
 *
 * 为什么要这条路径：ArkTS 先 `import 'libosu.so'` 时，模块的 exports 上还没有
 * `OH_NATIVE_XCOMPONENT_OBJ`，Init 里拿不到 native 实例，回调就注册不上 →
 * XComponent 永远不出图（黑屏）。从 onLoad 的 context 里再抓一次是唯一的保底。
 */
napi_value AttachContext(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value result = nullptr;
    napi_get_boolean(env, false, &result);

    if (argc < 1 || args[0] == nullptr) {
        OH_LOG_WARN(LOG_APP, "[%{public}s] attachContext: no argument", kTag);
        return result;
    }

    // 先打印 context 上的所有键名，方便版本差异时定位真实属性名
    napi_value names = nullptr;
    if (napi_get_property_names(env, args[0], &names) == napi_ok) {
        uint32_t len = 0;
        napi_get_array_length(env, names, &len);
        std::string keys;
        for (uint32_t i = 0; i < len; i++) {
            napi_value key = nullptr;
            if (napi_get_element(env, names, i, &key) != napi_ok) {
                continue;
            }
            char buf[64] = {0};
            size_t written = 0;
            if (napi_get_value_string_utf8(env, key, buf, sizeof(buf) - 1, &written) == napi_ok) {
                keys.append(buf).append(",");
            }
        }
        OH_LOG_INFO(LOG_APP, "[%{public}s] attachContext keys=[%{public}s]", kTag, keys.c_str());
    }

    // 情况 A：context 本身就是 native 实例的包装
    OH_NativeXComponent *nativeXComponent = nullptr;
    napi_unwrap(env, args[0], reinterpret_cast<void **>(&nativeXComponent));
    if (nativeXComponent != nullptr) {
        RegisterCallbacks(nativeXComponent);
        napi_get_boolean(env, true, &result);
        return result;
    }

    // 情况 B：context.nativeXComponent 才是 native 实例
    const char *candidates[] = {"nativeXComponent", "nativeXcomponent", "xcomponent"};
    for (const char *name : candidates) {
        napi_value nativeObj = nullptr;
        if (napi_get_named_property(env, args[0], name, &nativeObj) != napi_ok || nativeObj == nullptr) {
            continue;
        }
        napi_unwrap(env, nativeObj, reinterpret_cast<void **>(&nativeXComponent));
        if (nativeXComponent != nullptr) {
            RegisterCallbacks(nativeXComponent);
            napi_get_boolean(env, true, &result);
            return result;
        }
    }

    OH_LOG_ERROR(LOG_APP, "[%{public}s] attachContext: could not obtain OH_NativeXComponent", kTag);
    return result;
}

/**
 * ArkTS 每帧调用：提交本帧的绘制指令。
 * commands 是 Float32Array 的底层 ArrayBuffer，count 是指令条数（不是 float 个数）。
 */
napi_value DrawFrame(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);

    if (argc < 2) {
        return undefined;
    }

    void *data = nullptr;
    size_t byteLength = 0;
    if (napi_get_arraybuffer_info(env, args[0], &data, &byteLength) != napi_ok || data == nullptr) {
        return undefined;
    }

    int32_t count = 0;
    if (napi_get_value_int32(env, args[1], &count) != napi_ok || count <= 0) {
        g_commandCount.store(0);
        return undefined;
    }

    const size_t maxFloats = byteLength / sizeof(float);
    size_t needed = static_cast<size_t>(count) * kFloatsPerCommand;
    if (needed > maxFloats) {
        needed = maxFloats;
    }

    {
        std::lock_guard<std::mutex> lock(g_commandMutex);
        g_commands.assign(static_cast<float *>(data), static_cast<float *>(data) + needed);
    }
    g_commandCount.store(static_cast<int>(needed / kFloatsPerCommand));
    return undefined;
}

// ---------------------------------------------------------------- 音频 NAPI

/**
 * initAudio(sampleRate, channels) -> bool
 *
 * 打击音走 OHAudio 的低延迟通路，和音乐（AVPlayer）是两条独立流：
 * 音乐负责时钟基准，打击音负责手感。
 */
napi_value InitAudio(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t sampleRate = 48000;
    int32_t channels = 2;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &sampleRate);
    }
    if (argc >= 2) {
        napi_get_value_int32(env, args[1], &channels);
    }

    const bool ok = g_audio.Init(sampleRate, channels);

    napi_value result = nullptr;
    napi_get_boolean(env, ok, &result);
    return result;
}

napi_value ShutdownAudio(napi_env env, napi_callback_info /*info*/)
{
    g_audio.Shutdown();
    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

/**
 * playHitSound(kind, volume)
 * kind: 0=normal 1=whistle 2=finish 3=clap
 */
napi_value PlayHitSound(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value args[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    int32_t kind = 0;
    double volume = 1.0;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &kind);
    }
    if (argc >= 2) {
        napi_get_value_double(env, args[1], &volume);
    }

    if (kind >= 0 && kind < static_cast<int32_t>(osu::HitSoundKind::Count)) {
        g_audio.Play(static_cast<osu::HitSoundKind>(kind), static_cast<float>(volume));
    }

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    return undefined;
}

napi_value GetAudioLatency(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_double(env, g_audio.RouteLatencyMs(), &result);
    return result;
}

napi_value GetAudioBufferLatency(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_double(env, g_audio.BufferLatencyMs(), &result);
    return result;
}

napi_value GetAudioFastStatus(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_audio.FastStatus(), &result);
    return result;
}

napi_value GetAudioUnderruns(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, static_cast<int32_t>(g_audio.Underruns()), &result);
    return result;
}

napi_value GetAudioFrames(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int64(env, static_cast<int64_t>(g_audio.FramesRendered()), &result);
    return result;
}

/**
 * 上传皮肤图集：uploadAtlas(width, height, rgbaArrayBuffer)
 *
 * ArkTS 侧用 image 模块把 PNG 解成 RGBA，这里只做"排队 + 打标记"，
 * 真正 glTexImage2D 在渲染线程的 RenderFrame 里做。
 */
napi_value UploadAtlas(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    if (argc < 3) {
        return undefined;
    }

    int32_t w = 0;
    int32_t h = 0;
    if (napi_get_value_int32(env, args[0], &w) != napi_ok || napi_get_value_int32(env, args[1], &h) != napi_ok) {
        return undefined;
    }

    void *data = nullptr;
    size_t bytes = 0;
    if (napi_get_arraybuffer_info(env, args[2], &data, &bytes) != napi_ok || data == nullptr) {
        return undefined;
    }

    const size_t expected = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    if (w <= 0 || h <= 0 || bytes < expected) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] uploadAtlas size mismatch: %{public}dx%{public}d bytes=%{public}zu",
                     kTag, w, h, bytes);
        return undefined;
    }

    {
        std::lock_guard<std::mutex> lock(g_atlasMutex);
        g_atlasPending.assign(static_cast<unsigned char *>(data), static_cast<unsigned char *>(data) + expected);
        g_atlasWidth = w;
        g_atlasHeight = h;
    }
    g_atlasDirty.store(true);
    OH_LOG_INFO(LOG_APP, "[%{public}s] uploadAtlas queued %{public}dx%{public}d dirty@%{public}p",
                kTag, w, h, static_cast<void *>(&g_atlasDirty));
    return undefined;
}

/** 图集是否已经真的传上 GL（1 = 已传） */
napi_value GetAtlasUploaded(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_atlasUploaded.load(), &result);
    return result;
}

/**
 * 上传谱面封面：uploadBackground(width, height, rgbaArrayBuffer)
 *
 * 语义和 uploadAtlas 一样，只是进了另一条队列/另一张纹理。
 * 尺寸已在 ArkTS 侧降采样过（长边 ≤ 1280），所以这里不再缩放。
 */
napi_value UploadBackground(napi_env env, napi_callback_info info)
{
    size_t argc = 3;
    napi_value args[3] = {nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    napi_value undefined = nullptr;
    napi_get_undefined(env, &undefined);
    if (argc < 3) {
        return undefined;
    }

    int32_t w = 0;
    int32_t h = 0;
    if (napi_get_value_int32(env, args[0], &w) != napi_ok || napi_get_value_int32(env, args[1], &h) != napi_ok) {
        return undefined;
    }

    void *data = nullptr;
    size_t bytes = 0;
    if (napi_get_arraybuffer_info(env, args[2], &data, &bytes) != napi_ok || data == nullptr) {
        return undefined;
    }

    const size_t expected = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    if (w <= 0 || h <= 0 || bytes < expected) {
        OH_LOG_ERROR(LOG_APP, "[%{public}s] uploadBackground size mismatch: %{public}dx%{public}d bytes=%{public}zu",
                     kTag, w, h, bytes);
        return undefined;
    }

    {
        std::lock_guard<std::mutex> lock(g_bgMutex);
        g_bgPending.assign(static_cast<unsigned char *>(data), static_cast<unsigned char *>(data) + expected);
        // JPEG 没有 alpha 通道，解码器不保证把 alpha 填成 255（实测是 0）。
        // 而 fragment shader 里 alpha<=0.003 会 discard —— 整张封面会凭空消失。
        // 封面永远是不透明的，这里直接强制写死。
        for (size_t i = 3; i < expected; i += 4) {
            g_bgPending[i] = 255;
        }
        g_bgWidth = w;
        g_bgHeight = h;
    }
    g_bgDirty.store(true);
    OH_LOG_INFO(LOG_APP, "[%{public}s] uploadBackground queued %{public}dx%{public}d", kTag, w, h);
    return undefined;
}

/** 卸掉当前封面（离开游戏页、或本谱没有背景图时调） */
napi_value ClearBackground(napi_env env, napi_callback_info /*info*/)
{
    g_bgClear.store(true);
    g_bgDirty.store(false);
    napi_value result = nullptr;
    napi_get_undefined(env, &result);
    return result;
}

/** 封面是否已经传上 GL（1 = 已传） */
napi_value GetBackgroundUploaded(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_bgUploaded.load(), &result);
    return result;
}

/** 上一帧的纹理指令条数 */
napi_value GetSpriteCommands(napi_env env, napi_callback_info /*info*/)
{
    napi_value result = nullptr;
    napi_create_int32(env, g_spriteCommands.load(), &result);
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor desc[] = {
        {"getFps", nullptr, GetFps, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFrameCount", nullptr, GetFrameCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSurfaceWidth", nullptr, GetSurfaceWidth, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSurfaceHeight", nullptr, GetSurfaceHeight, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFrameTime", nullptr, GetFrameTime, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDrawCalls", nullptr, GetDrawCalls, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getVsyncPeriod", nullptr, GetVsyncPeriod, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getFrameRateRangeResult", nullptr, GetFrameRateRangeResult, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setPaused", nullptr, SetPaused, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"startRender", nullptr, StartRender, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"attachContext", nullptr, AttachContext, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"drawFrame", nullptr, DrawFrame, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"initAudio", nullptr, InitAudio, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"shutdownAudio", nullptr, ShutdownAudio, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"playHitSound", nullptr, PlayHitSound, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAudioLatency", nullptr, GetAudioLatency, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAudioBufferLatency", nullptr, GetAudioBufferLatency, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAudioFastStatus", nullptr, GetAudioFastStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAudioUnderruns", nullptr, GetAudioUnderruns, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAudioFrames", nullptr, GetAudioFrames, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"uploadAtlas", nullptr, UploadAtlas, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAtlasUploaded", nullptr, GetAtlasUploaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"uploadBackground", nullptr, UploadBackground, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearBackground", nullptr, ClearBackground, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getBackgroundUploaded", nullptr, GetBackgroundUploaded, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSpriteCommands", nullptr, GetSpriteCommands, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);

    // 被 ArkTS 直接 import 时，exports 上没有 native 实例，这里只是拿不到，不是致命错误：
    // 真正的注册会走 XComponent.onLoad → attachContext()。
    napi_value exportInstance = nullptr;
    if (napi_get_named_property(env, exports, OH_NATIVE_XCOMPONENT_OBJ, &exportInstance) == napi_ok
        && exportInstance != nullptr) {
        OH_NativeXComponent *nativeXComponent = nullptr;
        napi_unwrap(env, exportInstance, reinterpret_cast<void **>(&nativeXComponent));
        if (nativeXComponent != nullptr) {
            RegisterCallbacks(nativeXComponent);
        }
    } else {
        OH_LOG_INFO(LOG_APP, "[%{public}s] module loaded without xcomponent, waiting for attachContext", kTag);
    }

    OH_LOG_INFO(LOG_APP, "[%{public}s] module initialised", kTag);
    return exports;
}

napi_module g_module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = kModuleName,
    .nm_priv = nullptr,
    .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterOsuModule(void)
{
    napi_module_register(&g_module);
}
