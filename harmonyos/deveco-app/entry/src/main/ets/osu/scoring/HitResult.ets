/**
 * 判定结果（osu.Game/Scoring/HitResult.cs 的子集）。
 * 用字符串常量而非 enum，是为了同时满足 ArkTS 与 TS 类型裁剪。
 */
export class HitResult {
  static readonly NONE: string = 'none';
  static readonly MISS: string = 'miss';
  static readonly MEH: string = 'meh';
  static readonly OK: string = 'ok';
  static readonly GREAT: string = 'great';
  static readonly PERFECT: string = 'perfect';
  static readonly SMALL_TICK_MISS: string = 'smallTickMiss';
  static readonly SMALL_TICK_HIT: string = 'smallTickHit';
  static readonly LARGE_TICK_MISS: string = 'largeTickMiss';
  static readonly LARGE_TICK_HIT: string = 'largeTickHit';
  static readonly SMALL_BONUS: string = 'smallBonus';
  static readonly LARGE_BONUS: string = 'largeBonus';
  static readonly IGNORE_MISS: string = 'ignoreMiss';
  static readonly IGNORE_HIT: string = 'ignoreHit';

  /** 判定优劣序（越小越好判定）。 */
  static ordinal(r: string): number {
    switch (r) {
      case HitResult.MISS:
        return 1;
      case HitResult.MEH:
        return 2;
      case HitResult.OK:
        return 3;
      case HitResult.GREAT:
        return 4;
      case HitResult.PERFECT:
        return 5;
      case HitResult.SMALL_TICK_MISS:
        return 6;
      case HitResult.SMALL_TICK_HIT:
        return 7;
      case HitResult.LARGE_TICK_MISS:
        return 8;
      case HitResult.LARGE_TICK_HIT:
        return 9;
      case HitResult.SMALL_BONUS:
        return 10;
      case HitResult.LARGE_BONUS:
        return 11;
      default:
        return 0;
    }
  }

  /** 是否算作“命中”（影响 combo）。 */
  static isHit(r: string): boolean {
    switch (r) {
      case HitResult.MEH:
      case HitResult.OK:
      case HitResult.GREAT:
      case HitResult.PERFECT:
      case HitResult.SMALL_TICK_HIT:
      case HitResult.LARGE_TICK_HIT:
      case HitResult.SMALL_BONUS:
      case HitResult.LARGE_BONUS:
      case HitResult.IGNORE_HIT:
        return true;
      default:
        return false;
    }
  }

  /** 是否打断 combo。 */
  static breaksCombo(r: string): boolean {
    return r === HitResult.MISS || r === HitResult.SMALL_TICK_MISS || r === HitResult.LARGE_TICK_MISS;
  }

  /**
   * 基础分。第一版沿用 stable 的公开数值；lazer 的 ScoreProcessor 表在
   * 后续阶段接入排行榜时再逐项校准（见 PORT-PLAN 阶段 4）。
   */
  static baseScore(r: string): number {
    switch (r) {
      case HitResult.GREAT:
        return 300;
      case HitResult.OK:
        return 100;
      case HitResult.MEH:
        return 50;
      case HitResult.SMALL_TICK_HIT:
        return 10;
      case HitResult.LARGE_TICK_HIT:
        return 30;
      case HitResult.SMALL_BONUS:
        return 1000;
      default:
        return 0;
    }
  }
}
