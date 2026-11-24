import { abilityAccessCtrl, AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { i18n } from '@kit.LocalizationKit';
import pointer from '@ohos.multimodalInput.pointer';
// 输入法控制器安全代理：防止 login 面板关闭时 SDL3 异步 hide/on/off 在 detached
// 状态调用真实 IME 控制器抛 12800009 未捕获异常导致 Ability 崩溃（退回桌面）。
import { SafeIMEController } from './SafeIMEController';
import fs from '@ohos.file.fs';
import sdl from 'libSDL3.so';
// M0 回归尖刀：只验证 NativeAOT 托管代码能执行，不触碰 SDL3 全局状态。
// 注意不要在这里调 sdlGate()：它会 dlopen(libSDL3.so) 并 SDL_Init/SDL_Quit，
// 污染 SDL3 的启动状态，导致后面的 SDL_RunApp 失败。
import aotsample from 'libaotsample.so';

const DOMAIN = 0x0000;

/**
 * 路径 B：Ability 完全交给 SDL3 官方 OpenHarmony 后端接管。
 *
 * provideArkTSObjects() 通过 NAPI 给 this 挂上 onWindowStageCreate /
 * onWindowStageDestroy / onForeground / onBackground 等实现
 * （SDL_openharmony.c 的 TakeOverUIAbility）。所以本类不能再定义同名生命周期
 * 方法，否则会与 SDL3 注入的实例属性冲突。
 *
 * 启动链：
 *   onCreate → provideArkTSObjects
 *   → (SDL3) onWindowStageCreate → windowStage.loadContent('pages/Index')
 *   → XComponent OnSurfaceCreated → SDL_OpenHarmonyMainSurfaceCreated()
 *   → SDL_RunApp() → dlopen("libmain.so") → dlsym("SDL_main")
 *   → NativeAOT 里的 NativeEntry.Main → OHOSGameHost.Run(new OsuGameOHOS())
 */
export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'OSU-AOT', '%{public}s', 'Ability onCreate (route B: native SDL3 / osu!lazer)');

    // ---------------- 启动模式 ----------------
    // native 侧（NativeEntry.ReadMode）读这个文件决定跑 OsuGame 还是最小自检 Game。
    // 用文件而不是环境变量，是因为 aa start 不支持给应用传环境变量。
    // 每次启动都重写，未显式指定时回到 lazer，避免上次 selftest 残留。
    this.writeMode(want);

    // ---------------- 谱面导入暂存 ----------------
    // ArkTS 有沙箱写权限、native/AOT 侧没有「文件选择器」。这里把外部放好的
    // .osz 复制进游戏自己的 osu/import 目录；C# 侧 OsuGameOHOS 在 LoadComplete
    // 后扫描该目录调 BeatmapManager.Import()。
    this.stageBeatmapArchives();

    // ---------------- M0 回归 ----------------
    try {
      const r: number = aotsample.hello();
      hilog.info(DOMAIN, 'OSU-AOT', 'M0 regression aot hello = %{public}d (%{public}s)',
        r, r === 84 ? 'PASS' : 'VALUE-MISMATCH');
    } catch (err) {
      hilog.error(DOMAIN, 'OSU-AOT', 'aot hello failed: %{public}s', `${(err as Error).message}`);
    }

    // ---------------- 交棒给 SDL3 ----------------
    // 参数个数必须与 SDL_openharmony.c:1082 的 expected_argc = 5 完全一致，
    // 少一个 C 侧会 log fatal 后 exit(1)。
    try {
      sdl.provideArkTSObjects(
        this,
        abilityAccessCtrl.createAtManager(),
        i18n.System,
        pointer.setPointerVisibleSync,
        new SafeIMEController()
      );
      hilog.info(DOMAIN, 'OSU-AOT', '%{public}s', 'M1b SDL3 provideArkTSObjects OK');
    } catch (err) {
      hilog.error(DOMAIN, 'OSU-AOT', 'SDL3 provideArkTSObjects failed: %{public}s',
        `${(err as Error).message}`);
    }
  }

  /**
   * 准备待导入的 .osz：
   *   1. /data/local/tmp/osu-import/*.osz（hdc file send 的落点，任意谱面）
   *   2. rawfile/sample_beats.osz（HAP 内置的 Night of Knights 样本，兜底）
   * 只复制、不导入；真正的 BeatmapManager.Import 在 AOT 侧执行。
   */
  private stageBeatmapArchives(): void {
    const importDir = `${this.context.filesDir}/osu/import`;

    try {
      // 实测 HarmonyOS 的 mkdirSync(dir, true) 在目录已存在时会抛 "File exists"，
      // 不能无条件调用，否则第二次启动整个导入流程都会被跳过。
      if (!fs.accessSync(importDir)) {
        fs.mkdirSync(importDir, true);
      }
    } catch (err) {
      hilog.error(DOMAIN, 'OSU-AOT', 'create import dir failed: %{public}s', `${(err as Error).message}`);
      return;
    }

    // 让 native 侧不必猜 filesDir 的真实路径。
    try {
      const manifest = fs.openSync(`${importDir}/import-dir.txt`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(manifest.fd, importDir);
      fs.closeSync(manifest);
    } catch (err) {
      hilog.warn(DOMAIN, 'OSU-AOT', 'write import-dir.txt failed: %{public}s', `${(err as Error).message}`);
    }

    // 外部投递目录。hdc shell 不能直接写应用沙箱，只能先放这里。
    const staging = '/data/local/tmp/osu-import';
    try {
      if (fs.accessSync(staging)) {
        const entries: string[] = fs.listFileSync(staging);
        for (const name of entries) {
          if (!name.endsWith('.osz')) {
            continue;
          }
          try {
            if (fs.accessSync(`${importDir}/${name}.done`)) {
              continue;
            }
            fs.copyFileSync(`${staging}/${name}`, `${importDir}/${name}`);
            hilog.info(DOMAIN, 'OSU-AOT', 'staged beatmap from /data/local/tmp: %{public}s', name);
          } catch (err) {
            hilog.error(DOMAIN, 'OSU-AOT', 'copy staged beatmap failed: %{public}s', `${(err as Error).message}`);
          }
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'OSU-AOT', 'read /data/local/tmp/osu-import failed: %{public}s', `${(err as Error).message}`);
    }

    // 兜底：目录里还没有 .osz 时用 HAP 内置的样本，方便首次启动就能看到导入效果。
    try {
      if (this.hasArchive(importDir)) {
        return;
      }
      const raw: Uint8Array = this.context.resourceManager.getRawFileContentSync('sample_beats.osz');
      const buffer: ArrayBuffer = new ArrayBuffer(raw.byteLength);
      new Uint8Array(buffer).set(raw);
      const file = fs.openSync(`${importDir}/sample_beats.osz`,
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, buffer);
      fs.closeSync(file);
      hilog.info(DOMAIN, 'OSU-AOT', 'staged bundled sample_beats.osz (%{public}d bytes)', raw.byteLength);
    } catch (err) {
      hilog.error(DOMAIN, 'OSU-AOT', 'stage bundled beatmap failed: %{public}s', `${(err as Error).message}`);
    }
  }

  private hasArchive(dir: string): boolean {
    try {
      const entries: string[] = fs.listFileSync(dir);
      for (const name of entries) {
        // importer 成功后会删掉 .osz 并留下 .osz.done，二者都算「已处理过」。
        if (name.endsWith('.osz') || name.endsWith('.osz.done')) {
          return true;
        }
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'OSU-AOT', 'list import dir failed: %{public}s', `${(err as Error).message}`);
    }
    return false;
  }

  /**
   * 把 want 里的 osu_mode 落到沙箱文件，供 native 侧读取。
   *   hdc shell aa start -a EntryAbility -b com.example.myapplication --ps osu_mode selftest
   * 语法上 aa start 的 --ps 是「转成 string 的 key-value」，这里取不到就回落 lazer。
   */
  private writeMode(want: Want): void {
    let mode = 'lazer';

    try {
      const raw = want.parameters?.['osu_mode'];
      if (typeof raw === 'string' && raw.length > 0) {
        mode = raw;
      }
    } catch (err) {
      hilog.warn(DOMAIN, 'OSU-AOT', 'read want.osu_mode failed: %{public}s', `${(err as Error).message}`);
    }

    try {
      const path = `${this.context.filesDir}/osu-mode.txt`;
      const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, mode);
      fs.closeSync(file);
      hilog.info(DOMAIN, 'OSU-AOT', 'osu-mode=%{public}s written to %{public}s', mode, path);
    } catch (err) {
      hilog.error(DOMAIN, 'OSU-AOT', 'writeMode failed: %{public}s', `${(err as Error).message}`);
    }
  }
}
