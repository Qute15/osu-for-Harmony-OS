import { HitResult } from './HitResult';
import { DifficultyRange } from '../beatmap/BeatmapModel';

/**
 * osu.Game.Rulesets.Osu/Scoring/OsuHitWindows.cs 的移植。
 *
 * OD → 判定窗口：
 *   300g: OD0=80ms, OD5=50ms, OD10=20ms
 *   100 : OD0=140ms, OD5=100ms, OD10=60ms
 *   50  : OD0=200ms, OD5=150ms, OD10=100ms
 * miss 固定 400ms（与难度无关）
 * 每档都 Math.Floor(x) - 0.5，这是 stable 的整数化行为，直接决定边界手感。
 */
export class OsuHitWindows {
  static readonly GREAT_MIN: number = 80;
  static readonly GREAT_MID: number = 50;
  static readonly GREAT_MAX: number = 20;

  static readonly OK_MIN: number = 140;
  static readonly OK_MID: number = 100;
  static readonly OK_MAX: number = 60;

  static readonly MEH_MIN: number = 200;
  static readonly MEH_MID: number = 150;
  static readonly MEH_MAX: number = 100;

  static readonly MISS_WINDOW: number = 400;

  great: number = 0;
  ok: number = 0;
  meh: number = 0;

  constructor(difficulty: number = 5) {
    this.setDifficulty(difficulty);
  }

  setDifficulty(overallDifficulty: number): void {
    this.great = Math.floor(DifficultyRange.range(overallDifficulty, OsuHitWindows.GREAT_MIN,
      OsuHitWindows.GREAT_MID, OsuHitWindows.GREAT_MAX)) - 0.5;
    this.ok = Math.floor(DifficultyRange.range(overallDifficulty, OsuHitWindows.OK_MIN,
      OsuHitWindows.OK_MID, OsuHitWindows.OK_MAX)) - 0.5;
    this.meh = Math.floor(DifficultyRange.range(overallDifficulty, OsuHitWindows.MEH_MIN,
      OsuHitWindows.MEH_MID, OsuHitWindows.MEH_MAX)) - 0.5;
  }

  windowFor(result: string): number {
    switch (result) {
      case HitResult.GREAT:
        return this.great;
      case HitResult.OK:
        return this.ok;
      case HitResult.MEH:
        return this.meh;
      case HitResult.MISS:
        return OsuHitWindows.MISS_WINDOW;
      default:
        return 0;
    }
  }

  /** 命中偏差（ms，正负均可）→ 判定。超出 miss 窗口返回 NONE。 */
  resultFor(timeOffset: number): string {
    const abs = Math.abs(timeOffset);
    if (abs <= this.great) {
      return HitResult.GREAT;
    }
    if (abs <= this.ok) {
      return HitResult.OK;
    }
    if (abs <= this.meh) {
      return HitResult.MEH;
    }
    if (abs <= OsuHitWindows.MISS_WINDOW) {
      return HitResult.MISS;
    }
    return HitResult.NONE;
  }

  /** 该偏差是否还能在未来命中（用于鼠标未点击时的提前 miss 判定）。 */
  canBeHit(timeOffset: number): boolean {
    return timeOffset <= this.meh;
  }
}
