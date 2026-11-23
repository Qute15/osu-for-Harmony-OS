# ROUTE-A：把真·osu!lazer 原生跑进 HarmonyOS 应用（NativeAOT）

> 目标：不是"画得像"，而是**跑的就是那 300 万行 C#**。约束：延迟低、性能开销小。
> 这份是决策 + 施工文档，事实与风险都按"已验证 / 待验证"标注。

## 一、为什么是这个形态（而不是卓易通）

用户参考视频里"原版 osu 在卓易通"= Android 兼容层方案。它的问题正好踩中用户的两条约束：

| 方案 | 延迟 | 开销 | 可控性 |
| --- | --- | --- | --- |
| 卓易通（容器跑 Android lazer） | 触摸/渲染/音频都要过兼容层转发，多一整层调度 | 跑着整个 Android 运行时 + 容器开销，内存翻倍 | 层本身不是我们的，无法调优 |
| **A-native（本文）** | GL 直连 XComponent 的 EGL surface，输入一帧内进队 | 无 VM、无容器、NativeAOT 静态机器码 | 全链路自己的，可逐项调 |

## 二、架构

```
┌─ HAP（我们现有的 entry 模块）──────────────────────────────┐
│  ArkTS 外壳：权限/文件选择/生命周期（复用现有页面骨架）        │
│  XComponent (SURFACE) ── EGL Window ── GLES3/Vulkan        │
│        │ NAPI                                               │
│  libohos_host.so  (C/C++，桥接层，复用现有 cpp 工程骨架)      │
│   ├─ EGL/GL 上下文管理、vsync 驱动的主循环泵                  │
│   ├─ 触摸事件 → framework 输入队列                           │
│   └─ OHOS AudioRenderer (LOW_LATENCY) → 音频输出回调          │
│        │ dlopen + C ABI                                     │
│  libosu_lazer.so  (NativeAOT，linux-musl-arm64)             │
│   ├─ osu.Framework.OHOS  ← 要写的平台层（范本：Framework.Android）│
│   └─ osu.OHOS + osu.Game + osu.Game.Rulesets.* ← 全量原代码  │
└──────────────────────────────────────────────────────────────┘
```

现有资产复用/废弃：
- **复用**：HAP 外壳、XComponent + NAPI + GL 基础设施（cpp 工程骨架）、抽帧/真机自验流程、`.osz` 导入的文件落盘路径（lazer 自己会解压，我们只负责把文件放进它的 storage）
- **废弃**：1200 行 TS 规则集（`osu/ruleset/*`）与手绘 UI —— 路线 A 成功那天它们就是错的
- **保留参考价值**：`HitErrorBar` 的 UR/直方图语义（做对照时用）

## 三、已验证的事实（2026-11-12 深夜，M0 构建侧全部打通）

1. ✅ Windows 本机有 .NET 9.0.318 / 10.0.403 SDK
2. ❌ WSL 被会话安全策略拉黑（`wsl.exe` 在 Program Blacklist）——**但已经不需要它了**（见 4-6）
3. ✅ 源码包含 `osu.Android/`（38 文件）与 `osu.iOS/`（18 文件）两个移动端 host；游戏层 host 很薄（`OsuGameAndroid.cs` ~150 行），平台层在 `osu.Framework.Android`（NuGet，需从 GitHub 拉 `ppy/osu-framework` 当范本）
4. ✅ **`Cross-OS native compilation is not supported` 是软门不是墙**：`-p:DisableUnsupportedError=true` 直接绕过；之后 ILCompiler 在 Windows 上正常跑完 `Generating native code`，产出 **aarch64 ELF 的 `Hello.o`**（ELF magic + e_machine=183 已验证）
5. ✅ **链接用 DevEco 自带的 OHOS clang 完成**：`clang.exe --target=aarch64-linux-ohos --sysroot=<OHOS musl sysroot>` + nuget `runtime.linux-musl-arm64.Microsoft.DotNet.ILCompiler` 包里的 `.a` + `libclang_rt.builtins.a`（替代不存在的 libgcc）→ **`Hello.so` 6.5MB，`DT_NEEDED` 只有 `libc.so`**，导出 `ohos_hello@@V1.0`（FUNC GLOBAL）
6. ✅ ⏳ **构建宿主问题消失**：整条链路 Windows 本机闭环（dotnet 代码生成 → OHOS clang 链接 → HAP 打包），不依赖 WSL / Linux 服务器 / CI
7. ✅ **设备端 dlopen 实测已通过（2026-11-13，DevEco x86_64 模拟器 `127.0.0.1:5555`，SDK 26）**：
   `A00f0f/OSU-AOT: ohos_hello(21) = 84 (expect 84)` + `EntryAbility aot hello = 84 (M0 PASS)`。
   证明 Windows 本机 AOT 链路、OHOS musl libc 兼容、NativeAOT 运行时（GC/线程/TLS）在 OHOS 应用进程内可用。
   由于模拟器是 x86_64，另编了一份 `linux-musl-x64` / `--target=x86_64-linux-ohos` 的产物验证；
   aarch64 真机构建侧依旧全过，设备侧待真机插回做最终复核（同链路，仅架构不同）。
   详见 §十一「M0 Gate 验收记录」。
8. ✅ OHOS（OpenHarmony 标准系统）用户态就是 musl libc；.NET 官方支持 `linux-musl-arm64` RID

M0 尖刀代码已就位：`entry/libs/arm64-v8a/Hello.so` + `cpp/aot_sample.cpp`（NAPI 模块 `libaotsample.so`，dlopen+dlsym+调 `ohos_hello(21)`）+ `EntryAbility.onCreate` 调用并打 `M0 PASS/VALUE-MISMATCH` 日志。HAP 已构建通过，`Hello.so` 确认在包里。

### 手工链接命令（M0 用的那套，自动化脚本化时抄这个）

```bash
NUGET="C:/Users/z3306/.nuget/packages/runtime.linux-musl-arm64.microsoft.dotnet.ilcompiler/9.0.22"
OHOS="C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
clang.exe obj/.../Hello.o -o Hello.so \
  -Wl,--version-script=obj/.../Hello.exports -Wl,--export-dynamic \
  --target=aarch64-linux-ohos --sysroot="$OHOS/sysroot" \
  $NUGET/sdk/libbootstrapperdll.o $NUGET/sdk/libRuntime.WorkstationGC.a \
  $NUGET/sdk/libeventpipe-disabled.a $NUGET/sdk/libstandalonegc-disabled.a \
  $NUGET/sdk/libstdc++compat.a $NUGET/framework/libSystem.*.a $NUGET/sdk/libz.a \
  $OHOS/llvm/lib/clang/15.0.4/lib/aarch64-linux-ohos/libclang_rt.builtins.a \
  -L"$OHOS/sysroot/usr/lib/aarch64-linux-ohos" \
  -pthread -ldl -lrt -lm -lc -shared \
  -Wl,-z,relro -Wl,-z,now -Wl,-z,stack-size=1572864 -Wl,--eh-frame-hdr \
  -Wl,--discard-all -Wl,--gc-sections -Wl,-T,obj/.../sections.ld -g
```

踩坑记录（自动化时都会再遇到）：
- `where /Q` 探测链接器不认「带空格 + 正斜杠」的完整路径 → 把 OHOS llvm/bin 加进 PATH、`-p:CppCompilerAndLinker=clang.exe`
- OHOS 的 lld 没编 zlib → 别带 `-gz=zlib`（msbuild 侧设 `-p:CompressSymbols=false`）
- sysroot 自带 `libdl/libm/libpthread/librt` 的 musl 存根和 `crti.o/crtn.o`；**没有 libgcc**（OHOS 用 compiler-rt）→ 显式链 `libclang_rt.builtins.a`
- msbuild 里 `TargetTriple` 会被 RID 推导成 `aarch64-linux-musl` 覆盖掉（导致去 sysroot 下找 `usr/lib/aarch64-linux-musl` 而找不到 CRT）→ M0 用手工链接绕开；后续要么用 `AfterTargets` 追加 `LinkerArg`，要么维持「publish 出 .o + 自己链接」两段式


## 四、工具链链路（Windows 本机闭环，已跑通）

```
Windows（一台机器全做完）
  ① dotnet publish -r linux-musl-arm64 -p:DisableUnsupportedError=true
     → ILCompiler 在 Windows 上产出 aarch64 ELF 的 .o（"跨OS不支持"只是软门）
  ② DevEco 的 OHOS clang 链接（--target=aarch64-linux-ohos + OHOS musl sysroot
     + nuget runtime 包的 .a + libclang_rt.builtins.a）
     → libX.so，DT_NEEDED 仅 libc.so
  ③ 拷进 entry/libs/arm64-v8a/ → hvigorw assembleHap（M0 已验证 Hello.so 进包）
  ④ hdc install → 真机
```

后续自动化：把 ①② 写成一个脚本（build-aot.sh），M1 起接入 Framework.OHOS 工程的产物。

## 五、要写的代码（按依赖顺序）

1. **`libohos_host.so` 桥接层（C）** —— 在现有 cpp 工程上加：EGL context 于 XComponent、vsync 对齐的循环泵（`OH_NativeVSync`）、touch → 输入桥、`OH_AudioRenderer` 低延迟回调。骨架大半与现有 `osu_scene.cpp` 重叠。
2. **`osu.Framework.OHOS`（C#，新工程，范本 = Framework.Android）** —— 最重的一块：
   - `OHOSGameHost : GameHost`（生命周期、storage 路径、线程模型）
   - `OHOSGameWindow : IGameWindow`（尺寸/旋转/标题，GL surface 由桥接层供给）
   - 输入设备：把 NAPI 触摸包成 framework 的 `ITouchSource`
   - **音频（最大风险，见 R1）**：framework 唯一后端是 BASS；OHOS 没有 musl-arm64 的 BASS → 自实现 framework 的音频设备接口，接 `OH_AudioRenderer`（LOW_LATENCY 模式）
3. **`osu.OHOS`（C#，照抄 osu.Android 的 ~150 行）** —— 版本号、旋转、导入入口。
4. **`osu.Game.Resources` 内容** —— git 子模块不在 zip 里，从 GitHub 拉官方资源包（字体/默认皮肤纹理全在这）。

## 六、里程碑（每个都有硬验收，不做完不进下一个）

| 里程碑 | 内容 | 验收标准 |
| --- | --- | --- |
| **M0（gate，1–2 天）** | 任意一个 C# 类 NativeAOT 成 .so，HAP 里 dlopen 跑起来 | **✅ 2026-11-13 已通过**：构建侧（双架构产物、`DT_NEEDED` 仅 libc.so、符号导出、进 HAP）+ 设备侧（模拟器 `ohos_hello(21) = 84`、`M0 PASS`）全部达成。aarch64 真机复核为可选项，不阻塞 M1 |
| M1（约 1 周） | Framework.OHOS 空游戏跑起来 | XComponent 里出现 framework 渲染的清屏/测试图形，vsync 对齐不掉帧 |
| M2（约 1 周） | osu! 主菜单 + 选歌真画面 | 真字体真皮肤真封面；帧时间画像对比当前原生渲染器（120fps 基线） |
| M3（约 1–2 周） | 完整可玩 + `.osz` 导入 + 调优 | 打一张谱，与 lazer 桌面端同谱对照：300/100/50/miss、score、acc、maxCombo 全部一致；音频偏移标定流程可用 |
| M4 | 外围收尾（旋转锁定、导入意图、语言） | 全部可玩内容 = lazer 行为 |

## 七、风险（按杀伤力排序，写明对策）

- **R1 音频后端**：framework 只认 BASS，无 OHOS/musl 版 → 必须自写音频设备层接 OHOS 低延迟 API。工作量最大、最影响"手感"。对策：M1 就先打通音频回调，别拖到最后。
- **R2 NativeAOT 反射裁剪**：lazer 重度 DI/反射，裁剪器会砍掉运行时需要的类型 → 逐个补 `rd.xml` 动态成员清单，是持续的体力活。缓解：iOS Full-AOT 兼容历史 + rd.xml 有社区先例。
- **R3 musl/ELF 兼容**：.NET 官方 musl 支持是 Alpine 口径，OHOS musl 有自家 soname 布局 → M0 第一天就验证；不行就走 OHOS clang 链接或 QEMU。
- **R4 内存**：lazer 桌面级占用（几百 MB GC 堆），8GB 手机可行但紧。NativeAOT GC 无分层并发标记，长局可能吃满一核的一部分。M3 做实测。
- **R5 资源缺失**：`osu.Game.Resources` 不在 zip（已知问题）→ GitHub 拉取解决。
- **R6 网络/排行**：设备没 Google 服务、连 osu! 服务器登录在大陆网络不可保证 → 保持离线可玩，排名如实显示"未连接"。

## 八、待用户做的事

1. ~~把手机插回电脑~~ —— **M0 已在 x86_64 模拟器通过**；aarch64 真机复核变为可选项，不再阻塞。
2. ~~构建宿主决策~~ —— **已不需要**（Windows 本机闭环，2026-11-12 实测）。
3. **现有 TS 引擎的去留**：路线 A 期间冻结（不再投入），M2 过了直接删。

## 九、已解除 / 已修正的风险（2026-11-13）

- ~~**R5 资源缺失**：`osu.Game.Resources` 是 git 子模块，不在 zip 里~~ → **判断有误，已解除**。
  `osu.Game.csproj` 直接引用 NuGet 包 `ppy.osu.Game.Resources 2026.918.0`，`dotnet restore` 自动拉齐
  （含 40+ 语言卫星程序集）。同理 `ppy.osu.Framework 2026.921.1` 也是 NuGet 包。
- **`osu.Game.dll` 本机编译已验证**：`dotnet build osu.Game/osu.Game.csproj -c Release` →
  **0 警告 0 错误**（.NET 10.0.403，耗时 1m14s）。这是「跑真 lazer」最基础的可行性证据。
- **Android 平台层精确入口已定位**：`osu.Android.props` 引用 `ppy.osu.Framework.Android 2026.921.0`，
  包内是 `osu.Framework.Android.dll`（30 KB）+ `.aar`（42 MB），nuspec 给出精确 commit `247dee98`。
  平台层很薄，重写范围可控。
- **native 依赖清单（新增风险 R8）**：`.aar` 的 `jni/*/` 含 `libbass.so / libbassmix.so / libbass_fx.so`
  与 FFmpeg 全套（avcodec/avformat/avutil/swresample/swscale/avdevice）、`libc++_shared.so`。
  这些是 **Android/Bionic ABI**，即便同为 aarch64 也不能直接搬到 OHOS musl。
  → 音频必须自实现（R1 确认成立）；FFmpeg 只服务视频背景，M1/M2 可先禁用。
  ~~SDL 不在 Android 平台层依赖里~~ → **此判断有误，已按源码修正，见 §十二**：
  `AndroidGameHost : SDLGameHost`、`AndroidGameWindow : SDL3MobileWindow`、
  `AndroidGameSurface : SDLSurface(Org.Libsdl.App)`，framework 窗口层就是 SDL3。

## 十、M1 前置：已落地工具

| 工具 | 路径 | 作用 |
| --- | --- | --- |
| `build-aot.py` | `output/aot-tools/build-aot.py` | 双架构 AOT 构建；`--rid linux-musl-arm64\|linux-musl-x64` 自动选 OHOS triple、CRT 目录、builtins；自动补 x64 缺失的 `sections.ld` 与 `libRuntime.VxsortEnabled.a` |
| `run-m0-gate.py` | `output/aot-tools/run-m0-gate.py` | 一键 安装 → 启动 → 清日志 → 读 hilog → 判定 `M0 PASS`；规避 hdc 路径拼接坑 |
| HAP 改动 | `entry/build-profile.json5` | `abiFilters` 增加 `x86_64`，让 CMake 同时产出模拟器可用的 NAPI 模块 |

## 十一、M0 Gate 验收记录（2026-11-13 12:25）

设备：DevEco 模拟器 `127.0.0.1:5555`，`Linux localhost 5.10.210 x86_64`，`const.product.cpu.abilist=x86_64`，
`const.ohos.apiversion=26`，`product.name=emulator`。

为满足架构一致，给模拟器另编一份产物：

```bash
python build-aot.py --project output/aot-spike --rid linux-musl-x64 \
  --output output/aot-tools/Hello-x64.so \
  --hap-libs "<project>/entry/libs/x86_64"
# 产物：ELF e_machine=62 (x86-64)，DT_NEEDED 仅 libc.so，导出 ohos_hello@@V1.0
# 落 HAP 时改名为 Hello.so（桥接层 dlopen 固定名）
```

`assembleHap` 成功（40s，x86_64 CMake 同步产出 `libaotsample.so`），安装 + 启动后 hilog：

```text
11-13 12:25:57.111  I C03f04/MMG: [NMM:352]Tail:default/aotsample
11-13 12:25:57.218  I A00f0f/OSU-AOT: ohos_hello(21) = 84 (expect 84)
11-13 12:25:57.218  I A00000/OSU-AOT: EntryAbility aot hello = 84 (expect 84, M0 PASS)
```

**Gate 结论：PASS。** 路线 A 成立，可以正式进入 M1（`osu.Framework.OHOS` 平台层）。
剩余架构差异仅 aarch64 真机复核，与链路正确性无关。

## 十二、M1 架构修正：SDL3 官方已支持 HarmonyOS（2026-11-13）

### 12.1 源码证据

按精确 commit `247dee98` 取回 `osu.Framework.Android` 源码（`output/src-framework-android/`）后确认：

| 类 | 继承 | 关键 override |
| --- | --- | --- |
| `AndroidGameHost` | **`SDLGameHost`** | `SetupConfig`（强制 `ExecutionMode.SingleThread`）、`CreateWindow`、`DrawFrame`（SurfaceReady 门控）、`Swap`（vsync 等待）、`GetStorage`、`UserStoragePaths`、`CreateTextureLoaderStore`、`CreateVideoDecoder`、`CanExit=false`、`CanSuspendToBackground=true` |
| `AndroidGameWindow` | **`SDL3MobileWindow`** | 仅 `SurfaceHandle`（指向 Android Surface）+ `SafeAreaPadding.BindTo` |
| `AndroidGameSurface` | **`SDLSurface`（`Org.Libsdl.App`）** | 生命周期 `HandlePause/HandleResume`、`updateSafeArea` |
| `AndroidStorage` | `NativeStorage` | 空实现，直接可复用 |
| `ChoreographerVsyncWaiter` | — | 用 HandlerThread + Choreographer 做 vsync 对齐 → OHOS 对应 `OH_NativeVSync` |

结论：**平台层极薄，framework 的窗口 / 渲染 / 输入全部走 SDL3**。此前「自写 EGL/vsync/输入桥」的设计对 SDL3 而言是重复劳动。

### 12.2 SDL3 官方 OHOS 后端（外部事实，已查证）

- PR [libsdl-org/SDL#16281](https://github.com/libsdl-org/SDL/pull/16281)，2026-09-15 合入 main，计划 **SDL 3.6.0**；Ryan C. Gordon 移植，Outfit7 赞助，已在华为 Mate 80 真机测试，商业游戏准备上线。
- 覆盖子系统：**Video（OpenGL ES 2.0/3.0）、Audio、Input/触摸、Sensors、电源管理、窗口管理**。
  缺口：手柄 API 为 stub、无触控笔、无系统对话框、2in1 部分支持 —— 对本项目的触屏音游不构成阻塞。
- 支持 HarmonyOS 5.0.4（API 16）+，本机模拟器 SDK 26 / 真机目标满足。
- 平台 triplet 正是 `aarch64-linux-ohos`（与 AOT 链接用的完全一致），devtools 亦支持 `x86_64`。
- 官方构建文档 `docs/README-harmonyos.md`（已存 `output/aot-tools/SDL3-README-harmonyos.md`）：
  ```bash
  $CLT/sdk/default/openharmony/native/build-tools/cmake/bin/cmake -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE=$CLT/sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake \
    -DCMAKE_BUILD_TYPE=Release -DOHOS_COMPATIBLE_SDK_VERSION=16.0.0 \
    -DOHOS_ARCH=arm64-v8a ..     # 或 x86_64
  ```
  产物 `libSDL3.so` + `libmain.so`；官方还提供 `openharmony-project/` 模板工程与
  `build-scripts/harmonyos-tool.sh`（`--build --debug` 一条龙）。

### 12.3 修订后的 M1 施工路径

| 步骤 | 内容 | 与原计划差异 |
| --- | --- | --- |
| 1 | 用 OHOS CMake 工具链编译 SDL3 main 分支，产出 `libSDL3.so`（arm64 + x86_64），放进 `entry/libs/<abi>/` | **新增**：替代自写 EGL/窗口/输入桥 |
| 2 | 写 `OHOSGameHost : SDL3GameHost`、`OHOSGameWindow : SDL3MobileWindow`（照 Android 版约 100 行），`OHOSStorage : NativeStorage` | 大幅缩小：只做 SDL3 接 XComponent NativeWindow + `OH_NativeVSync` 对齐 |
| 3 | `osu.OHOS : OsuGame`（照 `OsuGameAndroid.cs` 的 ~150 行），去掉 Android 专属的 PackageInfo / Orientation | 不变 |
| 4 | **R1 音频**：framework 依赖 `ppy.ManagedBass 2022.1216.0`（纯 C# 绑定）+ native `bass/bassmix/bass_fx`，OHOS 无对应库。SDL3 自带 OHOS audio 后端 → 用 SDL3 音频实现一个 BASS API 兼容 shim，或改写 framework 的 `AudioManager` 后端 | 仍是最大工作量，但已有可用的低延迟输出底座 |
| 5 | FFmpeg / 视频背景：M1/M2 先禁用（`AndroidVideoDecoder` 无 OHOS 对应），M3 再补 | 可延后 |

### 12.4 依赖版本锚点（framework 2026.921.1 的 nuspec）

| 包 | 版本 | 说明 |
| --- | --- | --- |
| `ppy.SDL3-CS` | 2026.722.0 | 纯 P/Invoke 绑定，自带 win/osx/linux/android/ios 的 `libSDL3.so`；**无 OHOS 版 → 用官方 port 编同名库替换** |
| `ppy.Veldrid` | 4.9.69-ga405fe8484 | 渲染抽象，走 SDL3 提供的 GLES 上下文 |
| `ppy.ManagedBass` / `.Fx` / `.Mix` / `.Wasapi` | 2022.1216.0 | 音频，native 缺失（R1） |
| `FFmpeg.AutoGen` | 4.3.0.1 | 视频解码，M1/M2 可禁用 |
| `ppy.osu.Game.Resources` | 2026.918.0 | 字体/纹理，NuGet 自动还原 ✅ |
| `ppy.osu.Framework.NativeLibs` | 2025.806.0-nativelibs | 只有 Windows 的 BASS/FFmpeg DLL，OHOS 用不上 |

> 修订后 M1 的关键风险从「整套平台桥」收敛为「SDL3 for OHOS 能否编译 + BASS 兼容层」，
> 两者都已有明确抓手。

## 十三、M1 实作记录（2026-11-13）

### 13.1 SDL3 for OHOS 双架构编译：完成

源码：SDL3 main（含官方 OpenHarmony 后端），`output/SDL-main/`，16.8 MB。
工具：`output/aot-tools/build-sdl3.py`，DevEco SDK 自带 OHOS CMake / Ninja / clang，Windows 本机闭环。

| 架构 | 产物 | 大小 | SONAME |
| --- | --- | --- | --- |
| `x86_64` | `output/SDL3-build-x86_64-ohos/libSDL3.so` | 2,361,824 | `libSDL3.so` |
| `arm64-v8a` | `output/SDL3-build-arm64-v8a-ohos/libSDL3.so` | 2,237,976 | `libSDL3.so` |

CMake 识别到 `Video: openharmony` / `Audio: ohaudio` / `Camera: openharmony`。
两个必须记住的参数：
- `-DOHOS_COMPATIBLE_SDK_VERSION=26.0.0`（本机 SDK `apiVersion=26`；官方 README 的 `16.0.0` 不适用）；
- `-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1`（官方模板要求，否则 SDL3 数据段被加载两次）。

两份 `.so` 已拷入 `entry/libs/<abi>/libSDL3.so`。

### 13.2 M1a Gate：PASS（x86_64 模拟器）

```
A00f0f/OSU-AOT: SDL3 GATE PASS ver=3005000 platform=OpenHarmony rev=SDL-3.5.0-HEAD... direct_init=0 (SDL_RunApp guard expected)
A00000/OSU-AOT: EntryAbility SDL3 GATE PASS ver=3005000 platform=OpenHarmony
A00000/OSU-AOT: EntryAbility aot hello = 84 (expect 84, M0 PASS)
C03f04/MMG: [NMM:373]Head:default/SDL3, isApp:1     ← SDL3 NAPI 模块注册成功
```

**关键约束（实测）**：从 NAPI 直接调 `SDL_Init()` 会返回 false，报
`Application didn't initialize properly, did you include SDL_main.h...`。SDL3 的 OHOS 后端强制走
`XComponent.OnSurfaceCreated → SDL_OpenHarmonyMainSurfaceCreated → SDL_RunApp →
dlopen("libmain.so") → dlsym("SDL_main")` 启动链。因此 AOT 产物必须命名为 `libmain.so`
并导出 `SDL_main`；不能由 ArkTS 侧手动初始化 SDL。

工具：`output/aot-tools/run-m1a-gate.py`（含 `aa force-stop` 冷启动，否则 `onCreate` 不重跑）。

### 13.3 第二次架构修正：必须使用 framework 源码

- `SDL3MobileWindow` / `SDL3Window` 是 `internal`，`AssemblyInfo.cs` 的 `InternalsVisibleTo`
  只列了 Android/iOS/Tests，**没有 OHOS**；
- R1（BASS 音频后端）必须改 framework 内部实现（18 个文件引用 ManagedBass / Bass.*）。

→ 已拉取 `ppy/osu-framework` 精确 commit `247dee98` 源码（111 MB → `output/fw/`，1098 个文件 +
`CodeAnalysis/` 配置），并在 `AssemblyInfo.cs` 增加 `[assembly: InternalsVisibleTo("osu.Framework.OHOS")]`。

### 13.4 C# 工程骨架：编译通过（0 警告 0 错误）

| 路径 | 内容 |
| --- | --- |
| `output/osu-ohos/osu.Framework.OHOS/` | `OHOSGameHost : SDLGameHost`、`OHOSGameWindow : SDL3MobileWindow`、`OHOSStorage : NativeStorage`、`OHOSHostBridge`（M2 桥接占位） |
| `output/osu-ohos/osu.OHOS/` | `OsuGameOHOS : OsuGame`、`NativeEntry.Main`（`[UnmanagedCallersOnly(EntryPoint="SDL_main")]`）、`osu.OHOS.csproj`（PublishAot + NativeLibrary） |
| `output/src-osu-lazer/.../osu.Game/osu.Game.csproj` | 增加条件 `UseLocalFramework`：AOT 时改用本地 framework 源码 ProjectReference，桌面构建不受影响 |
| `output/aot-tools/build-lazer-aot.py` | 调用 `build-aot.py`，强制 `-p:UseLocalFramework=true`、`--sdk-major 10`，校验 `SDL_main` 导出并按架构落 `libmain.so` |

复现命令：

```bash
dotnet restore output/osu-ohos/osu.OHOS/osu.OHOS.csproj -p:UseLocalFramework=true --force
dotnet build   output/osu-ohos/osu.OHOS/osu.OHOS.csproj -c Release --no-restore \
  -p:UseLocalFramework=true -p:PublishAot=false -p:UseSharedCompilation=false -p:RunAnalyzers=false
# 0 警告 0 错误：osu.Framework / osu.Framework.OHOS / osu.Game / osu_lazer 四个程序集
```

踩坑：
- `CodeAnalysis/BannedSymbols.txt` 与 `osu-framework.globalconfig` 由根目录 `Directory.Build.props` 引用，
  解压时不能只取 `osu.Framework/`；缺了会报 CS2001。
- Windows 长路径：`osu.Framework.SourceGeneration.Tests` 里有超 MAX_PATH 的资源文件，
  必须按短根目录手动提取、跳过 Tests。
- `UseLocalFramework` 必须作为**命令行全局属性**传播；只写在 csproj 里不会传给 `osu.Game`，
  会产生 CS1704「两份同名 osu.Framework」。
- VBCSCompiler 会锁 `osu.Framework.dll` → `dotnet build-server shutdown` + `-p:UseSharedCompilation=false`。

### 13.5 下一步

1. 首次 `dotnet publish -r linux-musl-x64` 全量 AOT，收集反射裁剪 / native 依赖障碍清单
   （`build-lazer-aot.py --arch x86_64`）。
2. M1b：接 XComponent 页面，让 SDL3 拉起 `libmain.so` 的 `SDL_main`，空窗口跑通。
3. R1：BASS → SDL3 `ohaudio` 后端替换。

### 13.6 真 lazer NativeAOT 产物首次链接成功（M1b 前置完成）

`build-lazer-aot.py --arch x86_64` 首次 publish：ILCompiler **成功产出 `osu_lazer.o`**
（真 lazer + framework 源码全部编译成本机代码），publish 只在预期的
`clang : error : invalid linker name in argument '-fuse-ld=bfd'` 处失败。
`--skip-publish` 手工链接后：

```text
[link] .NET 10 运行时布局：.../microsoft.netcore.app.runtime.nativeaot.linux-musl-x64/10.0.14/runtimes/linux-musl-x64/native（21 个库/对象）
[link] OK  661297136 bytes
[verify] ELF e_machine=62；DT_NEEDED 仅 libc.so；导出 SDL_main@@V1.0
```

**新踩坑（重要）**：.NET 10 的 ILCompiler 运行时静态库不再位于
`runtime.<rid>.microsoft.dotnet.ilcompiler/<ver>/sdk/`，而是搬到
`microsoft.netcore.app.runtime.nativeaot.<rid>/<ver>/runtimes/<rid>/native/`，
并新增 `libSystem.Native.a`、`libaotminipal.a`、`libbrotli*.a`；x64 用
`libRuntime.VxsortDisabled.a`（不是 M0 时的 `VxsortEnabled`）。
`build-aot.py` 已同时兼容新旧布局，并用 `--start-group/--end-group` 解决静态库交叉引用。

体积：链接产物 661 MB（含 `-g` 调试信息）→ `llvm-strip --strip-debug` 468 MB
→ **`llvm-strip --strip-all` 222.8 MB**，strip 后 `SDL_main` 与 `DT_NEEDED` 均保持不变。
strip-all 版本已落入 `entry/libs/x86_64/libmain.so`。

> 注意：目前 `SDL_main` 只是**可被加载的导出符号**，还没有 XComponent 页面去触发
> `SDL_RunApp`，所以真 lazer 尚未在设备上跑起来。这是 M1b 的唯一剩余前置。

### 13.7 M1b 首次冷启动：启动链打通，但托管侧 ICU FailFast（已定位根因）

路径 B（用户选择）：`EntryAbility.onCreate()` 调 `sdl.provideArkTSObjects(...)`，
`Index.ets` 只留一个 `XComponent({ id:'SDL_XComponent', type:SURFACE, libraryname:'SDL3' })`。
x86_64 模拟器冷启动 hilog：

```text
A00000/OSU-AOT: Ability onCreate (route B: native SDL3 / osu!lazer)
A00000/OSU-AOT: M0 regression aot hello = 84 (PASS)
A00000/OSU-AOT: M1b SDL3 provideArkTSObjects OK
A00000/SDL/STARTUP: Calling SDL_main!
Reason:Signal:SIGABRT(SI_TKILL) ... Tid:17520, Name:SDL_main
LastFatalMessage:Calling SDL_main!
#01 ld-musl-x86_64.so.1(abort+17)
#02..#18 libmain.so
#19 libmain.so(SDL_main+92)
#20 libSDL3.so
```

**根因**：用未 strip 的 `libmain.so` + `llvm-symbolizer` 还原 18 帧 PC，得到完整调用链：

```text
SystemNative_Abort                                   (pal_threading.c:284)
S_P_CoreLib_System_RuntimeExceptionHelpers__FailFast (RuntimeExceptionHelpers.cs:338)
S_P_CoreLib_System_Globalization_GlobalizationMode_Settings___cctor (GlobalizationMode.Unix.cs:31)
... ClassConstructorRunner / CultureData.CreateCultureWithInvariantData / CultureInfo..cctor
S_P_CoreLib_System_Globalization_CultureInfo__get_CurrentCulture
osuTK_osuTK_Vector2___cctor
osu_Framework_..._CompositeDrawable___ctor
osu_Framework_..._Container_1___ctor
osu_Game_osu_Game_OsuGame___ctor
SDL_main                                             (NativeEntry.cs:20)
```

即：`OsuGame` 构造 → `Vector2` 静态构造 → 首次访问 `CultureInfo.CurrentCulture`
→ 触发 `GlobalizationMode.Settings..cctor` → `LoadICU()` 返回 0
→ `Environment.FailFast("Couldn't find a valid ICU package installed on the system...")`
→ `abort()`。与 osu 逻辑、SDL3、BASS 全部无关，是 **NativeAOT 运行时在 OHOS 上找不到 glibc 版 ICU**。

源码依据（`dotnet/runtime` `GlobalizationMode.Unix.cs`）：

```csharp
static Settings() {
    if (!GlobalizationMode.Invariant) {
        if (TryGetAppLocalIcuSwitchValue(out string? v)) LoadAppLocalIcu(v);
        else {
            int loaded = LoadICU();
            if (loaded == 0) Environment.FailFast(GetIcuLoadFailureMessage());
        }
    }
}
```

**为什么 OHOS 上必然失败**：`pal_icushim.c` 的 Linux 分支只探测
`libicuuc.so.<NN>` / `libicui18n.so.<NN>`（`NN` 从 `U_ICU_VERSION_MAJOR_NUM+30` 递减到 60，
再试 suse 前缀），符号名按 `dlsym(libicuuc, "u_strlen_<NN>")` 解析。
DevEco sysroot 里只有一个无版本后缀的 NDK 链接桩
`sysroot/usr/lib/<triple>/libicu.so`（560 个导出符号，全部是 stub，无 `DT_NEEDED`），
设备上也没有 `libicuuc.so.*`。

**M1 阶段的修复**（已落地）：

| 文件 | 改动 |
| --- | --- |
| `osu.OHOS/osu.OHOS.csproj` | `<InvariantGlobalization>true</InvariantGlobalization>` + `<PredefinedCulturesOnly>false</PredefinedCulturesOnly>` |
| `aot-tools/build-lazer-aot.py` | publish 时全局传 `-p:InvariantGlobalization=true -p:PredefinedCulturesOnly=false`；HAP 内自动 `llvm-strip --strip-all`，未 strip 原产物保留供符号化 |
| `osu.OHOS/NativeEntry.cs` | `try/catch` 包住 `host.Run()`；新增 `OHOSLog`，用 `DllImport("libhilog_ndk.z.so") OH_LOG_PrintMsg`（API 18+ 固定 5 参数非变参）把托管异常打进 hilog；注册 `AppDomain.UnhandledException` |
| `aot-tools/run-m1b-gate.py` | 一键冷启动验收：安装 → `aa force-stop` → 清 hilog → `aa start` → 全量 hilog 落盘 + 判据 |

效果验证：重编后的 publish 链接命令里 **`libSystem.Globalization.Native.a` 已消失**，
说明 feature switch 在编译期把 ICU 初始化裁掉了。

> **新增风险 R9（本地化保真度）**：invariant 模式下所有 culture 退化为 invariant，
> 数字/日期格式、`CompareInfo` 排序会与桌面 lazer 不同；这不符合「体验完全一样」。
> M2 必须补回真实 ICU。已做可行性摸底：NativeAOT 需要 105 个 ICU 函数，
> OHOS ICU 桩只能覆盖 77 个，缺 28 个（`usearch_*` / `ures_*` / `udatpg_*` /
> `ucol_*` / `ucurr_*` / `ulocdata_*` 等），且其中不少是 `required`，缺失会 `abort()`。
> 因此「给 OHOS ICU 套一层版本名 shim」不够，可选路径：
> ① 用 OHOS clang 交叉编译一份完整 ICU4C，按 `libicuuc.so.<NN>` 命名随 HAP 分发；
> ② 以 OHOS ICU 为底座 + 自写 28 个函数的兼容实现（有语义损失）；
> ③ 保持 invariant，仅把 lazer 的格式化层替换为自有实现（语义损失最大）。
> 优先 ①。

### 13.8 M1b 第二轮：托管代码真正跑起来，暴露 R2 反射裁剪（已修复待复验）

修复 ICU 后重编并安装，设备侧日志（`output/m1b2-hilog.txt`）：

```text
A00000/SDL/STARTUP: Calling SDL_main!
A0a0a0/OSU-CS: SDL_main entered (NativeAOT osu!lazer)
A0a0a0/OSU-CS: invariant-globalization=True, culture='', base='/system/bin/', cwd='/'
A0a0a0/OSU-CS: SDL_main exception: System.TypeInitializationException ...
A0a0a0/OSU-CS:   ---> System.ArgumentException: Method ...AdhocContext.AdhocTestMethod not found
A00000/SDL/STARTUP: SDL_main returned 1! Now terminating the process...
LastFatalMessage:[appspawn_server.c:69]Unexpected call: exit(1)
```

**两个关键结论**：

1. `Calling SDL_main!` + `SDL_main entered` 同时出现，说明
   **SDL3 OHOS 启动链 → libmain.so → NativeAOT 托管世界 → osu.Game 构造** 全线打通。
   `SIGABRT` 这次只是 SDL3 在 `SDL_main` 返回后调 `exit(1)` 被 appspawn 记录，
   不是原生崩溃；Gate 判据已据此修正（只有「SDL_main 未返回」的崩溃栈才算 FAIL）。
2. `using (var host = ...) host.Run(...)` 在异常路径上会先跑 `GameHost.Dispose()`，
   而 `Dispose → LoadingComponentsLogger.LogAndFlush → DebugUtils.IsNUnitRunning
   → TestExecutionContext.AdhocContext → MethodWrapper(type, "AdhocTestMethod")`
   在 NativeAOT 下因该私有方法被裁剪而抛 `TypeInitializationException`，
   **把 `host.Run()` 的原始异常整个盖掉了**。

本轮修复（一次性打包，避免 9 分钟一轮反复试错）：

| 文件 | 改动 |
| --- | --- |
| `osu.OHOS/NativeEntry.cs` | 拆开 `host.Run()` 与 `host.Dispose()` 的 try/catch，分别打 `host.Run failed:` / `host.Dispose failed (secondary):`；注释说明 `exit(1)` 语义 |
| `fw/osu.Framework/Development/DebugUtils.cs` | 新增 `#if OSU_OHOS` 分支，`IsNUnitRunning` 直接 `return false`（发布版游戏不可能在 NUnit 下）；桌面构建路径完全不变 |
| `fw/osu.Framework/osu.Framework.csproj` | 加 `OSU_OHOS` 编译符号（这份源码副本只服务 OHOS AOT） |
| `osu.OHOS/rd.xml` | 首个裁剪描述符：保留 `nunit.framework` 的 `TestExecutionContext/AdhocContext`、`MethodWrapper` 全部成员 |
| `osu.OHOS.csproj` | `TrimmerRootAssembly` 整体 root `osu_lazer` / `osu.Framework.OHOS` / `osu.Framework` / `osu.Game`，系统性缓解 R2；`TrimmerRootDescriptor` 引入 `rd.xml` |
| `aot-tools/run-m1b-gate.py` | 判据改为 `sdl_main_called && managed_entered && !sdl_main_returned && !crashed`，区分原生崩溃栈与 SDL3 `exit(1)`，并单独检测托管异常 |

**静态验证（不依赖设备）**：修复前 `llvm-nm -S` 显示
`GlobalizationMode.Settings..cctor` 仅 0x59 字节，反汇编只见两次
`AppContextConfigHelper.GetBooleanConfig`，没有 `LoadICU` / `FailFast`；
`GlobalizationNative_LoadICU`、`InitICUFunctions` 符号与
`Couldn't find a valid ICU package` 字符串全部消失；
`__pinvoke_...libhilog_ndk_z_so__OH_LOG_PrintMsg` 存在。ICU abort 根因在二进制层面确认移除。

**新增 R11（原生依赖 ABI）**：摸底 HAP 里目前只有
`Hello.so` / `libSDL3.so` / `libmain.so`，而 framework 通过 NuGet 还依赖
`libbass.so` / `libbassmix.so` / `libbass_fx.so` / `librealm-wrappers.so` /
`libe_sqlite3.so` 以及 FFmpeg 系列。这些 NuGet 的 `linux-x64` 产物全部是
glibc ABI（`libc.so.6` / `libm.so.6` / `libpthread.so.0` / `ld-linux-x86-64.so.2`），
**OHOS musl 无法直接加载**。下一轮托管异常大概率就落在这里，需要按 M2 计划
逐个用 OHOS clang 交叉编译或写兼容 shim（音频优先用 SDL3 `ohaudio`）。
