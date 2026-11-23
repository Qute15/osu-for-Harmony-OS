import { BeatmapDifficulty } from '../beatmap/BeatmapModel';

/**
 * Mod 定义（osu.Game/Rulesets/Mods 的子集）。
 *
 * 只实现“改变速度 / 改变难度”这一类可量化 mod；FL/HD 等纯视觉 mod
 * 在阶段 3（渲染）里接入。
 */
export class ModId {
  static readonly NO_FAIL: string = 'NF';
  static readonly EASY: string = 'EZ';
  static readonly HALF_TIME: string = 'HT';
  static readonly DAYCORE: string = 'DC';
  static readonly HARD_ROCK: string = 'HR';
  static readonly DOUBLE_TIME: string = 'DT';
  static readonly NIGHTCORE: string = 'NC';
  static readonly HIDDEN: string = 'HD';
  static readonly FLASHLIGHT: string = 'FL';
  static readonly SUDDEN_DEATH: string = 'SD';
  static readonly PERFECT: string = 'PF';
  static readonly NO_MOD: string = 'NM';
  static readonly CLASSIC: string = 'CL';
  static readonly MIRROR: string = 'MR';
  static readonly DIFFICULTY_ADJUST: string = 'DA';
  static readonly CINEMA: string = 'CN';
}

export class OsuMod {
  id: string = ModId.NO_MOD;
  acronym(): string {
    return this.id;
  }
}

export class ModSet {
  mods: string[] = [];

  constructor(ids: string[] = []) {
    this.mods = ids;
  }

  has(id: string): boolean {
    return this.mods.indexOf(id) >= 0;
  }

  /** 时间轴速度倍率（DT/NC 1.5，HT/DC 0.75）。 */
  speedMultiplier(): number {
    if (this.has(ModId.DOUBLE_TIME) || this.has(ModId.NIGHTCORE)) {
      return 1.5;
    }
    if (this.has(ModId.HALF_TIME) || this.has(ModId.DAYCORE)) {
      return 0.75;
    }
    return 1;
  }

  /**
   * 应用难度改动。HR 乘 1.4 后夹到 [0,10]；EZ 乘 0.5。
   * AR/OD 的 mod 后夹取语义与 stable 一致（HR：min(AR*1.4, 10)）。
   */
  applyDifficulty(base: BeatmapDifficulty): BeatmapDifficulty {
    const d = base.clone();

    if (this.has(ModId.HARD_ROCK)) {
      d.circleSize = Math.min(10, d.circleSize * 1.4);
      d.approachRate = Math.min(10, d.approachRate * 1.4);
      d.overallDifficulty = Math.min(10, d.overallDifficulty * 1.4);
      d.drainRate = Math.min(10, d.drainRate * 1.4);
    }

    if (this.has(ModId.EASY)) {
      d.circleSize = d.circleSize * 0.5;
      d.approachRate = d.approachRate * 0.5;
      d.overallDifficulty = d.overallDifficulty * 0.5;
      d.drainRate = d.drainRate * 0.5;
    }

    return d;
  }

  /** 谱面时间 → 游玩时间 */
  mapTimeToGameTime(mapTime: number): number {
    return mapTime / this.speedMultiplier();
  }

  gameTimeToMapTime(gameTime: number): number {
    return gameTime * this.speedMultiplier();
  }

  toString(): string {
    return this.mods.length === 0 ? 'NM' : this.mods.join('');
  }
}
