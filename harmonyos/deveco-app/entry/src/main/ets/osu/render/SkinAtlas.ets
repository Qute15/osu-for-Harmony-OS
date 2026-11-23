import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { resourceManager } from '@kit.LocalizationKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import osuNative from 'libosu.so';

const DOMAIN = 0x0F0F;
const TAG = 'OSU-SKIN';

const ATLAS_PNG = 'skin/atlas.png';
const ATLAS_JSON = 'skin/atlas.json';

interface AtlasMeta {
  size: number[];
  sprites: Record<string, number[]>;
}

/** 贴图名 —— 和 gen_skin.py 里 place() 的 key 一一对应 */
export class SpriteName {
  static readonly WHITE: string = 'white';
  static readonly HITCIRCLE: string = 'hitcircle';
  static readonly HITCIRCLE_OVERLAY: string = 'hitcircleoverlay';
  static readonly APPROACH_CIRCLE: string = 'approachcircle';
  static readonly SLIDER_BALL: string = 'sliderb';
  static readonly FOLLOW_CIRCLE: string = 'sliderfollowcircle';
  static readonly CURSOR: string = 'cursor';
  static readonly HIT_LIGHT: string = 'hitlight';
}

/**
 * 皮肤图集。
 *
 * 一张 1024x1024 的 RGBA 图，装着所有判定圈 / 滑条球 / 光标 / 数字，
 * 上传到 GL 后整帧共用一次纹理绑定 —— 这就是 osu! 皮肤 atlas 的思路，
 * 也是为什么"换皮肤"在这个引擎里只是换一张图和一份 json。
 *
 * 贴图全是白色 + alpha，实际颜色由绘制时的顶点色决定（combo 色）。
 * 图集加载失败不致命：BeatmapRenderer 会退回矢量画法，照样能玩。
 */
export class SkinAtlas {
  static loaded: boolean = false;
  static textureWidth: number = 0;
  static textureHeight: number = 0;

  /** name -> [u0, v0, u1, v1]（归一化） */
  private static uvs: Map<string, number[]> = new Map<string, number[]>();
  private static sizes: Map<string, number[]> = new Map<string, number[]>();

  private static lastError: string = '';

  static error(): string {
    return SkinAtlas.lastError;
  }

  /** 贴图原始像素尺寸（画的时候要按它算宽高比） */
  static pixelSize(name: string): number[] {
    const s = SkinAtlas.sizes.get(name);
    return s === undefined ? [0, 0] : s;
  }

  /**
   * 归一化 UV；没加载成功时返回空数组，调用方据此退回矢量画法。
   *
   * 注意这里显式写 `SkinAtlas.uvs` 而不是 `this.uvs`：静态方法里的 this
   * 依赖调用方的绑定方式，跨模块调用时一旦被解构就会丢，查表会静默返回空。
   */
  static uv(name: string): number[] {
    if (name === undefined || name === null || name.length === 0) {
      return [];
    }
    const v = SkinAtlas.uvs.get(name);
    return v === undefined ? [] : v;
  }

  static digitUV(d: number): number[] {
    return SkinAtlas.uv(`digit${d % 10}`);
  }

  /**
   * 把 atlas.json 的 rect 表灌成归一化 UV 表，返回装载的 sprite 数。
   *
   * 和 GL 上传特意分开：UV 表是纯数据，可以脱离真机离线验证；
   * 而 uploadAtlas 必须在 GL 上下文所在线程执行。两边拆开后
   * "皮肤数据对不对"和"贴图传没传上去"是两个独立可测的问题。
   */
  static applyMeta(atlasWidth: number, atlasHeight: number,
    sprites: Record<string, number[]>): number {
    const tw = atlasWidth > 0 ? atlasWidth : 1;
    const th = atlasHeight > 0 ? atlasHeight : 1;
    SkinAtlas.textureWidth = atlasWidth;
    SkinAtlas.textureHeight = atlasHeight;

    // 先清空：传空表要能真的把皮肤卸掉（回退矢量），而不是留下上一份的 UV
    SkinAtlas.uvs.clear();
    SkinAtlas.sizes.clear();

    const names = Object.keys(sprites);
    let loaded = 0;
    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const r = sprites[name];
      if (r === undefined || r.length < 4) {
        continue;
      }
      SkinAtlas.uvs.set(name, [r[0] / tw, r[1] / th, (r[0] + r[2]) / tw, (r[1] + r[3]) / th]);
      SkinAtlas.sizes.set(name, [r[2], r[3]]);
      loaded++;
    }
    SkinAtlas.loaded = loaded > 0;
    return loaded;
  }

  static async load(resMgr: resourceManager.ResourceManager): Promise<boolean> {
    if (SkinAtlas.loaded) {
      return true;
    }
    try {
      const metaText = await resMgr.getRawFileContent(ATLAS_JSON);
      const text = new util.TextDecoder().decodeToString(metaText);
      const meta = JSON.parse(text) as AtlasMeta;

      const raw = await resMgr.getRawFileContent(ATLAS_PNG);
      const buf: ArrayBuffer = raw.buffer.slice(raw.byteOffset, raw.byteOffset + raw.byteLength);

      const src = image.createImageSource(buf);
      const pm = await src.createPixelMap({
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      const info = await pm.getImageInfo();
      const w = info.size.width;
      const h = info.size.height;

      // readPixelsToBuffer 给的可能是带行 padding 的，按 stride 摊平再上传，
      // 否则宽不是 4 的倍数时整张图会斜着错位。
      const stride = pm.getBytesNumberPerRow();
      const rawBytes = stride * h;
      const rawBuf = new ArrayBuffer(rawBytes);
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

      osuNative.uploadAtlas(w, h, pixels);

      const names = SkinAtlas.applyMeta(w, h, meta.sprites);
      hilog.info(DOMAIN, TAG, 'atlas ready %{public}dx%{public}d sprites=%{public}d',
        w, h, names);

      pm.release();
      src.release();
      return true;
    } catch (err) {
      SkinAtlas.lastError = JSON.stringify(err);
      hilog.error(DOMAIN, TAG, 'load atlas failed: %{public}s', SkinAtlas.lastError);
      return false;
    }
  }
}
