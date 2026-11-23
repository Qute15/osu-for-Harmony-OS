/**
 * 时间轴控制点。
 *
 * osu! 的谱面时间轴由 4 条平行轨道组成：BPM（uninherited）、SV/刻度（inherited）、
 * 采样组、Kiai/Barline。这里逐类复刻 osu.Game/Beatmaps/ControlPoints。
 */

/** 非继承（BPM）控制点。 */
export class TimingControlPoint {
  time: number = 0;
  beatLength: number = 0;
  meter: number = 4;

  /** 60000 / beatLength。 */
  bpm(): number {
    return this.beatLength > 0 ? 60000 / this.beatLength : 0;
  }
}

/** 继承控制点：SV 倍率 + 是否生成滑条刻度。 */
export class DifficultyControlPoint {
  time: number = 0;
  sliderVelocityMultiplier: number = 1;
  generateTicks: boolean = true;
  /** taiko/mania 的滚动速度（osu! 模式忽略）。 */
  scrollSpeed: number = 1;
}

/** 采样组控制点。 */
export class SampleControlPoint {
  time: number = 0;
  /** 'normal' | 'soft' | 'drum' */
  sampleBank: string = 'normal';
  /** 'normal' | 'soft' | 'drum' | '' （继承） */
  additionBank: string = '';
  volume: number = 100;
  index: number = 0;
}

/** 效果控制点。 */
export class EffectControlPoint {
  time: number = 0;
  kiai: boolean = false;
  omitFirstBarline: boolean = false;
}

/**
 * 控制点集合 + 时间查询。
 * 查询语义与上游一致：取 time <= t 的最后一个点；若没有则取第一个点。
 */
export class ControlPointInfo {
  timingPoints: TimingControlPoint[] = [];
  difficultyPoints: DifficultyControlPoint[] = [];
  samplePoints: SampleControlPoint[] = [];
  effectPoints: EffectControlPoint[] = [];

  timingPointAt(time: number): TimingControlPoint {
    if (this.timingPoints.length === 0) {
      const fallback = new TimingControlPoint();
      fallback.time = 0;
      fallback.beatLength = 500;
      return fallback;
    }
    let result = this.timingPoints[0];
    for (let i = 0; i < this.timingPoints.length; i++) {
      if (this.timingPoints[i].time <= time) {
        result = this.timingPoints[i];
      } else {
        break;
      }
    }
    return result;
  }

  difficultyPointAt(time: number): DifficultyControlPoint {
    if (this.difficultyPoints.length === 0) {
      return new DifficultyControlPoint();
    }
    let result = this.difficultyPoints[0];
    for (let i = 0; i < this.difficultyPoints.length; i++) {
      if (this.difficultyPoints[i].time <= time) {
        result = this.difficultyPoints[i];
      } else {
        break;
      }
    }
    return result;
  }

  samplePointAt(time: number): SampleControlPoint {
    if (this.samplePoints.length === 0) {
      return new SampleControlPoint();
    }
    let result = this.samplePoints[0];
    for (let i = 0; i < this.samplePoints.length; i++) {
      if (this.samplePoints[i].time <= time) {
        result = this.samplePoints[i];
      } else {
        break;
      }
    }
    return result;
  }

  effectPointAt(time: number): EffectControlPoint {
    if (this.effectPoints.length === 0) {
      return new EffectControlPoint();
    }
    let result = this.effectPoints[0];
    for (let i = 0; i < this.effectPoints.length; i++) {
      if (this.effectPoints[i].time <= time) {
        result = this.effectPoints[i];
      } else {
        break;
      }
    }
    return result;
  }

  /** 谱面最后一个控制点时间，用于估算长度。 */
  lastTime(): number {
    let last = 0;
    if (this.timingPoints.length > 0) {
      last = Math.max(last, this.timingPoints[this.timingPoints.length - 1].time);
    }
    if (this.difficultyPoints.length > 0) {
      last = Math.max(last, this.difficultyPoints[this.difficultyPoints.length - 1].time);
    }
    return last;
  }
}
