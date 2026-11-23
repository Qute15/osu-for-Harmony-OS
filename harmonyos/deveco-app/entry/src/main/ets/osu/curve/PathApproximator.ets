import { Vec2 } from '../core/Vec2';

/**
 * 谱面路径的曲线类型（对应 .osu 文件里 slider 的 curveType 字符）。
 */
export class SplineType {
  static readonly LINEAR: string = 'L';
  static readonly PERFECT_CURVE: string = 'P';
  static readonly BEZIER: string = 'B';
  static readonly CATMULL: string = 'C';
}

/**
 * osu.Framework/Utils/PathApproximator.cs 的 ArkTS 移植。
 *
 * 这一层决定 slider 的几何形状 → 直接决定长度 → 决定滑条时长与刻度位置，
 * 所以容差（BEZIER_TOLERANCE = 0.25px，CATMULL 每结 100 采样点）必须与上游一致，
 * 否则判定与实际游玩会对不上。
 */
export class PathApproximator {
  static readonly BEZIER_TOLERANCE: number = 0.25;
  /** osu!stable / framework 的 catmull_detail 常数。 */
  static readonly CATMULL_DETAIL: number = 50;
  static readonly MAX_DEPTH: number = 24;

  static approximate(type: string, controlPoints: Vec2[]): Vec2[] {
    if (controlPoints.length === 0) {
      return [];
    }

    switch (type) {
      case SplineType.PERFECT_CURVE: {
        if (controlPoints.length === 3) {
          const arc = PathApproximator.circularArcToPiecewiseLinear(controlPoints);
          if (arc.length > 0) {
            return arc;
          }
        }
        // 与上游一致：无法拟合圆弧时退化为 B-Spline（3 点即等价于 Bezier）。
        return PathApproximator.bsplineToPiecewiseLinear(controlPoints, controlPoints.length);
      }
      case SplineType.CATMULL:
        return PathApproximator.catmullToPiecewiseLinear(controlPoints);
      case SplineType.BEZIER:
        return PathApproximator.bezierToPiecewiseLinear(controlPoints);
      case SplineType.LINEAR:
      default:
        return PathApproximator.linearToPiecewiseLinear(controlPoints);
    }
  }

  static linearToPiecewiseLinear(points: Vec2[]): Vec2[] {
    const out: Vec2[] = [];
    for (let i = 0; i < points.length; i++) {
      out.push(points[i]);
    }
    return out;
  }

  // ---------------------------------------------------------------- Bezier

  /**
   * Bezier：相邻重复控制点会把路径切分成多条子曲线（stable 的行为），
   * 每条子曲线用 de Casteljau 细分到与弦的偏差 < 0.25px。
   */
  static bezierToPiecewiseLinear(points: Vec2[]): Vec2[] {
    const out: Vec2[] = [];
    if (points.length < 2) {
      return PathApproximator.linearToPiecewiseLinear(points);
    }

    let start = 0;
    for (let i = 1; i < points.length; i++) {
      if (points[i].equals(points[i - 1])) {
        if (i - start >= 2) {
          PathApproximator.subdivideBezier(points.slice(start, i), out, 0);
        } else if (out.length === 0) {
          out.push(points[start]);
        }
        start = i;
      }
    }
    if (points.length - start >= 2) {
      PathApproximator.subdivideBezier(points.slice(start, points.length), out, 0);
    } else if (out.length === 0) {
      out.push(points[start]);
    }
    return out;
  }

  private static subdivideBezier(ctrl: Vec2[], out: Vec2[], depth: number): void {
    const first = ctrl[0];
    const last = ctrl[ctrl.length - 1];

    if (depth >= PathApproximator.MAX_DEPTH || PathApproximator.isFlat(ctrl)) {
      if (out.length === 0) {
        out.push(first);
      }
      out.push(last);
      return;
    }

    // de Casteljau 在 t=0.5 处切分
    let tmp: Vec2[] = ctrl.slice();
    const left: Vec2[] = [tmp[0]];
    const right: Vec2[] = [];
    while (tmp.length > 1) {
      const next: Vec2[] = [];
      for (let i = 0; i + 1 < tmp.length; i++) {
        next.push(Vec2.interpolate(tmp[i], tmp[i + 1], 0.5));
      }
      left.push(next[0]);
      right.unshift(next[next.length - 1]);
      tmp = next;
    }
    right.push(ctrl[ctrl.length - 1]);

    PathApproximator.subdivideBezier(left, out, depth + 1);
    PathApproximator.subdivideBezier(right, out, depth + 1);
  }

  private static isFlat(ctrl: Vec2[]): boolean {
    const a = ctrl[0];
    const b = ctrl[ctrl.length - 1];
    for (let i = 1; i < ctrl.length - 1; i++) {
      if (PathApproximator.distanceToSegment(ctrl[i], a, b) > PathApproximator.BEZIER_TOLERANCE) {
        return false;
      }
    }
    return true;
  }

  private static distanceToSegment(p: Vec2, a: Vec2, b: Vec2): number {
    const abx = b.x - a.x;
    const aby = b.y - a.y;
    const lenSq = abx * abx + aby * aby;
    if (lenSq < 1e-12) {
      return p.distance(a);
    }
    let t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lenSq;
    t = t < 0 ? 0 : (t > 1 ? 1 : t);
    return p.distance(new Vec2(a.x + abx * t, a.y + aby * t));
  }

  // --------------------------------------------------------------- Catmull

  /**
   * Catmull（均匀 Catmull-Rom，tension = 0.5）。
   * 每段固定 2 * CATMULL_DETAIL = 100 个采样点，与 framework 的
   * catmull_segment_length 完全对应（SliderPath 的 OptimiseCatmull 依赖这个数）。
   */
  static catmullToPiecewiseLinear(controlPoints: Vec2[]): Vec2[] {
    const count = controlPoints.length;
    const out: Vec2[] = [];
    if (count < 2) {
      return PathApproximator.linearToPiecewiseLinear(controlPoints);
    }
    if (count === 2) {
      return PathApproximator.linearToPiecewiseLinear(controlPoints);
    }

    // 两端点外推，保证首尾段也有 p0 / p3
    const pts: Vec2[] = [];
    pts.push(controlPoints[0].mul(2).sub(controlPoints[1]));
    for (let i = 0; i < count; i++) {
      pts.push(controlPoints[i]);
    }
    pts.push(controlPoints[count - 1].mul(2).sub(controlPoints[count - 2]));

    const detail = PathApproximator.CATMULL_DETAIL * 2;
    out.push(controlPoints[0]);

    for (let i = 0; i < count - 1; i++) {
      const p0 = pts[i];
      const p1 = pts[i + 1];
      const p2 = pts[i + 2];
      const p3 = pts[i + 3];

      for (let j = 1; j <= detail; j++) {
        const t = j / detail;
        const t2 = t * t;
        const t3 = t2 * t;

        const x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t +
          (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
          (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3);
        const y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t +
          (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
          (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3);

        out.push(new Vec2(x, y));
      }
    }
    return out;
  }

  // ------------------------------------------------------------ CircularArc

  /**
   * Perfect curve：3 点拟合圆弧。无效（共线/半径过大/采样点爆炸）时返回空数组，
   * 由调用方退化为 Bezier。
   */
  static circularArcToPiecewiseLinear(points: Vec2[]): Vec2[] {
    if (points.length !== 3) {
      return [];
    }

    const a = points[0];
    const b = points[1];
    const c = points[2];

    const d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (Math.abs(d) < 1e-6) {
      return [];
    }

    const aSq = a.x * a.x + a.y * a.y;
    const bSq = b.x * b.x + b.y * b.y;
    const cSq = c.x * c.x + c.y * c.y;

    const ux = (aSq * (b.y - c.y) + bSq * (c.y - a.y) + cSq * (a.y - b.y)) / d;
    const uy = (aSq * (c.x - b.x) + bSq * (a.x - c.x) + cSq * (b.x - a.x)) / d;
    const centre = new Vec2(ux, uy);
    const radius = centre.distance(a);

    if (!Number.isFinite(radius) || radius > 1e6) {
      return [];
    }

    // 以 b 为参考角，保证 theta 范围连续
    const theta = Math.atan2(b.y - centre.y, b.x - centre.x);
    let theta2 = Math.atan2(a.y - centre.y, a.x - centre.x) - theta;
    let theta3 = Math.atan2(c.y - centre.y, c.x - centre.x) - theta;

    if (Math.abs(theta2 - theta3) > Math.PI) {
      if (theta2 < theta3) {
        theta2 += 2 * Math.PI;
      } else {
        theta3 += 2 * Math.PI;
      }
    }

    const thetaRange = theta3 - theta2;
    const thetaStart = theta + theta2;

    let amount: number;
    if (2 * radius <= 0.1) {
      amount = 2;
    } else {
      amount = 2 * Math.max(2, Math.ceil(Math.abs(thetaRange) / (2 * Math.acos(1 - 0.1 / radius))));
    }

    // 上游在 subPoints >= 1000 时放弃圆弧（约等于 12 万像素弧长）
    if (amount >= 1000) {
      return [];
    }

    const out: Vec2[] = [];
    for (let i = 0; i < amount; i++) {
      const fract = i / (amount - 1);
      const ang = thetaStart + thetaRange * fract;
      out.push(new Vec2(centre.x + radius * Math.cos(ang), centre.y + radius * Math.sin(ang)));
    }
    return out;
  }

  // ---------------------------------------------------------------- B-Spline

  /**
   * 通用 B-Spline（de Boor）。osu! 里实际只用于 Perfect 曲线退化场景，
   * degree = 点数时等价于 Bezier。
   */
  static bsplineToPiecewiseLinear(points: Vec2[], degree: number): Vec2[] {
    if (points.length < 2) {
      return PathApproximator.linearToPiecewiseLinear(points);
    }
    const deg = Math.min(degree, points.length - 1);
    if (deg <= 1) {
      return PathApproximator.linearToPiecewiseLinear(points);
    }
    if (deg >= points.length - 1) {
      return PathApproximator.bezierToPiecewiseLinear(points);
    }

    // 均匀节点向量 + clamped
    const n = points.length;
    const knots: number[] = [];
    const inner = n + deg + 1;
    for (let i = 0; i < inner; i++) {
      if (i <= deg) {
        knots.push(0);
      } else if (i >= n) {
        knots.push(n - deg);
      } else {
        knots.push(i - deg);
      }
    }

    const samples = Math.max(8, (n - deg) * 16);
    const out: Vec2[] = [];
    for (let s = 0; s <= samples; s++) {
      const t = (n - deg) * s / samples;
      out.push(PathApproximator.deBoor(points, knots, deg, t));
    }
    return out;
  }

  private static deBoor(points: Vec2[], knots: number[], degree: number, t: number): Vec2 {
    let k = degree;
    const max = points.length - 1;
    for (let i = degree; i < points.length; i++) {
      if (t < knots[i + 1]) {
        k = i;
        break;
      }
      k = i;
    }
    k = Math.min(k, max);

    const d: Vec2[] = [];
    for (let j = 0; j <= degree; j++) {
      const idx = Math.min(Math.max(k - degree + j, 0), max);
      d.push(points[idx]);
    }

    for (let r = 1; r <= degree; r++) {
      for (let j = degree; j >= r; j--) {
        const i = j + k - degree;
        const denom = knots[i + 1] - knots[i + 1 - r];
        const alpha = denom === 0 ? 0 : (t - knots[i + 1 - r]) / denom;
        d[j] = Vec2.interpolate(d[j - 1], d[j], alpha);
      }
    }
    return d[degree];
  }
}
