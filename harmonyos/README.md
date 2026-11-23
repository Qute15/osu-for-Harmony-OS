# osu!lazer on HarmonyOS / OpenHarmony (NativeAOT)

把真正的 **osu!lazer** 以 **.NET NativeAOT** 的方式跑在 HarmonyOS NEXT 上：C# 直接编译成
`libmain.so`，由 SDL3 的 OpenHarmony 后端加载并调用 `SDL_main`，游戏逻辑一行不改。

不是重写：`osu.Game`、`osu.Game.Rulesets.*`、`osu.Framework` 全部是上游真实代码，
只有平台层（窗口 / 存储 / 宿主 / 音频垫片）是新增的。

## 当前状态

| 里程碑 | 内容 | 状态 |
| --- | --- | --- |
| M1a | NativeAOT 产物能在 OHOS 上被 dlopen、`SDL_main` 被调用 | PASS |
| M1b | 托管代码进入，SDL3 `openharmony` 视频后端建出 GL ES 上下文 | PASS |
| M2 | 冷启动进入主菜单（首次启动向导 → MainMenu），无 native crash / 无 runtime 病态异常 | PASS |
| 输入 | 触摸点击链路 | PASS |
| 音频 | BASS 垫片含解码器 + `OH_AudioRenderer` 输出 | 入口点齐全，**真机可听输出未验证**（模拟器无音频输出设备） |

两条启动路径都做过门禁：**首次编译**（清空着色器缓存）和**二次启动**（走缓存反序列化），
均为 `bad_runtime_lines: []`。

## 目录结构

```
osu.OHOS/                 NativeAOT 宿主工程（入口程序集 osu_lazer，产出 libmain.so）
osu.Framework.OHOS/       osu.Framework 的 HarmonyOS 平台层（GameHost / GameWindow / Storage / HostBridge）
harmonyos/
├── deveco-app/           DevEco Studio 工程（ArkTS + NAPI + HAP 打包）
├── native/bass-shim/     BASS P/Invoke 垫片（bass_shim.c / ma_decode.c / ohosdec.h）
├── tools/                SDL3 / NativeAOT / 原生依赖构建脚本 + M0~M2 门禁脚本
├── docs/                 移植计划与完整排障记录
└── patches/osu.framework/  osu.Framework 的 OHOS 相关改动（按原路径覆盖即可）
```

`osu.OHOS/` 与 `osu.Framework.OHOS/` 放在仓库根，和上游的 `osu.Android/`、`osu.iOS/`、
`osu.Desktop/` 平级，这样 `ProjectReference` 可以直接指到 `osu.Game`。

## 前置依赖

* **DevEco Studio**（自带 OHOS SDK / clang / CMake / Ninja），本工程按 `targetSdkVersion 26.0.0` 配置
* **.NET 10 SDK**（NativeAOT 交叉发布用）
* **SDL3 `main` 分支**（含官方 OpenHarmony 后端）：<https://github.com/libsdl-org/SDL>
* **osu.Framework 源码**：`ppy/osu.Framework`，版本与 `osu.Game.csproj` 里原本的
  `ppy.osu.Framework` 包版本对齐（移植时为 `2026.921.1`）

## 构建步骤

### 1. 准备 osu.Framework 源码（带 OHOS 补丁）

```bash
git clone https://github.com/ppy/osu.Framework.git osu.Framework   # 放在本仓库根目录
git -C osu.Framework checkout <与 osu.Game.csproj 中 ppy.osu.Framework 一致的 tag>
cp -r harmonyos/patches/osu.framework/osu.Framework/* osu.Framework/osu.Framework/
```

`osu.Framework/` 已在 `.gitignore` 里，不会污染仓库。想放在别处就传
`-p:OsuFrameworkSourceDir=<path>`。

补丁内容（12 个文件）：

* `RuntimeInfo` / `Bindable` / `IValueChangeNotifier` / `InputConfigManager` —— OHOS 平台识别与
  AOT 友好的绑定实现
* `Graphics/Rendering/Renderer`、`OpenGL/Buffers/*`、`Extensions/StructSize` —— GL ES 路径与
  结构体尺寸（避免 AOT 下 `Marshal.SizeOf` 走反射）
* `Extensions/ManagedHashes`、`ExtensionMethods` —— 去掉 AOT 下不可用的运行时哈希/反射路径
* `Graphics/Shaders/ShaderCompilationStore` —— **着色器缓存完整性自检**，并强制 ILC 为
  `List<Veldrid.ResourceLayoutDescription>` 等泛型实例生成代码（详见 docs 第 11.7 节）

### 2. 编译 SDL3

```bash
python harmonyos/tools/build-sdl3.py --arch x86_64      # 或 arm64-v8a / all
# 产物：SDL3-build-<arch>/libSDL3.so
```

### 3. 编译原生依赖

```bash
python harmonyos/tools/build-bass-shim.py              # libbass / libbass_fx / libbassmix
python harmonyos/tools/build-veldrid-spirv.py          # libveldrid-spirv
python harmonyos/tools/build-sqlite.py                 # libe_sqlite3
python harmonyos/tools/build-realm-wrappers.py         # librealm-wrappers
```

### 4. NativeAOT 发布

```bash
python harmonyos/tools/build-lazer-aot.py --arch x86_64   # 或 arm64-v8a
# 产物：libmain.so（约 300 MB，未 strip）
```

`build-lazer-aot.py` 会调用 `dotnet publish -r linux-musl-<arch> -p:DisableUnsupportedError=true`，
再用 DevEco 自带的 OHOS clang 手工链接成 aarch64/x86_64 的 OHOS ELF（详见
`docs/OHOS-PLATFORM-CHECKLIST.md` 中的工具链章节）。

### 5. 放进 DevEco 工程并打包

```bash
# 所有原生库都放在 entry/libs/<abi>/ 下
cp libmain.so libSDL3.so libbass*.so libveldrid-spirv.so libe_sqlite3.so librealm-wrappers.so \
   osu.Framework.OHOS/... harmonyos/deveco-app/entry/libs/x86_64/
```

```bash
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
cd harmonyos/deveco-app
"C:/Program Files/Huawei/DevEco Studio/tools/hvigor/bin/hvigorw" \
  assembleHap --mode module -p product=default --no-daemon
```

> 注意：hvigor 打包时对 `entry/libs` 的增量判定不可靠，曾把 `libbass.so` 打成缓存里的旧版本。
> 签名前请核对 HAP 内 `.so` 的大小，必要时手工替换（docs 第 11.9 节有记）。

### 6. 签名与安装

仓库里**不含**任何签名材料。用 DevEco 的 *Project Structure > Signing Configs* 生成，
或按 `docs/OHOS-PLATFORM-CHECKLIST.md` 第 11.6 节的手工流程签名，然后：

```bash
hdc install -r entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.example.myapplication
```

### 7. 门禁验证

```bash
python harmonyos/tools/run-m2-gate.py --target 127.0.0.1:16555
```

判据：hilog 有 `Calling SDL_main!`、runtime log 有 `SDL_main entered`、无 `SDL_main returned`、
无 native crash、无 `NullReferenceException` / `NotSupportedException` 等病态行、并且出现主菜单证据。

## 已知问题

* **音频**：BASS 垫片已实现 `BASS_StreamCreateFileUser` + miniaudio 解码（VBR 也能算准
  `Track.Length`），并接了 `OH_AudioRenderer`；但模拟器没有音频输出设备，
  **真机可听输出尚未验证**。
* **IntroScreen 8 秒看门狗**：首次启动时 intro 动画可能被
  `IntroScreen.ensureEventuallyArrivingAtMenu()` 的 8 秒兜底跳过，日志会打
  `osu! doesn't seem to be able to play audio correctly`。这不是驱动报错，
  更可能与首次启动纹理上传拥塞 + 软件渲染低帧率有关，真机硬件 GPU 大概率不触发。
* **InvariantGlobalization**：OHOS 的 ICU 是无版本后缀的 NDK 桩，NativeAOT 默认探测会
  `FailFast`，所以 M1/M2 阶段开了 `InvariantGlobalization=true`，本地化数据退化为 invariant
  （界面文案仍正常，排序/日期格式等与桌面版有差异）。

## 排障记录

`docs/OHOS-PLATFORM-CHECKLIST.md` 是完整的踩坑与验证记录，含：

* NativeAOT 交叉到 OHOS 的工具链细节（ilc 产物 → OHOS clang 手工链接）
* 反射元数据被裁剪的一系列问题（AutoMapper / Realm / osuTK / 本地化字符串 / Veldrid 着色器反射）
* 着色器缓存反序列化崩溃的定位过程（`llvm-nm` 查符号 + DWARF 行表 + `llvm-objdump`）
* HAP 签名证书过期后的本地重签流程
* **关闭登录面板闪退**（ArkTS 输入法客户端 `input method client detached`，错误码 12800009）
  的定位与修复
* 门禁脚本自身的误判源（设备时间被改，`ls -t` 取到"未来时间"的旧日志）

## 仓库里不包含什么

以下内容**故意不入库**，避免仓库膨胀和凭据泄漏：

* 所有预编译产物：`*.so`、`*.hap`、`libmain.so`（单文件 300 MB+，超过 GitHub 100 MB 单文件上限）
* 签名材料：`*.p12` / `*.cer` / `*.p7b`，以及 `build-profile.json5` 里原始的 signingConfigs
  （仓库版本已脱敏为空数组）
* `entry/rawfile/` 下的音频与谱面包（`*.mp3` / `*.osz`）
* SDL3 / osu.Framework 的完整源码树（按上面的步骤自行 clone）

## 许可

移植代码沿用上游许可（osu!lazer 为 MIT）。BASS 垫片仅用于本地开发验证，
BASS 本身是 Un4seen Developments 的商业库，正式分发需自行取得授权。
