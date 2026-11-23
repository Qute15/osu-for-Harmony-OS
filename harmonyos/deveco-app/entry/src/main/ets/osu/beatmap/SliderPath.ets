import { Vec2, Precision } from '../core/Vec2';
import { PathApproximator, SplineType } from '../curve/PathApproximator';

/** 路径控制点。type 为 '' 表示“继承当前段类型”，否则是 SplineType 之一。 */
export class PathControlPoint {
  position: Vec2;
  type: string;

  constructor(position: Vec2, type: string = '') {
    this.position = position;
    this.type = type;
  }
}

/**
 * osu.Game/Rulesets/Objects/SliderPath.cs 的移植。
 *
 * 关键行为（与上游逐条对齐）：
 *  - 控制点按 type 切段，每段的曲线类型取该段首点的 type；
 *  - ExpectedDistance 会把最后一段拉长或截短（stable 会跳过“末两点重合时的延长”）；
 *  - Catmull 段做 6px 优化，并把被优化掉的长度记入 optimisedLength，
 *    防止路径被错误延长（否则真实谱面的滑条时长会整体偏移）。
 */
export class SliderPath {
  controlPoints: PathControlPoint[] = [];
  /** < 0 表示未设置（对应 C# 的 null）。 */
  expectedDistance: number = -1;
  optimiseCatmull: boolean = true;

  private calculatedPath: Vec2[] = [];
  private cumulativeLength: number[] = [];
  private segmentEnds: number[] = [];
  private segmentEndDistances: number[] = [];
  private calculatedLengthValue: number = 0;
  private optimisedLength: number = 0;
  private valid: boolean = false;

  constructor(controlPoints: PathControlPoint[] = [], expectedDistance: number = -1, optimiseCatmull: boolean = true) {
    this.controlPoints = controlPoints;
    this.expectedDistance = expectedDistance;
    this.optimiseCatmull = optimiseCatmull;
  }

  // ------------------------------------------------------------- 公开查询

  /** 最终长度（应用 ExpectedDistance 之后）。 */
  distance(): number {
    this.ensureValid();
    return this.cumulativeLength.length === 0 ? 0 : this.cumulativeLength[this.cumulativeLength.length - 1];
  }

  /** 原始计算长度（未应用 ExpectedDistance）。 */
  calculatedDistance(): number {
    this.ensureValid();
    return this.calculatedLengthValue;
  }

  /** progress ∈ [0,1] → 路径上的点。 */
  positionAt(progress: number): Vec2 {
    this.ensureValid();
    const d = Precision.clamp01(progress) * this.distance();
    return this.interpolateVertices(this.indexOfDistance(d), d);
  }

  /** 供渲染层直接取折线顶点（只读使用）。 */
  getVertices(): Vec2[] {
    this.ensureValid();
    return this.calculatedPath;
  }

  /** 各段终点对应的 progress（可能 >1 或 <1，见上游文档）。 */
  getSegmentEnds(): number[] {
    this.ensureValid();
    const dist = this.distance();
    const out: number[] = [];
    if (dist === 0) {
      for (let i = 0; i < this.segmentEndDistances.length; i++) {
        out.push(0);
      }
      return out;
    }
    for (let i = 0; i < this.segmentEndDistances.length; i++) {
      out.push(this.segmentEndDistances[i] / dist);
    }
    return out;
  }

  // ------------------------------------------------------------- 计算内核

  private ensureValid(): void {
    if (this.valid) {
      return;
    }
    this.calculatePath();
    this.calculateLength();
    this.valid = true;
  }

  private calculatePath(): void {
    this.calculatedPath = [];
    this.segmentEnds = [];
    this.optimisedLength = 0;

    const n = this.controlPoints.length;
    if (n === 0) {
      return;
    }

    const vertices: Vec2[] = [];
    for (let i = 0; i < n; i++) {
      vertices.push(this.controlPoints[i].position);
    }

    let start = 0;
    for (let i = 0; i < n; i++) {
      const isLast = i === n - 1;
      const cpType = this.controlPoints[i].type;
      if (cpType === '' && !isLast) {
        continue;
      }

      const segmentType = this.controlPoints[start].type === '' ? SplineType.LINEAR : this.controlPoints[start].type;
      const segLen = i - start + 1;

      if (segLen === 1) {
        this.calculatedPath.push(vertices[start]);
      } else if (segLen > 1) {
        const segmentVertices = vertices.slice(start, i + 1);
        const subPath = this.calculateSubPath(segmentVertices, segmentType);

        let skipFirst = false;
        if (this.calculatedPath.length > 0 && subPath.length > 0) {
          const lastPoint = this.calculatedPath[this.calculatedPath.length - 1];
          if (lastPoint.equals(subPath[0])) {
            skipFirst = true;
          }
        }
        for (let j = skipFirst ? 1 : 0; j < subPath.length; j++) {
          this.calculatedPath.push(subPath[j]);
        }
      }

      if (i > 0) {
        this.segmentEnds.push(this.calculatedPath.length - 1);
      }

      start = i;
    }
  }

  private calculateSubPath(subControlPoints: Vec2[], type: string): Vec2[] {
    switch (type) {
      case SplineType.LINEAR:
        return PathApproximator.linearToPiecewiseLinear(subControlPoints);

      case SplineType.PERFECT_CURVE: {
        if (subControlPoints.length !== 3) {
          break;
        }
        const arc = PathApproximator.circularArcToPiecewiseLinear(subControlPoints);
        if (arc.length > 0) {
          return arc;
        }
        break;
      }

      case SplineType.CATMULL: {
        const subPath = PathApproximator.catmullToPiecewiseLinear(subControlPoints);
        if (!this.optimiseCatmull) {
          return subPath;
        }

        // stable 会把间距 6px 内的细分点压掉；主要影响“重合结”附近的鼓包。
        // 被压掉的长度必须补进 optimisedLength，否则 ExpectedDistance 会把路径拉长。
        const optimised: Vec2[] = [];
        let lastStart: Vec2 | null = null;
        let lengthRemovedSinceStart = 0;

        for (let i = 0; i < subPath.length; i++) {
          if (lastStart === null) {
            optimised.push(subPath[i]);
            lastStart = subPath[i];
            continue;
          }
          const distFromStart = lastStart.distance(subPath[i]);
          lengthRemovedSinceStart += subPath[i - 1].distance(subPath[i]);

          const catmullSegmentLength = PathApproximator.CATMULL_DETAIL * 2;
          if (distFromStart > 6 || (i + 1) % catmullSegmentLength === 0 || i === subPath.length - 1) {
            optimised.push(subPath[i]);
            this.optimisedLength += lengthRemovedSinceStart - distFromStart;
            lastStart = null;
            lengthRemovedSinceStart = 0;
          }
        }
        return optimised;
      }

      default:
        break;
    }

    const degree = subControlPoints.length;
    return PathApproximator.bsplineToPiecewiseLinear(subControlPoints, degree);
  }

  private calculateLength(): void {
    this.calculatedLengthValue = this.optimisedLength;
    this.cumulativeLength = [0];

    for (let i = 0; i + 1 < this.calculatedPath.length; i++) {
      this.calculatedLengthValue += this.calculatedPath[i + 1].distance(this.calculatedPath[i]);
      this.cumulativeLength.push(this.calculatedLengthValue);
    }

    this.segmentEndDistances = [];
    for (let i = 0; i < this.segmentEnds.length; i++) {
      const idx = this.segmentEnds[i];
      this.segmentEndDistances.push(idx >= 0 && idx < this.cumulativeLength.length ? this.cumulativeLength[idx] : 0);
    }

    if (this.expectedDistance < 0 || this.calculatedLengthValue === this.expectedDistance) {
      return;
    }

    const expected = this.expectedDistance;

    // stable：若最后两个路径点重合，则不做延长
    if (this.calculatedPath.length >= 2) {
      const last = this.calculatedPath[this.calculatedPath.length - 1];
      const prev = this.calculatedPath[this.calculatedPath.length - 2];
      if (last.equals(prev) && expected > this.calculatedLengthValue) {
        this.cumulativeLength.push(this.calculatedLengthValue);
        return;
      }
    }

    // 最后一个长度总是错的，先移除
    this.cumulativeLength.pop();
    let pathEndIndex = this.calculatedPath.length - 1;

    if (this.calculatedLengthValue > expected) {
      while (this.cumulativeLength.length > 0 &&
        this.cumulativeLength[this.cumulativeLength.length - 1] >= expected) {
        this.cumulativeLength.pop();
        this.calculatedPath.pop();
        pathEndIndex--;
      }
    }

    if (pathEndIndex <= 0) {
      this.cumulativeLength.push(0);
      return;
    }

    const base = this.calculatedPath[pathEndIndex - 1];
    const dir = this.calculatedPath[pathEndIndex].sub(base).normalized();
    const tail = this.cumulativeLength[this.cumulativeLength.length - 1];
    this.calculatedPath[pathEndIndex] = base.add(dir.mul(expected - tail));
    this.cumulativeLength.push(expected);
  }

  private indexOfDistance(d: number): number {
    // 复刻 C# List.BinarySearch 的语义：返回首个 >= d 的下标
    let lo = 0;
    let hi = this.cumulativeLength.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (this.cumulativeLength[mid] < d) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  private interpolateVertices(i: number, d: number): Vec2 {
    if (this.calculatedPath.length === 0) {
      return Vec2.ZERO;
    }
    if (i <= 0) {
      return this.calculatedPath[0];
    }
    if (i >= this.calculatedPath.length) {
      return this.calculatedPath[this.calculatedPath.length - 1];
    }

    const p0 = this.calculatedPath[i - 1];
    const p1 = this.calculatedPath[i];
    const d0 = this.cumulativeLength[i - 1];
    const d1 = this.cumulativeLength[i];

    if (Precision.almostEquals(d0, d1)) {
      return p0;
    }

    const w = (d - d0) / (d1 - d0);
    return new Vec2(p0.x + (p1.x - p0.x) * w, p0.y + (p1.y - p0.y) * w);
  }
}
