import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import osuNative from 'libosu.so';

const DOMAIN = 0x0F0F;
const TAG = 'OSU-BG';

/**
 * 谱面封面（lazer 的 BackgroundScreenBeatmap）。
 *
 * 数据流和皮肤图集一致：ArkTS 解码 → native 渲染线程里 glTexImage2D。
 * 差别只在**两张独立的纹理**：图集是"白 + alpha"的蒙版，封面是真彩色图，
 * 混成一张会让圆 / 滑条这些纯色图元采样到封面的图案，整场变花。
 *
 * 尺寸策略：长边压到 1280 再上传。4K 原图直传要多花 30MB 显存和几十毫秒，
 * 而它在屏幕上最多 2000 多像素宽、还被压暗到 30% 亮度，肉眼看不出差别。
 *
 * 压暗系数不在这里做：lazer 的 DimLevel 是用户设置（默认 0.7 = 亮度 0.3），
 * 由渲染器在画全屏四边形时用顶点色乘上去，换谱不用重新解码。
 */
export class BeatmapBackground {
  static readonly MAX_EDGE: number = 1280;

  /** 最近一次失败原因，日志 / HUD 用 */
  static lastError: string = '';

  /** 卸掉当前封面（换谱、离开游戏页）—— 不卸会把上一张留到下一局 */
  static clear(): void {
    osuNative.clearBackground();
  }

  /**
   * 解码并上传。path 是沙箱里的绝对路径，空串表示这张谱没有背景图。
   * 返回 false 不算错误：没有背景时游戏照常跑，只是 Playfield 后面是纯色。
   */
  static async load(path: string): Promise<boolean> {
    if (path.length === 0) {
      BeatmapBackground.clear();
      return false;
    }

    let file: fs.File | null = null;
    let src: image.ImageSource | null = null;
    let pm: image.PixelMap | null = null;

    try {
      if (!fs.accessSync(path)) {
        BeatmapBackground.lastError = `背景文件不存在: ${path}`;
        BeatmapBackground.clear();
        return false;
      }

      file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      src = image.createImageSource(file.fd);
      const info: image.ImageInfo = await src.getImageInfo();

      let w = info.size.width;
      let h = info.size.height;
      if (w <= 0 || h <= 0) {
        BeatmapBackground.lastError = `背景尺寸非法 ${w}x${h}`;
        BeatmapBackground.clear();
        return false;
      }

      const longest = Math.max(w, h);
      if (longest > BeatmapBackground.MAX_EDGE) {
        const k = BeatmapBackground.MAX_EDGE / longest;
        w = Math.max(1, Math.round(w * k));
        h = Math.max(1, Math.round(h * k));
      }

      const opts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        desiredSize: { width: w, height: h }
      };
      pm = await src.createPixelMap(opts);

      // readPixelsToBuffer 的每行可能带 padding，宽不是 4 的倍数时不摊平会斜着错位
      const stride = pm.getBytesNumberPerRow();
      const rawBuf = new ArrayBuffer(stride * h);
      await pm.readPixelsToBuffer(rawBuf);

      let pixels: ArrayBuffer = rawBuf;
      if (stride !== w * 4) {
        const tight = new ArrayBuffer(w * h * 4);
        const src8 = new Uint8Array(rawBuf);
        const dst8 = new Uint8Array(tight);
        for (let y = 0; y < h; y++) {
          const from = y * stride;
          dst8.set(src8.subarray(from, from + w * 4), y * w * 4);
        }
        pixels = tight;
      }

      osuNative.uploadBackground(w, h, pixels);
      BeatmapBackground.lastError = '';
      hilog.info(DOMAIN, TAG, 'background ready %{public}dx%{public}d (source %{public}dx%{public}d)',
        w, h, info.size.width, info.size.height);
      return true;
    } catch (err) {
      BeatmapBackground.lastError = JSON.stringify(err);
      hilog.error(DOMAIN, TAG, 'load background failed: %{public}s', BeatmapBackground.lastError);
      BeatmapBackground.clear();
      return false;
    } finally {
      if (pm !== null) {
        pm.release();
      }
      if (src !== null) {
        src.release();
      }
      if (file !== null) {
        fs.closeSync(file);
      }
    }
  }
}
