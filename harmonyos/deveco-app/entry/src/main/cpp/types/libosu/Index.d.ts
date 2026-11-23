/**
 * libosu.so 的 ArkTS 类型声明。
 * 渲染线程在 native 侧（vsync 驱动），ArkTS 只读取统计信息与下发控制指令。
 *
 * 注意：不要在这里导出 interface/对象返回值——ArkTS 会把未声明为具体类/接口的
 * 返回值推断成 any，触发 arkts-no-any-unknown 编译错误。全部用扁平的基础类型。
 */

/** 当前实时帧率（每 500ms 更新一次） */
export const getFps: () => number;

/** 累计渲染帧数 */
export const getFrameCount: () => number;

/** XComponent 表面宽度（px） */
export const getSurfaceWidth: () => number;

/** XComponent 表面高度（px） */
export const getSurfaceHeight: () => number;

/** 上一帧的 CPU 侧耗时（ms） */
export const getFrameTime: () => number;

/** 上一帧的 draw call 数 */
export const getDrawCalls: () => number;

/**
 * vsync 实际周期（ms）。16.67 = 屏幕在 60Hz，8.33 = 120Hz。
 * 用来区分"我们渲染慢"和"屏幕被系统降频"。
 */
export const getVsyncPeriod: () => number;

/** SetExpectedFrameRateRange 的返回值，0 表示系统接受高刷请求 */
export const getFrameRateRangeResult: () => number;

/** 暂停 / 恢复场景时间推进（渲染继续） */
export const setPaused: (paused: boolean) => boolean;

/**
 * 诊断状态：0=没收到 XComponent 表面 1=有表面但 EGL 未就绪
 * 2=EGL 就绪但没出帧 3=正在出帧
 */
export const getStatus: () => number;

/** XComponent.onLoad 里调用，注册 native 回调并启动 vsync 循环 */
export const startRender: () => boolean;

/** 把 XComponent.onLoad 的 context 交给 native（注册 native 实例的保底路径） */
export const attachContext: (context: object) => boolean;

/**
 * 提交本帧绘制指令。
 * commands 是 Float32Array 的底层 ArrayBuffer，每条指令 12 个 float：
 *   [type, x, y, w, h, rotation, r, g, b, a, param1, param2]
 *   type 0=矩形 3=线段 1=圆(w=直径) 2=圆环(w=直径, param1=环厚)
 * count 是指令条数（不是 float 个数）。
 */
export const drawFrame: (commands: ArrayBuffer, count: number) => void;

// ---------------------------------------------------------------- 音频

/**
 * 初始化打击音引擎（OHAudio 低延迟渲染）。
 * 先试 AUDIOSTREAM_LATENCY_MODE_FAST，失败自动退回 NORMAL。
 * 返回是否成功拿到可用的 audio renderer。
 */
export const initAudio: (sampleRate: number, channels: number) => boolean;

/** 释放音频流（离开游玩页时调用，避免占用音频焦点） */
export const shutdownAudio: () => void;

/**
 * 触发打击音。kind: 0=normal 1=whistle 2=finish 3=clap
 * volume 0~1。无锁入队，不会阻塞调用线程。
 */
export const playHitSound: (kind: number, volume: number) => void;

/** 设备上报的整链路音频延迟（ms），-1 表示查询失败 */
export const getAudioLatency: () => number;

/** 回调缓冲区时长（ms），即一次写入要多久才播完 = 低延迟的真实下限 */
export const getAudioBufferLatency: () => number;

/** 是否真的跑在 FAST 通路上：1=FAST 0=NORMAL -1=只拿到构建期判断 */
export const getAudioFastStatus: () => number;

/** 累计欠载次数（>0 说明音频线程被饿到了） */
export const getAudioUnderruns: () => number;

/** 已渲染的总帧数，可用于估算音频时钟推进速率 */
export const getAudioFrames: () => number;

/**
 * 上传皮肤图集（RGBA8888）。
 *
 * 解码（PNG → RGBA）在 ArkTS 侧用 image 模块做，这里只排队；
 * 真正的 glTexImage2D 发生在渲染线程的下一帧 —— 因为 GL 上下文在那个线程上。
 */
export const uploadAtlas: (width: number, height: number, pixels: ArrayBuffer) => void;

/** 图集是否已真正上传到 GL：1=是 0=还在排队/没传 */
export const getAtlasUploaded: () => number;

/** 上一帧实际提交的纹理（SPRITE）指令条数，用于区分"没发指令"和"发了没画出来" */
export const getSpriteCommands: () => number;

// ---------------------------------------------------------------- 谱面背景

/**
 * 上传谱面封面（RGBA8888，长边已在 ArkTS 侧降到 1280）。
 *
 * 和皮肤图集是两张独立纹理：封面是彩色图，混进图集会让
 * 圆/滑条这些"纯色图元"采样到封面的像素颜色。
 */
export const uploadBackground: (width: number, height: number, pixels: ArrayBuffer) => void;

/** 卸掉当前封面（换谱、离开游戏页时调，避免上一张残留在下一局） */
export const clearBackground: () => void;

/** 封面是否已真正上传到 GL：1=是 0=没有 */
export const getBackgroundUploaded: () => number;
