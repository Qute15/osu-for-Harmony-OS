import { Vec2 } from '../core/Vec2';
import { DecodedBeatmap, LegacyHitObject, BeatmapDifficulty } from '../beatmap/BeatmapModel';
import { SliderPath, PathControlPoint } from '../beatmap/SliderPath';
import { LegacyOsuDecoder } from '../beatmap/LegacyOsuDecoder';
import { ModSet } from '../mods/Mods';
import {
  HitCircle,
  OsuDefaults,
  OsuHitObject,
  Slider,
  SliderNested,
  SliderNestedKind,
  Spinner,
  ObjectKind
} from './OsuObjects';

/**
 * 可游玩谱面：解码 → 应用默认值 → combo 分组 → 堆叠 → 生成滑条内部判定点。
 *
 * 对应 osu.Game 的 LegacyBeatmapDecoder + OsuBeatmapConverter + OsuBeatmapProcessor
 * 三段流程。任何渲染层只吃这个对象，保证玩法数值只有一处来源。
 */
export class OsuPlayableBeatmap {
  decoded: DecodedBeatmap;
  difficulty: BeatmapDifficulty;
  mods: ModSet;
  hitObjects: OsuHitObject[] = [];
  /** 最大 combo（head + tick + repeat + tail 全算） */
  maxCombo: number = 0;

  constructor(decoded: DecodedBeatmap, mods: ModSet) {
    this.decoded = decoded;
    this.mods = mods;
    this.difficulty = mods.applyDifficulty(decoded.difficulty);
    this.build();
  }

  static fromOsuText(text: string, mods: ModSet = new ModSet()): OsuPlayableBeatmap {
    return new OsuPlayableBeatmap(LegacyOsuDecoder.decode(text), mods);
  }

  // ------------------------------------------------------------------ 构建

  private build(): void {
    const dx = this.decoded;
    const modSpeed = this.mods.speedMultiplier();

    for (let i = 0; i < dx.hitObjects.length; i++) {
      const legacy = dx.hitObjects[i];
      const obj = this.createObject(legacy, modSpeed);
      if (obj !== null) {
        // 打击音信息只在这里塞一次：渲染/判定都不关心，只有音频层用。
        obj.hitSound = legacy.hitSound;
        obj.sampleVolume = this.decoded.controlPoints.samplePointAt(legacy.time).volume;
        this.hitObjects.push(obj);
      }
    }

    this.hitObjects.sort((a: OsuHitObject, b: OsuHitObject) => a.startTime - b.startTime);

    this.applyDefaults();
    this.applyComboInfo();
    this.applyStacking();
    this.computeMaxCombo();
  }

  private createObject(legacy: LegacyHitObject, modSpeed: number): OsuHitObject | null {
    const preempt = OsuDefaults.timePreempt(this.difficulty.approachRate);
    const scale = OsuDefaults.scaleFromCircleSize(this.difficulty.circleSize);

    if (legacy.isCircle()) {
      const circle = new HitCircle();
      circle.position = new Vec2(legacy.x, legacy.y);
      // DT/HT 会整体缩放时间轴；谱面时间统一走 game time
      circle.startTime = legacy.time / modSpeed;
      circle.timePreempt = preempt;
      circle.timeFadeIn = OsuDefaults.timeFadeIn(preempt);
      circle.scale = scale;
      return circle;
    }

    if (legacy.isSlider()) {
      const slider = new Slider();
      slider.position = new Vec2(legacy.x, legacy.y);
      slider.startTime = legacy.time / modSpeed;
      slider.timePreempt = preempt;
      slider.timeFadeIn = OsuDefaults.timeFadeIn(preempt);
      slider.scale = scale;
      slider.newCombo = legacy.newCombo;
      slider.comboOffset = legacy.comboOffset;

      // 控制点：首点带曲线类型，其余继承
      const cps: PathControlPoint[] = [new PathControlPoint(new Vec2(legacy.x, legacy.y), legacy.curveType)];
      for (let p = 0; p + 1 < legacy.curvePoints.length; p += 2) {
        cps.push(new PathControlPoint(new Vec2(legacy.curvePoints[p], legacy.curvePoints[p + 1]), ''));
      }

      const expected = legacy.length > 0 ? legacy.length : -1;
      slider.path = new SliderPath(cps, expected, true);

      const timing = this.decoded.controlPoints.timingPointAt(legacy.time);
      const diffPoint = this.decoded.controlPoints.difficultyPointAt(legacy.time);

      slider.sliderVelocityMultiplier = diffPoint.sliderVelocityMultiplier;
      slider.velocity = OsuDefaults.sliderVelocity(this.difficulty.sliderMultiplier,
        timing.beatLength, diffPoint.sliderVelocityMultiplier);

      const scoringDistance = slider.velocity * timing.beatLength;
      slider.generateTicks = diffPoint.generateTicks;
      slider.tickDistance = diffPoint.generateTicks
        ? scoringDistance / Math.max(0.001, this.difficulty.sliderTickRate)
        : Number.POSITIVE_INFINITY;

      slider.spanCount = Math.max(1, Math.round(legacy.slides));

      // 时间轴按 mod 速度缩放：先算谱面时长再除速度
      const mapSpanDuration = slider.path.distance() / slider.velocity;
      const speedFactor = 1 / modSpeed;
      slider.spanDurationOverride = mapSpanDuration * speedFactor;
      this.generateNested(slider, slider.startTime, slider.spanDurationOverride, slider.velocity * modSpeed);

      return slider;
    }

    if (legacy.isSpinner()) {
      const spinner = new Spinner();
      spinner.position = new Vec2(256, 192);
      spinner.startTime = legacy.time / modSpeed;
      spinner.spinnerEndTime = legacy.endTime / modSpeed;
      spinner.timePreempt = preempt;
      spinner.timeFadeIn = OsuDefaults.timeFadeIn(preempt);
      spinner.scale = scale;
      return spinner;
    }

    // mania 的 hold note：osu! 标准模式里不参与
    return null;
  }

  /**
   * SliderEventGenerator.Generate 的移植：
   * 每个 span 生成 tick，span 之间生成 repeat，最后补 LegacyLastTick 与 Tail。
   */
  private generateNested(slider: Slider, startTime: number, spanDuration: number, velocity: number): void {
    const maxLength = 100000;
    const length = Math.min(maxLength, slider.path.distance());
    const tickDistance = Math.min(Math.max(slider.tickDistance, 0), length);
    const minDistanceFromEnd = velocity * 10;

    const head = new SliderNested('head');
    head.spanIndex = 0;
    head.spanStartTime = startTime;
    head.time = startTime;
    head.pathProgress = 0;
    slider.nested.push(head);

    for (let span = 0; span < slider.spanCount; span++) {
      const spanStartTime = startTime + span * spanDuration;
      const reversed = span % 2 === 1;

      if (tickDistance > 0 && Number.isFinite(tickDistance)) {
        const ticks: SliderNested[] = [];
        let d = tickDistance;
        let guard = 0;
        while (d <= length && guard < 10000) {
          guard++;
          if (d >= length - minDistanceFromEnd) {
            break;
          }
          const pathProgress = d / length;
          const timeProgress = reversed ? 1 - pathProgress : pathProgress;
          const tick = new SliderNested(SliderNestedKind.TICK);
          tick.spanIndex = span;
          tick.spanStartTime = spanStartTime;
          tick.time = spanStartTime + timeProgress * spanDuration;
          tick.pathProgress = pathProgress;
          ticks.push(tick);
          d += tickDistance;
          if (tickDistance <= 0) {
            break;
          }
        }

        if (reversed) {
          ticks.reverse();
        }
        for (let i = 0; i < ticks.length; i++) {
          slider.nested.push(ticks[i]);
        }
      }

      if (span < slider.spanCount - 1) {
        const repeat = new SliderNested(SliderNestedKind.REPEAT);
        repeat.spanIndex = span;
        repeat.spanStartTime = spanStartTime;
        repeat.time = spanStartTime + spanDuration;
        repeat.pathProgress = (span + 1) % 2;
        slider.nested.push(repeat);
      }
    }

    const totalDuration = slider.spanCount * spanDuration;
    const finalSpanIndex = slider.spanCount - 1;
    const finalSpanStartTime = startTime + finalSpanIndex * spanDuration;

    // stable 的 -36ms 尾判宽容
    const legacyLastTickTime = Math.max(startTime + totalDuration / 2,
      (finalSpanStartTime + spanDuration) - 36);
    let legacyLastTickProgress = (legacyLastTickTime - finalSpanStartTime) / spanDuration;
    if (slider.spanCount % 2 === 0) {
      legacyLastTickProgress = 1 - legacyLastTickProgress;
    }
    const legacy = new SliderNested(SliderNestedKind.LEGACY_LAST_TICK);
    legacy.spanIndex = finalSpanIndex;
    legacy.spanStartTime = finalSpanStartTime;
    legacy.time = legacyLastTickTime;
    legacy.pathProgress = legacyLastTickProgress;
    slider.nested.push(legacy);

    const tail = new SliderNested(SliderNestedKind.TAIL);
    tail.spanIndex = finalSpanIndex;
    tail.spanStartTime = finalSpanStartTime;
    tail.time = startTime + totalDuration;
    tail.pathProgress = slider.spanCount % 2;
    slider.nested.push(tail);
  }

  private applyDefaults(): void {
    const preempt = OsuDefaults.timePreempt(this.difficulty.approachRate);
    const fadeIn = OsuDefaults.timeFadeIn(preempt);
    const scale = OsuDefaults.scaleFromCircleSize(this.difficulty.circleSize);

    for (let i = 0; i < this.hitObjects.length; i++) {
      const o = this.hitObjects[i];
      o.timePreempt = preempt;
      o.timeFadeIn = fadeIn;
      o.scale = scale;
    }
  }

  /**
   * combo 分组：每个 newCombo 物件开始新一组，comboOffset 跳过颜色，
   * 保证颜色循环与 stable 一致。同时保证 spinner 之后一定开新组。
   */
  private applyComboInfo(): void {
    let comboIndex = 0;
    let indexInCombo = 0;
    let colourIndex = 0;
    let lastWasSpinner = true;

    for (let i = 0; i < this.hitObjects.length; i++) {
      const o = this.hitObjects[i];
      const startsNewCombo = o.newCombo || lastWasSpinner || i === 0;

      if (startsNewCombo) {
        comboIndex++;
        indexInCombo = 0;
        colourIndex += 1 + o.comboOffset;
      }

      o.comboIndex = comboIndex;
      o.indexInCurrentCombo = indexInCombo;
      o.comboColourIndex = colourIndex;
      indexInCombo++;

      lastWasSpinner = o.kind === ObjectKind.SPINNER;
    }
  }

  // ---------------------------------------------------------------- 堆叠

  /**
   * OsuBeatmapProcessor.ApplyStacking 的移植。
   * 这是“同位置物件向左上偏移 6.4px * scale”的那套算法，缺了它谱面看起来是糊的。
   */
  private applyStacking(): void {
    const objs = this.hitObjects;
    for (let i = 0; i < objs.length; i++) {
      objs[i].stackHeight = 0;
    }
    if (objs.length === 0) {
      return;
    }

    if (this.decoded.formatVersion >= 6) {
      this.applyStackingNew(objs, 0, objs.length - 1);
    } else {
      this.applyStackingOld(objs);
    }

    for (let i = 0; i < objs.length; i++) {
      const o = objs[i];
      const offset = o.stackHeight * o.scale * -6.4;
      o.stackOffset = new Vec2(offset, offset);
    }
  }

  private stackThreshold(obj: OsuHitObject): number {
    return Math.trunc(obj.timePreempt) * this.decoded.general.stackLeniency;
  }

  private applyStackingNew(objs: OsuHitObject[], startIndex: number, endIndex: number): void {
    const stackDistance = 3;
    let extendedEndIndex = endIndex;

    if (endIndex < objs.length - 1) {
      for (let i = endIndex; i >= startIndex; i--) {
        let stackBaseIndex = i;

        for (let n = stackBaseIndex + 1; n < objs.length; n++) {
          const stackBaseObject = objs[stackBaseIndex];
          if (stackBaseObject.kind === ObjectKind.SPINNER) {
            break;
          }

          const objectN = objs[n];
          if (objectN.kind === ObjectKind.SPINNER) {
            continue;
          }

          const endTime = stackBaseObject.endTime();
          const stackThreshold = this.stackThreshold(objectN);

          if (objectN.startTime - endTime > stackThreshold) {
            break;
          }

          const nearStart = stackBaseObject.position.distance(objectN.position) < stackDistance;
          const nearEnd = stackBaseObject.kind === ObjectKind.SLIDER &&
            stackBaseObject.endPosition().distance(objectN.position) < stackDistance;

          if (nearStart || nearEnd) {
            stackBaseIndex = n;
            objectN.stackHeight = 0;
          }
        }

        if (stackBaseIndex > extendedEndIndex) {
          extendedEndIndex = stackBaseIndex;
          if (extendedEndIndex === objs.length - 1) {
            break;
          }
        }
      }
    }

    let extendedStartIndex = startIndex;

    for (let i = extendedEndIndex; i > startIndex; i--) {
      let n = i;
      let objectI = objs[i];

      if (objectI.stackHeight !== 0 || objectI.kind === ObjectKind.SPINNER) {
        continue;
      }

      const stackThreshold = this.stackThreshold(objectI);

      if (objectI.kind === ObjectKind.CIRCLE) {
        while (--n >= 0) {
          const objectN = objs[n];
          if (objectN.kind === ObjectKind.SPINNER) {
            continue;
          }

          const endTime = objectN.endTime();

          // 整数截断：与 stable 一致
          if (Math.trunc(objectI.startTime) - Math.trunc(endTime) > stackThreshold) {
            break;
          }

          if (n < extendedStartIndex) {
            objectN.stackHeight = 0;
            extendedStartIndex = n;
          }

          if (objectN.kind === ObjectKind.SLIDER &&
            objectN.endPosition().distance(objectI.position) < stackDistance) {
            const offset = objectI.stackHeight - objectN.stackHeight + 1;

            for (let j = n + 1; j <= i; j++) {
              const objectJ = objs[j];
              if (objectN.endPosition().distance(objectJ.position) < stackDistance) {
                objectJ.stackHeight -= offset;
              }
            }
            break;
          }

          if (objectN.position.distance(objectI.position) < stackDistance) {
            objectN.stackHeight = objectI.stackHeight + 1;
            objectI = objectN;
          }
        }
      } else if (objectI.kind === ObjectKind.SLIDER) {
        while (--n >= startIndex) {
          const objectN = objs[n];
          if (objectN.kind === ObjectKind.SPINNER) {
            continue;
          }

          if (objectI.startTime - objectN.startTime > stackThreshold) {
            break;
          }

          if (objectN.endPosition().distance(objectI.position) < stackDistance) {
            objectN.stackHeight = objectI.stackHeight + 1;
            objectI = objectN;
          }
        }
      }
    }
  }

  /** 旧格式（< v6）的堆叠算法 */
  private applyStackingOld(objs: OsuHitObject[]): void {
    const stackDistance = 3;

    for (let i = 0; i < objs.length; i++) {
      const curr = objs[i];
      if (curr.stackHeight !== 0 && curr.kind !== ObjectKind.SLIDER) {
        continue;
      }

      let startTime = curr.endTime();
      let sliderStack = 0;

      for (let j = i + 1; j < objs.length; j++) {
        const stackThreshold = this.stackThreshold(objs[i]);
        if (objs[j].startTime - stackThreshold > startTime) {
          break;
        }

        const position2 = curr.kind === ObjectKind.SLIDER
          ? curr.position.add(curr.endPosition().sub(curr.position))
          : curr.position;

        if (objs[j].position.distance(curr.position) < stackDistance) {
          curr.stackHeight++;
          startTime = objs[j].startTime;
        } else if (objs[j].position.distance(position2) < stackDistance) {
          sliderStack++;
          objs[j].stackHeight -= sliderStack;
          startTime = objs[j].startTime;
        }
      }
    }
  }

  // ------------------------------------------------------------- max combo

  private computeMaxCombo(): void {
    let total = 0;
    for (let i = 0; i < this.hitObjects.length; i++) {
      const o = this.hitObjects[i];
      if (o.kind === ObjectKind.CIRCLE) {
        total += 1;
      } else if (o.kind === ObjectKind.SPINNER) {
        total += 1;
      } else if (o.kind === ObjectKind.SLIDER) {
        const s = o as Slider;
        for (let n = 0; n < s.nested.length; n++) {
          const kind = s.nested[n].kind;
          if (kind !== SliderNestedKind.LEGACY_LAST_TICK) {
            total += 1;
          }
        }
      }
    }
    this.maxCombo = total;
  }

  /** 谱面长度（ms，game time） */
  length(): number {
    if (this.hitObjects.length === 0) {
      return 0;
    }
    return this.hitObjects[this.hitObjects.length - 1].endTime();
  }

  /** 在给定时间点取物件（简单线性窗口，供渲染层裁剪） */
  objectsInWindow(from: number, to: number): OsuHitObject[] {
    const out: OsuHitObject[] = [];
    for (let i = 0; i < this.hitObjects.length; i++) {
      const o = this.hitObjects[i];
      if (o.endTime() < from) {
        continue;
      }
      if (o.startTime > to) {
        break;
      }
      out.push(o);
    }
    return out;
  }
}
