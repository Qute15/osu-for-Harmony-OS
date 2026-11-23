import { Vec2 } from '../core/Vec2';
import { ObjectKind, OsuHitObject, Slider, Spinner } from './OsuObjects';
import { OsuPlayableBeatmap } from './OsuPlayableBeatmap';

/** 一帧的输入意图 */
export class AutoInput {
  cursor: Vec2 = new Vec2(256, 192);
  press: boolean = false;
  release: boolean = false;
}

/**
 * 自动游玩（Auto mod 的移植）。
 *
 * 用途有两层：
 *   1. osu! 本身就有 Auto mod，属于要移植的内容；
 *   2. 它是唯一能在没有真人的情况下验证"判定 → 打击音 → 偏差条"整条链路的手段。
 *
 * 刻意走和触屏完全相同的 press/move/release 路径，而不是直接调计分器——
 * 这样它验证的是真实输入路径，而不是一条"给测试开后门"的分支。
 */
export class AutoPlayer {
  private index: number = 0;
  private down: boolean = false;
  private input: AutoInput = new AutoInput();

  get currentIndex(): number {
    return this.index;
  }

  get isDown(): boolean {
    return this.down;
  }

  reset(): void {
    this.index = 0;
    this.down = false;
  }

  update(beatmap: OsuPlayableBeatmap, time: number): AutoInput {
    const input = this.input;
    input.press = false;
    input.release = false;

    const objects = beatmap.hitObjects;
    if (objects.length === 0) {
      return input;
    }

    // 跳过已经彻底过去的物件
    while (this.index < objects.length && objects[this.index].endTime() + 120 < time) {
      this.index++;
    }

    if (this.index >= objects.length) {
      if (this.down) {
        input.release = true;
        this.down = false;
      }
      return input;
    }

    const obj = objects[this.index];
    input.cursor = this.cursorFor(obj, time);

    if (!this.down) {
      // 提前 4ms 按下：tick 是 8ms 一次，等到"恰好等于"会漏帧。
      // 上界是保险：时间跳变后不要对着一个早就过去的物件按下去。
      if (time >= obj.startTime - 4 && time <= obj.startTime + 200) {
        input.press = true;
        this.down = true;
      }
    } else {
      // 圆点按下即判，滑条和转盘要按到结束。
      // 松手必须在 endTime 之后：滑条尾判恰好在 endTime 结算，
      // 提前撒手会让尾判拿不到跟踪状态直接 miss。
      const finished = obj.kind === ObjectKind.CIRCLE
        ? time > obj.startTime + 12
        : time > obj.endTime() + 8;
      if (finished) {
        input.release = true;
        this.down = false;
        // 关键：松开后立刻前进。否则 !!down 会在下一帧对同一个物件再按一次，
        // 造成每个物件被按十几次，准确率会掉到 30% 多。
        this.index++;
      }
    }

    return input;
  }

  private cursorFor(obj: OsuHitObject, time: number): Vec2 {
    if (obj.kind === ObjectKind.SLIDER) {
      const slider = obj as Slider;
      if (time < slider.startTime) {
        return slider.position.add(slider.stackOffset);
      }
      const spanDuration = Math.max(0.001, slider.spanDuration());
      const elapsed = time - slider.startTime;
      let spanIndex = Math.floor(elapsed / spanDuration);
      if (spanIndex < 0) {
        spanIndex = 0;
      }
      if (spanIndex > slider.spanCount - 1) {
        spanIndex = slider.spanCount - 1;
      }
      let progress = (elapsed - spanIndex * spanDuration) / spanDuration;
      progress = Math.min(1, Math.max(0, progress));
      return slider.positionAtSpan(spanIndex, progress).add(slider.stackOffset);
    }

    if (obj.kind === ObjectKind.SPINNER) {
      // 绕着中心转，保证判定引擎认为游标在动
      const spinner = obj as Spinner;
      const t = time * 0.012;
      const r = 40;
      return new Vec2(256 + Math.cos(t) * r, 192 + Math.sin(t) * r);
    }

    return obj.position.add(obj.stackOffset);
  }
}
