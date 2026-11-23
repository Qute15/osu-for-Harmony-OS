/**
 * osu! for HarmonyOS — 2D vector.
 *
 * 移植自 osuTK.Vector2 / osu.Framework 的二维向量语义。
 * 注意：C# 的 Vector2 是 float 精度，这里统一用 number(double)，
 * 只在需要 bit-exact 的地方（如稳定版打滑计算）做 Math.fround 收敛。
 */
export class Vec2 {
  x: number;
  y: number;

  constructor(x: number = 0, y: number = 0) {
    this.x = x;
    this.y = y;
  }

  static get ZERO(): Vec2 {
    return new Vec2(0, 0);
  }

  static fround(v: Vec2): Vec2 {
    return new Vec2(Math.fround(v.x), Math.fround(v.y));
  }

  add(o: Vec2): Vec2 {
    return new Vec2(this.x + o.x, this.y + o.y);
  }

  sub(o: Vec2): Vec2 {
    return new Vec2(this.x - o.x, this.y - o.y);
  }

  mul(f: number): Vec2 {
    return new Vec2(this.x * f, this.y * f);
  }

  div(f: number): Vec2 {
    return new Vec2(this.x / f, this.y / f);
  }

  neg(): Vec2 {
    return new Vec2(-this.x, -this.y);
  }

  length(): number {
    return Math.sqrt(this.x * this.x + this.y * this.y);
  }

  lengthSquared(): number {
    return this.x * this.x + this.y * this.y;
  }

  normalized(): Vec2 {
    const len = this.length();
    return len > 0 ? new Vec2(this.x / len, this.y / len) : Vec2.ZERO;
  }

  distance(o: Vec2): number {
    return this.sub(o).length();
  }

  distanceSquared(o: Vec2): number {
    return this.sub(o).lengthSquared();
  }

  equals(o: Vec2): boolean {
    return this.x === o.x && this.y === o.y;
  }

  static interpolate(a: Vec2, b: Vec2, t: number): Vec2 {
    return new Vec2(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t);
  }

  toString(): string {
    return `(${this.x}, ${this.y})`;
  }
}

/** osu.Framework.Precision 的等价实现。 */
export class Precision {
  static readonly FLOAT_EPSILON: number = 1e-3;

  static almostEquals(a: number, b: number, epsilon: number = Precision.FLOAT_EPSILON): boolean {
    return Math.abs(a - b) < epsilon;
  }

  static definitelyBigger(a: number, b: number, epsilon: number = Precision.FLOAT_EPSILON): boolean {
    return a - b > epsilon;
  }

  static clamp(value: number, min: number, max: number): number {
    return value < min ? min : (value > max ? max : value);
  }

  static clamp01(value: number): number {
    return Precision.clamp(value, 0, 1);
  }

  /** 与 C# double 相同的“四舍五入到最近整数，.5 取偶”之外，这里复刻 MidpointRounding.ToEven。 */
  static roundHalfEven(value: number): number {
    const floor = Math.floor(value);
    const diff = value - floor;
    if (diff > 0.5) return floor + 1;
    if (diff < 0.5) return floor;
    return floor % 2 === 0 ? floor : floor + 1;
  }
}

export class MathUtil {
  static degreesToRadians(d: number): number {
    return d * Math.PI / 180;
  }

  static radiansToDegrees(r: number): number {
    return r * 180 / Math.PI;
  }
}
