import { Vec2 } from '../core/Vec2';
import { SliderPath } from '../beatmap/SliderPath';
import { SampleInfo } from '../beatmap/BeatmapModel';
import { DifficultyRange } from '../beatmap/BeatmapModel';

/** 物件类型。 */
export class ObjectKind {
  static readonly CIRCLE: string = 'circle';
  static readonly SLIDER: string = 'slider';
  static readonly SPINNER: string = 'spinner';
}

/**
 * osu! 规则集物件的公共部分（osu.Game.Rulesets.Osu/Objects/OsuHitObject.cs）。
 *
 * 坐标系为谱面的 512x384 虚拟场，渲染层再缩放到屏幕。
 */
export class OsuHitObject {
  kind: string = '';
  startTime: number = 0;
  position: Vec2 = Vec2.ZERO;

  /** 堆叠高度（>0 向上偏移，<0 向下偏移）。 */
  stackHeight: number = 0;
  /** 堆叠后的实际渲染偏移量，由 scale 决定。 */
  stackOffset: Vec2 = Vec2.ZERO;

  newCombo: boolean = false;
  comboOffset: number = 0;
  comboIndex: number = 0;
  indexInCurrentCombo: number = 0;
  comboColourIndex: number = 0;

  samples: SampleInfo[] = [];

  /**
   * 命中音位掩码：1=normal 2=whistle 4=finish 8=clap。
   * 0 表示"没指定"，按 osu! 的规则回退成 normal。
   */
  hitSound: number = 0;
  /** 该物件所在 sample 控制点的音量（0~100） */
  sampleVolume: number = 100;

  /** AR 决定的预判时间（ms）。 */
  timePreempt: number = 600;
  timeFadeIn: number = 400;
  /** 物件缩放（半径 = 64 * scale，即 CS5 → 32px 半径）。 */
  scale: number = 0.5;

  endTime(): number {
    return this.startTime;
  }

  /** 滑条终点 / 圆圈自身位置 */
  endPosition(): Vec2 {
    return this.position;
  }

  radius(): number {
    return 64 * this.scale;
  }
}

export class HitCircle extends OsuHitObject {
  constructor() {
    super();
    this.kind = ObjectKind.CIRCLE;
  }
}

/** 滑条内部生成的判定点类型。 */
export class SliderNestedKind {
  static readonly TICK: string = 'tick';
  static readonly REPEAT: string = 'repeat';
  static readonly TAIL: string = 'tail';
  static readonly LEGACY_LAST_TICK: string = 'legacyLastTick';
}

export class SliderNested {
  kind: string;
  spanIndex: number = 0;
  spanStartTime: number = 0;
  time: number = 0;
  /** 0..1 的路径进度 */
  pathProgress: number = 0;

  constructor(kind: string) {
    this.kind = kind;
  }
}

export class Slider extends OsuHitObject {
  path: SliderPath = new SliderPath();
  /** 折返次数，总段数 = spanCount */
  spanCount: number = 1;
  /** px/ms */
  velocity: number = 0;
  tickDistance: number = 0;
  generateTicks: boolean = true;
  /** SV 倍率（供编辑/显示） */
  sliderVelocityMultiplier: number = 1;

  nested: SliderNested[] = [];
  /**
   * 单段时长（game time）。由规则集在应用默认值/BPM mod 后写入；
   * < 0 表示未计算，回退到 path.distance() / velocity。
   */
  spanDurationOverride: number = -1;

  constructor() {
    super();
    this.kind = ObjectKind.SLIDER;
  }

  duration(): number {
    const span = this.spanDuration();
    return this.spanCount * span;
  }

  spanDuration(): number {
    if (this.spanDurationOverride > 0) {
      return this.spanDurationOverride;
    }
    return this.path.distance() / this.velocity;
  }

  endTime(): number {
    return this.startTime + this.duration();
  }

  /**
   * 尾点位置。
   *
   * 坐标系约定：SliderPath 的控制点存的是**绝对场坐标**（首点就是滑条头），
   * 所以任何取路径点的地方都不能再加一次 position，
   * 否则整条路径会平移一个头坐标（表现为滑条整体错位、球飞出轨道）。
   */
  endPosition(): Vec2 {
    return this.path.positionAt(this.spanCount % 2);
  }

  /** t ∈ [0,1] 的路径位置（不含折返） */
  curvePositionAt(progress: number): Vec2 {
    return this.path.positionAt(progress);
  }

  /** 第 span 段第 progress 处的场坐标（含折返，不含堆叠偏移） */
  positionAtSpan(span: number, progress: number): Vec2 {
    const p = span % 2 === 0 ? progress : 1 - progress;
    return this.path.positionAt(p);
  }
}

export class Spinner extends OsuHitObject {
  /** 结束时间（绝对 ms） */
  spinnerEndTime: number = 0;

  constructor() {
    super();
    this.kind = ObjectKind.SPINNER;
  }

  duration(): number {
    return this.spinnerEndTime - this.startTime;
  }

  endTime(): number {
    return this.spinnerEndTime;
  }
}

/**
 * osu! 规则集的默认值应用（OsuHitObject.ApplyDefaultsToSelf）。
 *
 * 注意 CS 缩放公式：lazer 用 (1 - 0.7 * (CS-5)/5) / 2，CS5 → 0.5（半径 32px）。
 */
export class OsuDefaults {
  static readonly PREEMPT_MAX: number = 1800;
  static readonly PREEMPT_MID: number = 1200;
  static readonly PREEMPT_MIN: number = 450;
  static readonly BASE_SCORING_DISTANCE: number = 100;

  static timePreempt(approachRate: number): number {
    return DifficultyRange.rangeInt(approachRate, OsuDefaults.PREEMPT_MAX, OsuDefaults.PREEMPT_MID, OsuDefaults.PREEMPT_MIN);
  }

  static timeFadeIn(timePreempt: number): number {
    return 400 * Math.min(1, timePreempt / OsuDefaults.PREEMPT_MIN);
  }

  static scaleFromCircleSize(circleSize: number): number {
    const cs = Math.min(10, Math.max(0, circleSize));
    const norm = (cs - 5) / 5;
    return (1 - 0.7 * norm) / 2;
  }

  /**
   * SV 精度修正：stable 用 float 做 100/SV 的除法，再夹到 [0.1, 10]。
   * 这个乘子直接进 slider 的速度公式，不能省。
   */
  static precisionAdjustedBeatLength(beatLength: number, svMultiplier: number): number {
    const svAsBeatLength = -100 / svMultiplier;
    let bpmMultiplier = 1;
    if (svAsBeatLength < 0) {
      bpmMultiplier = Math.min(1000, Math.max(10, -svAsBeatLength)) / 100;
    }
    return beatLength * bpmMultiplier;
  }

  /** px/ms */
  static sliderVelocity(sliderMultiplier: number, beatLength: number, svMultiplier: number): number {
    const adjusted = OsuDefaults.precisionAdjustedBeatLength(beatLength, svMultiplier);
    return OsuDefaults.BASE_SCORING_DISTANCE * sliderMultiplier / adjusted;
  }
}
