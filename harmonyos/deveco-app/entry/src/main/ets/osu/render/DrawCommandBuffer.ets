/**
 * 绘制指令缓冲。
 *
 * 每条指令 16 个 float：
 *   type, x, y, w, h, rotation, r, g, b, a, param1, param2, u0, v0, u1, v1
 * 预分配一次，每帧 reset 复用，避免 120Hz 下的 GC 抖动。
 *
 * 为什么 UV 也塞进来而不是按贴图 id 查表：native 侧就完全不需要知道
 * "什么是 hitcircle"，只认"画一块图集子矩形"，规则改动不用动 C++。
 */
export class DrawCommandBuffer {
  static readonly FLOATS_PER_COMMAND: number = 16;

  static readonly RECT: number = 0;
  static readonly CIRCLE: number = 1;
  static readonly RING: number = 2;
  static readonly LINE: number = 3;
  static readonly SPRITE: number = 4;

  private data: Float32Array;
  count: number = 0;
  /**
   * 本帧攒下的贴图指令数。
   *
   * 由缓冲自己数，而不是让渲染器一边画一边加 —— 渲染器里有五处（判定圈底图、
   * 数字、缩圈、滑条球、光标）会发贴图，手写计数迟早漏一处，而这个数是要
   * 和 native 侧收到的指令数对账的，错了会把"贴图没生效"误判成"渲染器没发"。
   */
  spriteCount: number = 0;

  constructor(capacityCommands: number) {
    this.data = new Float32Array(capacityCommands * DrawCommandBuffer.FLOATS_PER_COMMAND);
  }

  reset(): void {
    this.count = 0;
    this.spriteCount = 0;
  }

  get capacity(): number {
    return Math.floor(this.data.length / DrawCommandBuffer.FLOATS_PER_COMMAND);
  }

  push(type: number, x: number, y: number, w: number, h: number, rotation: number,
    colour: number, alpha: number, param1: number = 0, param2: number = 0,
    u0: number = 0, v0: number = 0, u1: number = 0, v1: number = 0): void {
    if (this.count >= this.capacity) {
      return;
    }
    const i = this.count * DrawCommandBuffer.FLOATS_PER_COMMAND;
    const r = ((colour >> 16) & 0xFF) / 255;
    const g = ((colour >> 8) & 0xFF) / 255;
    const b = (colour & 0xFF) / 255;

    this.data[i] = type;
    this.data[i + 1] = x;
    this.data[i + 2] = y;
    this.data[i + 3] = w;
    this.data[i + 4] = h;
    this.data[i + 5] = rotation;
    this.data[i + 6] = r;
    this.data[i + 7] = g;
    this.data[i + 8] = b;
    this.data[i + 9] = alpha;
    this.data[i + 10] = param1;
    this.data[i + 11] = param2;
    this.data[i + 12] = u0;
    this.data[i + 13] = v0;
    this.data[i + 14] = u1;
    this.data[i + 15] = v1;

    this.count++;
  }

  rect(x: number, y: number, w: number, h: number, colour: number, alpha: number): void {
    this.push(DrawCommandBuffer.RECT, x, y, w, h, 0, colour, alpha);
  }

  circle(x: number, y: number, diameter: number, colour: number, alpha: number): void {
    this.push(DrawCommandBuffer.CIRCLE, x, y, diameter, diameter, 0, colour, alpha);
  }

  ring(x: number, y: number, diameter: number, thickness: number, colour: number, alpha: number): void {
    this.push(DrawCommandBuffer.RING, x, y, diameter, diameter, 0, colour, alpha, thickness);
  }

  /** 线段用旋转矩形实现，avoid 额外的 shader 分支 */
  line(x1: number, y1: number, x2: number, y2: number, width: number, colour: number, alpha: number): void {
    const dx = x2 - x1;
    const dy = y2 - y1;
    const length = Math.sqrt(dx * dx + dy * dy);
    if (length < 0.01) {
      return;
    }
    this.push(DrawCommandBuffer.LINE, (x1 + x2) * 0.5, (y1 + y2) * 0.5, length, width, Math.atan2(dy, dx),
      colour, alpha);
  }

  /**
   * 画一块图集子矩形（x,y 是中心，w,h 是完整宽高，rotation 是弧度）。
   * 贴图是白色 + alpha，所以 colour 就是最终着色。
   */
  sprite(x: number, y: number, w: number, h: number, rotation: number,
    colour: number, alpha: number, uv: number[]): void {
    if (uv.length < 4) {
      return;
    }
    if (this.count >= this.capacity) {
      return;
    }
    this.push(DrawCommandBuffer.SPRITE, x, y, w, h, rotation, colour, alpha, 0, 0,
      uv[0], uv[1], uv[2], uv[3]);
    this.spriteCount++;
  }

  /** 同上，但按中心缩放（画 combo 数字、缩圈环时更顺手） */
  spriteScaled(x: number, y: number, w: number, h: number, scale: number, rotation: number,
    colour: number, alpha: number, uv: number[]): void {
    this.sprite(x, y, w * scale, h * scale, rotation, colour, alpha, uv);
  }

  arrayBuffer(): ArrayBuffer {
    return this.data.buffer;
  }
}
