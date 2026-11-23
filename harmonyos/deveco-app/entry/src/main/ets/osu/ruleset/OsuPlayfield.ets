import { Vec2 } from '../core/Vec2';
import { HitResult } from '../scoring/HitResult';
import { OsuHitWindows } from '../scoring/OsuHitWindows';
import { ScoreProcessor } from '../scoring/ScoreProcessor';
import { OsuHitObject, Slider, Spinner, ObjectKind, SliderNestedKind } from './OsuObjects';
import { OsuPlayableBeatmap } from './OsuPlayableBeatmap';

/** 单条判定事件：渲染层播特效、HUD 更新、回放录制都用它。 */
export class JudgementEvent {
  kind: string = '';
  result: string = HitResult.NONE;
  objectIndex: number = -1;
  time: number = 0;
  /** 命中偏差（ms）；miss 时为 NaN */
  offset: number = NaN;
  position: Vec2 = Vec2.ZERO;
  nestedIndex: number = -1;

  constructor(kind: string, result: string, objectIndex: number, time: number) {
    this.kind = kind;
    this.result = result;
    this.objectIndex = objectIndex;
    this.time = time;
  }
}

class ObjectState {
  headJudged: boolean = false;
  nestedJudged: boolean[] = [];
  /** nested 下标的按时间排序序列（已剔除 head 与 legacyLastTick） */
  nestedOrder: number[] = [];
  nestedCursor: number = 0;
  totalRotation: number = 0;
  lastAngle: number = 0;
  spinning: boolean = false;
}

/**
 * osu! 标准模式判定场 —— 只做规则，不做绘制和音频。
 *
 * 因此它可以在 Node 里被自动机驱动做回归测试（见 harness 的 autoplay 用例），
 * 这是"移植是否真的对"唯一可靠的验证手段。
 *
 * 时间基准：所有 time 都是 game time（DT/HT 已缩放）。
 */
export class OsuPlayfield {
  beatmap: OsuPlayableBeatmap;
  windows: OsuHitWindows;
  score: ScoreProcessor = new ScoreProcessor();

  clock: number = 0;
  /** 所有物件判定完毕 */
  finished: boolean = false;

  static readonly FOLLOW_RADIUS_MULTIPLIER: number = 2.4;

  /**
   * 滑条 tick/尾判漏掉时该记成哪种结果。
   *
   * 关键：不能再记成 HitResult.MISS。MISS 会进准确率的分母，一条 8 段滑条
   * 能凭空生出十几个 "miss"，玩家看到的 300 计数也会超过物件总数
   * （实测 192 物件的 Easy 显示 300=418，就是这么来的）。
   * tick 类结果只加/断 combo，不参与准确率 —— 和 lazer 的 SmallTick/LargeTick 一致。
   */
  static tickMissFor(kind: string): string {
    return kind === SliderNestedKind.TAIL ? HitResult.LARGE_TICK_MISS : HitResult.SMALL_TICK_MISS;
  }

  private states: ObjectState[] = [];
  private nextIndex: number = 0;

  private activeSlider: Slider | null = null;
  private tracking: boolean = false;

  private activeSpinner: Spinner | null = null;
  private activeSpinnerIndex: number = -1;

  constructor(beatmap: OsuPlayableBeatmap) {
    this.beatmap = beatmap;
    this.windows = new OsuHitWindows(beatmap.difficulty.overallDifficulty);

    for (let i = 0; i < beatmap.hitObjects.length; i++) {
      const o = beatmap.hitObjects[i];
      const st = new ObjectState();

      if (o.kind === ObjectKind.SLIDER) {
        const s = o as Slider;
        for (let n = 0; n < s.nested.length; n++) {
          st.nestedJudged.push(false);
          const kind = s.nested[n].kind;
          if (kind === 'head' || kind === SliderNestedKind.LEGACY_LAST_TICK) {
            st.nestedJudged[n] = true; // 不参与判定
            continue;
          }
          st.nestedOrder.push(n);
        }
        // 按判定时间排序（折返段的 tick 在数组里是倒序的）
        const s2 = s;
        st.nestedOrder.sort((a: number, b: number) => {
          const ta = s2.nested[a].kind === SliderNestedKind.TAIL ? s2.endTime() : s2.nested[a].time;
          const tb = s2.nested[b].kind === SliderNestedKind.TAIL ? s2.endTime() : s2.nested[b].time;
          return ta - tb;
        });
      }
      this.states.push(st);
    }
  }

  // ------------------------------------------------------------- 时间推进

  /** 每帧调用。cursor 为虚拟场坐标，null 表示无光标信息（回放缺数据/自动机）。 */
  update(time: number, cursor: Vec2 | null): JudgementEvent[] {
    const events: JudgementEvent[] = [];
    this.clock = time;

    for (let i = this.nextIndex; i < this.beatmap.hitObjects.length; i++) {
      const o = this.beatmap.hitObjects[i];
      if (o.startTime > time) {
        break;
      }
      const st = this.states[i];

      if (o.kind === ObjectKind.SPINNER) {
        this.updateSpinner(i, o as Spinner, time, cursor, events);
        continue;
      }

      if (!st.headJudged && o.kind === ObjectKind.SLIDER) {
        // 滑条头由 press() 判定；超时则整条 miss（漏头=漏滑条）
        if (time > o.startTime + this.windows.meh) {
          st.headJudged = true;
          events.push(this.record('head', HitResult.MISS, i, time));
          const s = o as Slider;
          for (let k = 0; k < st.nestedOrder.length; k++) {
            const n = st.nestedOrder[k];
            if (!st.nestedJudged[n]) {
              st.nestedJudged[n] = true;
              events.push(this.record(s.nested[n].kind, OsuPlayfield.tickMissFor(s.nested[n].kind),
                i, s.nested[n].time, n));
            }
          }
        }
        continue;
      }

      if (o.kind === ObjectKind.SLIDER && st.headJudged) {
        this.updateSlider(i, o as Slider, st, time, cursor, events);
        continue;
      }

      // 圆圈：窗口过了还没按下 → miss
      if (!st.headJudged && time > o.startTime + this.windows.meh) {
        st.headJudged = true;
        events.push(this.record('head', HitResult.MISS, i, time));
      }
    }

    this.advanceNextIndex();
    if (this.nextIndex >= this.beatmap.hitObjects.length) {
      this.finished = true;
    }
    return events;
  }

  private updateSlider(index: number, s: Slider, st: ObjectState, time: number,
    cursor: Vec2 | null, events: JudgementEvent[]): void {
    const isActive = this.activeSlider === s;
    const canTrack = isActive && this.tracking && this.isTrackingCursor(s, time, cursor);

    while (st.nestedCursor < st.nestedOrder.length) {
      const n = st.nestedOrder[st.nestedCursor];
      const nn = s.nested[n];
      const isTail = nn.kind === SliderNestedKind.TAIL;
      const due = isTail ? s.endTime() : nn.time;

      if (time < due) {
        break;
      }

      if (isTail) {
        st.nestedJudged[n] = true;
        st.nestedCursor++;
        events.push(this.record('tail', canTrack ? HitResult.LARGE_TICK_HIT : HitResult.LARGE_TICK_MISS,
          index, time, n));
        continue;
      }

      if (canTrack) {
        st.nestedJudged[n] = true;
        st.nestedCursor++;
        events.push(this.record(nn.kind, HitResult.SMALL_TICK_HIT, index, nn.time, n));
        continue;
      }

      if (time > due + this.windows.meh) {
        st.nestedJudged[n] = true;
        st.nestedCursor++;
        events.push(this.record(nn.kind, OsuPlayfield.tickMissFor(nn.kind), index, nn.time, n));
        continue;
      }

      // 还在宽容窗内，等光标回来
      break;
    }

    if (isActive && time > s.endTime()) {
      this.activeSlider = null;
      this.tracking = false;
    }
  }

  private updateSpinner(index: number, s: Spinner, time: number, cursor: Vec2 | null,
    events: JudgementEvent[]): void {
    const st = this.states[index];

    if (!st.spinning && cursor !== null) {
      st.spinning = true;
      st.lastAngle = Math.atan2(cursor.y - s.position.y, cursor.x - s.position.x);
      return;
    }

    if (st.spinning && cursor !== null) {
      const angle = Math.atan2(cursor.y - s.position.y, cursor.x - s.position.x);
      let delta = angle - st.lastAngle;
      while (delta > Math.PI) {
        delta -= 2 * Math.PI;
      }
      while (delta < -Math.PI) {
        delta += 2 * Math.PI;
      }
      st.totalRotation += Math.abs(delta);
      st.lastAngle = angle;
    }

    if (time >= s.endTime() && !st.headJudged) {
      st.headJudged = true;
      const spins = Math.floor(st.totalRotation / (2 * Math.PI));
      const required = Math.max(1, Math.floor(s.duration() / 1000));
      events.push(this.record('spinner', spins >= required ? HitResult.GREAT : HitResult.MISS, index, time));
    }
  }

  // --------------------------------------------------------------- 输入

  /** 按下。 */
  press(time: number, cursor: Vec2): JudgementEvent[] {
    const events: JudgementEvent[] = [];
    const idx = this.findHittable(time);
    if (idx < 0) {
      return events;
    }

    const o = this.beatmap.hitObjects[idx];
    const st = this.states[idx];

    if (o.kind === ObjectKind.SPINNER) {
      const s = o as Spinner;
      if (time >= s.startTime - this.windows.meh && time <= s.endTime()) {
        this.activeSpinner = s;
        this.activeSpinnerIndex = idx;
        st.spinning = false;
        st.totalRotation = 0;
      }
      return events;
    }

    if (o.position.distance(cursor) > o.radius()) {
      return events;
    }

    const offset = time - o.startTime;
    const result = this.windows.resultFor(offset);
    if (result === HitResult.NONE) {
      return events;
    }

    st.headJudged = true;
    events.push(this.record('head', result, idx, time, -1, offset));

    if (o.kind === ObjectKind.SLIDER) {
      this.activeSlider = o as Slider;
      this.tracking = true;
    }

    this.advanceNextIndex();
    return events;
  }

  /** 抬起：断跟随，滑条剩余 tick 会在后续 update 里判 miss。 */
  release(time: number): JudgementEvent[] {
    this.tracking = false;
    this.activeSlider = null;
    this.activeSpinner = null;
    this.activeSpinnerIndex = -1;
    return [];
  }

  move(time: number, cursor: Vec2): void {
    this.clock = time;
  }

  // --------------------------------------------------------------- 内部

  private isTrackingCursor(slider: Slider, time: number, cursor: Vec2 | null): boolean {
    if (cursor === null) {
      return true;
    }
    const span = Math.max(0.0001, slider.spanDuration());
    const elapsed = time - slider.startTime;
    let spanIndex = Math.floor(elapsed / span);
    if (spanIndex < 0) {
      spanIndex = 0;
    }
    if (spanIndex > slider.spanCount - 1) {
      spanIndex = slider.spanCount - 1;
    }
    let progress = (elapsed - spanIndex * span) / span;
    progress = Math.min(1, Math.max(0, progress));
    const expected = slider.positionAtSpan(spanIndex, progress);
    return cursor.distance(expected) <= slider.radius() * OsuPlayfield.FOLLOW_RADIUS_MULTIPLIER;
  }

  private findHittable(time: number): number {
    let best = -1;
    let bestAbs = Number.POSITIVE_INFINITY;

    for (let i = this.nextIndex; i < this.beatmap.hitObjects.length; i++) {
      const o = this.beatmap.hitObjects[i];
      if (this.states[i].headJudged) {
        continue;
      }
      const offset = time - o.startTime;
      if (offset < -this.windows.meh) {
        break;
      }
      const abs = Math.abs(offset);
      if (abs <= this.windows.meh && abs < bestAbs) {
        best = i;
        bestAbs = abs;
      }
    }
    return best;
  }

  private advanceNextIndex(): void {
    while (this.nextIndex < this.beatmap.hitObjects.length) {
      const o = this.beatmap.hitObjects[this.nextIndex];
      const st = this.states[this.nextIndex];
      if (!st.headJudged) {
        break;
      }
      if (o.kind === ObjectKind.SLIDER) {
        let allJudged = true;
        for (let n = 0; n < st.nestedJudged.length; n++) {
          if (!st.nestedJudged[n]) {
            allJudged = false;
            break;
          }
        }
        if (!allJudged) {
          break;
        }
      }
      this.nextIndex++;
    }
  }

  private record(kind: string, result: string, objectIndex: number, time: number,
    nestedIndex: number = -1, offset: number = NaN): JudgementEvent {
    const ev = new JudgementEvent(kind, result, objectIndex, time);
    ev.nestedIndex = nestedIndex;
    ev.offset = offset;
    ev.position = this.beatmap.hitObjects[objectIndex].position;
    this.score.applyResult(result);
    return ev;
  }

  accuracy(): number {
    return this.score.accuracy();
  }

  combo(): number {
    return this.score.combo;
  }
}
