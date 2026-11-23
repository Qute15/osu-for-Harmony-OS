# osu! → HarmonyOS 移植方案与进度（P0 已完成）

> 目标设备：HarmonyOS 6.x（SDK 26.0.0，`C:\Users\z3306\DevEcoStudioProjects\MyApplication`）
> 源码基线：osu!lazer `2026.1005.0`（6211 个文件，约 4500 个 `.cs`，48 MB 文本源码）

---

## 一、先把话说清楚：这不是"编译一下搬过去"

osu!lazer 的技术栈是 **C# / .NET 8 + 自研引擎 osu.Framework**：

| 依赖 | 作用 | HarmonyOS 上是否存在 |
|---|---|---|
| .NET 8 运行时（CoreCLR / Mono） | 跑全部游戏逻辑 | **不存在**。华为官方无 .NET runtime for OpenHarmony，社区也没有可用实现 |
| osu.Framework | 自绘 UI、渲染、音频、输入、依赖注入 | 无移植版，且重度依赖桌面 GPU API 与 SDL |
| Veldrid / OpenGL / Vulkan 后端 | 渲染 | 需重写为 OpenGL ES / ArkGraphics |
| BASS / SDL 音频 | 音频混音与低延迟输出 | 需重写为 AudioRenderer / OHAudio |
| 47 个 NuGet 包 | JSON、压缩、字体、图像…… | 逐个找 ArkTS 等价物 |

所以路径只有一条：**把玩法内核用 ArkTS 重写，逐个模块对齐上游数值**。所谓"编译报错修一修"在这条路上不存在。

**工作量级**：osu.Game + 4 个 ruleset 的可玩部分约 6~8 万行有效逻辑，osu.Framework 的图形/音频/UI 层再 3~5 万行。1:1 全内容移植是**多阶段工程**，不是一次交付。谁跟你说"今天就能给你一个完整 osu!"，那是骗你的。

本文件 = 已经做完的部分 + 剩下怎么切。

---

## 二、已完成：P0 玩法内核（ArkTS，可直接进工程）

全部落在 `entry/src/main/ets/osu/`，纯逻辑、零 UI 依赖，后续渲染层只吃这一层。

| 模块 | 文件 | 对应上游 | 状态 |
|---|---|---|---|
| 向量/精度 | `core/Vec2.ets` | osuTK.Vector2 + osu.Framework.Precision | ✅ |
| 曲线逼近 | `curve/PathApproximator.ets` | PathApproximator.cs（Bezier/Catmull/Perfect/Linear/BSpline） | ✅ |
| 滑条路径 | `beatmap/SliderPath.ets` | SliderPath.cs（含 ExpectedDistance 拉扯、Catmull 6px 优化） | ✅ |
| 时间轴 | `beatmap/ControlPoints.ets` | Timing/Difficulty/Sample/Effect 四类控制点 + 时间查询 | ✅ |
| 数据模型 | `beatmap/BeatmapModel.ets` | DifficultyRange、难度、元数据、事件、颜色、采样 | ✅ |
| .osu 解码 | `beatmap/LegacyOsuDecoder.ets` | LegacyBeatmapDecoder.cs，兼容 v3–v14 | ✅ |
| 物件与默认值 | `ruleset/OsuObjects.ets` | HitCircle/Slider/Spinner + ApplyDefaultsToSelf + SV 精度修正 | ✅ |
| 可玩谱面 | `ruleset/OsuPlayableBeatmap.ets` | 转换 + combo 分组 + 堆叠 + SliderEventGenerator + maxCombo | ✅ |
| 判定窗口 | `scoring/OsuHitWindows.ets` | OsuHitWindows.cs（OD→300/100/50/miss） | ✅ |
| 判定结果 | `scoring/HitResult.ets` | HitResult 子集 + 基础分表 | ✅ |
| 计分 | `scoring/ScoreProcessor.ets` | combo / 准确率 / 计数 | ⚠️ 分数公式为占位，见 P4 |
| 判定引擎 | `ruleset/OsuPlayfield.ets` | OsuPlayfield 规则部分：press/update/release、滑条跟随、spinner 旋转、超时 miss | ✅ |
| Mod | `mods/Mods.ets` | DT/HT/HR/EZ/NF/HD/FL 等 + 难度与时间轴改动 | ✅ |

关键数值都是照抄上游，不是"差不多"：

- `TimePreempt = (int)DifficultyRange(AR, 1800, 1200, 450)`，`TimeFadeIn = 400 * min(1, preempt/450)`
- `Scale = (1 - 0.7*(CS-5)/5)/2` → CS5 半径 32px（512×384 虚拟场）
- 判定窗口 `floor(DifficultyRange(OD, 80/50/20 …)) - 0.5`，miss 固定 400ms
- 滑条速度 `100 * SliderMultiplier / precisionAdjustedBeatLength`，SV 的 `-100/beatLength` 编码与 `[0.1,10]` 夹取、`[10,1000]/100` 的 float 精度修正全部保留
- 滑条尾判 `-36ms` 宽容、Catmull 每结 100 采样点、6px 优化并回填 `optimisedLength`
- 堆叠算法整段搬（含 v6 前后的两套算法、整数截断、slider 端点负堆叠特例）

### 验证（不依赖模拟器）

`output/harness/build_and_test.py` 把 `.ets` 打包成单个 `.ts`，用 Node 的 type-stripping 直接执行：

```
===== 结果：106 通过 / 0 失败 =====
```

覆盖：

- 合成谱面：BPM、AR→preempt、CS→半径、滑条速度/时长/结束时间精确到 1e-6
- 几何：共线 Bezier = 100、半圆弧 = π·50、共线三点退化、Catmull 采样数 1+3×100、无 NaN
- 路径拉扯：expectedDistance 截短 100→50、延长 100→150
- 判定窗口：OD0/8/10 的 300/100/50 边界与 miss
- 真实谱面 6 张（含 897 物件、1328 maxCombo 的 Renatus [Insane]，171s 的 Marathon）：时间单调、滑条时长>0、堆叠高度合法、tick/repeat 统计正常
- 老格式：v3（无 hitSample、TimingPoints 只有 2 字段、缺 AR）、v4/v6 空物件不崩
- Mod：DT 时间轴 ÷1.5、HR CS×1.4、EZ AR×0.5
- 计分：全 300 = 100%、miss 断 combo、10×300+1miss = 90.909%
- **判定引擎自动机（最强的一条）**：以 1ms 帧驱动 autoplay 打 Renatus [Insane]（897 物件），
  结果 `combo 1328 / maxCombo 1328`、`acc 100.000%`、`miss 0`。这说明
  滑条 tick/repeat/尾判、combo 链、超时 miss、时间轴缩放全部自洽。
- 人工偏差：+40ms→100、-90ms→50、+150ms 按下不判定随后超时 miss、点出判定圈→无判定、不点→miss

另外用 DevEco 自带的 TypeScript 4.9.5 做了 `--strict` 全量类型检查：**0 error**。

---

## 三、技术选型（HarmonyOS 侧）

| 关注点 | 选型 | 理由 |
|---|---|---|
| 渲染 | **XComponent + native OpenGL ES（C++/NAPI）** | 判定线要 120Hz 稳定；ArkUI Canvas 每帧走 JS 桥，物件多时掉帧 |
| 音频 | **OHAudio（C API，低延迟）+ AudioRenderer 兜底** | 需要 <30ms 输出延迟，AVPlayer 太慢 |
| 判定时钟 | **系统单调时钟为主，音频位置只做漂移校正** | 拿音频进度当判定基准会被缓冲抖动毁掉 hit error |
| 输入 | ArkUI 触摸事件 + 鼠标/触控板（2in1）双通道 | 与既有键鼠+触屏双通道路线一致 |
| 谱面存储 | `@ohos.file.fs` 应用沙箱 + `@ohos.zlib` 解 .osz | .osz 就是 zip |
| 皮肤 | 自写 `skin.ini` 解析 + 图片解码 | lazer 的 `ISkin` 体系需要重做精简版 |

**坐标系不变**：内部一律用 512×384 虚拟场，只在最终绘制时缩放/letterbox。这样谱面数值和上游完全对得上。

---

## 四、剩余路线（按可玩性优先级切）

### P1 可玩 osu!standard（下一阶段，最关键）
- [ ] XComponent + GLES 渲染器：背景、circle/slider/spinner、follow point、判定动画
- [ ] 音频管线：解码 → 低延迟输出 → 谱面时间 = `audioTime - leadIn`，带 offset 校准页
- [ ] 输入与判定：鼠标/触屏按下位置 → `HitWindows.resultFor(offset)`，slider 跟随与 tick 判定、spinner 转速
- [ ] HUD：combo / 准确率 / 血条 / 判定文字
- [ ] 结算页
- **验收**：能完整打通一张 4★ 谱面，且 hit error 曲线中心在 ±3ms 内

### P2 完整 UI（osu!lazer 是自绘 UI，必须重画）
主菜单 → 选歌（谱面库、排序、搜索）→ Mod 选择 → 游玩 → 结算 → 设置（音量/offset/皮肤/按键）
- 谱面导入：文件选择器选 `.osz` → 解压 → 写库 → 解析元数据
- **验收**：不接电脑、纯手机完成"导入 .osz → 选歌 → 打出 A 评价"

### P3 其余三个 ruleset
taiko（鼓点 + 判定线）、catch（水果 + 盘子跟随）、mania（键位 + 长条 + SC 变速）
- 附：ruleset 转换器（osu→taiko/catch 的物件生成规则）
- **验收**：同一张谱面在四个模式都能出分

### P4 元系统对齐
- [ ] 官方分数公式（ScoreV2 / lazer 标准分）与准确率口径逐行对齐
- [ ] 血条 HP drain、Mod 完整语义（FL 视野收敛、HD 淡出、SD/PF 重开）
- [ ] 回放录制/播放、本地排行榜、成绩导出
- **验收**：同一回放在 PC lazer 与鸿蒙端得到相同分数

### P5 打磨
音频延迟自动校准、触屏手感（滑条容错半径）、帧同步、省电、崩溃兜底

---

## 五、明确不会 1:1 的部分（降级，不是遗漏）

| 内容 | 处理 |
|---|---|
| Storyboard（.osb 脚本、SBR 指令） | 第一版不渲染，只取背景图；后续做精简版 |
| 视频背景 | 不接入（解码开销与包体不值得） |
| 在线功能（官网 API、谱面上传、多人、排行榜同步） | 不做，纯离线 |
| 编辑器 | 不做（工作量=另一个游戏） |
| tournament 客户端 | 不做 |
| 部分皮肤特性（hitsound 叠层、动画皮肤元素） | 第一版只取静态贴图 + hitsound |

---

## 六、已定方案（本轮确认）

1. **UI：osu!lazer 原生自绘**。逐屏重画主菜单 / 选歌 / Mod 选择 / 游玩 / 结算 / 设置，走自绘而非 ArkUI 原生组件，保证还原度。
2. **渲染：XComponent + native OpenGL ES**。C++/NAPI 层持有 EGL 上下文，ArkTS 只负责送"这一帧要画什么"。

### 下一步（P1）开工顺序

1. NAPI 骨架：XComponent 回调 → EGL 初始化 → 清屏 + 画一个矩形，跑通 120Hz 不掉帧
2. 贴图与精灵批渲染：纹理加载（PNG）、quad batch、纹理图集
3. 谱面元素绘制：circle（含 approach circle）、slider（轨道+球+跟随圈）、spinner、follow point、堆叠偏移
4. 音频：OHAudio 低延迟输出 + 谱面时钟（音频位置只做漂移校正）+ leadIn/offset 校准
5. 输入接入：触摸/鼠标 → `OsuPlayfield.press/move/release`
6. HUD 与结算

验收线：不接电脑，手机上手打通一张 4★ 图，hit error 中心在 ±3ms 内。

---

## 七、P1 进度：渲染骨架已跑通构建（本轮）

### 已落地

| 文件 | 作用 |
|---|---|
| `entry/src/main/cpp/CMakeLists.txt` | 编译 `libosu.so`，链 EGL/GLESv3/ace_napi/ace_ndk/native_window/native_vsync/hilog |
| `entry/src/main/cpp/napi_init.cpp` | XComponent 四回调注册（`OH_NATIVE_XCOMPONENT_OBJ` + `napi_unwrap`）、vsync 驱动的主循环、FPS/帧耗时统计、6 个 NAPI 导出 |
| `entry/src/main/cpp/render/egl_core.{h,cpp}` | EGL3 上下文：RGBA8888 窗口表面、OpenGL ES 3 上下文、尺寸查询 |
| `entry/src/main/cpp/render/sprite_renderer.{h,cpp}` | 批量四边形渲染器：单 program、动态 VBO、8192 quad 上限、旋转、解析式圆/环（`fwidth` 抗锯齿）、alpha 混合 |
| `entry/src/main/cpp/osu_scene.{h,cpp}` | 512×384 虚拟场 letterbox + 3 个带 approach ring 的判定圈 + 旋转轨道 |
| `entry/src/main/cpp/types/libosu/*` | NAPI 的 `.d.ts` 与 oh-package，供 ArkTS import |
| `entry/src/main/ets/pages/Play.ets` | XComponent(SURFACE, libraryname='osu') + FPS/帧耗时/DrawCall 覆盖层 |
| `entry/src/main/ets/pages/Index.ets` | 入口按钮（后续替换为 osu! 主菜单） |

### 关键设计决定（踩过的坑）

- **EGL 上下文不在 UI 线程创建**。`OnSurfaceCreated` 只记录 window 和尺寸，真正 `eglCreateContext` + 首次渲染都在 vsync 回调线程里做，否则上下文绑错线程，后续所有 GL 调用静默失效。
- **不引第三方窗口层**。HarmonyOS 没有 GLFW/SDL，XComponent 的 `OHNativeWindow` 直接喂给 `eglCreateWindowSurface`。
- **`.d.ts` 不导出对象/interface 返回值**。ArkTS 会把未声明为具体类的返回值推成 `any`，直接触发 `arkts-no-any-unknown` 编译失败（本轮实际踩到，`getSurfaceSize()` 改成 `getSurfaceWidth()/getSurfaceHeight()` 才过）。
- **第一版不用纹理**。圆和圆环用 fragment shader 解析式画，先把管线跑通；纹理/图集在下一步接皮肤时引入。

### 构建验证

```
> hvigor Finished :entry:default@BuildNativeWithCmake... after 10 s 168 ms
> hvigor Finished :entry:default@BuildNativeWithNinja... after 3 s 440 ms
> hvigor Finished :entry:default@CompileArkTS... after 11 s 46 ms
> hvigor BUILD SUCCESSFUL in 26 s 454 ms
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`（1.5 MB，含 `libosu.so`）。
另有独立校验：用 SDK 自带 clang 直接编四个 `.cpp` 并链接出 `libosu.so`（43 KB，导出 `RegisterOsuModule`），不依赖 hvigor 也能确认原生代码本身没语法/符号问题。

### 未完成 / 已知风险

- **未签名**：`build-profile.json5` 没有 signingConfigs，CLI 构建出的 HAP 是 unsigned，装不上真机。DevEco Run 时会自己签（`entry-default-signed.hap`）。
- **只在 arm64-v8a** 构建；模拟器要跑需在 `abiFilters` 加 `x86_64`。
- 触摸事件还没接（`DispatchTouchEvent` 是空实现），下一步接 `OsuPlayfield`。

### 黑屏排查与修复（2026-11-08）

真机实测黑屏一轮，定位到三个必踩的问题：

1. **ArkTS 先 `import 'libosu.so'`，导致 Init 里拿不到 native 实例。**
   XComponent 的 `libraryname` 路径要求 `exports` 上挂着 `__NATIVE_XCOMPONENT_OBJ__`；
   但 ArkTS 静态 import 会先把模块加载掉，那时 exports 是干净的普通对象，
   旧代码在这个分支直接 `return`，回调永远注册不上 → XComponent 全程不出图。
   修法：Init 不再提前 return；新增 `attachContext(context)`，在 `XComponent.onLoad` 里
   从 context 再抓一次 native 实例（先直接 unwrap，再试 `nativeXComponent` 等属性名，
   并打印 context 的所有 key 便于版本差异排查）。

2. **窗口 buffer 尺寸没设，EGL 表面是 0×0。**
   `glViewport(0,0)` + 空尺寸渲染 = 纯黑，且不报任何错。
   修法：`OnSurfaceCreated` 里先 `OH_NativeWindow_NativeWindowHandleOpt(SET_BUFFER_GEOMETRY, w, h)`
   再建 EGL 表面；`EglCore` 里 `eglQuerySurface` 拿不到尺寸时用 `GET_BUFFER_GEOMETRY` 兜底。

3. **尺寸未知时直接 return，连清屏都不做**，留下未初始化的 buffer。
   修法：先 `glClear` 再判断尺寸，宁可只有底色也不要黑屏。

配套加了**屏幕上的状态码**（`getStatus()`）：`0` 没收到表面 / `1` 有表面但 EGL 失败 /
`2` EGL 就绪但没出帧 / `3` 正在出帧。黑屏时看一眼数字就知道断在哪一层，不用猜。

排查命令（设备连上时）：

```
hdc shell hilog -r
hdc shell aa start -a EntryAbility -b com.example.myapplication
hdc shell "hilog -x | grep -i -E 'osu-napi|osu-egl|osu-gl'"
```

期望日志：`module initialised` → `xcomponent callbacks registered` → `surface created WxH` →
`first frame: egl=WxH` → `renderer ready`。

---

## 八、P1 进度：音频时钟 + 打击音 + 自动游玩（本轮）

### 已落地

**1. 横屏 + 沉浸式**
`module.json5` 给 EntryAbility 加 `"orientation": "landscape"`；`EntryAbility` 里
`setWindowLayoutFullScreen(true)` + `setWindowKeepScreenOn(true)` + 隐藏系统栏。
之前竖屏下 512×384 的场地被压成中间一条，现在整块屏幕（2844×1260）都是场地，
letterbox 由 `PlayfieldLayout` 自动居中。

**2. 打击音引擎（native，OHAudio 低延迟）** — `cpp/audio/audio_engine.{h,cpp}`
- `AUDIOSTREAM_USAGE_GAME` + `AUDIOSTREAM_LATENCY_MODE_FAST`，失败自动退回 NORMAL
- 单生产者/单消费者无锁队列（JS 线程投递 → 音频线程混音），音频回调里不加锁、不分配
- 打击音采样在 `Init()` 里程序化合成（normal / whistle / finish / clap），
  **不依赖任何外部素材**，确定性噪声便于回归
- 实测：`FAST=1`，回调缓冲 **5.0ms**，整链路 **25.0ms**，欠载 0

**3. 主时钟 `AudioClock`** — `ets/osu/audio/AudioClock.ets`
音乐走 AVPlayer（解码交给系统），时钟 = 音频位置为主 + 系统单调时间（`getUptime(STARTUP)`）
插值 + 周期性漂移校正。三个阈值：3ms 内当噪声、超 120ms 当跳转、中间按 35% 增益修正。

**4. 打击音调度** — `ets/osu/audio/HitSoundPlayer.ets`
按 osu! 的规则展开 `hitSound` 位掩码：`0` → normal；否则只响被置位的；
音量 = 物件 sample 控制点音量 × 全局音量。滑条尾判不发声（与 stable 一致）。

**5. 判定偏差条** — `ets/osu/render/HitErrorBar.ets`
屏幕底部一条，tick 按颜色区分 300/100/50/miss，并统计均值与平均绝对偏差。
这是校准音频偏移的唯一可视依据。

**6. 自动游玩（Auto mod）** — `ets/osu/ruleset/OsuAutoPlayer.ets`
刻意走和触屏完全相同的 `press/move/release` 路径，不直连计分器；
既是上游功能移植，也是没有真人时唯一能端到端验证的输入源。

### 本轮修掉的三个真 bug

**A. 时钟校正漏加时间增量**（`AudioClock.update`）
修正锚点时写成 `anchorAudio += err * gain`，丢掉了这一个采样间隔的系统时间增量，
结果每次校正 `now()` 都往回跳 ~100ms。正确写法是基于 `predicted` 修正：
`anchorAudio = predicted + err * gain - offset`。

**B. 单次坏样本就把时钟拽走**
AVPlayer 偶尔吐一个 0 或跳几百毫秒的位置。原逻辑 |err| > 120ms 立刻重锚，
一次坏样本就让谱面倒回开头（现场表现就是"打着打着卡住/倒退"）。
现在：**大偏差必须连续两次一致才认**，单次一律丢弃，播放中途的 0 位置直接拒收。

**C. 滑条路径坐标被平移了两次**（最严重）
`SliderPath` 的控制点存的是**绝对场坐标**（首点就是滑条头），
但 `Slider.endPosition()` / `positionAtSpan()` / `BeatmapRenderer.buildPolyline()`
又各自 `position.add(path...)` 了一次 —— 整条滑条平移了一个头坐标。
表现：滑条轨道错位、滑条球飞出画面、拖尾判定永远不成立、自动游玩命中率 70%。
修法：去掉这三处重复叠加，并在 `OsuObjects` 里写清坐标系约定。

> 这个 bug 是靠设备实测发现的：离线 1ms 步进时准确率 100%，
> 设备 8ms 步进只有 70%，而"命中时的偏差"又是 0.4ms ——
> 偏差正常但命中率低，说明是"根本没按到"，不是精度问题。
> 顺着这条线索在 harness 里补了 8ms/16ms 两种步长的对照跑，离线复现后才定位到坐标。

### 验证结果

离线（Node，`output/harness/build_and_test.py`）：**167 通过 / 0 失败**
其中新增：
- `AudioClock`：插值、3ms 内抖动忽略、10% 漂移跟随、单次跳变拒绝、连续跳变接受、
  播放中途 0 位置拒收、暂停恢复、用户偏移 —— 共 16 条
- `HitSoundPlayer`：9 条（掩码展开、miss 静音、尾判静音、音量缩放、开关）
- `HitErrorBar`：4 条（均值 / 平均绝对偏差 / NaN 过滤 / reset）
- `AutoPlayer`：1ms / 8ms / 16ms 三种步长下打 Renatus [Insane] 60 秒，
  **全部 100% 准确率、0 miss、combo 419**

真机（`4DV0224C10013384`，2844×1260）：
`100.00%` 准确率 / `COMBO 169` / 已判 169 / hit error **均值 0.4ms、平均绝对 2.4ms** /
音频 `FAST=1 buf 5.0ms route 25.0ms 欠载 0` / 状态 3 / 指令 67

### 别的踩坑

- **hilog domain/tag 默认是 0/NULL**，native 侧 `OH_LOG_INFO` 打出来的日志在
  `hilog -x` 里根本查不到（会误判成"代码没执行"）。必须在 `#include <hilog/log.h>`
  **之前** `#define LOG_DOMAIN 0x0F0F` / `#define LOG_TAG "..."`。
- ArkTS 的 `hilog.info` **不支持 `%{public}.1f` 这种精度修饰**，会把后续参数全部错位，
  看起来像"变量值莫名其妙"。整数用 `%{public}d`、字符串用 `%{public}s`，浮点先 `Math.round`。
- `hdc shell hilog -x` 是环形缓冲，隔太久再 dump 会丢掉启动期的日志，
  要定位启动流程必须 `hilog -r` 之后立刻抓。

### 下一步

1. **音频偏移校准页**：用 hit error 的均值做一次自动校准（当前只能靠 ±5ms 按钮手调）
2. **`.osz` 导入**：`@ohos.zlib` 解压 + 写应用沙箱 + 选歌页（现在只有一张内置测试谱）
3. **皮肤与纹理**：把原生渲染器从"纯色几何"升级到纹理图集（hitcircle/slider/tail/数字）

---

## 九、FPS 60 → 120（已解决）

### 症状

渲染跑起来后 FPS 一直卡在 60，而更早的纯几何版本能到 120。

### 定位过程（先取证，不猜）

```
hdc shell hidumper -s RenderService -a screen
```

输出里两个字段直接给了答案：

```
screen[0]: ... skipFrameInterval=1, expectedRefreshRate=-1
supportedMode[0]: 1260x2844, refreshRate=120
supportedMode[2]: 1260x2844, refreshRate=60
activeMode: 1260x2844, refreshRate=60      ← 屏幕真的在 60Hz
```

屏幕支持 120/90/60/30，`activeMode` 却是 60，`expectedRefreshRate=-1` 说明
**应用从来没声明过自己要高刷**。LTPO 屏对 2D 应用默认按 60Hz 跑，跟我们渲染快慢无关
（实测帧耗时只有 1.7~2.4ms）。

### 修法

`napi_init.cpp` 里拿到 vsync 后调用：

```cpp
OH_NativeVSync_ExpectedRateRange range{60, 120, 120};   // min / max / expected
OH_NativeVSync_SetExpectedFrameRateRange(g_vsync, &range);
```

注意两点：
- **必须在 `OH_NativeVSync_RequestFrame` 之后调用**——周期只在收到回调后才刷新，
  在 `OnSurfaceCreated` 里立刻调会拿不到有效周期；
- 这里每 60 帧重设一次（约 0.5s），周期变化或系统重新降频时能自己拉回来。

配套加了两个诊断接口，HUD 上直接可见：
- `getVsyncPeriod()` — 实际 vsync 周期，**16.67ms = 60Hz，8.29ms = 120Hz**
- `getFrameRateRangeResult()` — `SetExpectedFrameRateRange` 的返回值，0 = 系统接受

### 结果

| | 修复前 | 修复后 |
|---|---|---|
| 屏幕 activeMode | 60Hz | **120Hz** |
| FPS | 60 | **120** |
| vsync 周期 | 16.67ms | **8.29ms** |
| 单帧耗时 | — | **1.73ms**（占预算 21%） |

45 秒持续运行后复查，仍是 120Hz / 120 FPS，没有回退。

> 教训：帧率不对先看 `hidumper -s RenderService -a screen` 的 `activeMode`，
> 一眼就能分清"我们慢"还是"屏幕慢"。之前如果没有这个字段，很容易去优化渲染管线白忙一场。


---

## 十、P1 进度：`.osz` 导入 + 选歌 + 暂停/结算（已完成）

### 数据落地

```
files/osu/songbook.tsv          索引（一行一个难度，15 字段 TSV）
files/osu/Songs/<id>/           .osz 解压后的原样内容
```

`<id>` 是 `s<时间戳>`，**同一张 .osz 的所有难度共用一个 id**（它们共享一个目录）。
这一点后面埋了个坑，见下。

### 导入流程

```
bytes 来源 ──┬─ picker 选中的 uri  → copyFileSync 到 import_<id>.zip
             └─ rawfile 里的示例   → writeSync    到 import_<id>.zip
                                    ↓
                    zlib.decompressFile(zip, Songs/<id>)
                                    ↓
                    递归扫 .osu（深度 ≤3，跳过 mode≠0）
                                    ↓
              LegacyOsuDecoder 解出标题/AR-OD-CS-HP/BPM/时长/物件数
                                    ↓
                         按 标题+难度名 去重 → 写索引
```

两条路径共用 `extractInto()`，只有"字节怎么来"不同。为什么要留 rawfile 这条：
`hdc file send` 推不进 `/sdcard`（shell 用户 uid=2000 对 `/storage/media/100` 无权限），
真机上没法自动摆一个 .osz 进去。把 `Night of Knights.osz` 打进 `rawfile/sample_beats.osz`
（5.2MB）后，示例能玩就等于导入链路能跑——**示例和真实导入走的是同一段代码**。

### 真机结果

| 项 | 结果 |
|---|---|
| 解压出难度 | 8 个（Easy / Guy's Extra / Hard / Kotori's Extreme / Insane ...） |
| 元数据 | `beatMARIO - Night of Knights`、AR/OD/CS/HP、180 BPM、2:51、192~914 物件、mapped by alacat |
| 索引持久化 | force-stop 后重启，列表逐像素一致 |
| 重复导入 | 提示「这张图已经在库里了」，不产生重复行 |
| 音频 | 从沙箱 mp3 播放，FAST=1 / buf 5.0ms / route 25.0ms / 欠载 0 |
| 游玩 | Kotori's Extreme（856 物件 / maxCombo 1305）100%、偏差均值 0.1ms |

### 顺手修的两个 bug

**1. 所有难度都进第一个（Easy）**

`SongBridge` 只传了 `id`，而 8 个难度 id 相同 → `getById()` 永远返回第一项。
修法：桥接多传一个 `osuFile`，`SongLibrary` 加 `getByIdAndFile(id, osuFile)`。

**2. 结算面板 300 计数超过物件总数（192 物件的图显示 300=418）**

滑条 tick / repeat / tail 全被记成 `HitResult.GREAT`，直接污染准确率分母。
修法：改记 `SMALL_TICK_HIT` / `LARGE_TICK_HIT` / `SMALL_TICK_MISS` / `LARGE_TICK_MISS`
（只加/断 combo，不进准确率），再加 `ScoreProcessor.mainJudged` 作为 HUD 与结算的口径。
修正后 300=192、maxCombo=418，都对上了。

### 暂停 / 结算

- 按钮行新增「暂停」：`clock.stop()` + `player.pause()`，画面冻结在最后一帧，
  遮罩给 继续 / 重来 / 退出到选歌。
- 谱面末尾 +1.6s 自动弹结算：评级（SS/S/A/B/C/D，stable 口径）+ 准确率 + 300/100/50/miss/最大连击。
- `tick()` 在 `paused || finished` 时直接 return，判定不再推进，不会"暂停期间继续算 miss"。

### 还没验证的

picker 那条路（手机上的真实 .osz）在真机上没法自动化验证——需要人工把文件放进手机。
代码与 rawfile 路径共用 `extractInto()`，风险点只剩 `fs.openSync(uri)` 读 picker uri 一步。

---

## 十一、P1 进度：皮肤与纹理（已完成）

上一轮之前，判定圈、缩圈、滑条球、光标都是**解析式画出来的**：圆心 + 环 + 数字位图缺位。
几何是对的，但它不是 osu!。这一轮把整个物件图层换成真正的**皮肤贴图**。

### 为什么是图集，不是一张张图

osu! 的皮肤贴图是"白色 + alpha"，最终颜色由顶点色相乘决定（combo 色）。
所以同一张 `hitcircle` 一张图就能画出所有 combo 颜色。顺着这个思路：

- 把所有贴图打进一张 **1024×1024 RGBA 图集**（18 个 sprite，36.7% 覆盖率）；
- 整帧只做**一次**纹理绑定，所有贴图共享 —— 120Hz 下这是能否稳住帧率的关键；
- UV 直接塞进每条绘制指令，native 侧**完全不知道"什么是 hitcircle"**，
  只认"画图集里的一块矩形"。以后加 spinner 圈、滑条边界、打击爆炸，都不用改 C++。

图集由 `output/harness/gen_skin.py`（Pillow，4× 超采样 + LANCZOS）生成，
输出 `atlas.png` + `atlas.json`，拷进 `resources/rawfile/skin/`。

| sprite | 尺寸 | 说明 |
| --- | --- | --- |
| `white` | 8×8 | 通用纯白块 |
| `hitcircle` | 128×128 | 实心圆（着色成 combo 色） |
| `hitcircleoverlay` | 128×128 | 环厚 7.5% 直径的白色描边 |
| `approachcircle` | 256×256 | 缩圈 |
| `sliderb` | 128×128 | 滑条球，中心带 150 alpha 的层次 |
| `sliderfollowcircle` | 256×256 | 跟随圈 |
| `cursor` | 128×128 | 光标 |
| `hitlight` | 256×256 | 命中白光（平方衰减径向渐变） |
| `digit0`..`digit9` | 96×128 | combo 数字，Arial Bold |

### 指令格式：12 → 16 float

```
type, x, y, w, h, rotation, r, g, b, a, param1, param2, u0, v0, u1, v1
```

`type = 4` 是贴图。UV 跟着指令走，不做"贴图 id 查表"——规则层多一个 sprite
不需要动 native。

### 踩的坑（值得记下来）

**1. `glVertexAttribPointer` 的偏移必须和 Vertex 字段顺序严格对应**

Vertex 是 `x,y | lx,ly | u,v | r,g,b,a | shape,param`，所以偏移是
`0 / 2 / 4 / 6 / 10` 个 float。一开始把颜色指到 `*4`（其实是 u,v 的位置）、
UV 指到 `*10`，结果是：贴图采样全错位，屏幕上出现**粉紫渐变的球**。

定位手段：把整张图集当一张大 quad 画在屏幕左上角，看到"彩色渐变圆 + 白色文字"
——颜色在渐变、UV 却落在文字上，一眼就能确认是属性错位而不是 UV 算错。

**2. 不要 v 轴翻转**

中途怀疑 OpenGL 的 UV 原点在左下，加了 `1.0 - v`，方块消失、形状还是不对。
`readPixelsToBuffer` 给的就是自上而下、第 0 行是图片顶部的 RGBA，
和 `glTexImage2D` 的期望一致，翻转反而是错的。

**3. `glTexImage2D` 必须在 GL 上下文线程**

XComponent 的 vsync 回调线程才有上下文。ArkTS 侧只做"排队 + 打脏标记"，
真正上传发生在 `RenderFrame` 里 `Begin()` 之后。

**4. ArkTS 静态方法里别用 `this`**

`SkinAtlas.uv()` 里原本写 `this.uvs`，跨模块调用时 this 绑定会丢，
查表静默返回空 → 渲染器永远走矢量回退。改成显式 `SkinAtlas.uvs`。

**5. Text 里直接调 native 函数不会建立依赖**

HUD 上 `GPU贴图 0 sprite 0` 一直不动，而下一行 `native 12` 是对的。
原因是 ArkUI 只重建有 `@State` 依赖的节点，纯函数调用那行被当成静态内容，
永远停在首帧。修法：把值提到 `@State nativeSprites / atlasUploaded`，
在 HUD 定时器里更新。

### 顺带修掉的两个问题

**combo 数字手写计数漏项**：`spriteDraws` 原本在渲染器里手动 `+=`，
只数了判定圈和数字，漏掉缩圈、滑条球、跟随圈、命中光、光标，
和 native 收到的指令数对不上。改成 `DrawCommandBuffer.spriteCount` 自己数
（发指令的地方就是唯一的真相），渲染器只负责读。现在 `arkTS-sprite 14 / native 14`
逐帧一致。

**滑条轨道像色块**：旋转矩形拼接在拐角必然缺一块。改成两层
（外描边 `0x32323E` + 主体 `blendColour(0x1C1C26, combo, 0.42)`），
并且在每个折点补一个同直径的圆。混色用绝对值混合而不是半透明叠加，
重叠段不会越叠越深。

### 保底策略

`SkinAtlas.load()` 失败（rawfile 缺失 / 解码失败）时 `uv()` 返回空数组，
`BeatmapRenderer` 每个物件都检查 UV 长度，为空就退回原来的矢量画法。
**皮肤挂了还能玩，不会黑屏。**

### 验证

| 项 | 结果 |
| --- | --- |
| 离线断言 | 202 通过 / 0 失败（新增 9b 段 33 条，含 UV 换算、指令步长、回退路径） |
| 真机画面 | 判定圈白环 + combo 色填充 + 数字 1/2/3、缩圈、滑条球、跟随圈、滑条轨道拐角连续 |
| 对账 | `arkTS-sprite 14 / native 14`、`GPU贴图 1` |
| 帧率 | 120 FPS / 帧耗时 1.97ms / 指令 85 |

### 还没做

- spinner 仍是矢量双环（`spinnerspin` / `spinner-approachcircle` 贴图未做）
- 命中爆炸（`hit0`/`hit50`/`hit100`/`hit300` 粒子贴图）未做，目前只有一张白光
- 皮肤自定义（用户自己丢皮肤文件夹进来）—— 图集是内置的，换肤要先跑一遍
  `gen_skin.py` 的打包流程；后续可以把"从 skin.ini + 散图打图集"做成运行时能力

---

## 十二、P2：主菜单 + 选歌页（按 lazer 复刻）

这一轮的目标不是"能用"，是"看起来就是 osu!"。做法：**不凭截图目测，直接读 lazer 源码里的布局常量**。

### 主菜单（复刻 ButtonSystem / MainMenuButton）

`osu.Game/Screens/Menu/` 里读到的原值：

| 常量 | 值 | 用途 |
| --- | --- | --- |
| `ButtonSystem.BUTTON_WIDTH` | 140 | 按钮宽 |
| `ButtonArea.BUTTON_AREA_HEIGHT` | 100 | 按钮高 |
| `ButtonSystem.WEDGE_WIDTH` | 20 | 楔形剪切量，也是负间距 |
| `ButtonArea` Spacing | (-20, 0) | **横排**，靠负间距咬合 |
| `MainMenuButton` HoverScale | 1.2 | 悬停放大 |
| 图标 / 文字 | 32 / 20 | 图标居中、文字贴底（Margin.Bottom=7） |

配色也是源码里的原值：play `#6644CC`、edit `#EEAA00`、browse `#A5CC00`、exit `#EE3399`。

最终形态：**一条贯穿全屏的灰色横带**，中间压着 osu! logo，
左边一个灰色「设置」，右边四个彩色楔形按钮（开始游玩 / 编辑 / 浏览谱面 / 退出）。
logo 是粉圆 + 白环 + 白色 `osu!` + 背后放射状黑色尖刺（对应 `LogoVisualisation`）。
收起状态 logo 居中放大，点一下才展开横带（对应 `ButtonSystemState.Initial → TopLevel`）。

### 选歌页（复刻 SongSelect）

源码里的结构不是"横向封面轮播"，而是：

- 左边一列**竖排面板**，每个面板 = 一首歌：封面铺底 + 标题 / 艺术家 / 难度点
  （`PanelBeatmapSet.HEIGHT = 45 × 1.6 = 72`，`Panel.CORNER_RADIUS = 10`，
  内边距 left 15 / top 7.5 / bottom 13，`BeatmapCarousel.SPACING = 3`）；
- 选中的面板**右移 25**（`Panel.active_x_offset`）并展开，把这首歌的难度
  作为子面板列在下面（`PanelBeatmap.HEIGHT = 45`）；
- 右边是信息区（封面 + 标题 + 谱师 + BPM / 时长 / 难度数 / 物件）；
- 底部是 footer（`ScreenFooter` 高 50）；
- 背景是当前谱面的封面，模糊 + 压暗（`BackgroundScreenBeatmap`）。

### 尺寸策略：和 lazer 的 UIScale 同构

lazer 的设计分辨率是 1366×768，所有尺寸写成"设计像素"，运行时乘
`UIScale = 屏幕高 / 768`。这里照抄成 `osu/ui/UiScale.ets`，
所以每个数字都是 `设计值 * UiScale.of()`，在任何分辨率下比例都对 ——
而不是"照着某张截图量出来的绝对像素"。

### 封面从哪来

`[Events]` 的 `0,0,"bg.jpg"` 早就在 `LegacyOsuDecoder` 里解析了，这次把它接出来：

- `SongEntry` 新增 `backgroundFile`，作为 **TSV 第 16 列追加在最后**；
  读取时按 15 列校验（最小可读列数），读不到第 16 列就当空 ——
  旧索引不用迁移、也不会因为升级而整库消失；
- `SongLibrary.load()` 顺手补一次自愈：老条目背景为空时按目录重新找一遍并回写，
  否则升级后所有人的选歌页都是占位色块；
- 找图不做"随便挑一张"的兜底：`.osz` 里通常还有一堆皮肤贴图
  （`hitcircle.png`…），乱挑会把判定圈当封面贴出来。只认声明 + `bg` 前缀。

新增 `osu/library/SongGrouping.ets`：把"一个难度一行"的索引折成"一首歌一组"
（组内按 AR 升序 = 从易到难，组间按标题字母序），搜索过滤也在这里。
纯数据、不碰文件系统，所以能在 harness 里离线断言。

### 踩的坑（都很隐蔽，值得记）

**1. ArkUI 的 8 位十六进制是 `#AARRGGBB`，不是 `#RRGGBBAA`**

按 CSS 习惯写了 `#FFFFFF14`（想要 8% 白），实际被解析成「不透明黄色 `#FFFF14`」，
整个选歌页的面板、按钮、输入框全变成亮黄。项目里老代码 `#F207070A` 才是对的。

**2. `Path` / `Shape` 的坐标不是 vp**

`commands` 和 `viewPort` 里的数字既不按组件尺寸缩放，也不按 vp 解释，
一条 140×100 的平行四边形画出来只有 26×20 的小方块（缩了约 1/3.4）。
最后改用 **Canvas** 画楔形 —— Canvas 坐标就是 vp，所见即所得，画一次不重绘。

**3. 铺满全屏的容器会吃掉所有点击**

底部提示原本用一个 `height('100%')` 的 Column 做底对齐，结果点 logo 时日志是
`Touch test result is empty` —— ArkUI 的容器默认参与命中测试，透明的全屏容器
一样会挡住下面的所有控件。改成按内容高度 + `.position()` 定位。

**4. 溢出的 Canvas 也会吃掉点击**

logo 背后的尖刺画布是 logo 的 2 倍尺寸，盖住了两侧按钮，
点「开始游玩」时被它吞掉。加 `.hitTestBehavior(HitTestMode.None)` 解决。

**5. 别用 `blur` 画光晕**

`Circle().blur(90)` 会按图层边界裁剪，屏幕上出现一道从顶到底的硬分界线
（看着像两张不同底色的图拼起来）。改成在 Canvas 里画径向渐变。

### 验证

| 项 | 结果 |
| --- | --- |
| 主菜单 | 横带贯穿全屏、logo 压带、四个彩色楔形按钮、logo 白环 + 放射尖刺 |
| 选歌页 | 竖排封面面板 + 选中展开 8 个难度 + 右侧信息区 + 模糊封面背景 |
| 流程 | 主菜单 → 开始游玩 → 选歌 → Easy → 游戏 121 FPS，皮肤显示正常 |
| 离线断言 | **223 通过 / 0 失败**（新增 14 段 21 条：TSV 16 列兼容、分组、搜索） |

### 还没做

- 没有官方字体（Torus / Aller）和图标字体（osu! icon），
  文字用系统字体、图标用 Unicode 近似 —— `osu.Game.Resources` 是 git 子模块，包里没有
- 选歌页还没有 lazer 的 `FilterControl`（排序/分组下拉）和 `BeatmapDetailsArea` 的楔形块
- 游戏页背景还没有用谱面封面（现在是纯色 playfield）

---

## 十三、P2 续：SongTicker + 游戏页谱面封面

### 13.1 主菜单 SongTicker（右上角）

照 `osu.Game/Screens/Menu/SongTicker.cs` 复刻：

| 项 | lazer 原值 | 移植 |
| --- | --- | --- |
| 位置 | `Anchor/Origin = TopRight`，`Margin = { Right = 15, Top = 5 }` | 全宽 Column + `padding.right = 15 * uiScale`，`position.y = 5 * uiScale` |
| 标题 | `OsuFont(size: 24, weight: Light, italics: true)` | `fontSize 24 * uiScale` + `FontWeight.Lighter` + `FontStyle.Italic` |
| 艺术家 | `size: 16` | `fontSize 16 * uiScale` |
| 行距 | `Spacing = (0, 3)` | `Column({ space: 3 * uiScale })` |
| 节奏 | `FadeInFromZero(400)` → `Delay(4000)` → `FadeOut(800)` | `animateTo(400)` → `setTimeout(4400)` → `animateTo(800)` |

绑定对象：lazer 绑 `Bindable<WorkingBeatmap>`（上一次玩/选中的谱面）。我们没有跨会话的
"当前谱面"，用库里第一首 —— 结构一一对应，只是选中态还没接上选歌页。

原来的「谱面库 N 首 · M 难度」统计挪到右下角（lazer 那里什么都没有，是我们的诊断信息）。
两个容器都加了 `hitTestBehavior(HitTestMode.None)` —— 全宽容器会吃掉点击，这条已经踩过一次。

### 13.2 游戏页谱面封面（BackgroundScreenBeatmap）

lazer 游戏背景 = 谱面封面铺满全屏 + 按 `OsuSetting.DimLevel` 压暗（默认 0.7 → 亮度 0.3），
Playfield 本身**没有底色**，直接叠在压暗的封面上。

数据流和皮肤图集同构，但是**第二张独立纹理**：

```
ArkTS image 解码（长边压到 1280）→ uploadBackground(w,h,rgba)
   → 队列 + dirty 标记 → 渲染线程 glTexImage2D → DrawBackground 全屏四边形
```

为什么必须独立纹理：图集是"白 + alpha"的蒙版，纯色图元（圆/滑条/环）靠采样图集左上角
白块来着色。把封面混进图集，这些图元会去采样封面的像素，整场画面变花。

`DrawBackground` 的几何是一块正好覆盖屏幕的四边形，**只改 UV 做 cover 裁切**
（图更宽就裁左右、更高就裁上下），压暗用顶点色 rgb 乘上去（alpha 固定 1），
换谱不用重新解码。

### 踩坑

**1. JPEG 解码后 alpha = 0，整张封面被 shader discard**

第一次传完纹理，日志显示 `background uploaded 1024x768 err=0`、`bg quad ... dim=1.00 err=0`、
draw call 也提交了，屏幕上却什么都没有。原因是 HarmonyOS 的 image 解码器对没有 alpha 通道的
JPEG 不保证把 alpha 填成 255（实测全是 0），而 fragment shader 里 `alpha <= 0.003` 就 `discard`。
在 `UploadBackground` 里强制写 `alpha = 255` 解决 —— 封面永远不透明。

**2. 全屏底色矩形把封面整块盖死（第二个"什么都没有"）**

修完 alpha 后仍然看不到封面。真凶是 `BeatmapRenderer.draw()` 开头那两块 **alpha=1 的实心矩形**：
全屏底 `0x0E0E12` + 场地底 `0x17171F`。它们和封面在同一个 framebuffer，但顺序在后 → 全盖住。
lazer 的 Playfield 没有底色，所以在 `useBackground = true` 时这两块直接不下发。
这个 flag 由 Play 每帧从 `getBackgroundUploaded()` 同步 —— 纹理没传上去时保持不进位，
不会出现"底色没了、封面还没到"的黑场。

**3. `getBackgroundUploaded()` 不能在上传后立刻读**

`uploadBackground()` 只是入队，真正的 `glTexImage2D` 在渲染线程下一帧。上传后立刻读必然是 0，
HUD 会一直显示「封面 0」误导判断。改成在 HUD 定时器里轮询。

**4. `DEVECO_SDK_HOME` 必须显式给**

命令行跑 `hvigorw` 报 `00303217 Configuration Error: Invalid value of 'DEVECO_SDK_HOME'`，
而 IDE 里点构建是好的（IDE 自己注入）。命令行构建要带：

```bash
export DEVECO_SDK_HOME="C:/Program Files/Huawei/DevEco Studio/sdk"
hvigorw.bat assembleHap --mode module -p product=default --no-daemon
```

### 验证

| 项 | 结果 |
| --- | --- |
| SongTicker | 右上角出现 `Night of Knights`（24 Light 斜体）+ `beatMARIO`（16），4.4s 后淡出 |
| 游戏背景 | `Night of Knights [Easy]` 的封面铺满全屏、压暗到 30%，判定圈/滑条/尾判叠在上面 |
| HUD | `封面 1`、`FPS 101`、`指令 44`、`arkTS-sprite 14 / native 14` |
| 暂停 | 暂停面板压在封面上，可读 |
| 离线断言 | **225 通过 / 0 失败**（新增 2 条：有封面时省掉两块底色矩形、不存在不透明全屏矩形） |

### 还没做

- 没有官方字体（Torus / Aller）与图标字体，文字系统字体、图标 Unicode 近似
- 选歌页缺 `FilterControl`（排序/分组下拉）、`BeatmapDetailsArea` 楔形色块
- SongTicker 绑的是库里第一首，还没接"选中哪首显示哪首"
- 主菜单缺 `MenuSideFlashes`（左右边缘跟拍闪烁）与 `KiaiMenuFountains`

---

## 十四、按卓易通真机录屏还原（Argon 皮肤）

参考素材：两段真机录屏（1920×852，osu!lazer 2025 默认皮肤 **Argon** 在卓易通上的运行画面），
抽帧放在 `output/oring/`（`v1/`、`v2/` 两个序列 + 联系表 + 关键帧 `sel.jpg` `pause.jpg` `result2.jpg`）。

结论：之前做的是"lazer 经典 HUD"（左上准确率 + COMBO 文本 + 调试字样），
真机是 **Argon**，完全另一套视觉。这一轮把游戏内 HUD、暂停页、结算页、选歌页全部按录屏重做。

### 14.1 游戏内 HUD

全部尺寸用「屏幕宽/高百分比」而不是 UiScale —— Argon 自己就是 `RelativeSizeAxes`，
量的比例和它的设计意图是同一件事。

| 元素 | 位置（占屏） | 做法 |
| --- | --- | --- |
| 分数面板 | x 0.030、y 0.020、w 0.215、h 0.108 | 一个 Canvas 画半透明深青圆角板 + 上方发光折线，数字用 Text 叠上去 |
| 发光折线 | 面板内 y 0.30h | 水平走 70% 然后 45° 折下来收圆头；亮段长度 = 歌曲进度，`shadowBlur` 出白光 |
| 准确率 | 右上 x 0.972 | `准确率`（8FC7E8）+ 大数字 + `pp N` |
| 连击 | 左下 x 0.045、y 0.775 | `连击` + `42x`（x 缩小贴在数字右下） |
| 进度条 | y 0.952、x 0.075..0.930 | 4vp 白线，前景按 progress 拉伸，两端是 `0:41` / `2:51` |
| 帧统计 | 右下 x 0.995 | 黑底橙字 `2 ms / 120 fps` —— lazer 的 FrameStatistics 就长这样，顺便当诊断用 |
| 暂停按钮 | x 0.955、y 0.775 | 圆形 ✕，半透明底 + 白描边 |

调试开关（AUTO / ±5ms / 结算）从游戏画面挪进暂停页 —— 录屏里游戏内只有那一个 ✕，
原样保留会让画面一眼假。

### 14.2 暂停页

| 元素 | 值 |
| --- | --- |
| 标题 | `已暂停`，金色 `#F2C23C`，y 0.115 |
| 三根斜条 | x 0.185、w 0.695、每根 h 0.150、间距 0.010；斜切量 = 0.30h |
| 颜色 | 继续 `#88B200` / 重试 `#EDAB01` / 退出 `#A91B25`（从录屏采样得到） |
| 底部摘要 | `重试次数 / 歌曲进度 / 准确率` 三行，x 0.395 |
| 等级徽章 | 圆环 + `1`，x 0.735 |

### 14.3 结算页

左卡片（宽 0.30）：头像 + 名字 + 谱面名/艺术家 + **等级环**（按 300/100/50/miss 比例分段着色，
颜色 `#5FE0E8 / #7ED957 / #FFD24D / #FF4D6A`，中间叠大字母）+ 分数 + `准确率 · 最大连击`。

右列（宽 0.545）四个面板：
`Performance Breakdown`（Aim/Speed/Accuracy 三条 + Achieved PP）、
`Timing Distribution`（偏差直方图，41 箱 ±150ms）、
`Accuracy Heatmap`（散布图 + Overshoot/Undershoot）、
`Overall Ranking`（本地名次）。

**判定计数不摆面板**：lazer 把 300/100/50/miss 挂在准确率环外圈（录屏里环左上、环左侧、
环右下各有小方块），count 为 0 的档位不画。所以这一栏用 `judgeBadge(x, y, count, colour)`
贴在等级环 Stack 上，位置是百分比（`1%/11%`、`-5%/52%`、`80%/73%`、`76%/6%`）。

**Overall Ranking 的数据从哪来**：录屏里这块被底栏挡住，只露出标题，所以内容按 lazer 的结构补
（左侧大位次 + 右侧两组统计 + 一条「本次 / 本谱最佳」比例条），数据源是新加的本地存档
`osu/library/ResultHistory.ets`：

- `files/history.txt`，一行一局 `key \t score \t acc \t pp \t grade \t time`，最多 400 条；
- `files/favourites.txt`，一行一个谱面 key（结算页那个心）；
- 谱面 key = `artist - title`（没接服务器，只能用这个当主键）；
- 名次定义：`1 + (分数严格更高的记录数)`，所以同分并列 —— 真机上 3 次同分 4949 都显示 `#1`，
  打了一局 2288 之后变 `#4 / of 4 plays`、比例条 46%（2288/4949），符合预期。

**注意**：这是单机存档，不是服务器排行榜。UI 文案用 `本谱最佳 / 本谱排名 / 本次分数`，
没有伪装成全球排名。

`HitErrorBar` 为此补了三个能力：全部样本（`sampleAt`）、偏差平方和 → `unstableRate()`
（标准差 ×10，osu! 的 UR 定义）、`histogram(bins, span)` 分箱。


能力拆解是**近似**：lazer 真值来自 strain 图，我们没做，改用
`Aim = 准确率 × (0.45 + 0.55×连击保持率)`、`Speed = min(1, 260/UR)`、`Accuracy = 准确率`，
再归一化成百分比。语义一样（占比），数值别当真。

### 14.4 选歌页（移动端布局）

参考 `sel.jpg`：左栏详情卡 + 右栏搜索/轮播 + 底部斜切工具条 + 右下角压出屏幕的大 logo。
与原实现（左竖排面板 / 右详情）相比是**整体换布局**。

### 踩坑

**1. ArkUI 的 `@Builder` 不能当参数传回调里包 UI**

`@Builder statPanel(title, body: () => void)` 里调用 `body()` 展开 `Row() { ... }` 会直接
编译失败（`';' expected`）—— 箭头函数体里的 UI 语法不被 DSL 解析器接受。
只能把每个面板的容器写全，或者用 `@BuilderParam`（那需要自定义组件）。
最后改成：`@Builder panelTitle()` + 每个面板自己写 4 行容器修饰符。

**2. `Image` 加载沙箱文件必须带 `file://`**

结算页背景一开始写成 `Image(this.backgroundPath)`，**静默失败**（不报错、不显示），
画面透出游戏最后一帧。选歌页的 `coverUri()` 一直是对的：`file://${path}`。
这种"不报错的空白"最难查 —— 加新页面时先确认有没有前缀。

**3. `hdc install` / `file recv` 传 `C:/...` 绝对路径会被拼上当前目录**

设了 `MSYS_NO_PATHCONV=1` 之后路径不会被转成 `/c/...`，但 hdc 自己又把它当相对路径，
报 `Error opening file ... path:c:\现有目录\C:/Users/...`。解法：**先 `cd` 到目标目录，
再用文件名**（`install -r entry-default-signed.hap` / `file recv /data/local/tmp/x.jpeg x.jpeg`）。

**4. `hvigorw` 的 `-p` 参数不指定工程目录**

写 `hvigorw assembleHap -p <工程路径>` 会去**当前工作目录**找 `hvigor/hvigor-config.json5`，
报 `00304004 Not Found`。必须 `cd <工程目录>` 之后再跑，`-p` 只用来传 `product=default`。

**5. `@Builder` 按值传参不会触发刷新**

`this.resultButton(0.801, 0.074, this.resFav ? '♥' : '♡', …)` —— 点下去 `resFav` 变了、
UI 一动不动。`@Builder` 的**按值参数是快照**，只有参数本身被重新传入才会重建；
而 Builder **内部直接读 `this.xxx`** 就会跟着 state 走（同文件里
`if (this.exportTip.length > 0)` 能刷新就是证据）。
所以收藏按钮拆成独立的 `@Builder favButton()`，图标/颜色都在里面读 `this.resFav`。

**6. `♥`(U+2665) 在 HarmonyOS 上会走 emoji 回退**

渲染成系统红色彩色字形，`fontColor` 完全失效；加 `\uFE0E`（文本变体选择符）也压不住。
要可控颜色就得用 `Path` / Canvas 自己画。
另外 **`Path` 的 commands 坐标是 vp，不随 `.width()/.height()` 缩放**，
必须按图标实际尺寸生成路径（`heartPath()` 就是这么来的）。

**7. 小尺寸 Path 不能用空心描边**

心形只有约 50px 宽时，`strokeWidth` 0.9vp 的两条描边会把顶部凹口（宽仅 5~7px）糊成实块，
看起来像实心心。最终改实心双态：未收藏 `#B9C6C2` / 收藏 `#E5368C`，按钮底色同步
`#4A4F52 → #5C2436`。另外 **`Path` 默认带 1vp 黑描边**，不写 `.strokeWidth(0)` 心形外圈会挂一圈黑边。

**8. `hdc file send` 进沙箱目录会被 SELinux 拒**

`/data/app/el2/100/base/<bundle>/haps/entry/files/` 下 `rm` 能成功、`file send` 报
`permission denied`（shell 有删除权限但没写权限）。想造测试数据只能走应用自己的写入路径，
或者用"真实对局"来生成。

### 验证（真机，2026-11-09 全部复验通过）

| 项 | 结果 |
| --- | --- |
| 游戏内 HUD | 分数板 + 发光折线 + 准确率 + pp + 连击 + 进度条 + `2ms/120fps` 全部到位 |
| 暂停页 | 三色斜条 + 金色标题 + 摘要 + 徽章，与录屏一致 |
| 结算页 | 等级环 SS、能力拆解（Achieved PP 单行不挤压）、直方图、散布图；背景模糊封面正常（`file://` 生效） |
| 等级环判定标签 | 全 300 时显示 `7`（青）；D 级那局显示 `4` + miss `35`（红，右上），0 的档位不画 |
| Overall Ranking | 同分 3 局 → `#1 / of 3 plays`、本谱 `第 1 / 3 次`；打一局 2288 → `#4 / of 4 plays`、`第 4 / 4 次`、比例条 46%（2288/4949） |
| 结算页底部条 | 录屏同款 5 槽：返回粉 0.069W / 导出绿 0.239W / 重试绿 0.240W / 选歌灰 0.074W / 收藏灰 0.074W，y 0.885H |
| 结算页导出 | 写 `files/results/last-result.json`，含 `localRank/localTotal/mapBest/mapRank/mapPlays/favourited` |
| 收藏持久化 | 点一次 → `favourites.txt` 出现该 key、心形粉色；再点一次 → 文件清空、心形灰；重启应用后状态保留 |
| 历史存档 | `files/history.txt` 追加式，一行一局，重启后累加（3 局 → `of 3 plays`） |
| 选歌页 | 左详情卡 / 右搜索+轮播 / 底部斜切工具条 / 右下大 logo / 模糊封面背景全部到位；统计行为 `数值 + 中文标签` |

**遗留**：选歌页左详情卡还没有收藏标记（收藏目前只在结算页可见）；判定计数与 combo 的差值
（全 300 的 Easy 局 `300=7` 而 `21x` 连击）是滑条 tick 计入连击造成的，属于 osu 正常语义。


