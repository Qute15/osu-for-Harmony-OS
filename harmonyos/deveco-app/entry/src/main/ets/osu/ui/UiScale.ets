import { display } from '@kit.ArkUI';

/**
 * 全局 UI 缩放系数，和 osu!lazer 的 `UIScale` 同构。
 *
 * osu!framework 的设计分辨率是 1366×768，界面上所有尺寸都写成"设计像素"，
 * 运行时统一乘一个 scale（默认 = 屏幕高 / 768）。这样在 1080p 显示器、
 * 手机、平板上比例完全一致 —— 而不是"照着某张截图量出来的绝对像素"。
 *
 * 这里照抄这个思路：任何一个界面尺寸都写成 `设计值 * UiScale.of()`。
 */
export class UiScale {
  /** 设计高度基准（lazer 的 768） */
  static readonly DESIGN_HEIGHT: number = 768;

  private static cached: number = 0;

  /**
   * 取缩放系数。缓存一次即可 —— 窗口尺寸变了（分屏/折叠）应该重建页面。
   * 取不到屏幕信息时退回 0.42（手机横屏常见量级），宁小不大。
   */
  static of(): number {
    if (UiScale.cached > 0) {
      return UiScale.cached;
    }
    let s = 0.42;
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels > 0 ? d.densityPixels : 3;
      const vpHeight = d.height / density;
      if (vpHeight > 0) {
        s = vpHeight / UiScale.DESIGN_HEIGHT;
      }
    } catch (err) {
      s = 0.42;
    }
    // 夹一下：极端密度下别让界面变成蚂蚁或糊满屏
    if (s < 0.25) {
      s = 0.25;
    }
    if (s > 1.6) {
      s = 1.6;
    }
    UiScale.cached = s;
    return s;
  }
}
