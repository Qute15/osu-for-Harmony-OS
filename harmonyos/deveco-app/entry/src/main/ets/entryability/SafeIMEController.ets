import { inputMethod } from '@kit.IMEKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN = 0x0000;
const TAG = 'OSU-IME';

/** 与 ArkTS AsyncCallback<void> 等价的回调类型（NAPI 传进来的是无参 JS function）。 */
type IMEAsyncCallback = (err?: BusinessError) => void;
type IMEEventCallback = (text: string) => void;

/**
 * SDL3 OpenHarmony 后端输入法控制器的安全代理。
 *
 * 背景：SDL_openharmony.c 通过 provideArkTSObjects() 拿到 inputMethod.getController()
 * 的引用，然后在 JS 线程里异步（napi_tsfn_nonblocking）调用 attach / hideTextInput /
 * on / off。它有两个缺陷：
 *   1. attach 与 hideTextInput 的异步任务没有串行化，文本框快速获得/失去焦点时，
 *      hideTextInput 可能在 attach 还没完成时被调用；
 *   2. hideTextInput 之后并不 detach，login 面板重建文本框时系统会自行 detach，
 *      此时任何 hideTextInput/on/off 都会抛 12800009 "input method client detached"，
 *      ArkTS 未捕获 -> UIAbility 崩溃 -> 游戏退回桌面。
 *
 * 代理把「SDL 的意图」和「真实 IME 控制器」隔开：
 *   - 维护 attached 状态，只有真正 attach 成功才置位；
 *   - 未 attach 时的 hide/show 变成 no-op（直接回调成功，不碰真实控制器）；
 *   - 所有转发都包在 try/catch 里；
 *   - 回调一律会被调用（成功或降级都调），避免 SDL 的 userdata 泄漏 / 状态机停滞；
 *   - NAPI 侧拿到的就是这个对象的同名方法，签名与 InputMethodController 一致。
 *
 * 这样无需改 SDL C 源码或重编 libSDL3.so / libmain.so，只重新打包 HAP 即可。
 */
export class SafeIMEController {
  private real: inputMethod.InputMethodController;
  private attached: boolean = false;

  constructor() {
    this.real = inputMethod.getController();
  }

  /** 统一的安全转发：吞异常、保证回调触发。 */
  private invoke(name: string, cb: IMEAsyncCallback | undefined, fn: () => void): void {
    try {
      fn();
    } catch (err) {
      const e = err as BusinessError;
      hilog.warn(DOMAIN, TAG, '%{public}s rejected: code=%{public}d msg=%{public}s',
        name, e?.code ?? -1, e?.message ?? 'unknown');
      // 降级也要回调，否则 SDL 侧 SDL_JS_*Result 永远不执行。
      if (cb) {
        try {
          cb();
        } catch (_) {
          hilog.warn(DOMAIN, TAG, '%{public}s callback threw', name);
        }
      }
    }
  }

  attach(showKeyboard: boolean, textConfig: inputMethod.TextConfig, cb: IMEAsyncCallback): void {
    this.invoke('attach', cb, () => {
      // 幂等：已经 attach 就别再 attach（重复 attach 会报 12800003）。
      if (this.attached) {
        hilog.info(DOMAIN, TAG, 'attach skipped (already attached)');
        cb();
        return;
      }
      try {
        this.real.attach(showKeyboard, textConfig, (err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'real attach err: code=%{public}d msg=%{public}s',
              err.code, err.message);
          } else {
            this.attached = true;
          }
          // 无论成功失败都通知 SDL，让它继续注册 insertText/deleteLeft 监听。
          cb();
        });
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'attach threw: code=%{public}d msg=%{public}s',
          e?.code ?? -1, e?.message ?? 'unknown');
        cb();
      }
    });
  }

  hideTextInput(cb: IMEAsyncCallback): void {
    this.invoke('hideTextInput', cb, () => {
      if (!this.attached) {
        // 未 attach 时真实控制器会抛 12800009，这里直接降级成功。
        hilog.info(DOMAIN, TAG, 'hideTextInput skipped (not attached)');
        cb();
        return;
      }
      try {
        this.real.hideTextInput((err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'real hideTextInput err: code=%{public}d msg=%{public}s',
              err.code, err.message);
          }
          cb();
        });
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'hideTextInput threw: code=%{public}d msg=%{public}s',
          e?.code ?? -1, e?.message ?? 'unknown');
        cb();
      }
    });
  }

  showTextInput(cb: IMEAsyncCallback): void {
    this.invoke('showTextInput', cb, () => {
      if (!this.attached) {
        hilog.info(DOMAIN, TAG, 'showTextInput skipped (not attached)');
        cb();
        return;
      }
      try {
        this.real.showTextInput((err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'real showTextInput err: code=%{public}d msg=%{public}s',
              err.code, err.message);
          }
          cb();
        });
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'showTextInput threw: code=%{public}d msg=%{public}s',
          e?.code ?? -1, e?.message ?? 'unknown');
        cb();
      }
    });
  }

  on(event: string, cb: IMEEventCallback): void {
    this.invoke('on', undefined, () => {
      if (!this.attached) {
        // 未 attach 时 on 也会抛 12800009。SDL 依赖它注册 insertText 回调，
        // 但此时根本不会有输入事件，跳过是安全的。
        hilog.info(DOMAIN, TAG, 'on(%{public}s) skipped (not attached)', event);
        return;
      }
      // SDL 只用 insertText / deleteLeft 两个事件，按字面量重载分别转发。
      if (event === 'insertText') {
        this.real.on('insertText', cb);
      } else if (event === 'deleteLeft') {
        this.real.on('deleteLeft', cb as object as (length: number) => void);
      } else {
        hilog.info(DOMAIN, TAG, 'on(%{public}s) ignored (unsupported event)', event);
      }
    });
  }

  off(event: string, cb: IMEEventCallback): void {
    this.invoke('off', undefined, () => {
      if (!this.attached) {
        hilog.info(DOMAIN, TAG, 'off(%{public}s) skipped (not attached)', event);
        return;
      }
      if (event === 'insertText') {
        this.real.off('insertText', cb);
      } else if (event === 'deleteLeft') {
        this.real.off('deleteLeft', cb as object as (length: number) => void);
      } else {
        hilog.info(DOMAIN, TAG, 'off(%{public}s) ignored (unsupported event)', event);
      }
    });
  }

  /**
   * SDL 目前不主动 detach，但文本框销毁时系统可能自行 detach。
   * 提供这个方法让外部（或未来的 SDL 版本）能干净地复位状态。
   */
  detach(cb: IMEAsyncCallback): void {
    this.invoke('detach', cb, () => {
      if (!this.attached) {
        cb();
        return;
      }
      try {
        this.real.detach((err: BusinessError) => {
          if (err) {
            hilog.warn(DOMAIN, TAG, 'real detach err: code=%{public}d msg=%{public}s',
              err.code, err.message);
          }
          this.attached = false;
          cb();
        });
      } catch (err) {
        const e = err as BusinessError;
        hilog.warn(DOMAIN, TAG, 'detach threw: code=%{public}d msg=%{public}s',
          e?.code ?? -1, e?.message ?? 'unknown');
        this.attached = false;
        cb();
      }
    });
  }
}
