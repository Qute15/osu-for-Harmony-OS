import { HitResult } from './HitResult';

/**
 * 计分状态机（combo / 准确率 / 计数）。
 *
 * 说明：combo、各判定计数、准确率是精确值；`score()` 目前是
 * “combo 加权累加”，不等于官方排行榜分数。官方 ScoreV1/V2 需要在
 * 阶段 4 与 lazer 的 ScoreProcessor 逐行对齐后再切换（见 PORT-PLAN）。
 */
export class ScoreProcessor {
  counts: Map<string, number> = new Map<string, number>();
  combo: number = 0;
  maxCombo: number = 0;
  totalJudged: number = 0;
  scoreValue: number = 0;

  applyResult(result: string): void {
    const prev = this.counts.get(result);
    this.counts.set(result, (prev === undefined ? 0 : prev) + 1);

    if (result === HitResult.IGNORE_MISS || result === HitResult.IGNORE_HIT) {
      return;
    }

    // smallBonus / largeBonus 不进 combo
    const isBonus = result === HitResult.SMALL_BONUS || result === HitResult.LARGE_BONUS;

    if (HitResult.breaksCombo(result)) {
      this.combo = 0;
    } else if (HitResult.isHit(result) && !isBonus) {
      this.combo++;
      if (this.combo > this.maxCombo) {
        this.maxCombo = this.combo;
      }
    }

    if (!isBonus) {
      this.totalJudged++;
    }

    // combo 加权（占位，非官方分数）
    const base = HitResult.baseScore(result);
    const comboWeight = 1 + Math.max(0, this.combo - 1) * 0.1;
    this.scoreValue += Math.round(base * comboWeight);
  }

  count(result: string): number {
    const v = this.counts.get(result);
    return v === undefined ? 0 : v;
  }

  /**
   * 主判定数（300 + 100 + 50 + miss），不含滑条 tick。
   * 准确率的分母、HUD 的「已判」都该用这个 —— totalJudged 连 tick 一起数，
   * 一张 192 物件的图会显示成 418，看着像 bug。
   */
  get mainJudged(): number {
    return this.count(HitResult.GREAT) + this.count(HitResult.OK)
      + this.count(HitResult.MEH) + this.count(HitResult.MISS);
  }

  /**
   * 准确率（stable 口径）：(300*300g + 100*100 + 50*50) / (300 * 判定总数)。
   * 滑条 tick 不计入准确率，只计入分数——这与 stable 一致。
   */
  accuracy(): number {
    const great = this.count(HitResult.GREAT);
    const ok = this.count(HitResult.OK);
    const meh = this.count(HitResult.MEH);
    const miss = this.count(HitResult.MISS);
    const total = great + ok + meh + miss;
    if (total === 0) {
      return 1;
    }
    return (300 * great + 100 * ok + 50 * meh) / (300 * total);
  }

  score(): number {
    return this.scoreValue;
  }

  reset(): void {
    this.counts.clear();
    this.combo = 0;
    this.maxCombo = 0;
    this.totalJudged = 0;
    this.scoreValue = 0;
  }
}
