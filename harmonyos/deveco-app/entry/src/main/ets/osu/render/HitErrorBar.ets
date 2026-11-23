import { DrawCommandBuffer } from './DrawCommandBuffer';
import { PlayfieldLayout } from './BeatmapRenderer';
import { HitResult } from '../scoring/HitResult';

export class HitErrorEntry {
  offset: number = 0;
  result: string = HitResult.NONE;
  time: number = 0;
}

const MAX_ENTRIES = 24;
/** 直方图最多攒多少样本（够画分布就行，不占内存） */
const MAX_SAMPLES = 4000;

/**
 * 判定偏差条（osu! 的 hit error meter）。
 *
 * 屏幕上一条横条，中间是 0，每个 tick 表示一次命中的时间偏差。
 * 这是"手感校准"唯一的可视依据：如果所有 tick 都系统性地偏左/偏右，
 * 就说明音频偏移需要校，而不是玩家手抖。
 */
export class HitErrorBar {
  private entries: HitErrorEntry[] = [];
  /** 显示范围的半宽（ms），一般取 50 判定窗口 */
  private window: number = 200;

  /** 累计统计 */
  sum: number = 0;
  count: number = 0;
  absSum: number = 0;
  /** 偏差平方和：算标准差（不稳定率）用 */
  sqSum: number = 0;

  /** 全部偏移样本，结算页的 Timing Distribution 直方图要用 */
  private samples: number[] = [];

  setWindow(ms: number): void {
    this.window = Math.max(10, ms);
  }

  reset(): void {
    this.entries = [];
    this.samples = [];
    this.sum = 0;
    this.count = 0;
    this.absSum = 0;
    this.sqSum = 0;
  }

  add(offset: number, result: string, time: number): void {
    if (!Number.isFinite(offset)) {
      return;
    }
    const e = new HitErrorEntry();
    e.offset = offset;
    e.result = result;
    e.time = time;
    this.entries.push(e);
    if (this.entries.length > MAX_ENTRIES) {
      this.entries.splice(0, this.entries.length - MAX_ENTRIES);
    }
    // 样本只用来画直方图，攒太多没意义；超了从头丢
    this.samples.push(offset);
    if (this.samples.length > MAX_SAMPLES) {
      this.samples.splice(0, this.samples.length - MAX_SAMPLES);
    }
    this.sum += offset;
    this.absSum += Math.abs(offset);
    this.sqSum += offset * offset;
    this.count++;
  }

  /** 取历史样本（0 = 最旧）。结算页散布图用 */
  sampleAt(index: number): number {
    if (index < 0 || index >= this.samples.length) {
      return 0;
    }
    return this.samples[index];
  }

  /**
   * 不稳定率（UR）= 偏差标准差 × 10，osu! 的定义。
   * 用平方和算，避免为了求方差再遍历一遍。
   */
  unstableRate(): number {    if (this.count < 2) {
      return 0;
    }
    const mean = this.sum / this.count;
    const variance = Math.max(0, this.sqSum / this.count - mean * mean);
    return Math.sqrt(variance) * 10;
  }

  /**
   * 把样本按 [-span, span] 分 bins 段计数。
   * 结算页的 Timing Distribution 就是这样画的（中间密、两边稀）。
   */
  histogram(bins: number, span: number): number[] {
    const out: number[] = [];
    for (let i = 0; i < bins; i++) {
      out.push(0);
    }
    const width = (span * 2) / bins;
    for (let i = 0; i < this.samples.length; i++) {
      const v = this.samples[i];
      let idx = Math.floor((v + span) / width);
      if (idx < 0) {
        idx = 0;
      }
      if (idx >= bins) {
        idx = bins - 1;
      }
      out[idx]++;
    }
    return out;
  }

  /** 平均偏差：正值表示整体偏晚（需要把 offset 往大调） */
  mean(): number {
    return this.count > 0 ? this.sum / this.count : 0;
  }

  /** 平均绝对偏差，衡量稳定性 */
  meanAbs(): number {
    return this.count > 0 ? this.absSum / this.count : 0;
  }

  draw(cmds: DrawCommandBuffer, layout: PlayfieldLayout, time: number): void {
    if (layout.surfaceWidth <= 0) {
      return;
    }

    const barW = Math.min(layout.surfaceWidth * 0.42, 520);
    const barH = 8;
    const cx = layout.surfaceWidth * 0.5;
    const cy = layout.surfaceHeight - 46;

    const halfW = barW * 0.5;
    const colorFor = (result: string): number => {
      if (result === HitResult.GREAT) {
        return 0x66E0A0;
      }
      if (result === HitResult.OK) {
        return 0x7FD4FF;
      }
      if (result === HitResult.MEH) {
        return 0xFFD45E;
      }
      return 0xFF5566;
    };

    // 底条 + 中间刻度
    cmds.rect(cx, cy, barW, barH, 0x000000, 0.45);
    cmds.rect(cx, cy, barW, 1, 0x8A8A98, 0.5);
    cmds.rect(cx, cy, 2, barH * 2.6, 0xFFFFFF, 0.55);

    for (let i = 0; i < this.entries.length; i++) {
      const e = this.entries[i];
      const age = time - e.time;
      if (age > 4000) {
        continue;
      }
      // 最近 4 秒内淡出，避免旧 tick 一直糊着
      const fade = age < 3000 ? 1 : Math.max(0, 1 - (age - 3000) / 1000);
      let ratio = e.offset / this.window;
      if (ratio > 1) {
        ratio = 1;
      }
      if (ratio < -1) {
        ratio = -1;
      }
      const x = cx + ratio * halfW;
      cmds.rect(x, cy, 3, barH * 3.2, colorFor(e.result), 0.85 * fade);
    }
  }
}
