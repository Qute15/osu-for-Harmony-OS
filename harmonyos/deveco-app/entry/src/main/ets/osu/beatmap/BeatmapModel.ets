import { ControlPointInfo } from './ControlPoints';

/**
 * 难度插值：把 0..10 的难度值映射到 [min, mid, max] 的线性分段。
 * 这是 osu! 所有 AR/OD/CS/HP 相关数值的来源，必须与上游一致。
 */
export class DifficultyRange {
  min: number;
  mid: number;
  max: number;

  constructor(min: number, mid: number, max: number) {
    this.min = min;
    this.mid = mid;
    this.max = max;
  }

  static range(difficulty: number, min: number, mid: number, max: number): number {
    if (difficulty > 5) {
      return mid + (max - mid) * (difficulty - 5) / 5;
    }
    if (difficulty < 5) {
      return mid - (mid - min) * (5 - difficulty) / 5;
    }
    return mid;
  }

  /** C# (int) 强转：向零截断。 */
  static rangeInt(difficulty: number, min: number, mid: number, max: number): number {
    return Math.trunc(DifficultyRange.range(difficulty, min, mid, max));
  }

  rangeOf(difficulty: number): number {
    return DifficultyRange.range(difficulty, this.min, this.mid, this.max);
  }
}

export class BeatmapDifficulty {
  /** HP */
  drainRate: number = 5;
  circleSize: number = 5;
  overallDifficulty: number = 5;
  approachRate: number = 5;
  sliderMultiplier: number = 1.4;
  sliderTickRate: number = 1;

  clone(): BeatmapDifficulty {
    const d = new BeatmapDifficulty();
    d.drainRate = this.drainRate;
    d.circleSize = this.circleSize;
    d.overallDifficulty = this.overallDifficulty;
    d.approachRate = this.approachRate;
    d.sliderMultiplier = this.sliderMultiplier;
    d.sliderTickRate = this.sliderTickRate;
    return d;
  }
}

export class BeatmapMetadata {
  title: string = '';
  titleUnicode: string = '';
  artist: string = '';
  artistUnicode: string = '';
  creator: string = '';
  version: string = '';
  source: string = '';
  tags: string[] = [];
  beatmapId: number = 0;
  beatmapSetId: number = -1;
  audioFile: string = 'audio.mp3';

  displayTitle(): string {
    return this.titleUnicode.length > 0 ? this.titleUnicode : this.title;
  }

  displayArtist(): string {
    return this.artistUnicode.length > 0 ? this.artistUnicode : this.artist;
  }
}

export class GeneralSettings {
  audioLeadIn: number = 0;
  previewTime: number = -1;
  countdown: number = 0;
  /** 0=osu! 1=taiko 2=catch 3=mania */
  mode: number = 0;
  stackLeniency: number = 0.7;
  letterboxInBreaks: boolean = false;
  widescreenStoryboard: boolean = false;
  epilepsyWarning: boolean = false;
  /** mania 专用 */
  specialStyle: boolean = false;
  /** 采样组：normal/soft/drum */
  sampleSet: string = 'normal';
}

export class BreakPeriod {
  startTime: number;
  endTime: number;

  constructor(startTime: number, endTime: number) {
    this.startTime = startTime;
    this.endTime = endTime;
  }
}

export class StoryboardBackground {
  filename: string = '';
  x: number = 0;
  y: number = 0;
}

export class BeatmapColours {
  comboColours: number[] = [];
  sliderBorder: number = -1;
  sliderTrackOverride: number = -1;
}

/** 采样（hitsound）。bank: 'normal'|'soft'|'drum'，addition 为 whistle/finish/clap 用的组。 */
export class SampleInfo {
  bank: string = 'normal';
  additionBank: string = '';
  index: number = 0;
  volume: number = 0;
  filename: string = '';

  constructor(bank: string = 'normal', additionBank: string = '', index: number = 0,
    volume: number = 0, filename: string = '') {
    this.bank = bank;
    this.additionBank = additionBank;
    this.index = index;
    this.volume = volume;
    this.filename = filename;
  }
}

/** 未应用默认值 / 未做堆叠的原始物件（解码产物）。 */
export class LegacyHitObject {
  x: number = 0;
  y: number = 0;
  time: number = 0;
  typeFlags: number = 0;
  hitSound: number = 0;
  newCombo: boolean = false;
  comboOffset: number = 0;

  // slider
  curveType: string = 'L';
  curvePoints: number[] = [];
  slides: number = 1;
  length: number = 0;
  edgeSounds: number[] = [];
  edgeSets: number[] = [];
  /** 高 BPM 直滑条（.osu 中被省略 length 的旧格式） */
  tickDistanceOverride: number = -1;

  // spinner / hold
  endTime: number = 0;

  sample: SampleInfo = new SampleInfo();

  isCircle(): boolean {
    return (this.typeFlags & 1) > 0;
  }

  isSlider(): boolean {
    return (this.typeFlags & 2) > 0;
  }

  isSpinner(): boolean {
    return (this.typeFlags & 8) > 0;
  }

  isHold(): boolean {
    return (this.typeFlags & 128) > 0;
  }
}

/** 解码后的谱面（对应 osu.Game 的 IBeatmap 的静态部分）。 */
export class DecodedBeatmap {
  formatVersion: number = 14;
  difficulty: BeatmapDifficulty = new BeatmapDifficulty();
  metadata: BeatmapMetadata = new BeatmapMetadata();
  general: GeneralSettings = new GeneralSettings();
  controlPoints: ControlPointInfo = new ControlPointInfo();
  hitObjects: LegacyHitObject[] = [];
  background: StoryboardBackground = new StoryboardBackground();
  breaks: BreakPeriod[] = [];
  colours: BeatmapColours = new BeatmapColours();
  /** [Events] 原始行，交给后续 storyboard 层 */
  eventLines: string[] = [];
}
