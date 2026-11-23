import { Vec2 } from '../core/Vec2';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { ObjectKind, OsuHitObject, Slider, Spinner } from '../ruleset/OsuObjects';
import { OsuPlayableBeatmap } from '../ruleset/OsuPlayableBeatmap';
import { DrawCommandBuffer } from './DrawCommandBuffer';
import { SkinAtlas, SpriteName } from './SkinAtlas';

/** 512x384 虚拟场 → 屏幕像素的 letterbox 映射。 */
export class PlayfieldLayout {
  scale: number = 1;
  offsetX: number = 0;
  offsetY: number = 0;
  surfaceWidth: number = 0;
  surfaceHeight: number = 0;

  static readonly PLAYFIELD_WIDTH: number = 512;
  static readonly PLAYFIELD_HEIGHT: number = 384;

  update(surfaceWidth: number, surfaceHeight: number): void {
    if (surfaceWidth <= 0 || surfaceHeight <= 0) {
      return;
    }
    this.surfaceWidth = surfaceWidth;
    this.surfaceHeight = surfaceHeight;
    const sx = surfaceWidth / PlayfieldLayout.PLAYFIELD_WIDTH;
    const sy = surfaceHeight / PlayfieldLayout.PLAYFIELD_HEIGHT;
    this.scale = Math.min(sx, sy);
    this.offsetX = (surfaceWidth - PlayfieldLayout.PLAYFIELD_WIDTH * this.scale) * 0.5;
    this.offsetY = (surfaceHeight - PlayfieldLayout.PLAYFIELD_HEIGHT * this.scale) * 0.5;
  }

  toScreenX(x: number): number {
    return this.offsetX + x * this.scale;
  }

  toScreenY(y: number): number {
    return this.offsetY + y * this.scale;
  }

  toPlayfieldX(px: number): number {
    return (px - this.offsetX) / this.scale;
  }

  toPlayfieldY(py: number): number {
    return (py - this.offsetY) / this.scale;
  }
}

/** 一次命中反馈（供渲染层画扩散圈） */
export class HitFlash {
  position: Vec2 = Vec2.ZERO;
  time: number = 0;
  great: boolean = true;
}

const DEFAULT_COMBO_COLOURS: number[] = [
  0xFF66AA, 0x66CCFF, 0x99FF66, 0xFFCC66, 0xCC99FF, 0x66FFCC
];

/** 数字贴图是 96x128，画的时候按这个宽高比 */
const DIGIT_ASPECT: number = 96 / 128;
/** 多位数字之间的间距系数（相对单字宽度），osu! 默认皮肤大约是 0.86 */
const DIGIT_GAP: number = 0.86;
/** 跟随圈直径 / 物件直径（osu! 的 follow circle 约 2.4 倍半径） */
const FOLLOW_DIAMETER_SCALE: number = 4.8;

/**
 * 谱面渲染器：把 OsuPlayableBeatmap + 时钟翻译成绘制指令。
 *
 * 只做"看得见"的部分：判定、combo、准确率都在 OsuPlayfield 里，
 * 这里不参与任何玩法计算，避免数值两处漂移。
 *
 * 两套画法并存：
 *   - 皮肤图集可用时，判定圈/滑条球/光标/数字全部走贴图 —— 观感接近 osu!；
 *   - 图集没加载成功（rawfile 缺失、解码失败）就退回纯矢量圆环，
 *     保证"皮肤挂了还能玩"，而不是直接黑屏。
 */
export class BeatmapRenderer {
  private beatmap: OsuPlayableBeatmap;
  layout: PlayfieldLayout = new PlayfieldLayout();

  /** 每个 slider 的折线（playfield 坐标），构造时算一次 */
  private sliderPoints: number[][] = [];
  private comboColours: number[] = [];
  private flashes: HitFlash[] = [];
  /** 上一帧实际发出的纹理指令数（诊断用：和 native 收到的对得上就说明管线通） */
  spriteDraws: number = 0;
  /**
   * 谱面封面是否已经真的铺在后面的 GL 里（由 Play 每帧同步）。
   * 为 true 时不画那两块不透明底色，让封面透上来。
   */
  useBackground: boolean = false;

  constructor(beatmap: OsuPlayableBeatmap) {
    this.beatmap = beatmap;

    const decoded = beatmap.decoded;
    if (decoded.colours.comboColours.length > 0) {
      this.comboColours = decoded.colours.comboColours;
    } else {
      this.comboColours = DEFAULT_COMBO_COLOURS;
    }

    for (let i = 0; i < beatmap.hitObjects.length; i++) {
      const o = beatmap.hitObjects[i];
      if (o.kind === ObjectKind.SLIDER) {
        this.sliderPoints.push(this.buildPolyline(o as Slider));
      } else {
        this.sliderPoints.push([]);
      }
    }
  }

  /**
   * 按 12px 间距抽稀路径顶点，避免每帧几千条线段。
   *
   * 顶点已经是绝对场坐标（SliderPath 的控制点就是绝对的），这里不再叠加 position。
   */
  private buildPolyline(slider: Slider): number[] {
    const vertices = slider.path.getVertices();
    const out: number[] = [];
    const minStep = 12;

    if (vertices.length === 0) {
      return out;
    }

    let lastX = vertices[0].x;
    let lastY = vertices[0].y;
    out.push(lastX);
    out.push(lastY);

    for (let i = 0; i < vertices.length; i++) {
      const vx = vertices[i].x;
      const vy = vertices[i].y;
      const dx = vx - lastX;
      const dy = vy - lastY;
      if (dx * dx + dy * dy >= minStep * minStep) {
        out.push(vx);
        out.push(vy);
        lastX = vx;
        lastY = vy;
      }
    }

    const tail = vertices[vertices.length - 1];
    out.push(tail.x);
    out.push(tail.y);
    return out;
  }

  addFlash(position: Vec2, time: number, great: boolean): void {
    const flash = new HitFlash();
    flash.position = position;
    flash.time = time;
    flash.great = great;
    this.flashes.push(flash);
    if (this.flashes.length > 32) {
      this.flashes.splice(0, this.flashes.length - 32);
    }
  }

  private colourFor(o: OsuHitObject): number {
    if (this.comboColours.length === 0) {
      return 0xFFFFFF;
    }
    const idx = ((o.comboColourIndex % this.comboColours.length) + this.comboColours.length) %
      this.comboColours.length;
    return this.comboColours[idx];
  }

  /** 每帧调用。time 为 game time（ms）。 */
  draw(cmds: DrawCommandBuffer, time: number, cursor: Vec2, hasCursor: boolean): void {
    const layout = this.layout;
    const w = layout.surfaceWidth;
    const h = layout.surfaceHeight;
    this.spriteDraws = 0;

    // lazer 里 Playfield 自己没有底色 —— 它直接叠在压暗过的谱面背景上。
    // 所以有封面（且纹理真的传上 GL 了）时，这两块底色必须让路，
    // 否则一整张不透明矩形会把封面盖死，看起来就是"封面没生效"。
    if (!this.useBackground) {
      cmds.rect(w * 0.5, h * 0.5, w, h, 0x0E0E12, 1);
      const playW = PlayfieldLayout.PLAYFIELD_WIDTH * layout.scale;
      const playH = PlayfieldLayout.PLAYFIELD_HEIGHT * layout.scale;
      cmds.rect(layout.offsetX + playW * 0.5, layout.offsetY + playH * 0.5, playW, playH, 0x17171F, 1);
    }

    const objects = this.beatmap.hitObjects;
    const horizon = time + 2000;

    for (let i = 0; i < objects.length; i++) {
      const o = objects[i];
      if (o.startTime - o.timePreempt > time) {
        continue;
      }
      if (o.endTime() + 400 < time) {
        continue;
      }
      if (o.startTime - o.timePreempt > horizon) {
        break;
      }
      this.drawObject(cmds, o, i, time);
    }

    // 命中反馈：贴图是径向渐变的白光，矢量模式退回扩散圆环
    const lightUV = SkinAtlas.uv(SpriteName.HIT_LIGHT);
    for (let i = this.flashes.length - 1; i >= 0; i--) {
      const f = this.flashes[i];
      const age = time - f.time;
      if (age > 260) {
        this.flashes.splice(i, 1);
        continue;
      }
      const p = age / 260;
      const px = layout.toScreenX(f.position.x);
      const py = layout.toScreenY(f.position.y);
      if (lightUV.length === 4) {
        const d = (layout.scale * 170) * (0.7 + 0.6 * p);
        cmds.sprite(px, py, d, d, 0, f.great ? 0xFFFFFF : 0xFF5566, (1 - p) * 0.85, lightUV);
      } else {
        const r = 20 + 90 * p;
        cmds.ring(px, py, r * 2, 6, f.great ? 0x66FF88 : 0xFF5566, (1 - p) * 0.7);
      }
    }

    if (hasCursor) {
      this.drawCursor(cmds, layout.toScreenX(cursor.x), layout.toScreenY(cursor.y));
    }

    // 指令缓冲自己数的才是真值（要拿去和 native 对账），别在这里累加
    this.spriteDraws = cmds.spriteCount;
  }

  private drawCursor(cmds: DrawCommandBuffer, x: number, y: number): void {
    const uv = SkinAtlas.uv(SpriteName.CURSOR);
    if (uv.length === 4) {
      const d = this.layout.scale * 22;
      cmds.sprite(x, y, d, d, 0, 0xFFFFFF, 1, uv);
      return;
    }
    cmds.ring(x, y, 28, 3, 0xFFFFFF, 0.85);
    cmds.circle(x, y, 5, 0xFFFFFF, 0.9);
  }

  private drawObject(cmds: DrawCommandBuffer, o: OsuHitObject, index: number, time: number): void {
    const layout = this.layout;
    const colour = this.colourFor(o);

    // 淡入：preempt 段
    const appear = o.startTime - o.timePreempt;
    let alpha = 1;
    if (time < appear + o.timeFadeIn) {
      alpha = Math.max(0, (time - appear) / o.timeFadeIn);
    }
    // 已经过时的物件淡出，避免糊在屏幕上
    const over = time - o.endTime();
    if (over > 0) {
      alpha *= Math.max(0, 1 - over / 400);
    }

    const cx = layout.toScreenX(o.position.x + o.stackOffset.x);
    const cy = layout.toScreenY(o.position.y + o.stackOffset.y);
    const radius = o.radius() * layout.scale;

    if (o.kind === ObjectKind.SLIDER) {
      this.drawSlider(cmds, o as Slider, index, time, colour, alpha);
      return;
    }

    if (o.kind === ObjectKind.SPINNER) {
      const spinner = o as Spinner;
      const remain = Math.max(0, spinner.endTime() - time) / Math.max(1, spinner.duration());
      const ringR = radius * (2.2 + 1.6 * remain);
      cmds.ring(cx, cy, ringR * 2, radius * 0.16, colour, alpha * 0.75);
      cmds.circle(cx, cy, radius * 0.5, colour, alpha * 0.35);
      return;
    }

    this.drawHitCircle(cmds, o, cx, cy, radius, colour, alpha);

    // approach ring
    const progress = Math.min(1, Math.max(0, (time - appear) / Math.max(1, o.timePreempt)));
    const approachScale = 1 + 2.0 * (1 - progress);
    const uv = SkinAtlas.uv(SpriteName.APPROACH_CIRCLE);
    if (uv.length === 4) {
      const d = radius * 2 * approachScale;
      cmds.sprite(cx, cy, d, d, 0, colour, alpha * 0.75 * progress, uv);
    } else {
      cmds.ring(cx, cy, radius * 2 * approachScale, radius * 0.1, colour, alpha * 0.55 * progress);
    }
  }

  /** 判定圈：彩色底 + 白描边 + combo 数字 */
  private drawHitCircle(cmds: DrawCommandBuffer, o: OsuHitObject, cx: number, cy: number,
    radius: number, colour: number, alpha: number): void {
    const baseUV = SkinAtlas.uv(SpriteName.HITCIRCLE);
    const overlayUV = SkinAtlas.uv(SpriteName.HITCIRCLE_OVERLAY);
    const d = radius * 2;

    if (baseUV.length === 4 && overlayUV.length === 4) {
      cmds.sprite(cx, cy, d, d, 0, colour, alpha, baseUV);
      cmds.sprite(cx, cy, d, d, 0, 0xFFFFFF, alpha, overlayUV);
      this.drawComboNumber(cmds, o, cx, cy, radius, alpha);
      return;
    }

    cmds.circle(cx, cy, d, colour, alpha * 0.92);
    cmds.ring(cx, cy, d, radius * 0.16, 0xFFFFFF, alpha * 0.85);
  }

  /**
   * combo 数字：`indexInCurrentCombo + 1`，和 osu! 一样随新 combo 重置。
   *
   * 多位数要整体缩放 —— 否则 100+ combo 的数字会横向撑出圈外，
   * 这在 AR9 的图上会直接糊住下一个物件。
   */
  private drawComboNumber(cmds: DrawCommandBuffer, o: OsuHitObject, cx: number, cy: number,
    radius: number, alpha: number): void {
    const value = o.indexInCurrentCombo + 1;
    const digits: number[] = [];
    let v = value;
    while (v > 0) {
      digits.unshift(v % 10);
      v = Math.floor(v / 10);
    }
    if (digits.length === 0) {
      digits.push(1);
    }

    let h = radius * 1.08;
    let total = digits.length * h * DIGIT_ASPECT * DIGIT_GAP;
    const maxW = radius * 1.55;
    if (total > maxW && total > 0) {
      const k = maxW / total;
      h *= k;
      total = maxW;
    }

    const step = h * DIGIT_ASPECT * DIGIT_GAP;
    let x = cx - total * 0.5 + step * 0.5;
    const w = h * DIGIT_ASPECT;
    for (let i = 0; i < digits.length; i++) {
      const uv = SkinAtlas.digitUV(digits[i]);
      if (uv.length === 4) {
        cmds.sprite(x, cy, w, h, 0, 0xFFFFFF, alpha, uv);
      }
      x += step;
    }
  }

  /** 颜色按比例混合，用来把 combo 色压进滑条体的深色里（结果不透明，重叠不会越叠越深） */
  private blendColour(base: number, top: number, t: number): number {
    const br = (base >> 16) & 0xFF;
    const bg = (base >> 8) & 0xFF;
    const bb = base & 0xFF;
    const tr = (top >> 16) & 0xFF;
    const tg = (top >> 8) & 0xFF;
    const tb = top & 0xFF;
    const r = Math.round(br + (tr - br) * t);
    const g = Math.round(bg + (tg - bg) * t);
    const b = Math.round(bb + (tb - bb) * t);
    return (r << 16) | (g << 8) | b;
  }

  private drawSlider(cmds: DrawCommandBuffer, slider: Slider, index: number, time: number,
    colour: number, alpha: number): void {
    const layout = this.layout;
    const points = index < this.sliderPoints.length ? this.sliderPoints[index] : [];
    const radius = slider.radius() * layout.scale;
    const trackWidth = radius * 1.62;

    const endX = layout.toScreenX(slider.position.x + slider.stackOffset.x);
    const endY = layout.toScreenY(slider.position.y + slider.stackOffset.y);

    const sx = slider.stackOffset.x;
    const sy = slider.stackOffset.y;

    // 轨道分两层画：外描边 + 主体。每个折点补一个圆，否则拐角处会出现方块缺口
    // （旋转矩形拼接，转角必然缺一块）。
    const outline = 0x32323E;
    const body = this.blendColour(0x1C1C26, colour, 0.42);
    const n = points.length;

    for (let i = 0; i + 3 < n; i += 2) {
      cmds.line(layout.toScreenX(points[i] + sx), layout.toScreenY(points[i + 1] + sy),
        layout.toScreenX(points[i + 2] + sx), layout.toScreenY(points[i + 3] + sy),
        trackWidth, outline, alpha);
    }
    for (let i = 0; i + 1 < n; i += 2) {
      cmds.circle(layout.toScreenX(points[i] + sx), layout.toScreenY(points[i + 1] + sy),
        trackWidth, outline, alpha);
    }
    for (let i = 0; i + 3 < n; i += 2) {
      cmds.line(layout.toScreenX(points[i] + sx), layout.toScreenY(points[i + 1] + sy),
        layout.toScreenX(points[i + 2] + sx), layout.toScreenY(points[i + 3] + sy),
        trackWidth * 0.84, body, alpha);
    }
    for (let i = 0; i + 1 < n; i += 2) {
      cmds.circle(layout.toScreenX(points[i] + sx), layout.toScreenY(points[i + 1] + sy),
        trackWidth * 0.84, body, alpha);
    }

    // 头圈（和普通圆圈同款，带数字）
    this.drawHitCircle(cmds, slider, endX, endY, radius, colour, alpha);

    const appear = slider.startTime - slider.timePreempt;
    const progress = Math.min(1, Math.max(0, (time - appear) / Math.max(1, slider.timePreempt)));
    if (time < slider.startTime) {
      const approachScale = 1 + 2.0 * (1 - progress);
      const uvA = SkinAtlas.uv(SpriteName.APPROACH_CIRCLE);
      if (uvA.length === 4) {
        const d = radius * 2 * approachScale;
        cmds.sprite(endX, endY, d, d, 0, colour, alpha * 0.75 * progress, uvA);
      } else {
        cmds.ring(endX, endY, radius * 2 * approachScale, radius * 0.1, colour, alpha * 0.55 * progress);
      }
      return;
    }

    // 球位置（按总时长在整条路径上取，折返用 span 计算）
    const spanDuration = Math.max(0.001, slider.spanDuration());
    const elapsed = time - slider.startTime;
    let spanIndex = Math.floor(elapsed / spanDuration);
    if (spanIndex < 0) {
      spanIndex = 0;
    }
    if (spanIndex > slider.spanCount - 1) {
      spanIndex = slider.spanCount - 1;
    }
    let spanProgress = (elapsed - spanIndex * spanDuration) / spanDuration;
    spanProgress = Math.min(1, Math.max(0, spanProgress));
    const ball = slider.positionAtSpan(spanIndex, spanProgress);

    const bx = layout.toScreenX(ball.x + slider.stackOffset.x);
    const by = layout.toScreenY(ball.y + slider.stackOffset.y);

    // 滑条还没结束才画跟随圈和球
    if (time > slider.endTime()) {
      return;
    }
    const followUV = SkinAtlas.uv(SpriteName.FOLLOW_CIRCLE);
    const ballUV = SkinAtlas.uv(SpriteName.SLIDER_BALL);
    if (followUV.length === 4) {
      const fd = radius * FOLLOW_DIAMETER_SCALE;
      cmds.sprite(bx, by, fd, fd, 0, 0xFFFFFF, alpha * 0.45, followUV);
    }
    if (ballUV.length === 4) {
      const bd = radius * 2.1;
      cmds.sprite(bx, by, bd, bd, 0, 0xFFFFFF, alpha, ballUV);
    } else {
      cmds.circle(bx, by, radius * 1.6, 0xFFFFFF, alpha);
      cmds.ring(bx, by, radius * 2 * 2.4, radius * 0.1, 0xFFFFFF, alpha * 0.35);
    }
  }
}
