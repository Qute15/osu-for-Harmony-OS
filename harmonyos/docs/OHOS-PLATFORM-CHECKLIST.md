# osu!framework → HarmonyOS 平台层实现清单（M1 / Task #2 产出）

生成时间：2026-11-13
基线：osu!lazer `2026.1005.0`、`ppy.osu.Framework 2026.921.1`（精确 commit `247dee9888c51606b939f027bce54504f8ca26fa`）、
`ppy.osu.Framework.Android 2026.921.0`、SDL3 main（含官方 OpenHarmony 后端）。

---

## 一、结论先行

1. **M0 已 PASS**（NativeAOT 托管代码在 OHOS 应用进程内可执行），路线 A 成立。
2. **M1 的平台桥比原计划更薄**：framework 的窗口 / 渲染 / 输入全部走 SDL3，而 SDL3 main 分支已有官方
   OpenHarmony 后端（Video: `openharmony` / Audio: `ohaudio` / Camera: `openharmony`），且**本机 DevEco SDK
   已成功编译出 arm64 + x86_64 两个架构的 `libSDL3.so`**。
3. **但"只写一个新平台层项目"不够**：`SDL3MobileWindow` 是 `internal`，且 R1（BASS 音频）必须替换 framework
   内部实现 —— 因此 M1 必须**把 osu-framework 源码拉到本地一起编译**，而不是引用 NuGet 的 `osu.Framework.dll`。
   这是相对 §十二 的第二次架构修正。
4. AOT 产物与 SDL3 的接点是现成的：SDL3 的 `RunAppOpenHarmonyMain()` 会 `dlopen("libmain.so")` 并寻找
   `SDL_main`，所以 **NativeAOT 产出的 `.so` 命名为 `libmain.so` 并导出 `SDL_main` 即可被 SDL3 直接拉起**。

---

## 二、M1a 已落地：SDL3 for OHOS 编译结果

| 项 | arm64-v8a（真机） | x86_64（模拟器） |
| --- | --- | --- |
| ELF | `ELF64 / AArch64 / DYN` | `ELF64 / X86-64 / DYN` |
| 大小 | 2,237,976 bytes | 2,361,824 bytes |
| 构建脚本 | `output/aot-tools/build-sdl3.py` | 同左 |
| CMake 后端 | `Video: dummy offscreen openharmony` / `Audio: disk dummy ohaudio` / `Camera: dummy openharmony` | 同左 |
| 关键依赖 | `libdeviceinfo_ndk.z.so`、`libace_napi.z.so`、`libace_ndk.z.so`、`librawfile.z.so`、`libhilog_ndk.z.so`、`libohcommonevent.so`、`libability_runtime.so`、`libc.so` | 同左 |

构建命令（脚本内固化，Windows 本机，无需 Linux/WSL）：

```bash
python build-sdl3.py --arch all
# cmake -S SDL-main -B SDL3-build-<arch>-ohos -G Ninja \
#   -DCMAKE_TOOLCHAIN_FILE=<DevEco>/native/build/cmake/ohos.toolchain.cmake \
#   -DCMAKE_MAKE_PROGRAM=<DevEco>/native/build-tools/cmake/bin/ninja.exe \
#   -DCMAKE_BUILD_TYPE=Release \
#   -DOHOS_COMPATIBLE_SDK_VERSION=26.0.0   # 本机 SDK apiVersion=26，官方 README 的 16.0.0 不适用 \
#   -DOHOS_ARCH=arm64-v8a|x86_64 \
#   -DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1  # 官方模板必需：否则 SDL3 数据段被加载两次 \
#   -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL=OFF
# ninja -C ...
```

**两个必须记住的坑**

- `OHOS_COMPATIBLE_SDK_VERSION=26.0.0`：`openharmony/native/oh-uni-package.json` 是 `apiVersion: "26"`；
  官方 README 里的 `16.0.0` 对应它自己的 API 16 环境，照抄会选错 NDK 头。
- `-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1`：来自 `openharmony-project/entry/build-profile.json5` 的注释
  *"Otherwise, we load SDL3's data segment twice"*。不带它 SONAME 是 `libSDL3.so.0`；带上后链接命令变成
  `-Wl,-soname,libSDL3.so`。XComponent 的 `libraryname: 'SDL3'` 与 ArkTS 的 `import sdl from 'libSDL3.so'`
  必须是同一个 SONAME。

已知上游瑕疵（不影响 M1a，M3 前修）：`src/audio/ohaudio/SDL_ohaudio.c:597` 的 `ResumeOneDevice`
函数指针参数顺序与 `SDL_sysaudio.h:93` 声明相反，clang 报 `-Wincompatible-function-pointer-types`。

---

## 三、启动链路（源码证据，含路径行号）

```
ArkTS EntryAbility.onCreate
  └─ import sdl from 'libSDL3.so'                       openharmony-project/.../EntryAbility.ets:7
     └─ libSDL3.so constructor SDL_RegisterNativeInterfaces()   SDL_openharmony.c:1194-1206
        └─ 注册 NAPI 模块 nm_modname = "SDL3"                  SDL_openharmony.c:1201
  └─ sdl.provideArkTSObjects(this, atManager, i18n.System,
                             pointer.setPointerVisibleSync,
                             inputMethod.getController())      EntryAbility.ets:22
     └─ SDL_JS_ProvideArkTSObjects → monkey-patch Ability       SDL_openharmony.c:1144
  └─ onWindowStageCreate（C 接管）→ loadContent('pages/Index')
     └─ XComponent({ id:'SDL_XComponent', type:SURFACE,
                     libraryname:'SDL3' })                     pages/Index.ets:9
        └─ OnSurfaceCreated → SDL_XComponent_OnSurfaceCreatedCallback   SDL_openharmony.c:830
           └─ SDL_OpenHarmonyMainSurfaceCreated()              SDL_sysmain_runapp.c:92
              └─ SDL_RunApp(0, NULL, RunAppOpenHarmonyMain)
                 └─ dlopen("libmain.so")                      SDL_sysmain_runapp.c:54-55
                    ├─ dlsym("SDL_main") → pthread_create → 阻塞式主循环   :61-73
                    └─ 否则要求 SDL_AppInit/Iterate/Event/Quit            :76-89
```

**对路线 A 的直接含义**：AOT 产物取名为 `libmain.so`，用
`[UnmanagedCallersOnly(EntryPoint = "SDL_main")]` 导出一个永不返回的 C 函数，里面跑
`new OsuGameOHOS()` + `host.Run(game)`。SDL3 会把它放在独立线程里，主线程继续收 XComponent 的
`OnFrame`/触摸回调 —— 与 lazer 桌面版的 `GameHost.Run()` 单线程模型不冲突。

`OPENHARMONY_CreateWindow()`（`src/video/openharmony/SDL_openharmonywindow.c:44`）**并不主动建窗口**：
它由 `SDL_CreateWindow()` 触发，从 XComponent 取 `native_window`（`:60`），建 EGL surface（`:100`），
并把指针写进 window properties（`:94`、`:107`）。所以 framework 仍按原样调用 `SDL_CreateWindow`
即可，无需像 Android 那样传 surface pointer。

framework 侧对应实现：

- `osu.Framework/Platform/SDL3/SDL3Window.cs:211-242` — `public virtual void Create()`，
  `:228` 调 `SDL_CreateWindow(title, Size.Width, Size.Height, flags)`，`:238` `graphicsSurface.Initialise()`。
- `osu.Framework/Platform/SDL3/SDL3MobileWindow.cs` — `internal class`，仅 override
  `UpdateWindowStateAndSize()` 调 `SDL_SetWindowFullscreen(true)`。
- `osu.Framework/Platform/SDLGameHost.cs` — `public abstract class SDLGameHost : GameHost`，
  负责 Clipboard / TextInput / InputHandlers；`FrameworkEnvironment.UseSDL3` 决定 SDL2 还是 SDL3 分支。

**`internal` 是硬约束**：`SDL3MobileWindow`、`SDL3Window` 都是 internal，外部程序集无法继承。
Android 版 `osu.Framework.Android` 能继承是因为它在 framework 解决方案内且享有 `InternalsVisibleTo`。
→ M1 必须把 OHOS 平台层放进 framework 源码树（或给新程序集加友元程序集/访问检查绕过），推荐前者。

---

## 四、Android → OHOS 平台层逐项映射

基准文件：`output/src-framework-android/AndroidGameHost.cs`（210 行）、`AndroidGameWindow.cs`、
`AndroidGameSurface.cs`、`AndroidStorage.cs`、`ChoreographerVsyncWaiter.cs`。

| Android 实现 | 行号 | OHOS 对应 | 工作量 |
| --- | --- | --- | --- |
| `AndroidGameHost : SDLGameHost` | :25 | `OHOSGameHost : SDLGameHost` | 保留骨架 |
| ctor 持有 `AndroidGameActivity` | :27-35 | 不需要 Activity；改为持有 native host handle（可选） | 删 |
| `SetupConfig` 强制 `ExecutionMode.SingleThread` | :37-43 | **保留**（移动端必需） | 照抄 |
| `CreateWindow` → `AndroidGameWindow` | :45 | → `OHOSGameWindow : SDL3MobileWindow` | 小 |
| `DrawFrame` 用 `Surface.IsSurfaceReady` 门控 | :47-51 | 用 XComponent 的 surface 生命周期标志（native 侧导出 bool） | 小 |
| `Swap` + `ChoreographerVsyncWaiter.WaitForVsync()` | :53-71 | SDL3 OHOS 后端已处理 swap/vsync；先**不接** `OH_NativeVSync`，跑通后再评估帧对齐 | 删/延后 |
| `CanExit = false` / `CanSuspendToBackground = true` | :73-75 | 照抄 | 0 |
| `OnScreenKeyboardOverlapsGameWindow = true` | :77 | 照抄 | 0 |
| `GetStorage` → `AndroidStorage : NativeStorage` | :79 | `OHOSStorage : NativeStorage`，路径指向 `context.filesDir` | 0 |
| `UserStoragePaths` → `GetExternalFilesDir` | :81-83 | 由 ArkTS 把沙箱路径通过 NAPI 传进来 | 小 |
| `CreateSystemFileSelector` → `AndroidFileSelector` | :85-86 | 返回 null / 空实现（M4 再接系统文件选择器） | 小 |
| `OpenFileExternally` / `PresentFileExternally` / `OpenUrlExternally` | :133-186 | 用 OHOS `Want` / `startAbility`；M1 可先返回 false | 延后 |
| `CreateTextureLoaderStore` → `AndroidTextureLoaderStore` | :188-189 | 用 framework 默认（不走 Android Bitmap） | 删 |
| `CreateVideoDecoder` → `AndroidVideoDecoder` | :191-192 | **M1/M2 禁用视频背景**（FFmpeg 是 Android/Bionic ABI，不能搬到 OHOS musl） | 延后 M3 |
| `SuspendToBackground` → `MoveTaskToBack` | :194-197 | 空实现 / ArkTS 侧处理 | 小 |
| `AndroidGameWindow.SurfaceHandle` | `AndroidGameWindow.cs` | 不需要（OHOS 后端自己从 XComponent 取 native window） | 删 |
| `SafeAreaPadding.BindTo(...)` | `AndroidGameWindow.cs` | 从 OHOS `window.getWindowAvoidArea()` 经 NAPI 传入 | 小 |
| `ChoreographerVsyncWaiter` | 全文 | `OH_NativeVSync` 或 SDL3 OHOS 的 OnFrame 回调；**SDL3 已提供帧回调，优先复用** | 延后 |

`osu.Android/OsuGameAndroid.cs`（约 150 行）→ `osu.OHOS/OsuGameOHOS.cs`：
保留 `ScalingContainerTargetDrawSize`、`CursorState.Hidden`、`MobileUpdateNotifier`；
去掉 `PackageInfo` / 屏幕方向 / 电池信息等 Android 专属 API。

---

## 五、必须在 framework 源码里改的点（这是要用源码而非 NuGet 的真正原因）

| # | 位置 | 改动 | 原因 |
| --- | --- | --- | --- |
| 1 | `SDL3/SDL3MobileWindow.cs` | 新增 `OHOSGameWindow`（同程序集，可访问 internal） | `internal` 继承约束 |
| 2 | `Platform/SDLGameHost.cs` | 新增 `OHOSGameHost`；强制 `FrameworkEnvironment.UseSDL3 = true` | OHOS 只有 SDL3 后端 |
| 3 | **音频 R1** | 用 SDL3 的 `ohaudio` 后端替换 BASS：写 `OHOSAudioManager` / BASS API 兼容 shim | `libbass.so / libbassmix.so / libbass_fx.so` 是 Android/Bionic ABI，OHOS musl 无法加载；这是最大工作量 |
| 4 | 视频 | `VideoDecoder` 工厂在 OHOS 返回 null / 禁用背景视频 | FFmpeg `.so` 同样是 Bionic |
| 5 | `NativeLibs` / `ppy.SDL3-CS` | 把 `ppy.SDL3-CS` 的原生库解析指向我们编的 `libSDL3.so` | NuGet 包里只有 win/osx/linux/android/ios，无 OHOS |
| 6 | 反射裁剪 | 生成 `rd.xml`，补齐 DI / 资源 / 序列化动态成员 | NativeAOT 裁剪（R2） |
| 7 | `osu.Game.csproj` | `PackageReference ppy.osu.Framework` → `ProjectReference ../osu.Framework/osu.Framework.csproj` | 走本地源码 |

---

## 六、里程碑与可验证 Gate

| Gate | 判据 | 状态 |
| --- | --- | --- |
| M0 | `ohos_hello(21) = 84` + `M0 PASS` | ✅ 已通过（x86_64 模拟器） |
| M1a | HAP 内 `libSDL3.so` 可被 `dlopen`，`SDL_GetVersion()` ≥ 3.x、`SDL_GetPlatform()` 为 OpenHarmony、NAPI 模块 `SDL3` 注册成功 | ✅ **已通过**（x86_64 模拟器：`ver=3005000 platform=OpenHarmony`，M0 回归 PASS） |

> **M1a 实测约束**：从 NAPI 直接调 `SDL_Init()` 会返回 false 并报
> `Application didn't initialize properly, did you include SDL_main.h...`。
> 这不是加载失败，而是 SDL3 OHOS 后端强制走 `SDL_RunApp → libmain.so → SDL_main`。
> 所以 Gate 判据**不含**直接 `SDL_Init`，且 M1b 必须由 XComponent 触发启动链。
| M1b | XComponent surface created → SDL3 调 `libmain.so` 的 `SDL_main` → 托管 `GameHost` 起来并清屏 | 🔶 启动链 + 托管入口已实测通过；ICU / NUnit 裁剪两处已修；R11 原生依赖待解 |
| M1c | 真 `OsuGame` 主菜单 / 选歌页渲染 | 未开始 |
| M2 | 真判定 / 计分 / acc / maxCombo 与桌面 lazer 同谱一致 | 未开始 |
| M3 | `.osz` 导入、音频打通、120Hz、性能与延迟实测 | 未开始 |

---

## 七、当前未决风险

- **R1 音频**：BASS → SDL3 `ohaudio` 的替换深度尚未实测；可能需要在 framework 的 `AudioManager` 层做完整后端替换，
  也可能可以用 `libbass.so` API 兼容 shim（导出 `BASS_Init/BASS_StreamCreateFile/BASS_ChannelPlay/...`）降低改动量。
  M1b 跑通后立即启动，不要拖到 M3。
- **R2 反射裁剪**：lazer 重度 DI/反射，`rd.xml` 是持续体力活；iOS Full-AOT 历史说明代码库本身兼容。
- **R8 native ABI**：Android `.aar` 里的 FFmpeg / `libc++_shared.so` 一律不可复用。
- **SDL3 main 非 release**：当前拉的是 main（OHOS 后端计划 3.6.0，最新 release 仅 3.4.20），需在后续锁定一个 commit。
- **双入口冲突**：现有 TS 版 Index 页与 SDL3 的 XComponent 页不能同时接管 `EntryAbility`；
  M1b 前需要决定切换方式（新增独立 Gate 页面 / want 参数分支 / 直接替换）。
  → 已按用户选择 **路径 B** 解决：`Index.ets` 全换成单个 XComponent，旧 TS 主菜单备份到 `output/legacy-ts/Index.ets`。
- **R9 本地化保真度（本轮新增）**：为绕开 ICU FailFast 开了 `InvariantGlobalization=true`，
  所有 culture 退化为 invariant，数字/日期格式化与 `CompareInfo` 排序与桌面 lazer 不同，
  违背「体验完全一样」。摸底结果：NativeAOT 需 105 个 ICU 函数，
  OHOS 的 `libicu.so` NDK 桩只有 560 个符号且缺 28 个必需函数
  （`usearch_*` / `ures_*` / `udatpg_*` / `ucol_*` / `ucurr_*` / `ulocdata_*`），
  且只导出**无版本后缀**符号、库名也不是 `libicuuc.so.<NN>`。
  简单改名 shim 不可行，M2 需用 OHOS clang 交叉编译一份完整 ICU4C 随 HAP 分发。
- **R11 原生依赖 ABI（本轮摸底）**：HAP 目前只有 `Hello.so` / `libSDL3.so` / `libmain.so`。
  framework 经 NuGet 还需要 `libbass.so` / `libbassmix.so` / `libbass_fx.so`
  （`ppy.osu.framework.nativelibs`）、`librealm-wrappers.so`（Realm 20.1.0）、
  `libe_sqlite3.so`（SQLite 3.53.4）与 FFmpeg 系列。实测这些 `linux-x64` 产物的
  `DT_NEEDED` 全是 `libc.so.6` / `libm.so.6` / `libpthread.so.0` /
  `ld-linux-x86-64.so.2`，**glibc ABI，OHOS musl 不可直接加载**。
  M2 需逐个用 OHOS clang 交叉编译或写兼容 shim（音频优先 SDL3 `ohaudio`）。
- **R10 托管侧可观测性**：OHOS 应用进程 stdout/stderr 不进 hilog，
  FailFast / 未处理异常表现为「无 LastFatalMessage 的 SIGABRT」。
  已在 `NativeEntry.cs` 加 `OHOSLog`（`OH_LOG_PrintMsg` 固定 5 参数）与 try/catch；
  崩溃栈用未 strip 的 `output/aot-tools/libmain-x86_64/libmain.so` + `llvm-symbolizer` 还原。

---

## 八、M1b 首轮冷启动复盘（2026-11-13）

1. `hilog` 证据：`M0 PASS`、`provideArkTSObjects OK`、`Calling SDL_main!`、
   `SIGABRT` / `LastFatalMessage:Calling SDL_main!`，栈 18 帧全在 `libmain.so`。
2. 符号化结论（详见 `ROUTE-A-PLAN.md` §13.7）：
   `OsuGame..ctor → Vector2..cctor → CultureInfo.CurrentCulture → GlobalizationMode.Settings..cctor
   → LoadICU() == 0 → Environment.FailFast → SystemNative_Abort → abort()`。
3. 修复：`InvariantGlobalization=true` + `PredefinedCulturesOnly=false`（编译期裁剪掉
   `libSystem.Globalization.Native.a`）、托管异常打进 hilog、HAP 内自动 strip。
4. 复验受阻：修复版 HAP 已构建并安装成功，但模拟器随后出现
   `THREAD_BLOCK_6S`（sceneboard 重启）→ 锁屏 → `aa start` 返回
   `10106102 The device screen is locked` → hdc 目标 Offline。
   属于设备环境故障，不是代码回归；需等模拟器恢复后重跑
   `python aot-tools/run-m1b-gate.py --skip-install --wait 25`。

---

## 九、M1b 逐层排障记录（2026-11-21）

启动链已完全打通，之后暴露出的都是「桌面 Linux 假设」与「NativeAOT 静态编译」两类问题。
每轮只推进一层，因此按崩溃点顺序记录。

| 轮次 | 崩溃点 | 根因 | 修复 |
|---|---|---|---|
| 1 | `GlobalizationMode.Settings..cctor → FailFast → abort()` | OHOS 无带版本号的 ICU | `InvariantGlobalization=true`，编译期裁掉 `libSystem.Globalization.Native.a` |
| 2 | `LoadingComponentsLogger → DebugUtils → NUnit.AdhocContext` | 发布版仍走 NUnit 探测 + 反射，被裁剪 | `DebugUtils.IsNUnitRunning` 在 `OSU_OHOS` 下直接返回 false |
| 3 | `Library.Load() → NullReferenceException` | `AppContext.GetData("NATIVE_DLL_SEARCH_DIRECTORIES")` 在 NativeAOT 共享库宿主返回 null，原码 `paths.Split(':')` 直接 NRE；且 `[DllImport("libdl.so.2")]` 在 musl 不存在 | `Library.cs` 增加 `#if OSU_OHOS` 分支，改用 `NativeLibrary.TryLoad`；`GameHost.Run` 的 `RuntimeInfo.EntryAssembly.GetName()` 改为 `?.`，`OHOSGameHost` 构造时补 `EntryAssembly` |
| 4 | `InputConfigManager.bindToHandlersBindables() → MethodInfo.MakeGenericMethod()` | NativeAOT 只编译编译期已知的泛型实例化，运行时构造泛型方法不可用 | 新增非泛型接口 `IValueChangeNotifier`，`Bindable<T>` 在 `TriggerValueChange` 中同步触发；`InputConfigManager` 改为 `is IValueChangeNotifier` 订阅，彻底去掉泛型反射 |

### 9.1 新增：启动模式切换（不重编即可切换）

为了把「平台链是否健康」和「lazer 原生依赖是否齐备」两类问题隔离开，新增最小自检 Game：

- `osu-ohos/osu.OHOS/SelfTestGame.cs`：零依赖 `Game`（两个 `Box` + 旋转动画），
  跑满 240 帧后主动 `Exit()`，每 60 帧打一条 `selftest frame=N`。
- `NativeEntry.ReadMode()` 读 `/data/storage/el2/base/files/osu-mode.txt`：
  `selftest` → `SelfTestGame`，其余 → `OsuGameOHOS`。
- `EntryAbility.writeMode(want)` 每次 `onCreate` 重写该文件（缺省写 `lazer`，
  避免上次 selftest 残留），来源是 `want.parameters['osu_mode']`。

用法：

```bash
# 平台链自检
hdc shell aa force-stop com.example.myapplication
hdc shell aa start -a EntryAbility -b com.example.myapplication --ps osu_mode selftest

# 回到完整 lazer
hdc shell aa force-stop com.example.myapplication
hdc shell aa start -a EntryAbility -b com.example.myapplication
```

判定：`OSU-CS: selftest frame=60/120/180` 递增 + `selftest completed 240 frames`
即说明 SDL3 窗口、GL 渲染、线程与帧循环全部正常，问题只可能在 lazer 的数据/音频原生库。

### 9.2 已确认的下一个硬墙

- **Realm**：`librealm-wrappers.so` 的 `DT_NEEDED` 含 `ld-linux-x86-64.so.2`，
  glibc 专属，OHOS 无法加载；NuGet 只发二进制，必须从 `realm-core` 源码交叉编译。
- **SQLite**：`libe_sqlite3.so` 同理是 glibc ABI；但 SQLite 是纯 C 单文件 amalgamation，
  用 OHOS clang 重编成本很低。
- **BASS**：`libbass.so` 依赖 `libdl.so.2` / `libpthread.so.0` / `GLIBC_2.2.5`
  版本化符号与 `__fxstat64`，musl 下不可用；M2 需以 SDL3 `ohaudio` 或
  `OH_AudioRenderer` 为底座另建低延迟后端。

### 9.3 构建链陷阱：publish 失败时静默复用旧 `.o`

**现象**：修改 `InputConfigManager.cs` 后重编，产物体积与 `SDL_main` 偏移跟上一轮
**逐字节一致**；设备上仍然抛同一个 `MakeGenericMethod` 异常。

**根因**：`build-aot.py` 的 publish 阶段允许失败（最终链接必然因 OHOS lld 差异失败），
只检查「native 目录里有没有 `.o`」。publish 若在 ILCompiler 之前就失败，
上一轮留下的 `.o` 仍在，脚本于是判定成功并继续链接 —— 打出的是**旧代码的二进制**。

**修复**：publish 前主动删除 `obj/Release/net*/<rid>/native/*.o` 与 `*.exports`，
让「没有 `.o`」真正等价于「ILCompiler 失败」。

**通用教训**：任何「允许部分步骤失败」的构建脚本，都必须保证**失败不可能被旧产物掩盖**。
验证手段不能只看文件是否存在，要看**产物是否比输入新**，或干脆先删。

**自检方法**（无需上设备）：

```bash
# 新代码里的唯一字符串必须出现在最终 .so 里
python - <<'PY'
data = open("aot-tools/libmain-x86_64/libmain.so", "rb").read()
print(b"IValueChangeNotifier" in data)
PY
```

### 9.4 第 5-7 轮：从「静默返回」到 EGL 根因

| 轮次 | 现象 | 根因 | 修复 |
|---|---|---|---|
| 5 | `GameHost.Run returned unexpectedly`，0.7 秒正常返回，无异常 | `ChooseAndSetupRenderer()` 用 `catch { }` 吞掉所有渲染/窗口初始化异常，最后 `Window == null` 时静默 return | 在 `OHOSGameHost` 覆写 `ChooseAndSetupRenderer()`，只走 GL 路径并把异常完整抛出（`OHOSHostBridge.LogError`） |
| 6 | `Failed to create an SDL3 GL context (Could not bind EGL API)` | `SDL3GraphicsSurface.initialiseOpenGL()` 用 `RuntimeInfo.IsMobile` 选 profile；OHOS 既非 Android 也非 iOS，被判为桌面 → 请求 `SDL_GL_CONTEXT_PROFILE_CORE` → `eglBindAPI(EGL_OPENGL_API)`，而 OHOS `libEGL.so` 只支持 `EGL_OPENGL_ES_API` | `RuntimeInfo` 在 `OSU_OHOS` 下固定 `IsMobile=true` / `IsDesktop=false` |
| 7 | 待验证 | — | — |

**为什么第 6 轮的修法是对的，而不是在 `SDL3GraphicsSurface` 里打补丁**：
OHOS 的语义确实是移动端——只有 GLES、触摸输入、单实例单线程渲染、竖屏缩放容器。
把 `IsMobile` 修正后，framework 里所有「移动端 vs 桌面」的分支（光标隐藏、
缩放目标尺寸、输入处理、窗口装饰）会一次性全部走对，而不是只修好 GL 一处。

### 9.5 设备环境踩坑：模拟器被主机内存压垮

本轮排障中模拟器反复掉线，`kernel.log` 显示：

```
sysrq: Show Blocked State
Kickdog: OpenInitWatchdogFile
StopAllServices stop service watchdog_service
sysrq: Trigger a crash
Kernel panic - not syncing: sysrq triggered crash
```

不是应用崩溃，而是 **guest 启动超时**（约 340 秒）后 init 主动 sysrq crash。
`crash_server.log` 同时报 `memory is low, freeMem: 1438 / 15986`。

原因：AOT 链接 742 MB 的 `.o` 与 4 GB 的模拟器同时跑，主机内存被挤爆。

处置：
1. **构建与模拟器不要同时跑**——先 `Emulator.exe -stop "Mate 90 Pro"` 再 publish。
2. 实例内存从 4096 降到 3072（`config.ini` / `hardware-qemu.ini` 的 `hw.ramSize`），
   备份为 `*.bak4096`，需要时可还原。
3. 模拟器可用 CLI 直接管理（无需 GUI）：

```bash
Emulator.exe -list -details
Emulator.exe -start "Mate 90 Pro" -noWindow
Emulator.exe -stop  "Mate 90 Pro"
```

### 9.6 第 8 轮：GL context 成功，暴露出 osuTK 反射裁剪

`RuntimeInfo.IsMobile = true` 生效后：

```
OSU-CS: osu-mode = 'selftest'
OSU-OHOS: ChooseAndSetupRenderer failed: System.InvalidOperationException:
  Sequence contains no matching element
   at System.Linq.ThrowHelper.ThrowNoMatchException()
   at osu.Framework.Platform.SDL3.SDL3GraphicsSurface.loadEntryPoints(...)
   at osu.Framework.Platform.SDL3.SDL3GraphicsSurface.loadBindings()
   at osu.Framework.Platform.SDL3.SDL3Window.Create()
```

**含义**：EGL / GLES 这一关已经过了（不再有 `Could not bind EGL API`），
现在是在 GL context 建好之后、装载入口点的反射步骤失败。

`loadEntryPoints()` 的实现：

```csharp
var pointsInfo = type.GetRuntimeFields().First(x => x.Name == "_EntryPointsInstance");
```

它靠反射读 `osuTK` 中 `GraphicsBindingsBase` 各子类的**私有静态字段**。
`osu.Framework` / `osu.Game` 已是裁剪根，但 `osuTK` 是独立程序集、没有 root，
这些从未被代码直接引用的私有字段被 NativeAOT 裁掉，`First()` 因此抛异常。

**修复**：`osu.OHOS.csproj` 增加 `<TrimmerRootAssembly Include="osuTK" />`。

**规律**：NativeAOT 下任何 `GetRuntimeFields()` / `GetProperties()` 反射访问
未直接引用的私有成员，都需要显式 root，否则表现为
`Sequence contains no matching element` 这类与真实原因毫不相干的 LINQ 异常。

### 9.7 第 9 轮：NativeAOT 结构体封送数据缺失

`osuTK` root 之后，GL context 建好、`loadBindings()` 通过，崩在**第一帧**：

```
host.Run failed: System.NotSupportedException:
  'osu.Framework.Graphics.Shaders.Types.UniformBool' is missing structure marshalling data
   at RuntimeInteropData.GetStructUnsafeStructSize
   at Renderer.validateUniformLayout[TData]()
   at Renderer.CreateUniformBuffer[TData]()
   at Renderer.BeginFrame(Vector2)
   at GLRenderer.BeginFrame(Vector2)
   at DrawThread.OnInitialize()
```

**根因**：`Marshal.SizeOf` 需要该类型的「结构体封送数据」，
而 NativeAOT 只为确实出现在 P/Invoke / Marshal 调用中的类型生成这些数据。
`Uniform*` 系列是纯托管结构体，从未参与封送，因此没有数据。

**受影响的 4 处**（全部在 GL 路径上，必须一起改）：

| 位置 | 原代码 |
|---|---|
| `Renderer.validateUniformLayout` | `Marshal.SizeOf(field.FieldType)` |
| `GLUniformBuffer<TData>` | `Marshal.SizeOf(default(TData))` |
| `GLShaderStorageBufferObject<TData>` | `Marshal.SizeOf(default(TData))` |
| `GLVertexUtils<T>.STRIDE` | `Marshal.SizeOf(default(T))` |

**修复**：新增 `osu.Framework/Extensions/StructSize.cs`：

```csharp
public static int Of<T>()
{
    var layout = typeof(T).StructLayoutAttribute;
    if (layout != null && layout.Size > 0)
        return layout.Size;      // 显式 Size 优先，语义完全一致
    return Unsafe.SizeOf<T>();    // blittable 结构按托管布局
}
```

关键点：**不能用 `Unsafe.SizeOf` 统一替换**。
`UniformBool` 声明了 `[StructLayout(Size = 4)]`，但托管布局只有 1 字节的 `bool`，
`Unsafe.SizeOf<UniformBool>()` 会返回 1，直接算错 UBO 步长。
必须先读 `StructLayoutAttribute.Size`。

### 9.8 第 10 轮：OpenSSL 缺失 → FailFast（不是异常，抓不到托管栈）

符号化 `SIGABRT` 的栈顶落在 `libmain.so` 内部，还原后是：

```
CryptoInitializer.InitializeOpenSslShim()
  -> SystemNative_InitializeOpenSSLShim() == 0
     -> FailFast()   // abort()，不是 throw
```

**根因**：.NET 的 `System.Security.Cryptography` 在 Unix 上走 OpenSSL shim，
启动时 `dlopen("libssl.so.3")`。OHOS 既没有 OpenSSL 共享库，
sysroot 里的 `libcrypto_ndk.z.so` 也只是给 NAPI 用的极小子集，符号对不上。

触发点很小：`osu.Framework/Extensions/ExtensionMethods.cs` 里 4 个
`ComputeMD5Hash` / `ComputeSHA2Hash`（`GlyphStore` 算字体缓存 key 就会调）。

**修复**（两选一里选了后者，因为前者要额外背一套 OpenSSL 编译）：

* 方案 A：给 OHOS 编 OpenSSL 3 并塞进 HAP —— 多一个 ~3 MB 依赖，且要处理
  `libssl`/`libcrypto` 的 `DT_NEEDED` 与 musl 复用。
* **方案 B（采用）**：这 4 处只需要 MD5 与 SHA-256，且 `ExtensionMethods` 是
  framework 内部工具函数，调用频率低（字体缓存 key、资源包校验）。
  新增 `osu.Framework/Extensions/ManagedHashes.cs`，用纯托管实现替换，
  彻底去掉 `System.Security.Cryptography` 的原生依赖。

对照验证：`output/aot-tools/hashcheck` 用 Windows 上 .NET 的 CNG 实现
（`MD5.HashData` / `SHA256.HashData`）做逐字节比对，
覆盖长度 0–200、跨块边界、大块（>1 MB）与标准测试向量，全部一致。

> 注意：这条只解决 **framework**。`osu.Game` 若在别处用 AES/RSA/随机数，
> 同样会触发 `CryptoInitializer`。`RandomNumberGenerator` 尤其常见，
> 届时必须同样改为托管实现（或整体切换 `System.Security.Cryptography.UseOpenSsl=false`
> —— .NET 10 的 `System.Security.Cryptography.dll` 里**没有**这个开关字符串，已实测确认）。

### 9.9 第 11 轮：BASS 不存在（桌面二进制是 glibc，musl 加载不了）

`AudioManager` 一构造就 `BASS_Init`，`DllNotFoundException: bass`。

`libbass.so` 官方 Linux 版 `DT_NEEDED` 含 `libdl.so.2` / `libpthread.so.0`，
且引用 `GLIBC_2.2.5` 版本化符号与 `__fxstat64`——OHOS musl 一个都没有，
不可能靠符号垫片救活。因此写 **BASS 兼容层**：`output/osu-ohos/native/bass-shim/bass_shim.c`
（一份源码编出 `libbass.so` / `libbassmix.so` / `libbass_fx.so` 三个 .so，
用 `-DSHIM_MODULE=0/1/2` 区分导出集）。

关键约束（musl ldso 源码确认，见 `ldso/dynlink.c` 的 `load_library`）：

* 绝对路径 `dlopen("/data/.../libbass.so")` 加载的对象**不会**写入 `shortname`；
* 后续 `DllImport("bass")` 走的是裸名查找，只按 `shortname` / inode 复用，
  所以「先绝对路径 dlopen」**无效**；
* 只有作为 `DT_NEEDED` 加载（名字里没有 `/`）时 musl 才补 `shortname`。

所以垫片必须做成 `libmain.so` 的 `DT_NEEDED`，并配 `rpath=$ORIGIN`：

```
NEEDED libbass.so / libbassmix.so / libbass_fx.so   <- 由 build-aot.py 的 extra 段挂上
RUNPATH $ORIGIN                                     <- 与 libmain.so 同目录（libs/x86_64）
```

同时必须在 `libmain.so` 的 version script 之外允许这些未定义引用解析成功，
链接参数用 `-Wl,--no-as-needed -L<shim> -lbass -lbassmix -lbass_fx -Wl,-rpath,$ORIGIN`。

垫片当前语义：**时钟推进式静音后端**——所有 handle 有效、采样位置按
`BASS_ChannelGetPosition` 单调前进、`BASS_ChannelIsActive` 按播放状态返回，
但混音结果为静音。目的是让 lazer 的整个音频子系统（Track / Sample /
AdjustableAudioComponent / 混音器）能完整运行，先把画面跑起来。

### 9.10 第 12 轮：着色器编译器 `libveldrid-spirv`

GL context 与入口点都正常后，第一次编译着色器报 `DllNotFoundException: veldrid-spirv`。

**为什么绕不过**：`osu.Framework/Graphics/Shaders/ShaderCompilationStore.cs`
的整条链路是 GLSL → glslang → SPIR-V → SPIRV-Cross → ESSL，
只有 3 个 C 导出：`CompileGlslToSpirv` / `CrossCompile` / `FreeResult`。
NuGet `ppy.veldrid.spirv` 只发 glibc/GLIBCXX 版本，musl 无法加载。

**处置**：从 `ppy/veldrid-spirv@5911265ec3` 源码用 OHOS clang 重编，得到
`libveldrid-spirv.so`（19 MB，strip 后 12 MB），同样作为 `DT_NEEDED` 挂进 `libmain.so`。
构建脚本：`output/aot-tools/build-veldrid-spirv.py`。

两处上游必须打的补丁（脚本幂等施加）：

| 文件 | 问题 | 补丁 |
|---|---|---|
| `SPIRV-Tools/CMakeLists.txt` | 没有 OHOS 平台分支，落到 `else()` 报 Unknown platform | 加 `OHOS` 分支，与 Linux 同构 |
| `glslang/OSDependent/Unix/ossource.cpp` | 用 `pthread_setcanceltype`/`pthread_testcancel`，OHOS musl 未导出；Android/Fuchsia 已有豁免 | 判断里加 `__OHOS__` |

另一个坑：OHOS 工具链会注入 `--gcc-toolchain`，clang 视为「未使用参数」给警告，
而 shaderc 系列 target 开了 `-Werror`，必须加
`-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument`（CXX 同理）。

### 9.11 M1b 最终结果：PASS（2026-11-22 07:16）

`python aot-tools/run-m1b-gate.py --mode selftest`：

```json
{
  "success": true,
  "gate": "M1b-selftest PASS",
  "sdl_main_called": true,
  "managed_entered": true,
  "sdl_main_returned": false,
  "managed_exception": false,
  "crashed": false,
  "selftest_completed": true
}
```

hilog 实测帧循环（`load()` 后 0.6 秒出首帧，稳定 ~112 fps）：

```
07:16:25.872  selftest scene graph loaded (2 boxes)
07:16:26.534  selftest frame=60
07:16:27.071  selftest frame=120
07:16:27.614  selftest frame=180
07:16:28.143  selftest frame=240
...           selftest frame=2580
```

截图 `output/s5.png` 目视确认：深灰背景（`#1C1E24`）+ 粉色方块（`#FF69B5`）沿圆周运动并自转。

**至此「真 osu!lazer C# 代码在 HarmonyOS 上渲染出画面」已闭环**：
NativeAOT 无 VM → SDL3 OHOS 后端的 XComponent 窗口 → EGL/GLES 3.0 →
osuTK 入口点 → GLRenderer 帧循环 → 真实 scene graph 的 Box 绘制。

> 关于 `Exit()` 不生效：`OHOSGameHost.CanExit => false`（照 Android 语义，移动端
> 由系统回收进程），所以 `GameHost.Exit()` 是空操作，`SelfTestGame` 里调用它不会停。
> 这不是 bug，但意味着 selftest 无法「主动退出」，判据只能看帧数。

## 十、M2：数据/音频原生依赖

M1b 之后 `lazer` 模式的第一个硬墙就是 Realm（`DllNotFoundException: realm-wrappers`）。
下面按「依赖 → 处置 → 关键约束」记录。

### 10.1 依赖总表（从 libmain.so 的 P/Invoke 统计）

| 原生库 | 托管侧 P/Invoke 名 | 来源 | OHOS 处置 | 状态 |
|---|---|---|---|---|
| `libbass` / `libbassmix` / `libbass_fx` | `bass` / `bassmix` / `bass_fx` | ManagedBass + NuGet 原生 | 自建兼容层（静音时钟后端） | ✅ 已挂载 |
| `libveldrid-spirv` | `veldrid-spirv` | ppy.veldrid.spirv | 源码重编（含 glslang/SPIRV-Tools/SPIRV-Cross） | ✅ 已挂载 |
| `librealm-wrappers` | `realm-wrappers` | Realm 20.1.0（realm-core 20.1.2） | 源码重编 | ✅ 已挂载 |
| `libe_sqlite3` | `e_sqlite3` | SQLitePCLRaw（sqlite 3.53.4） | amalgamation 重编 | ✅ 已挂载 |
| SDL3 | `SDL3` | 官方 OHOS 后端 | 源码重编 | ✅ M1a 已完成 |
| sentry-native | `sentry_native` | Sentry .NET | 不需要（见 10.4） | — |
| FFmpeg | `avcodec` 等 | 视频背景 | 见 10.5 | 待办 |

### 10.2 Realm：musl 下反而**不需要 OpenSSL**

这是本轮最有价值的发现。realm-core 的条件是：

```cmake
if(REALM_ENABLE_ENCRYPTION AND CMAKE_SYSTEM_NAME MATCHES "Linux|Android")
    set(REALM_NEEDS_OPENSSL TRUE)
endif()
```

OHOS 的 `CMAKE_SYSTEM_NAME` 是 `OHOS`，不匹配 `Linux|Android`；
再加 `-DREALM_ENABLE_ENCRYPTION=OFF`（lazer 的本地库不加密），
就完全不会 `find_package(OpenSSL)`，而是落到**内置 SHA-1/SHA-2 实现**
（`src/realm/util/sha_crypto.cpp` 的 `REALM_USE_BUNDLED_SHA2` 分支 +
`src/external/sha-1`、`sha-2`）。

结果：`librealm-wrappers.so` 的 `DT_NEEDED` 只有 `libc.so`，12.7 MB（strip 后 6.8 MB），
导出 1169 个 C 函数，SONAME 正确。**不需要为 realm 编 OpenSSL。**

构建要点：

| 项 | 值/做法 |
|---|---|
| 源码 | realm-dotnet 20.1.0 的 `wrappers/` + realm-core **v20.1.2** 全量源码放进 `wrappers/realm-core/` |
| 子模块 | realm-core 的 `src/external/sha-1`（clibs/sha1）与 `sha-2`（kalven/sha-2）**不在 tarball 里**，必须单独补 |
| 目标 | `realm-wrappers`（SHARED），链接 `Realm::ObjectStore` + `Realm::QueryParser` |
| 必须补丁 | `realm-core/src/realm/util/thread.cpp` 的 robust mutex 判定加 `&& !defined(__OHOS__)` |

robust mutex 那处值得记下来：判据是
`_POSIX_THREADS >= 200809L && !__GNU_LIBRARY__ && !REALM_ANDROID → 可用`。
musl 声明了 `_POSIX_THREADS=200809L` 但**没实现** robust mutex
（`pthread_mutexattr_setrobust` / `pthread_mutex_consistent` 未导出），
启发式因此误判，编译期报 `use of undeclared identifier`。
副作用：进程崩溃时不会自动释放 Realm 的跨进程互斥锁（musl 的固有局限，Alpine 上同理）。

### 10.3 SQLite：一个纯 C 文件，零补丁

`osu.Game/Beatmaps/LocalCachedBeatmapMetadataSource.cs` 用 `Microsoft.Data.Sqlite`
（P/Invoke `e_sqlite3`）。NuGet 的 `libe_sqlite3.so` 只 `DT_NEEDED libc.so.6`，
musl 上名字对不上。直接用官方 amalgamation（`sqlite-amalgamation-3530400`，
与包版本 3.53.4 一致）编一遍即可，无补丁。

编译选项对齐 SQLitePCLRaw 发行版：`SQLITE_THREADSAFE=1`（对应源码里的
`sqlite3_config(SQLITE_CONFIG_MULTITHREAD)`）、FTS3/4/5、JSON1、RTREE、GEOPOLY 等。

### 10.4 Sentry：不需要移植

`osu.Game/Utils/SentryLogger.cs` 的构造函数有三道早退：
`OSU_DISABLE_ERROR_REPORTING=1`、`DebugUtils.IsNUnitRunning`、
`!game.IsDeployedBuild || WebsiteUrl 不以 .ppy.sh 结尾`。
我们的移植不是官方发行版，第三道必然成立，`SentrySdk.Init` 不会被调用，
因此 `sentry_native` 永不加载。

### 10.5 FFmpeg（视频背景）：M2 暂缓

Android 的 `.aar` 里是 Bionic ABI 的 `libavcodec.so` 等，musl 不可用。
lazer 的视频背景是可选功能（谱面背景视频），M2 先不处理；
真正需要时同样走「源码交叉编译 + DT_NEEDED」的路子。

---

## 十一、M2 排障与首个可用版本（2026-11-22）

目标：把真 osu!lazer 从「能起帧循环」推进到「能进主菜单、能响应触摸」。

### 11.1 着色器缓存的反射丢失（`GLShader.CompileInternal() + 0x4ce`）

**现象**：`LoadComplete()` 全部通过，但每一帧都抛

```
NullReferenceException
  at osu.Framework.Graphics.OpenGL.Shaders.GLShader.CompileInternal() + 0x4ce
  at osu.Framework.Graphics.OpenGL.Shaders.GLShader.compile() + 0x9f
  at osu.Framework.Threading.ScheduledDelegate.RunTask() ...
```

两帧后就 `Too many unhandled exceptions, crashing out.`

**定位**：用未 strip 的产物反汇编 `+0x4ce`，配合 DWARF 行表直接落到源码行。

```
llvm-objdump -d --line-numbers --start-address=0xfd0d0b8 --stop-address=0xfd0d0e0 libmain.so

; GLShader.cs:152
 fd0d0ce:  movl  8(%r13), %edi      <-- NRE 在这里
 fd0d0d2:  cmpl  %r14d, %edi
 fd0d0d5:  jle   ...+0x5c0
```

`%r13` 是被 `foreach` 枚举的那个数组，`8(%r13)` 是它的 length；
行号 152 是 `foreach (... in compilation.Reflection.ResourceLayouts)`。
所以不是「某个元素为 null」，而是 **`ResourceLayouts` 本身是 null**。

**根因（关键教训）**：`ShaderCompilationStore` 用 Newtonsoft 把
`VertexFragmentShaderCompilation` 序列化到 `cache/shaders/` 再读回来。
把设备上的缓存文件按 `BinaryWriter` 格式解出来，看到的是：

```json
{ "WasCached": false, ..., "Reflection": {} }
```

`Reflection` 的类型 `Veldrid.SPIRV.SpirvReflection` 是一个
「两个只读属性 + 一个带参构造」的不可变类。ILC 的依赖分析只看直接调用点：

```
llvm-nm libmain.so | grep SpirvReflection
  ..._SpirvReflection__get_ResourceLayouts     <-- 在
  （没有 __get_VertexElements）                  <-- 被裁掉
```

只有 `get_ResourceLayouts` 活下来（`VeldridShader` 用到它），
`get_VertexElements` 没有任何直接调用点，被裁掉。
**而一个属性只要缺任一访问器，NativeAOT 会连整个 Property 元数据记录一起丢掉**，
于是 Newtonsoft 用反射看到的是「零成员」，序列化出 `{}`；
反序列化时带参构造拿不到对应 JSON 属性，两个参数都是 null。

注意 `IlcTrimMetadata=false` + `IlcGenerateCompleteTypeMetadata=true`
**并不能救**：那两个开关管的是「元数据要不要为已保留的成员生成」，
管不了「成员已经被依赖分析移除」。反射可见性取决于成员是否活过裁剪。

**修复（两层）**：

1. `osu.OHOS/rd.xml` 精确保留反射类型（比整体 root `ppy.Veldrid` 便宜得多 ——
   后者会把 D3D11 / D3D12 / Metal / Vulkan 全套后端拖进来）：

```xml
<assembly fullname="ppy.Veldrid.SPIRV">
  <type fullname="Veldrid.SPIRV.SpirvReflection" preserve="all" />
</assembly>
<assembly fullname="ppy.Veldrid">
  <type fullname="Veldrid.ResourceLayoutDescription" preserve="all" />
  <type fullname="Veldrid.ResourceLayoutElementDescription" preserve="all" />
  <type fullname="Veldrid.VertexElementDescription" preserve="all" />
  ...
</assembly>
```

2. `ShaderCompilationStore.tryGetCached()` 增加完整性自检 `isUsable()`：
   缓存只是加速手段，内容不完整就当作未命中并重新编译，
   **绝不把半截数据喂给渲染器**。即使描述符以后失配，也只是退化成慢一点，
   不会再现「异常点离原因十万八千里」的 NRE。

**验证**：启动探针打印反射可见性，修复后为

```
reflection-probe: SpirvReflection.props=[VertexElements,ResourceLayouts]
  | ResourceLayoutDescription.fields=[Elements]
  | ResourceLayoutElementDescription.fields=[Name,Kind,Stages,Options]
```

缓存文件也从 `"Reflection": {}` 变成完整内容（6 个顶点属性、3 个资源布局）。

**同族问题（第二次踩）**：缓存能读之后又抛

```
NotSupportedException: 'List`1[Veldrid.ResourceLayoutDescription]'
  is missing native code or metadata
```

Newtonsoft 把 JSON 数组读成 `List<T>` 再 `ToArray()`，这个泛型实例是
「按 JSON 内容临时决定」的，ILC 看不到。用 `[DynamicDependency]` 显式声明：

```csharp
[DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.ResourceLayoutDescription>))]
[DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.ResourceLayoutElementDescription>))]
[DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.VertexElementDescription>))]
private static void primeAotReflection() { }
```

由 `tryGetCached()` 真实调用一次，保证方法本身不被裁掉。
注意必须写 `global::Veldrid` —— 本命名空间下有个
`osu.Framework.Graphics.Veldrid` 子命名空间，裸写 `Veldrid.X` 会被解析成它。

**方法论沉淀**：NativeAOT 里所有「只被 Newtonsoft / AutoMapper / Activator 用到」的
成员都是定时炸弹，而且**炸点离原因很远**（写入端静默产出空对象，读取端在几百行外 NRE）。
遇到这类问题：

1. 先看产物里有没有对应符号（`llvm-nm`），比读代码快得多；
2. 有 DWARF 行表就直接 `--line-numbers` 反汇编，别靠 `+0xNNN` 猜语句；
3. 加一个启动探针把「反射可见性」打出来，一次投入省掉后续所有推测。

### 11.2 M2 Gate：PASS（2026-11-22 08:48）

新增 `aot-tools/run-m2-gate.py`。M1b 的判据（SDL_main 被调到 + 没崩）不够用：
osu.Framework 把渲染线程 / 异步加载里的异常交给 `Logger` 记一条就继续跑，
进程活着完全不代表没问题。M2 判据因此额外要求运行期日志里
**没有** `NullReferenceException` / `NotSupportedException` /
`An unhandled error has occurred`。

```
{ "success": true, "gate": "M2 PASS",
  "sdl_main_called": true, "managed_entered": true,
  "sdl_main_returned": false, "native_crash": false,
  "bad_runtime_lines": [], "reached_menu": true }
```

运行期日志实证：

```
📺 OsuScreenStack(depth:1) suspended             <- 首次向导
📺 OsuScreenStack(depth:2) entered IntroTriangles
📺 OsuScreenStack(depth:3) entered MainMenu      <- 主菜单
📺 ScreenStack(depth:1) entered ScreenWelcome
```

截图 `m2_main_menu.jpeg`：首次启动向导完整渲染（Welcome 文案、语言列表
English / беларуская мова / български / català、元数据语言开关、Back / Get started
按钮、osu! 三角纹理背景）。字体、排版、配色均与桌面版一致。

### 11.3 输入链路验证：PASS

游戏运行中直接注入点击，向导退出并进入主菜单 logo 界面
（带“Click to resume first-run setup at any point”提示与 DEVELOPER BUILD 横幅）：

```bash
hdc shell "uitest uiInput click 1820 1185"
```

说明 SDL3 的 OpenHarmony 视频后端 → OHOS 触摸事件 → SDL 事件队列 →
osu.Framework 输入处理这条链是通的。

截图注意：模拟器只接受 `.jpeg` 后缀，写 `.png` 会报
`fileName invalid, suffix must be .jpeg`。

```bash
hdc shell "snapshot_display -f /data/local/tmp/x.jpeg"
```

### 11.4 音频缺口：`BASS_StreamCreateFileUser`

M2 运行期日志里每个音轨一次：

```
EntryPointNotFoundException: Unable to find an entry point named
'BASS_StreamCreateFileUser' in native library 'bass'.
   at osu.Framework.Audio.Track.TrackBass.prepareStream(...)
   at osu.Framework.Audio.Track.TrackStore.Get(String name)
```

`TrackBass.prepareStream()` 把 `Stream` 包成 `BASS_FILEPROCS`，走
`Bass.CreateStream(StreamSystem.NoBuffer, Decode|Prescan|AsyncFile, ...)`；
垫片缺这个入口，所有音轨（含菜单音乐、谱面音频）都加载失败。

用「从 AOT 产物里抽出所有 BASS 入口点，和垫片导出做全量比对」的办法
一次查清缺口（`llvm-nm -D` + 二进制里的 UTF-8 入口点字符串）：

* 真正缺的只有 `BASS_StreamCreateFileUser` 一个；
* `BASS_WASAPI_*`（11 个）是 Windows 独占模式专用分支，OHOS 不会走到；
* 其余「缺失」是日志插值字符串被正则误抓的噪声（`BASS_initialised____...` 之类）。

**已实现**：新增 `osu-ohos/native/bass-shim/ohosdec.h` 与 `ma_decode.c`
（miniaudio + stb_vorbis，用 `MA_NO_DEVICE_IO` 裁掉设备层只留 `ma_decoder`）。
`BASS_StreamCreateFileUser` 通过 FileProcedures 把整条流读进内存，
再用解码器探测**真实**的采样率 / 声道数 / 总帧数，据此建立通道。
这三个值不能估算 —— VBR mp3 与 ogg 的位速都不是常数，估错会让
`Track.Length`、进度条和 seek 全偏。顺带补了 `BASS_ATTRIB_BITRATE`
（`TrackBass` 建流后立刻读它）。

`ohshim_channel_free()` 相应改为释放解码器 + 压缩数据，
并回调 `procs->close` —— 托管侧 `TrackBass` 依赖这个回调来 Dispose 底层 Stream。

**当前语义仍是「静音但时钟真实」**：位置按墙钟推进，不产生 PCM。
真正出声需要再接一层混音器 + `OH_AudioRenderer`，见 11.5。

### 11.5 下一个里程碑：真音频输出

osu.Framework 的音频结构（读源码确认，不是猜的）：

```
TrackBass: 源 Stream -> BASS_StreamCreateFileUser(Decode|Prescan|AsyncFile)
                    -> BASS_FX_TempoCreate(Decode)      // 变速不变调
                    -> BASS_FX_ReverseCreate(...)       // 反转
                    -> MixerAddChannel(mixer, ...)      // 交给混音器拉取
BassAudioMixer: BASS_Mixer_StreamCreate(freq, 2, MixerNonStop)   // 播放型流
                BASS_ChannelPlay(mixer)
```

要点：子通道是 **Decode** 流（自己不播放），由播放型 mixer 拉取混音后再输出
到设备。所以垫片必须真的实现「混音器 + 设备输出」，不能只把每个通道各自播一遍。

实现计划：`OH_AudioRenderer`（48 kHz / 立体声 / s16 / 低时延模式）作为唯一输出，
回调里遍历「所属为 mixer 且在播放」的子通道，按 volume / pan / freq 做定点混音；
位置由混音进度驱动而非墙钟 —— 这样 `BASS_ChannelGetPosition` 与听到的声音
严格一致，而节奏游戏的判定完全依赖这一点。

已知还需补的：`BASS_ChannelSetSync`（菜单音乐循环用）、
`BassMix.ChannelGetData(FFT512)`（振幅 / 可视化用）。

### 11.6 签名材料过期时的本地重签（2026-11-22 晚）

调试证书在 09:47 过期，DevEco 重新打包得到的 `entry-default-signed.hap`
设备拒装；`devecocli signature generate` 需要重新登录华为账号。
不登录也能继续验证的办法：用 SDK 自带的 `hap-sign-tool.jar`
生成一套本地 CA / 应用证书 / profile 证书，自己重签 HAP。

```bash
# 1) 生成 keystore、三级 CA、应用证书、profile 证书（均 ECC P-256）
java -jar hap-sign-tool.jar generate-keypair ...
java -jar hap-sign-tool.jar generate-ca ...
java -jar hap-sign-tool.jar generate-app-cert ... -outForm certChain -outFile app.cer
java -jar hap-sign-tool.jar generate-profile-cert ... -outForm certChain -outFile prof.cer

# 2) 改写 provisioning profile：延长 validity、替换 development-certificate
# 3) 签 profile，再签 HAP
java -jar hap-sign-tool.jar sign-profile -mode localSign ... -outFile local.p7b
java -jar hap-sign-tool.jar sign-app -mode localSign \
  -appCertFile app-lf.cer -profileFile local.p7b \
  -inFile entry-default-unsigned.hap -outFile local-signed.hap
```

**关键坑**：`sign-app` 报 `Illegal base64 character 20` / `2f` 不是 keystore
或证书链的问题，而是 profile JSON 里 `bundle-info.development-certificate`
的格式。该字段走的是 **URL-safe base64**：
把 PEM 的 base64 体取出来后必须做 `+ → -`、`/ → _`（padding 可留），
否则标准 base64 里的 `/` 会被 URL decoder 拒绝；直接塞 PEM 则会被
`-----BEGIN CERTIFICATE-----` 里的空格拒掉。
`-appCertFile` 则必须保持 PEM（带 header）。

重新打包前务必确认 `entry/libs/<abi>/libbass.so` 与
`osu-ohos/native/bass-shim/<abi>/libbass.so` 一致 —— 构建脚本复制垫片的
时机早于手工重编，容易出现「源码是最新的、HAP 里却是旧的」。

### 11.7 `run-m2-gate.py` 会拉到旧 runtime.log（误判源）

为绕过证书过期，模拟器时间被 UI 改回 `2026-11-22 09:00`。此前的
runtime.log 写于改时间之前的 `12:12`，**mtime 落在"未来"**。
脚本用 `ls -t $REMOTE_LOGS_DIR/*.runtime.log` 取第一个当作"本次日志"，
于是每次都拿到上次运行的文件。后果：

* 已修复的 `BASS_StreamCreateFileUser` 报错一直出现在新建的 `m2-runtime.log` 里；
* `List<ResourceLayoutDescription> missing native code or metadata` 也可能
  是上次构建的残留，而不是当前 HAP 的真实行为。

**修复**：在 `force-stop` 之后、`aa start` 之前加

```python
hdc(["shell", f"rm -f {REMOTE_LOGS_DIR}/*.runtime.log"], a.target)
```

保证拉到的一定是本次启动写出的日志。这个坑和着色器缓存那次一样：
判断"当前构建是否修好"之前，先确认证据本身是不是当前这次运行产生的。

### 11.8 最终闭环：`List<ResourceLayoutDescription>` 修复 + 双路径 M2 PASS

**第 22 轮 AOT**：`ShaderCompilationStore.primeAotReflection()` 里加
`[DynamicDependency]` **不够**，ILC 仍不生成该泛型实例（`llvm-nm` 计数为 0）。
改成**真实实例化**并调用 `Add(default)` / `Count`（用不可达条件防优化掉）后：

```
List<ResourceLayoutDescription>:        0 -> 134 个符号
List<ResourceLayoutElementDescription>: 122 -> 152
List<VertexElementDescription>:        110 -> 134
```

结论：`[DynamicDependency]` 只影响裁剪保留，不会让 ILC 为未被直接引用的
泛型实例**生成代码**；必须有真实的构造 + 成员调用。

**重签产物**：新 `libmain.so`（323,831,000 bytes）替换进
`sign-local/final2-unsigned.hap`，用 `final-sign-tool.jar` + 原调试证书
（`signingTime` 固定在证书有效期内）重签得
`final2-signed.hap`（367,404,425 bytes）。官方 `verify-app` PASS：
`Digest verify result: true` / `verify-app success`。

**双路径 M2 全 PASS**（`bad_runtime_lines: []`，`reached_menu: true`）：

| 路径 | 命令 | 结果 |
|---|---|---|
| 首次编译（清 shader cache） | `run-m2-gate.py --hap final2-signed.hap` | PASS |
| 二次启动（走缓存，验证反序列化） | `--skip-install --keep-shader-cache` | PASS |

第二条是关键：`List<ResourceLayoutDescription>` 元数据缺失原本只在
**读缓存反序列化**时爆，这里证明它已真正修好。启动期反射探针也确认：

```
reflection-probe: SpirvReflection.props=[VertexElements,ResourceLayouts]
  | ResourceLayoutDescription.fields=[Elements]
  | ResourceLayoutElementDescription.fields=[Name,Kind,Stages,Options]
```

**BASS 报错确认为旧日志残留**：干净日志里只有
`BASS initialised` / `Device: OpenHarmony Audio` / `Driver: ohaudio`，
`BASS_StreamCreateFileUser` 的 `EntryPointNotFoundException` 再未出现。

**唯一遗留（属下一里程碑，非 M2 阻塞）**：intro 靠 `IntroScreen`
8 秒看门狗跳过，伴随 `osu! doesn't seem to be able to play audio correctly`。
源码确认该提示是 `ensureEventuallyArrivingAtMenu()` 的兜底（8s 内没到主菜单就
强推），并非音频驱动报错。`DecouplingFramedClock` 在音频源不运行时会用
`StopwatchClock` 自行推进，故 intro 不依赖音频也应走完；日志里反复出现
`Texture N's upload queue is large` 表明首次启动纹理上传拥塞 + 软件渲染低帧率
更可能是诱因。真音频可听输出仍待验证（见 11.5），模拟器无音频输出设备。


### 11.9 关闭登录面板闪退：ArkTS 输入法客户端崩溃（2026-11-23 修复）

**现象**：主菜单右上角 Guest 头像打开「账号」面板，输入用户名或反复
toggle 关闭后，游戏直接退回桌面（进程消失）。

**根因**：faultlog 里三份 `jscrash-com.example.myapplication-*.log` 完全一致：

```
Reason: Error
Error name: Error
Error message: input method client detached. need to be attached first
Error code: 12800009
```

不是 osu 逻辑、也不是 AOT 裁剪——是 **ArkTS 输入法（IME）客户端状态错乱**。
`EntryAbility.ets` 把 `inputMethod.getController()` 通过 `provideArkTSObjects()`
交给 SDL3 OHOS 后端。SDL 的 `SDL_openharmony.c` 两个缺陷：
1. `attach(true,...)` 与 `hideTextInput()` 都是 `napi_tsfn_nonblocking`
   异步投递，无串行化，快速 show→hide 时 hide 可能先于 attach 完成；
2. `hideTextInput()` 后**不 detach**，而登录面板销毁文本框时系统会自行
   detach，之后 SDL 再调 `hideTextInput`/`on`/`off` 就抛 12800009，
   ArkTS 未捕获 → UIAbility 崩溃 → 退回桌面。

**修复**：ArkTS 层注入安全代理 `entryability/SafeIMEController.ets`，
传给 SDL 的不是真实 controller 而是代理，实现同名方法
（`attach/hideTextInput/showTextInput/on/off/detach`）：

* 维护 `attached` 状态，只有真实 attach 成功才置位；
* 未 attach 时 hide/show/on/off 降级为 no-op，直接回调，不碰真实控制器；
* attach 幂等（重复 attach 直接成功回调，避免 12800003）；
* 所有转发包 try/catch，回调一律触发（避免 SDL userdata 泄漏 / 状态机停滞）；
* `insertText`/`deleteLeft` 按字面量重载分别转发（ArkTS 禁 unknown/any，
  用 `as object as` 中转解决 number/string 回调类型断言）。

`EntryAbility.ets`：去掉 `inputMethod` import，改传 `new SafeIMEController()`。
**无需改 SDL C 源码，无需重编 libSDL3.so / libmain.so**——只重新打包 HAP。

**构建/签名**：hvigor 编译 ArkTS 通过，但 SignHap 因证书过期失败（预期）；
用 `entry-default-unsigned.hap`，把 7 个原生库从 `entry/libs/x86_64/` 重新
替换进去（hvigor 会用缓存旧库：libbass.so 曾被打成 579760 而非 653880），
再用 `final-sign-tool.jar` 重签得 `sign-local/ime-fix-signed.hap`
（367,425,803 B），官方 `verify-app` PASS。

**验证**：
* 冷启动 → 主菜单 → 账号面板输入 `testuser` → 点空白处关闭：进程存活，
  jscrash 数量保持 3（全是修复前的旧记录，无新增）；
* 反复 toggle Guest ×6：进程始终存活，代理日志 `attach skipped (already attached)`
  证明幂等保护生效；
* M2 门禁复跑 PASS，`bad_runtime_lines: []`，无回归。
