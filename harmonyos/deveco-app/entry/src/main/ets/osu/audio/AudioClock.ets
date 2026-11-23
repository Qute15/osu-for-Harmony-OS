/**
 * 主时钟：音频位置为基准，系统单调时间插值，周期性漂移校正。
 *
 * 为什么不直接用 Date.now() 减起始时间：系统时钟和音频硬件的晶振是两套时钟，
 * 会持续漂移（一首 3 分钟的歌能差几十毫秒），而判定必须对着耳朵听到的东西。
 * 也不用每次读音频位置：AVPlayer 的位置更新是 100ms 级别的，直接当帧时钟会抖。
 *
 * 做法（和 osu!lazer 的 FramedClock + 音频同步思路一致）：
 *   - timeUpdate 到达时锚定 (audioPos, systemNow)
 *   - 两帧之间用系统时间线性插值
 *   - 每次锚定算预测误差：|err| 小就忽略（抖动），中等就按增益修正，大就判定为跳转
 */

/** 小于这个误差当作测量噪声，不动锚点 */
const CORRECT_THRESHOLD_MS = 3;
/** 超过这个误差认为是 seek / 卡顿，直接重锚 */
const SNAP_THRESHOLD_MS = 120;
/** 每次修正吃掉误差的比例：太大画面会跳，太小跟不上 */
const CORRECTION_GAIN = 0.35;

export type TimeSource = () => number;

export class AudioClock {
  private timeSource: TimeSource;
  /** 锚点：音频位置（ms，谱面时间） */
  private anchorAudio: number = 0;
  /** 锚点：系统单调时间（ms） */
  private anchorSystem: number = 0;
  private running: boolean = false;
  private pausedAt: number = 0;
  /** 用户校准偏移（ms）。正值 = 谱面整体提前，用于补偿输出延迟 */
  private userOffset: number = 0;

  private lastError: number = 0;
  private correctionCount: number = 0;
  private snapCount: number = 0;
  private rejectedCount: number = 0;
  /** 待确认的跳转目标 */
  private pendingSnap: number = -1;
  private pendingCount: number = 0;
  /** 诊断：最近一次收到的原始音频位置，以及累计 update 次数 */
  lastAudioMs: number = 0;
  updateCount: number = 0;

  constructor(timeSource: TimeSource) {
    this.timeSource = timeSource;
  }

  get isRunning(): boolean {
    return this.running;
  }

  /** 最近一次校正的误差（ms），正数是音频超前预测 */
  get error(): number {
    return this.lastError;
  }

  get corrections(): number {
    return this.correctionCount;
  }

  get snaps(): number {
    return this.snapCount;
  }

  /** 被丢弃的可疑音频样本数 */
  get rejected(): number {
    return this.rejectedCount;
  }

  get offset(): number {
    return this.userOffset;
  }

  setOffset(ms: number): void {
    this.userOffset = ms;
  }

  /** 从头开始：给定此刻的音频位置 */
  start(audioMs: number): void {
    this.anchorAudio = audioMs;
    this.anchorSystem = this.timeSource();
    this.running = true;
    this.lastError = 0;
    this.correctionCount = 0;
    this.snapCount = 0;
  }

  stop(): void {
    if (this.running) {
      this.pausedAt = this.now();
      this.running = false;
    }
  }

  resume(): void {
    if (!this.running) {
      this.anchorAudio = this.pausedAt;
      this.anchorSystem = this.timeSource();
      this.running = true;
    }
  }

  /** seek / 重新开始：直接重锚，不做平滑 */
  resync(audioMs: number): void {
    this.anchorAudio = audioMs;
    this.anchorSystem = this.timeSource();
    this.running = true;
    this.pendingSnap = -1;
    this.pendingCount = 0;
    this.snapCount++;
  }

  /**
   * 音频位置刷新时调用（AVPlayer 的 timeUpdate）。
   * 内部自己决定是忽略、微调还是重锚。
   */
  /**
   * 音频位置刷新时调用（AVPlayer 的 timeUpdate）。
   * 内部自己决定是忽略、微调还是重锚。
   *
   * 关键防护：AVPlayer 偶尔会吐一个明显错误的样本（0、或跳几百毫秒）。
   * 如果见到大偏差就立刻重锚，时钟会被这个坏样本拽回去，表现就是"谱面卡住倒退"。
   * 所以大偏差必须**连续两次一致**才认，单次一律丢弃。
   */
  update(audioMs: number): void {
    this.lastAudioMs = audioMs;
    this.updateCount++;
    if (!this.running) {
      return;
    }

    const sysNow = this.timeSource();
    const predicted = this.anchorAudio + (sysNow - this.anchorSystem) + this.userOffset;
    const err = audioMs + this.userOffset - predicted;
    this.lastError = err;

    if (Math.abs(err) <= CORRECT_THRESHOLD_MS) {
      this.pendingSnap = -1;
      this.pendingCount = 0;
      return;
    }

    if (Math.abs(err) > SNAP_THRESHOLD_MS) {
      // 播放刚开始时位置可能是 0，这时候不该把时钟拉回 0
      if (audioMs <= 0 && predicted > SNAP_THRESHOLD_MS) {
        this.rejectedCount++;
        return;
      }
      // 连续两次偏差方向一致且幅度接近，才承认是真正的跳转
      const consistent = this.pendingCount > 0 && Math.abs(audioMs - this.pendingSnap) < 80;
      this.pendingSnap = audioMs;
      this.pendingCount = consistent ? this.pendingCount + 1 : 1;
      if (this.pendingCount >= 2) {
        this.pendingSnap = -1;
        this.pendingCount = 0;
        this.resync(audioMs);
      } else {
        this.rejectedCount++;
      }
      return;
    }

    this.pendingSnap = -1;
    this.pendingCount = 0;

    // 按增益把当前时间往实测位置挪一点，剩下的靠后续插值吃掉。
    // 注意必须基于 predicted（含已经走过的系统时间）来改锚点，
    // 直接 anchorAudio += err*gain 会丢掉这一个采样间隔的增量，
    // 表现就是每次校正 now() 都往回跳 ~100ms。
    const corrected = predicted + err * CORRECTION_GAIN;
    this.anchorAudio = corrected - this.userOffset;
    this.anchorSystem = sysNow;
    this.correctionCount++;
  }

  /** 当前 game time（ms）。判定和渲染都只认这个。 */
  now(): number {
    if (!this.running) {
      return this.pausedAt;
    }
    return this.anchorAudio + (this.timeSource() - this.anchorSystem) + this.userOffset;
  }
}

/**
 * 系统单调时间源。
 *
 * 用 STARTUP 类型的 uptime：它不受系统时间同步影响，正是音频对齐需要的。
 * 拿不到就退回 Date.now()——精度差一点，但至少不会崩。
 */
export function createMonotonicSource(uptime: () => number): TimeSource {
  return (): number => {
    const v = uptime();
    return Number.isFinite(v) && v > 0 ? v : Date.now();
  };
}
