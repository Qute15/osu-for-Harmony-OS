import osuNative from 'libosu.so';
import { util } from '@kit.ArkTS';
import { media } from '@kit.MediaKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { fileIo as fs } from '@kit.CoreFileKit';

import { Vec2 } from '../osu/core/Vec2';
import { OsuPlayableBeatmap } from '../osu/ruleset/OsuPlayableBeatmap';
import { OsuPlayfield, JudgementEvent } from '../osu/ruleset/OsuPlayfield';
import { OsuHitObject, Slider, SliderNested, ObjectKind } from '../osu/ruleset/OsuObjects';
import { AutoPlayer, AutoInput } from '../osu/ruleset/OsuAutoPlayer';
import { BeatmapRenderer } from '../osu/render/BeatmapRenderer';
import { DrawCommandBuffer } from '../osu/render/DrawCommandBuffer';
import { HitErrorBar } from '../osu/render/HitErrorBar';
import { SkinAtlas, SpriteName } from '../osu/render/SkinAtlas';
import { HitResult } from '../osu/scoring/HitResult';
import { AudioClock, createMonotonicSource } from '../osu/audio/AudioClock';
import { HitSoundPlayer } from '../osu/audio/HitSoundPlayer';
import { SongLibrary } from '../osu/library/SongLibrary';
import { SongEntry } from '../osu/library/SongEntry';
import { SongBridge } from '../osu/library/SongBridge';
import { ResultHistory, Favourites, ResultRecord, HistoryStats } from '../osu/library/ResultHistory';
import { BeatmapBackground } from '../osu/render/BeatmapBackground';
import { display } from '@kit.ArkUI';

/** 第一个物件前留多少毫秒的预备时间（音乐直接 seek 过去） */
const LEAD_IN_MS = 3000;
/** 最后一个物件结束到弹结算的间隔，留够尾音 */
const END_DELAY_MS = 1600;

/**
 * 游玩页。
 *
 * 分工：
 *   - 时钟：AudioClock（音频位置为主 + 系统单调时间插值 + 漂移校正）
 *   - 判定：OsuPlayfield（纯逻辑，已被 Node 断言覆盖）
 *   - 打击音：native OHAudio 低延迟（按键按下必须马上响）
 *   - 音乐：AVPlayer（解码交给系统，我们只要位置）
 *   - 绘制：ArkTS 算指令 → native 光栅化
 */
@Entry
@Component
struct Play {
  @State fps: number = 0;
  @State combo: number = 0;
  @State accuracy: number = 100;
  @State judged: number = 0;
  @State status: number = 0;
  @State message: string = '载入谱面…';
  @State commandCount: number = 0;
  @State vsyncMs: number = 0;
  @State frameMs: number = 0;

  @State judgementText: string = '';
  @State judgementColor: string = '#FFE9A8';
  @State offsetText: string = '';
  @State meanText: string = '';
  @State progressText: string = '';
  @State audioState: string = '音频未就绪';
  @State skinState: string = '皮肤载入中…';
  @State layoutScale: number = 0;
  @State firstRadius: number = 0;
  @State spriteDraws: number = 0;
  @State nativeSprites: number = 0;
  @State atlasUploaded: number = 0;
  @State autoPlay: boolean = true;
  /** 封面是否已上传到 GL（1 = 已传），HUD 用来确认封面链路通没通 */
  @State bgReady: number = 0;

  // ---- Argon HUD（osu!lazer 2025 默认皮肤）
  /** 屏幕 vp 尺寸：HUD 所有尺寸都按「屏高的百分比」给，换分辨率比例不变 */
  @State vw: number = 948;
  @State vh: number = 420;
  @State scoreValue: number = 0;
  /** 0..1，同时驱动分数条与底部进度条 */
  @State progress01: number = 0;
  @State ppText: string = '0';
  private lastBarRatio: number = -1;
  /** 已重试次数（Argon 暂停页会显示） */
  @State restartCount: number = 0;
  @State timeNow: string = '0:00';
  @State timeTotal: string = '0:00';
  /** 结算页：能力拆解与谱面名（Argon 的三个百分比条） */
  @State skillAim: number = 33;
  @State skillSpeed: number = 33;
  @State skillAcc: number = 34;
  @State songTitle: string = '';
  @State songArtist: string = '';

  // ---- 暂停 / 结算
  @State paused: boolean = false;
  @State finished: boolean = false;
  @State resGrade: string = '';
  @State resGradeColour: string = '#FFFFFF';
  @State resAccuracy: string = '0.00';
  @State resMaxCombo: number = 0;
  @State res300: number = 0;
  @State res100: number = 0;
  @State res50: number = 0;
  @State resMiss: number = 0;
  @State resScore: number = 0;
  @State resFav: boolean = false;
  @State exportTip: string = '';
  // Overall Ranking 面板（本地存档统计，不是服务器排行）
  @State rankOverall: number = 0;
  @State rankOverallTotal: number = 0;
  @State rankMapRank: number = 0;
  @State rankMapPlays: number = 0;
  @State rankMapBest: number = 0;

  private beatmap: OsuPlayableBeatmap | null = null;
  private playfield: OsuPlayfield | null = null;
  private renderer: BeatmapRenderer | null = null;
  private cmds: DrawCommandBuffer = new DrawCommandBuffer(9000);
  private cursor: Vec2 = new Vec2(256, 192);
  private hasCursor: boolean = false;

  private clock: AudioClock = new AudioClock(
    createMonotonicSource(() => systemDateTime.getUptime(systemDateTime.TimeType.STARTUP)));
  private sfx: HitSoundPlayer = new HitSoundPlayer((kind: number, volume: number) => {
    osuNative.playHitSound(kind, volume);
  });
  private errorBar: HitErrorBar = new HitErrorBar();
  private history: ResultHistory = new ResultHistory();
  private favs: Favourites = new Favourites();
  /** 谱面标识，用于「本谱第几次打 / 本谱最佳 / 收藏」，格式 `artist - title`。 */
  private mapKey: string = '';
  private auto: AutoPlayer = new AutoPlayer();

  private player: media.AVPlayer | null = null;
  private audioFd: number = -1;
  /** 0 = rawfile 内建测试谱，1 = 歌库里的文件 */
  private audioKind: number = 0;
  /** 音频来源：kind=0 时是 rawfile 名，kind=1 时是绝对路径 */
  private audioRef: string = 'demo-audio.mp3';
  private songId: string = '';
  private sourceLabel: string = '内置测试谱 Renatus [Insane]';
  /** 谱面封面的绝对路径，空串表示这张谱没带背景图 */
  private backgroundPath: string = '';
  private mapStart: number = 0;
  private audioOk: boolean = false;

  private frameTimer: number = -1;
  private hudTimer: number = -1;
  private judgementTimer: number = -1;
  private logTick: number = 0;
  private timeUpdateCount: number = 0;

  /** 分数面板（含上方那条发光折线），一次 Canvas 里画完 */
  private hudSettings: RenderingContextSettings = new RenderingContextSettings(true);
  private scoreCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.hudSettings);
  /** 暂停页三根斜条：Canvas 画平行四边形，Text 叠在上面 */
  private pauseCtx: CanvasRenderingContext2D[] = [
    new CanvasRenderingContext2D(this.hudSettings),
    new CanvasRenderingContext2D(this.hudSettings),
    new CanvasRenderingContext2D(this.hudSettings)
  ];
  /** 结算页：等级环 / 判定直方图 / 散布图 */
  private ringCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.hudSettings);
  private histCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.hudSettings);
  private heatCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.hudSettings);

  aboutToAppear(): void {
    // 页面可能被复用（退出再进），这些瞬态必须清掉
    this.finished = false;
    this.paused = false;
    this.scoreValue = 0;
    this.progress01 = 0;
    this.lastBarRatio = -1;
    this.measureScreen();
    const dir: string = getContext(this).filesDir;
    this.history.load(dir);
    this.favs.load(dir);
    this.audioOk = osuNative.initAudio(48000, 2);
    this.bootstrap();
  }

  /**
   * HUD 用「屏高百分比」而不是 UiScale：Argon 的 HUD 是按屏幕比例铺的
   * （lazer 自己也是 RelativeSizeAxes），量出来的比例直接乘 vp 尺寸即可。
   */
  private measureScreen(): void {
    try {
      const d = display.getDefaultDisplaySync();
      const density = d.densityPixels > 0 ? d.densityPixels : 3;
      this.vw = d.width / density;
      this.vh = d.height / density;
    } catch (err) {
      this.vw = 948;
      this.vh = 420;
    }
  }

  /**
   * 皮肤图集要解码 + 上传纹理，必须等它落位再开帧循环，
   * 否则前几百毫秒会用矢量画法、然后突然切贴图（画面闪一下）。
   * 图集失败不影响游玩，BeatmapRenderer 会一直用矢量画法。
   */
  private async bootstrap(): Promise<void> {
    const ok = await SkinAtlas.load(getContext(this).resourceManager);
    if (!ok) {
      hilog.warn(0x0F0F, 'OSU-SKIN', 'atlas unavailable, falling back to vector drawing');
    }
    // 图集加载成功不代表查表成功，这里直接验一次 UV 是否真的能取到
    const check = SkinAtlas.uv('hitcircle');
    hilog.info(0x0F0F, 'OSU-SKIN',
      'bootstrap ok=%{public}s loaded=%{public}s hitcircleUV=%{public}d digit5UV=%{public}d spriteName=[%{public}s] uvByConst=%{public}d size=%{public}dx%{public}d',
      String(ok), String(SkinAtlas.loaded), check.length, SkinAtlas.digitUV(5).length,
      String(SpriteName.HITCIRCLE), SkinAtlas.uv(SpriteName.HITCIRCLE).length,
      SkinAtlas.textureWidth, SkinAtlas.textureHeight);
    this.skinState = ok ? `皮肤 图集${SkinAtlas.textureWidth}x${SkinAtlas.textureHeight}` : '皮肤 矢量（图集缺失）';
    this.loadBeatmap();
  }

  aboutToDisappear(): void {
    if (this.frameTimer >= 0) {
      clearInterval(this.frameTimer);
      this.frameTimer = -1;
    }
    if (this.hudTimer >= 0) {
      clearInterval(this.hudTimer);
      this.hudTimer = -1;
    }
    if (this.judgementTimer >= 0) {
      clearTimeout(this.judgementTimer);
      this.judgementTimer = -1;
    }
    this.stopAudio();
    osuNative.shutdownAudio();
    // 封面纹理跟着这一局释放，否则下一首歌开局会先闪一下上一张
    BeatmapBackground.clear();
    this.bgReady = 0;
  }

  onPageHide(): void {
    hilog.info(0x0F0F, 'OSU-PLAY', 'onPageHide -> 暂停时钟');
    this.clock.stop();
    if (this.player !== null) {
      try {
        this.player.pause();
      } catch (err) {
        // 状态机不允许时忽略
      }
    }
  }

  // ------------------------------------------------------------------ 载入

  /**
   * 谱面封面（lazer 的 BackgroundScreenBeatmap）。
   * 渲染器把它铺满全屏、按 DimLevel 压暗，Playfield 叠在上面。
   */
  private async applyBackground(): Promise<void> {
    const ok = await BeatmapBackground.load(this.backgroundPath);
    this.bgReady = osuNative.getBackgroundUploaded();
    hilog.info(0x0F0F, 'OSU-BG', 'apply ok=%{public}s uploaded=%{public}d path=[%{public}s]',
      String(ok), this.bgReady, this.backgroundPath);
  }

  private loadBeatmap(): void {
    try {
      const text = this.readBeatmapText();

      const beatmap = OsuPlayableBeatmap.fromOsuText(text);
      this.beatmap = beatmap;
      this.playfield = new OsuPlayfield(beatmap);
      this.renderer = new BeatmapRenderer(beatmap);
      this.message = `${this.sourceLabel}  ${beatmap.hitObjects.length} 物件 / maxCombo ${beatmap.maxCombo}`;

      // 从第一个物件前 3 秒开始，省掉原曲漫长的前奏
      const first = beatmap.hitObjects.length > 0 ? beatmap.hitObjects[0].startTime : 0;
      this.mapStart = Math.max(0, first - LEAD_IN_MS);

      this.errorBar.reset();
      this.prepareAudio();
      // 解码 + 上传封面：不阻塞开帧，几百毫秒内会自己出现。
      // 没背景就是没有，不挡游玩。
      this.applyBackground();
    } catch (err) {
      this.message = `谱面载入失败: ${err}`;
      return;
    }

    this.hudTimer = setInterval(() => {
      this.fps = osuNative.getFps();
      this.status = osuNative.getStatus();
      // 纹理是下一帧才在 GL 线程上传的，所以这个值必须在定时器里轮询，
      // 不能在上传调用之后立刻读（那时永远是 0）。
      this.bgReady = osuNative.getBackgroundUploaded();
      this.commandCount = this.cmds.count;
      this.vsyncMs = osuNative.getVsyncPeriod();
      this.frameMs = osuNative.getFrameTime();
      const pf = this.playfield;
      if (pf !== null) {
        this.combo = pf.combo();
        this.accuracy = pf.accuracy() * 100;
        this.judged = pf.score.mainJudged;
        this.scoreValue = pf.score.score();
        this.ppText = `${Math.max(0, Math.round(this.accuracy - 80) * 3)}`;
      }
      const rd = this.renderer;
      if (rd !== null && this.beatmap !== null && this.beatmap.hitObjects.length > 0) {
        this.layoutScale = rd.layout.scale;
        this.firstRadius = this.beatmap.hitObjects[0].radius();
        this.spriteDraws = rd.spriteDraws;
      }
      // 这两个值必须走 @State：Text 里直接调 native 函数不会建立依赖，
      // ArkUI 会把那行当成静态内容，永远停在首帧的值（0）。
      this.nativeSprites = osuNative.getSpriteCommands();
      this.atlasUploaded = osuNative.getAtlasUploaded();
      if (this.errorBar.count > 0) {
        this.meanText = `均值 ${this.errorBar.mean().toFixed(1)}ms  平均绝对 ${this.errorBar.meanAbs().toFixed(1)}ms`;
      }
      const total = this.beatmap !== null ? this.beatmap.length() : 0;
      if (total > 0) {
        const p = Math.min(100, Math.max(0, this.clock.now() / total * 100));
        this.progressText = `${this.fmt(this.clock.now())} / ${this.fmt(total)}  (${p.toFixed(0)}%)`;
        this.progress01 = p / 100;
        this.timeNow = this.fmt(this.clock.now());
        this.timeTotal = this.fmt(total);
      }
      // 分数条的亮度按歌曲进度走（lazer 的 ScoreCounter 也是这么填的）。
      // 每 2% 重画一次，没必要每帧重绘一条折线。
      const ratio = Math.round(this.progress01 * 50) / 50;
      if (ratio !== this.lastBarRatio) {
        this.lastBarRatio = ratio;
        this.drawScorePanel();
      }
      if (this.audioOk) {
        this.audioState = `音频 FAST=${osuNative.getAudioFastStatus()} ` +
          `buf ${osuNative.getAudioBufferLatency().toFixed(1)}ms ` +
          `route ${osuNative.getAudioLatency().toFixed(1)}ms ` +
          `欠载 ${osuNative.getAudioUnderruns()}`;
      } else {
        this.audioState = '打击音引擎初始化失败';
      }

      // 时钟诊断：每秒一条，确认 game time 是否跟着音频走
      this.logTick++;
      if (this.logTick % 7 === 0) {
        const p = this.player;
        hilog.info(0x0F0F, 'OSU-PLAY',
          'clock=%{public}d err=%{public}d audio=%{public}d upd=%{public}d corr=%{public}d snap=%{public}d judged=%{public}d state=%{public}s',
          Math.round(this.clock.now()), Math.round(this.clock.error),
          Math.round(this.clock.lastAudioMs), this.clock.updateCount,
          this.clock.corrections, this.clock.snaps, this.judged,
          p !== null ? p.state : 'none');
      }
    }, 150);

    this.frameTimer = setInterval(() => {
      this.tick();
    }, 8);
  }

  private fmt(ms: number): string {
    const total = Math.max(0, Math.floor(ms / 1000));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  /**
   * 谱面标识。收藏与历史都按这个 key 存，所以只要 title/artist 变了就得重建。
   * 没接服务器，只能用这种方法当主键。
   */
  private rebuildMapKey(): void {
    const artist: string = this.songArtist.length > 0 ? this.songArtist : 'unknown';
    const title: string = this.songTitle.length > 0 ? this.songTitle : 'unknown';
    this.mapKey = `${artist} - ${title}`;
    this.resFav = this.favs.has(this.mapKey);
  }

  /**
   * 决定这次玩哪张谱：优先用选歌页传来的 songId + osuFile，找不到就回退到内建测试谱。
   * 同时把音频来源也定好（rawfile 还是沙箱文件）。
   */
  private readBeatmapText(): string {
    const id = SongBridge.currentId();
    const file = SongBridge.currentFile();
    this.songId = id;

    if (id.length > 0) {
      const lib = new SongLibrary(getContext(this).filesDir);
      lib.load();
      const entry: SongEntry | null = lib.getByIdAndFile(id, file);
      if (entry !== null) {
        this.audioKind = entry.audioFile.length > 0 ? 1 : 2; // 2 = 有谱面没音频
        this.audioRef = entry.audioFile.length > 0 ? lib.audioPath(entry) : '';
        this.backgroundPath = lib.backgroundPath(entry);
        this.songTitle = entry.title;
        this.songArtist = entry.artist;
        this.sourceLabel = `${entry.displayTitle()} [${entry.version}]`;
        this.rebuildMapKey();
        hilog.info(0x0F0F, 'OSU-PLAY', 'load from library: %{public}s', lib.osuPath(entry));
        return fs.readTextSync(lib.osuPath(entry));
      }
      hilog.warn(0x0F0F, 'OSU-PLAY', 'song %{public}s not found, fallback to builtin', id);
      this.sourceLabel = '内置测试谱 Renatus [Insane]（请求的谱面不存在）';
    }

    this.audioKind = 0;
    this.audioRef = 'demo-audio.mp3';
    this.backgroundPath = '';
    this.songTitle = 'Renatus';
    this.songArtist = 'Soleily';
    this.rebuildMapKey();
    if (id.length === 0) {
      this.sourceLabel = '内置测试谱 Renatus [Insane]';
    }
    const bytes: Uint8Array = getContext(this).resourceManager.getRawFileContentSync('demo.osu');
    return util.TextDecoder.create('utf-8').decodeToString(bytes);
  }

  // ------------------------------------------------------------------ 音频

  private async prepareAudio(): Promise<void> {
    if (this.audioKind === 2) {
      this.audioState = '这张谱没有音频，用系统时钟';
      this.fallbackClock();
      return;
    }

    try {
      let fd = -1;
      let offset = 0;
      let length = 0;

      if (this.audioKind === 0) {
        const rawFd = getContext(this).resourceManager.getRawFdSync(this.audioRef);
        fd = rawFd.fd;
        offset = rawFd.offset;
        length = rawFd.length;
      } else {
        const stat = fs.statSync(this.audioRef);
        const file = fs.openSync(this.audioRef, fs.OpenMode.READ_ONLY);
        this.audioFd = file.fd;
        fd = file.fd;
        length = stat.size;
      }

      const player = await media.createAVPlayer();
      this.player = player;

      player.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          player.prepare();
        } else if (state === 'prepared') {
          // 先在 prepared 状态下 seek，seekDone 之后再开播，保证时钟锚点准确
          player.seek(this.mapStart, media.SeekMode.SEEK_CLOSEST);
        } else if (state === 'playing') {
          this.audioState = '音频播放中';
        } else if (state === 'completed') {
          this.audioState = '音频结束';
        }
      });

      player.on('seekDone', (seekTime: number) => {
        if (!this.clock.isRunning) {
          this.clock.start(seekTime);
          player.play();
        }
      });

      player.on('timeUpdate', (time: number) => {
        // AVPlayer 的位置是谱面时间的唯一权威来源
        this.timeUpdateCount++;
        if (this.timeUpdateCount <= 6 || this.timeUpdateCount % 500 === 0) {
          hilog.info(0x0F0F, 'OSU-PLAY', 'timeUpdate #%{public}d raw=%{public}d',
            this.timeUpdateCount, Math.round(time * 100));
        }
        this.clock.update(time);
      });

      player.on('error', (err: BusinessError) => {
        this.audioState = `音频错误 ${err.code}`;
        this.fallbackClock();
      });

      player.fdSrc = { fd: fd, offset: offset, length: length };
    } catch (err) {
      this.audioState = `音频载入失败: ${err}`;
      this.fallbackClock();
    }
  }

  /** 音频不可用时退回纯系统时钟，至少让谱面能跑 */
  private fallbackClock(): void {
    if (!this.clock.isRunning) {
      this.clock.start(this.mapStart);
    }
  }

  private stopAudio(): void {
    const player = this.player;
    this.player = null;
    if (player !== null) {
      try {
        player.release();
      } catch (err) {
        // 已经释放过
      }
    }
    if (this.audioKind === 0) {
      try {
        getContext(this).resourceManager.closeRawFd(this.audioRef);
      } catch (err) {
        // ignore
      }
    } else if (this.audioFd >= 0) {
      try {
        fs.closeSync(this.audioFd);
      } catch (err) {
        // ignore
      }
    }
    this.audioFd = -1;
  }

  // ------------------------------------------------------------------ 循环

  private restart(): void {
    const beatmap = this.beatmap;
    if (beatmap === null) {
      return;
    }
    this.restartCount++;
    this.scoreValue = 0;
    this.progress01 = 0;
    this.lastBarRatio = -1;
    this.playfield = new OsuPlayfield(beatmap);
    this.errorBar.reset();
    this.auto.reset();
    this.hasCursor = false;
    this.judgementText = '';
    this.offsetText = '';
    this.meanText = '';
    this.finished = false;
    this.paused = false;

    const player = this.player;
    if (player !== null) {
      try {
        player.seek(this.mapStart, media.SeekMode.SEEK_CLOSEST);
        this.clock.resync(this.mapStart);
        player.play();
        return;
      } catch (err) {
        // 掉到下面的兜底
      }
    }
    this.clock.start(this.mapStart);
  }

  // -------------------------------------------------------------- 暂停 / 结算

  private pauseGame(): void {
    if (this.paused || this.finished) {
      return;
    }
    this.paused = true;
    this.clock.stop();
    const player = this.player;
    if (player !== null) {
      try {
        player.pause();
      } catch (err) {
        // 已经停下的状态机再 pause 会抛，忽略
      }
    }
  }

  private resumeGame(): void {
    if (!this.paused) {
      return;
    }
    this.paused = false;
    this.clock.resume();
    const player = this.player;
    if (player !== null) {
      try {
        player.play();
      } catch (err) {
        // 音频已经放完就只靠时钟走
      }
    }
  }

  private exitToSelect(): void {
    this.getUIContext().getRouter().back();
  }

  /** 本次分数相对本谱历史最佳的百分比，给 Overall Ranking 的比例条用。 */
  private bestRatio(): number {
    if (this.rankMapBest <= 0) {
      return 0;
    }
    const r: number = this.resScore / this.rankMapBest * 100;
    return Math.max(0, Math.min(100, r));
  }

  /** 心形 Path 的 commands，按按钮图标尺寸实时算（Path 的坐标是 vp，不会自动缩放）。 */
  private heartPath(): string {
    const s = this.hudY(0.040);
    const pt = (x: number, y: number): string => `${(s * x).toFixed(2)} ${(s * y).toFixed(2)}`;
    // 标准心形：底部尖角 → 左半圆鼓包 → 顶部凹口 → 右半圆鼓包 → 回到尖角
    return `M ${pt(0.5, 0.95)} ` +
      `C ${pt(0.18, 0.72)} ${pt(0.0, 0.52)} ${pt(0.0, 0.30)} ` +
      `C ${pt(0.0, 0.11)} ${pt(0.14, 0.0)} ${pt(0.29, 0.0)} ` +
      `C ${pt(0.40, 0.0)} ${pt(0.47, 0.06)} ${pt(0.5, 0.15)} ` +
      `C ${pt(0.53, 0.06)} ${pt(0.60, 0.0)} ${pt(0.71, 0.0)} ` +
      `C ${pt(0.86, 0.0)} ${pt(1.0, 0.11)} ${pt(1.0, 0.30)} ` +
      `C ${pt(1.0, 0.52)} ${pt(0.82, 0.72)} ${pt(0.5, 0.95)} Z`;
  }

  /** 把本局成绩落成一个 json，方便从 Device File Explorer 里捞出来核对。 */
  private exportResult(): void {
    try {
      const dir = `${getContext(this).filesDir}/results`;
      try {
        fs.mkdirSync(dir);
      } catch (mkErr) {
        // 目录已存在时 mkdirSync 抛错，忽略。
      }
      const path = `${dir}/last-result.json`;
      const payload: Record<string, Object> = {
        'title': this.songTitle,
        'artist': this.songArtist,
        'score': this.resScore,
        'accuracy': this.resAccuracy,
        'grade': this.resGrade,
        'maxCombo': this.resMaxCombo,
        'count300': this.res300,
        'count100': this.res100,
        'count50': this.res50,
        'countMiss': this.resMiss,
        'pp': this.ppText,
        'unstableRate': this.errorBar.unstableRate().toFixed(2),
        'autoPlay': this.autoPlay,
        'localRank': this.rankOverall,
        'localTotal': this.rankOverallTotal,
        'mapBest': this.rankMapBest,
        'mapRank': this.rankMapRank,
        'mapPlays': this.rankMapPlays,
        'favourited': this.resFav,
        'exportedAt': new Date().toISOString()
      };
      const file = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, JSON.stringify(payload, null, 2));
      fs.closeSync(file);
      this.exportTip = `已导出 results/last-result.json`;
    } catch (err) {
      const e = err as BusinessError;
      hilog.error(0x0000, 'osu', 'export failed: %{public}s', `${e.message}`);
      this.exportTip = '导出失败';
    }
    setTimeout(() => {
      this.exportTip = '';
    }, 2600);
  }

  /**
   * 一局结束。
   *
   * 注意判定引擎自己有 finished 标记（所有物件都判完），但谱面最后一个
   * 物件结束之后往往还有尾音，所以额外等 END_DELAY_MS 再弹结算，
   * 否则玩家刚打完最后一个滑条就被糊一脸面板。
   */
  /**
   * 结算页的「能力拆解」。
   *
   * lazer 真实值来自 strain 计算（Aim/Speed skill 的 PP 贡献）。
   * 我们没做 strain 图，所以这里用三个可解释的近似量再归一化：
   *   - Aim：准确率 × 连击保持率（打飞得越少越接近满分）
   *   - Speed：不稳定率越低越高（UR 是手速稳定性的直接指标）
   *   - Accuracy：就是准确率本身
   * 三者归一化成 100%，和 Argon 面板的百分比语义一致（占比，不是分数）。
   */
  private computeSkillBreakdown(acc: number): void {
    const objects = this.beatmap !== null ? this.beatmap.hitObjects.length : 0;
    const comboRatio = objects > 0 ? Math.min(1, this.resMaxCombo / objects) : 0;
    const ur = this.errorBar.unstableRate();
    const rawAim = Math.max(0.01, (acc / 100) * (0.45 + 0.55 * comboRatio));
    const rawSpeed = Math.max(0.01, Math.min(1, 260 / Math.max(20, ur)));
    const rawAcc = Math.max(0.01, acc / 100);
    const sum = rawAim + rawSpeed + rawAcc;
    this.skillAim = rawAim / sum * 100;
    this.skillSpeed = rawSpeed / sum * 100;
    this.skillAcc = rawAcc / sum * 100;
  }

  private finishRun(): void {
    if (this.finished) {
      return;
    }
    this.finished = true;
    this.paused = false;
    this.clock.stop();
    const player = this.player;
    if (player !== null) {
      try {
        player.pause();
      } catch (err) {
        // 忽略
      }
    }

    const pf = this.playfield;
    if (pf === null) {
      return;
    }
    const score = pf.score;
    this.res300 = score.count(HitResult.GREAT);
    this.res100 = score.count(HitResult.OK);
    this.res50 = score.count(HitResult.MEH);
    this.resMiss = score.count(HitResult.MISS);
    this.resMaxCombo = score.maxCombo;
    this.resScore = score.score();

    const acc = pf.accuracy() * 100;
    this.resAccuracy = acc.toFixed(2);
    this.resGrade = this.gradeFor(acc, this.res300, this.res100, this.res50, this.resMiss);
    this.resGradeColour = this.gradeColour(this.resGrade);
    this.computeSkillBreakdown(acc);
    hilog.info(0x0F0F, 'OSU-PLAY',
      'finished: grade=%{public}s acc=%{public}s maxCombo=%{public}d 300=%{public}d 100=%{public}d 50=%{public}d miss=%{public}d',
      this.resGrade, this.resAccuracy, this.resMaxCombo, this.res300, this.res100, this.res50, this.resMiss);

    // pp 先按跟 HUD 同一个口径算死，别指望 150ms 定时器已经刷过
    this.ppText = `${Math.max(0, Math.round(acc - 80) * 3)}`;

    // 落一条历史，给结算页的 Overall Ranking 面板用（本地存档，不是服务器排行）
    const rec: ResultRecord = {
      key: this.mapKey,
      score: this.resScore,
      accuracy: acc,
      pp: Math.max(0, Math.round(acc - 80) * 3),
      grade: this.resGrade,
      time: new Date().getTime()
    };
    const stats: HistoryStats = this.history.add(rec);
    this.rankOverall = stats.overallRank;
    this.rankOverallTotal = stats.overallTotal;
    this.rankMapRank = stats.mapRank;
    this.rankMapPlays = stats.mapPlays;
    this.rankMapBest = stats.mapBest;
    hilog.info(0x0F0F, 'OSU-PLAY', 'local rank: %{public}d/%{public}d  map: %{public}d/%{public}d',
      stats.overallRank, stats.overallTotal, stats.mapRank, stats.mapPlays);
  }

  /** stable 的评级口径：全 300 才是 SS，其余按准确率分档 */
  private gradeFor(acc: number, c300: number, c100: number, c50: number, miss: number): string {
    if (miss === 0 && c100 === 0 && c50 === 0 && c300 > 0) {
      return 'SS';
    }
    if (acc >= 90) {
      return 'S';
    }
    if (acc >= 80) {
      return 'A';
    }
    if (acc >= 70) {
      return 'B';
    }
    if (acc >= 60) {
      return 'C';
    }
    return 'D';
  }

  private gradeColour(grade: string): string {
    switch (grade) {
      case 'SS':
        return '#FFE9A8';
      case 'S':
        return '#FFD45E';
      case 'A':
        return '#66E0A0';
      case 'B':
        return '#7FD4FF';
      case 'C':
        return '#CC99FF';
      default:
        return '#FF5566';
    }
  }

  /** 音频整体偏移（ms）。正值 = 谱面提前，可抵消蓝牙耳机之类的输出延迟 */
  private setOffset(ms: number): void {
    this.clock.setOffset(ms);
    this.offsetText = `偏移 ${this.clock.offset}ms`;
  }

  private tick(): void {
    const renderer = this.renderer;
    const playfield = this.playfield;
    const beatmap = this.beatmap;
    if (renderer === null || playfield === null || beatmap === null) {
      return;
    }
    // 暂停/结算时整个循环停掉：画面留在最后一帧，判定不再推进
    if (this.paused || this.finished) {
      return;
    }

    const surfaceWidth = osuNative.getSurfaceWidth();
    const surfaceHeight = osuNative.getSurfaceHeight();
    if (surfaceWidth > 0 && surfaceHeight > 0) {
      renderer.layout.update(surfaceWidth, surfaceHeight);
    }

    const time = this.clock.now();

    // 自动游玩和触屏共用同一条 press/move/release 路径
    let cursor = this.cursor;
    let hasCursor = this.hasCursor;
    let autoInput: AutoInput | null = null;
    if (this.autoPlay) {
      autoInput = this.auto.update(beatmap, time);
      cursor = autoInput.cursor;
      hasCursor = true;
      this.cursor = cursor;
    }

    const events: JudgementEvent[] = [];
    const updated = playfield.update(time, hasCursor ? cursor : null);
    for (let i = 0; i < updated.length; i++) {
      events.push(updated[i]);
    }

    if (autoInput !== null) {
      if (autoInput.press) {
        const pressed = playfield.press(time, cursor);
        for (let i = 0; i < pressed.length; i++) {
          events.push(pressed[i]);
        }
      } else if (autoInput.release) {
        const released = playfield.release(time);
        for (let i = 0; i < released.length; i++) {
          events.push(released[i]);
        }
      } else {
        playfield.move(time, cursor);
      }
    }

    for (let i = 0; i < events.length; i++) {
      this.onJudgement(events[i], renderer, time);
    }

    this.cmds.reset();
    // 封面纹理真上去了才让出底色；没上去时保持原来的不透明底，不会黑场
    renderer.useBackground = this.bgReady === 1;
    renderer.draw(this.cmds, time, cursor, hasCursor);
    this.errorBar.draw(this.cmds, renderer.layout, time);
    osuNative.drawFrame(this.cmds.arrayBuffer(), this.cmds.count);

    // 谱面尾音过完就结算
    if (time > beatmap.length() + END_DELAY_MS) {
      this.finishRun();
    }
  }

  private objectAt(index: number): OsuHitObject | null {
    const beatmap = this.beatmap;
    if (beatmap === null || index < 0 || index >= beatmap.hitObjects.length) {
      return null;
    }
    return beatmap.hitObjects[index];
  }

  private onJudgement(event: JudgementEvent, renderer: BeatmapRenderer, time: number): void {
    const obj = this.objectAt(event.objectIndex);

    // ---- 视觉反馈
    if (event.result === HitResult.GREAT) {
      renderer.addFlash(event.position, event.time, true);
    } else if (event.result === HitResult.MISS) {
      renderer.addFlash(event.position, event.time, false);
    }

    // ---- 打击音
    if (event.kind === 'tick' || event.kind === 'repeat') {
      const slider = obj !== null && obj.kind === ObjectKind.SLIDER ? obj as Slider : null;
      const nested = slider !== null && event.nestedIndex >= 0 && event.nestedIndex < slider.nested.length
        ? slider.nested[event.nestedIndex] : null;
      this.sfx.playForNested(nested, obj);
    } else if (event.kind === 'tail') {
      // 尾判不发声，和 stable 一致
    } else {
      this.sfx.playForResult(event.result, obj);
    }

    // ---- HUD 文本 + 偏差条
    if (event.kind === 'head' || event.kind === 'spinner') {
      if (Number.isFinite(event.offset)) {
        this.errorBar.add(event.offset, event.result, time);
      }
      this.showJudgement(event);
    }
  }

  private showJudgement(event: JudgementEvent): void {
    let text = '';
    let colour = '#FFE9A8';
    switch (event.result) {
      case HitResult.GREAT:
        text = '300';
        colour = '#66E0A0';
        break;
      case HitResult.OK:
        text = '100';
        colour = '#7FD4FF';
        break;
      case HitResult.MEH:
        text = '50';
        colour = '#FFD45E';
        break;
      case HitResult.MISS:
        text = 'X';
        colour = '#FF5566';
        break;
      default:
        return;
    }

    this.judgementText = text;
    this.judgementColor = colour;

    if (this.judgementTimer >= 0) {
      clearTimeout(this.judgementTimer);
    }
    this.judgementTimer = setTimeout(() => {
      this.judgementText = '';
    }, 420);
  }

  // ------------------------------------------------------------ Argon HUD

  private hudX(f: number): number {
    return this.vw * f;
  }

  private hudY(f: number): number {
    return this.vh * f;
  }

  /** 圆角矩形路径：ArkUI 的 Canvas 没有 roundRect，用 arc 拼 */
  private roundRectPath(c: CanvasRenderingContext2D, x: number, y: number, w: number, h: number,
    r: number): void {
    c.beginPath();
    c.moveTo(x + r, y);
    c.lineTo(x + w - r, y);
    c.arc(x + w - r, y + r, r, -Math.PI * 0.5, 0);
    c.lineTo(x + w, y + h - r);
    c.arc(x + w - r, y + h - r, r, 0, Math.PI * 0.5);
    c.lineTo(x + r, y + h);
    c.arc(x + r, y + h - r, r, Math.PI * 0.5, Math.PI);
    c.lineTo(x, y + r);
    c.arc(x + r, y + r, r, Math.PI, Math.PI * 1.5);
    c.closePath();
  }

  /**
   * 分数面板 + 上方那条「曲棍球杆」发光条（Argon 的 ScoreCounter）。
   *
   * 形状是固定几何：水平走 78% 然后 45° 折下来收圆头；
   * 亮的长度跟歌曲进度走，剩下的部分画成半透明白。
   * 整个面板一个 Canvas 画完，重绘只在进度每 2% 变化时触发。
   */
  private drawScorePanel(): void {
    const c = this.scoreCtx;
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);

    // 面板：半透明深青，顶部一条更亮的细边（Argon 的玻璃质感）
    this.roundRectPath(c, 0, 0, w, h, h * 0.22);
    c.fillStyle = 'rgba(18,44,42,0.46)';
    c.fill();
    c.strokeStyle = 'rgba(210,255,246,0.16)';
    c.lineWidth = 1;
    c.stroke();

    // 折线几何
    const bx = w * 0.06;
    const by = h * 0.30;
    const bendX = bx + w * 0.70;
    const tail = h * 0.30;
    const total = (bendX - bx) + tail;
    const lit = Math.max(0, Math.min(1, this.progress01)) * total;

    c.lineCap = 'round';
    c.lineJoin = 'round';

    // 暗底：未完成的部分
    c.lineWidth = h * 0.085;
    c.strokeStyle = 'rgba(230,255,250,0.22)';
    c.beginPath();
    c.moveTo(bx, by);
    c.lineTo(bendX, by);
    c.lineTo(bendX + tail, by + tail);
    c.stroke();

    // 亮段：沿折线截取 lit 长度，带白色外发光
    c.save();
    c.shadowColor = '#FFFFFF';
    c.shadowBlur = h * 0.22;
    c.strokeStyle = '#FFFFFF';
    c.beginPath();
    c.moveTo(bx, by);
    if (lit <= bendX - bx) {
      c.lineTo(bx + lit, by);
    } else {
      c.lineTo(bendX, by);
      const rest = lit - (bendX - bx);
      c.lineTo(bendX + rest, by + rest);
    }
    c.stroke();
    c.restore();
  }

  /** 暂停页的斜条：Argon 的 pause 按钮是平行四边形 + 细三角纹理 */
  private drawPauseBar(index: number): void {
    const c = this.pauseCtx[index];
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);
    const skew = h * 0.30;
    const colours: string[] = ['#88B200', '#EDAB01', '#A91B25'];
    c.fillStyle = colours[index];
    c.beginPath();
    c.moveTo(skew, 0);
    c.lineTo(w, 0);
    c.lineTo(w - skew, h);
    c.lineTo(0, h);
    c.closePath();
    c.fill();

    // 内部三角装饰（很淡，只为了不是一块死色）
    c.strokeStyle = 'rgba(255,255,255,0.10)';
    c.lineWidth = 1;
    for (let i = 0; i < 4; i++) {
      const x = w * (0.16 + i * 0.21);
      c.beginPath();
      c.moveTo(x, h * 0.16);
      c.lineTo(x + h * 0.42, h * 0.86);
      c.lineTo(x - h * 0.42, h * 0.86);
      c.closePath();
      c.stroke();
    }
  }

  @Builder
  pauseBar(index: number, label: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Canvas(this.pauseCtx[index])
        .width(this.hudX(0.695))
        .height(this.hudY(0.150))
        .onReady(() => {
          this.drawPauseBar(index);
        })
      Text(label)
        .fontSize(this.hudY(0.026))
        .fontWeight(FontWeight.Medium)
        .fontColor('#FFFFFF')
    }
    .width(this.hudX(0.695))
    .height(this.hudY(0.150))
    .onClick(action)
  }

  @Builder
  devButton(label: string, active: boolean, action: () => void) {
    Text(label)
      .fontSize(this.hudY(0.020))
      .fontColor(active ? '#12121A' : '#DDDDE8')
      .backgroundColor(active ? '#FF66AA' : '#33FFFFFF')
      .borderRadius(2)
      .padding({
        left: this.hudY(0.016), right: this.hudY(0.016),
        top: this.hudY(0.008), bottom: this.hudY(0.008)
      })
      .onClick(action)
  }

  /** 整套 Argon 游戏内 HUD */
  @Builder
  argonHud() {
    Stack({ alignContent: Alignment.TopStart }) {
      // ---- 左上：分数面板（数字叠在 Canvas 面板上）
      Stack({ alignContent: Alignment.TopStart }) {
        Canvas(this.scoreCtx)
          .width(this.hudX(0.215))
          .height(this.hudY(0.108))
          .onReady(() => {
            this.drawScorePanel();
          })
        Text(`${this.scoreValue}`)
          .fontSize(this.hudY(0.052))
          .fontWeight(FontWeight.Bold)
          .fontColor('#F4FAFA')
          .letterSpacing(1.5)
          .position({ x: this.hudX(0.030), y: this.hudY(0.046) })
      }
      .width(this.hudX(0.215))
      .height(this.hudY(0.108))
      .position({ x: this.hudX(0.030), y: this.hudY(0.020) })

      // ---- 右上：准确率 + pp
      Column({ space: this.hudY(0.002) }) {
        Text('准确率')
          .fontSize(this.hudY(0.020))
          .fontColor('#8FC7E8')
        Text(`${this.accuracy.toFixed(2)}%`)
          .fontSize(this.hudY(0.050))
          .fontWeight(FontWeight.Bold)
          .fontColor('#F4FAFA')
          .letterSpacing(1)
        Text(`pp  ${this.ppText}`)
          .fontSize(this.hudY(0.019))
          .fontColor('#8FC7E8')
      }
      .alignItems(HorizontalAlign.End)
      .position({ x: this.hudX(0.972), y: this.hudY(0.022) })
      .translate({ x: '-100%' })

      // ---- 左下：连击
      Column({ space: 0 }) {
        Text('连击')
          .fontSize(this.hudY(0.020))
          .fontColor('#DCE8E4')
        Row() {
          Text(`${this.combo}`)
            .fontSize(this.hudY(0.052))
            .fontWeight(FontWeight.Bold)
            .fontColor('#F4FAFA')
          Text('x')
            .fontSize(this.hudY(0.030))
            .fontColor('#F4FAFA')
            .margin({ left: this.hudY(0.004), bottom: this.hudY(0.006) })
        }
        .alignItems(VerticalAlign.Bottom)
      }
      .alignItems(HorizontalAlign.Start)
      .position({ x: this.hudX(0.045), y: this.hudY(0.775) })

      // ---- 底部：进度条 + 两端时间
      Row() {
        Row()
          .width(`${Math.min(100, this.progress01 * 100)}%`)
          .height('100%')
          .backgroundColor('#FFFFFF')
      }
      .width(this.hudX(0.855))
      .height(this.hudY(0.005))
      .backgroundColor('#4DFFFFFF')
      .position({ x: this.hudX(0.075), y: this.hudY(0.952) })

      Text(this.timeNow)
        .fontSize(this.hudY(0.019))
        .fontColor('#D8E2DE')
        .position({ x: this.hudX(0.084), y: this.hudY(0.922) })
      Text(this.timeTotal)
        .fontSize(this.hudY(0.019))
        .fontColor('#D8E2DE')
        .position({ x: this.hudX(0.930), y: this.hudY(0.922) })
        .translate({ x: '-100%' })

      // ---- 右下：帧统计（lazer 的 FrameStatistics，掉帧时是橙色）
      Column({ space: 0 }) {
        Text(`${Math.round(this.frameMs)} ms`)
          .fontSize(this.hudY(0.020))
          .fontColor('#FF8A5B')
        Text(`${this.fps} fps`)
          .fontSize(this.hudY(0.020))
          .fontColor('#FF8A5B')
      }
      .alignItems(HorizontalAlign.End)
      .padding({
        left: this.hudY(0.014), right: this.hudY(0.014),
        top: this.hudY(0.006), bottom: this.hudY(0.006)
      })
      .backgroundColor('#CC0E0E10')
      .borderRadius(this.hudY(0.008))
      .position({ x: this.hudX(0.995), y: this.hudY(0.930) })
      .translate({ x: '-100%' })
    }
    .width('100%')
    .height('100%')
  }

  // ------------------------------------------------------------ 结算（Argon）

  /** 等级环：按 300/100/50/miss 的比例分段，中间叠一个大字母 */
  private drawGradeRing(): void {
    const c = this.ringCtx;
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);
    const cx = w * 0.5;
    const cy = h * 0.5;
    const r = Math.min(w, h) * 0.40;
    const lw = Math.min(w, h) * 0.085;

    // 底环
    c.lineWidth = lw;
    c.strokeStyle = 'rgba(255,255,255,0.10)';
    c.beginPath();
    c.arc(cx, cy, r, 0, Math.PI * 2);
    c.stroke();

    const total = Math.max(1, this.res300 + this.res100 + this.res50 + this.resMiss);
    const segs: number[] = [this.res300, this.res100, this.res50, this.resMiss];
    const colours: string[] = ['#5FE0E8', '#7ED957', '#FFD24D', '#FF4D6A'];

    let angle = -Math.PI * 0.5;
    for (let i = 0; i < segs.length; i++) {
      const sweep = (segs[i] / total) * Math.PI * 2;
      if (sweep <= 0.004) {
        continue;
      }
      c.strokeStyle = colours[i];
      c.lineWidth = lw;
      c.lineCap = 'butt';
      c.beginPath();
      c.arc(cx, cy, r, angle + 0.004, angle + sweep - 0.004);
      c.stroke();
      angle += sweep;
    }
  }

  /** 判定偏差分布：中间青色、两边转蓝/黄，和 Argon 的 Timing Distribution 一个意思 */
  private drawTimingHistogram(): void {
    const c = this.histCtx;
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);

    const bins = 41;
    const data: number[] = this.errorBar.histogram(bins, 150);
    let peak = 1;
    for (let i = 0; i < data.length; i++) {
      if (data[i] > peak) {
        peak = data[i];
      }
    }

    c.strokeStyle = 'rgba(255,255,255,0.10)';
    c.lineWidth = 1;
    c.beginPath();
    c.moveTo(w * 0.5, 0);
    c.lineTo(w * 0.5, h);
    c.stroke();

    const slot = w / bins;
    const bw = slot * 0.66;
    for (let i = 0; i < bins; i++) {
      const v = data[i];
      if (v <= 0) {
        continue;
      }
      const bh = (v / peak) * h * 0.92;
      const mid = Math.abs(i - (bins - 1) * 0.5) / ((bins - 1) * 0.5);
      c.fillStyle = mid < 0.30 ? '#7FE3F0' : (mid < 0.62 ? '#6FA8FF' : '#C8D24A');
      c.fillRect(i * slot + (slot - bw) * 0.5, h - bh, bw, bh);
    }
  }

  /** 命中散布图（Argon 的 Accuracy Heatmap）：横轴是偏差，纵轴是确定性抖动 */
  private drawAccuracyHeatmap(): void {
    const c = this.heatCtx;
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);
    const cx = w * 0.5;
    const cy = h * 0.5;
    const r = Math.min(w, h) * 0.40;

    c.strokeStyle = 'rgba(255,255,255,0.16)';
    c.lineWidth = 1;
    c.beginPath();
    c.arc(cx, cy, r, 0, Math.PI * 2);
    c.stroke();
    c.beginPath();
    c.moveTo(cx - r, cy);
    c.lineTo(cx + r, cy);
    c.moveTo(cx, cy - r);
    c.lineTo(cx, cy + r);
    c.stroke();

    const n = this.errorBar.count;
    let show = n;
    if (show > 260) {
      show = 260;
    }
    for (let i = 0; i < show; i++) {
      const s = this.errorBar.sampleAt(n - 1 - i);
      const x = cx + Math.max(-1, Math.min(1, s / 200)) * r * 0.92;
      // 确定性抖动：同一批样本每次画都一样，不会闪
      const jitter = Math.sin(i * 12.9898) * 43758.5453;
      const y = cy + (jitter - Math.floor(jitter) - 0.5) * r * 0.9;
      const bad = Math.abs(s) > 60;
      c.fillStyle = bad ? 'rgba(255,120,140,0.85)' : 'rgba(120,235,215,0.85)';
      c.fillRect(x, y, 2.4, 2.4);
    }
  }

  @Builder
  panelTitle(label: string) {
    Text(label)
      .fontSize(this.hudY(0.017))
      .fontWeight(FontWeight.Bold)
      .fontColor('#D8E6E2')
      .margin({ bottom: this.hudY(0.008) })
  }

  @Builder
  skillRow(label: string, pct: number, colour: string) {
    Row() {
      Text(label)
        .fontSize(this.hudY(0.017))
        .fontColor('#BFCEC9')
        .width(this.hudX(0.058))
      Row() {
        Row()
          .width(`${Math.max(0, Math.min(100, pct))}%`)
          .height('100%')
          .backgroundColor(colour)
      }
      .layoutWeight(1)
      .height(this.hudY(0.008))
      .backgroundColor('#33FFFFFF')
      .borderRadius(this.hudY(0.004))
      Text(`${Math.round(pct)}%`)
        .fontSize(this.hudY(0.016))
        .fontColor('#D8E6E2')
        .width(this.hudX(0.034))
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 等级环外侧的判定计数小标签。
   *
   * lazer 不把 300/100/50/miss 摆成一行文字，而是挂在准确率环外圈上（见录屏），
   * 位置是环的四个方向；count 为 0 的档位不显示（参考那局 miss=0，画面上只有三个）。
   */
  @Builder
  judgeBadge(x: string, y: string, count: number, colour: string) {
    if (count > 0) {
      Text(`${count}`)
        .fontSize(this.hudY(0.015))
        .fontColor(colour)
        .backgroundColor('#D912181A')
        .borderRadius(this.hudY(0.005))
        .borderWidth(1)
        .borderColor(colour)
        .padding({
          left: this.hudY(0.007), right: this.hudY(0.007),
          top: this.hudY(0.001), bottom: this.hudY(0.001)
        })
        .position({ x: x, y: y })
    }
  }

  /** Overall Ranking 里「标签 + 数值」的一行。 */
  @Builder
  rankRow(label: string, value: string, colour: string) {
    Row({ space: this.hudY(0.006) }) {
      Text(label)
        .fontSize(this.hudY(0.014))
        .fontColor('#8FA8A2')
      Text(value)
        .fontSize(this.hudY(0.016))
        .fontColor(colour)
    }
  }

  /**
   * 收藏按钮单独写：@Builder 的**按值传参不会触发刷新**，
   * 心形图标和颜色必须在这里直接读 `this.resFav`，否则点了只有 state 变、UI 不动。
   *
   * 心形不能用 `♥`：HarmonyOS 字体对 U+2665 会走 emoji 回退，渲染成系统红色彩色字形，
   * `fontColor` 直接失效（加 U+FE0E 变体选择符也压不住）。所以手绘 Path。
   */
  @Builder
  favButton() {
    Row() {
      Path({ commands: this.heartPath() })
        .width(this.hudY(0.040))
        .height(this.hudY(0.040))
        // 这个尺寸（约 50px）下空心描边会把顶部凹口糊成实块，所以统一用实心双态。
        .fill(this.resFav ? '#E5368C' : '#B9C6C2')
        // Path 默认带 1vp 黑描边，不关掉心形外圈会挂一圈黑边
        .strokeWidth(0)
    }
    .justifyContent(FlexAlign.Center)
    .width(this.hudX(0.074))
    .height(this.hudY(0.062))
    .borderRadius(this.hudY(0.010))
    .backgroundColor(this.resFav ? '#5C2436' : '#4A4F52')
    .position({ x: this.hudX(0.801), y: this.hudY(0.885) })
    .onClick(() => {
      // toggle 里顺手落盘，返回值就是切换后的状态
      this.resFav = this.favs.toggle(this.mapKey);
    })
  }

  /**
   * 结算页底部的一个操作块。
   *
   * lazer 原版底部是「粉色返回小块 + 两个等宽绿按钮 + 两个灰色小方块」，
   * 宽度按录屏量出来的屏幕百分比给的，所以每个块自己带 x/width 而不是靠 Row 均分。
   */
  @Builder
  resultButton(x: number, w: number, icon: string, label: string,
    bg: string, fg: string, action: () => void) {
    Row({ space: this.hudY(0.008) }) {
      if (icon.length > 0) {
        Text(icon)
          .fontSize(this.hudY(0.026))
          .fontColor(fg)
      }
      if (label.length > 0) {
        Text(label)
          .fontSize(this.hudY(0.019))
          .fontColor(fg)
      }
    }
    .justifyContent(FlexAlign.Center)
    .width(this.hudX(w))
    .height(this.hudY(0.062))
    .borderRadius(this.hudY(0.010))
    .backgroundColor(bg)
    .position({ x: this.hudX(x), y: this.hudY(0.885) })
    .onClick(() => {
      action();
    })
  }

  /** Argon 结算页：左卡片（玩家/谱面/等级环）+ 右面板（能力拆解/分布/散布）+ 底部操作条 */
  @Builder
  resultScreen() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：谱面封面 + 模糊压暗（没有封面就只剩深色底）
      // 注意 Image 要 file:// 前缀，裸绝对路径加载不出来（会静默失败成空白）
      if (this.backgroundPath.length > 0) {
        Image(`file://${this.backgroundPath}`)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(this.hudY(0.030))
          .scale({ x: 1.12, y: 1.12 })
          .opacity(0.9)
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#99070A0C')

      // ---------------- 左列
      Column({ space: this.hudY(0.004) }) {
        Stack({ alignContent: Alignment.Center }) {
          Circle()
            .width(this.hudY(0.100))
            .height(this.hudY(0.100))
            .fill('#FF66AA')
          Text('osu!')
            .fontSize(this.hudY(0.028))
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
        Text('Qute15')
          .fontSize(this.hudY(0.019))
          .fontColor('#E8F2EE')

        Column() {
          Text(this.songTitle.length > 0 ? this.songTitle : this.sourceLabel)
            .fontSize(this.hudY(0.026))
            .fontWeight(FontWeight.Bold)
            .fontColor('#F4FAFA')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.songArtist)
            .fontSize(this.hudY(0.019))
            .fontColor('#A9BAB5')
            .margin({ bottom: this.hudY(0.010) })

          Stack({ alignContent: Alignment.Center }) {
            Canvas(this.ringCtx)
              .width(this.hudX(0.215))
              .height(this.hudX(0.215))
              .onReady(() => {
                this.drawGradeRing();
              })
            Text(this.resGrade)
              .fontSize(this.hudX(0.115))
              .fontWeight(FontWeight.Bold)
              .fontColor('#F6F1DC')

            // 判定计数挂在环外侧四个方向
            this.judgeBadge('1%', '11%', this.res300, '#5FE0E8')
            this.judgeBadge('-5%', '52%', this.res100, '#7ED957')
            this.judgeBadge('80%', '73%', this.res50, '#FFD24D')
            this.judgeBadge('76%', '6%', this.resMiss, '#FF4D6A')
          }
          .width(this.hudX(0.215))
          .height(this.hudX(0.215))

          Text(`${this.resScore}`)
            .fontSize(this.hudY(0.036))
            .fontWeight(FontWeight.Bold)
            .fontColor('#F4FAFA')
            .margin({ top: this.hudY(0.008) })
          Text(`${this.resAccuracy}%  ·  ${this.resMaxCombo}x`)
            .fontSize(this.hudY(0.019))
            .fontColor('#A9BAB5')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Center)
        .padding(this.hudY(0.014))
        .borderRadius(this.hudY(0.016))
        .backgroundColor('#B3141A1C')
      }
      .width(this.hudX(0.300))
      .position({ x: this.hudX(0.075), y: this.hudY(0.070) })

      // ---------------- 右列
      Column({ space: this.hudY(0.012) }) {
        // 能力拆解
        Column() {
          this.panelTitle('Performance Breakdown')
          Row() {
            Column({ space: this.hudY(0.006) }) {
              this.skillRow('Aim', this.skillAim, '#5FE0E8')
              this.skillRow('Speed', this.skillSpeed, '#7ED957')
              this.skillRow('Accuracy', this.skillAcc, '#FFD24D')
            }
            .layoutWeight(1)

            Column({ space: 0 }) {
              Text('Achieved PP')
                .fontSize(this.hudY(0.014))
                .fontColor('#8FA8A2')
                .maxLines(1)
              Text(this.ppText)
                .fontSize(this.hudY(0.026))
                .fontColor('#5FE0E8')
            }
            .alignItems(HorizontalAlign.Start)
            .width(this.hudX(0.125))
            .margin({ left: this.hudY(0.012) })
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(this.hudY(0.016))
        .borderRadius(this.hudY(0.014))
        .backgroundColor('#B3141A1C')

        Row({ space: this.hudY(0.012) }) {
          // 判定分布
          Column() {
            this.panelTitle('Timing Distribution')
            Canvas(this.histCtx)
              .width('100%')
              .height(this.hudY(0.078))
              .onReady(() => {
                this.drawTimingHistogram();
              })
            Row() {
              Text(`平均判定偏差 ${this.errorBar.mean().toFixed(1)} 毫秒`)
                .fontSize(this.hudY(0.015))
                .fontColor('#8FA8A2')
              Blank()
              Text(`UR ${this.errorBar.unstableRate().toFixed(2)}`)
                .fontSize(this.hudY(0.015))
                .fontColor('#8FA8A2')
            }
            .width('100%')
            .margin({ top: this.hudY(0.006) })
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding(this.hudY(0.016))
          .borderRadius(this.hudY(0.014))
          .backgroundColor('#B3141A1C')

          // 散布
          Column() {
            this.panelTitle('Accuracy Heatmap')
            Stack({ alignContent: Alignment.Center }) {
              Canvas(this.heatCtx)
                .width('100%')
                .height(this.hudY(0.088))
                .onReady(() => {
                  this.drawAccuracyHeatmap();
                })
              Text('Overshoot')
                .fontSize(this.hudY(0.013))
                .fontColor('#8FA8A2')
                .position({ x: '70%', y: '2%' })
              Text('Undershoot')
                .fontSize(this.hudY(0.013))
                .fontColor('#8FA8A2')
                .position({ x: '2%', y: '90%' })
            }
            .width('100%')
            .height(this.hudY(0.088))
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
          .padding(this.hudY(0.016))
          .borderRadius(this.hudY(0.014))
          .backgroundColor('#B3141A1C')
        }
        .width('100%')

        // Overall Ranking
        // 录屏里这块被底栏挡住只露了标题，所以内容按 lazer 的结构补：左边大位次，
        // 右边两组统计，底部一条「本次 / 本谱最佳」的比例条。
        // 数据源是本地 history.txt（没有服务器，只能算本地名次）。
        Column() {
          this.panelTitle('Overall Ranking')
          Row() {
            Column({ space: 0 }) {
              Text(`#${this.rankOverall}`)
                .fontSize(this.hudY(0.048))
                .fontWeight(FontWeight.Bold)
                .fontColor('#F4FAFA')
              Text(`of ${this.rankOverallTotal} plays`)
                .fontSize(this.hudY(0.014))
                .fontColor('#8FA8A2')
            }
            .alignItems(HorizontalAlign.Start)

            Blank()

            Column({ space: this.hudY(0.004) }) {
              this.rankRow('本谱最佳', `${this.rankMapBest}`, '#F4FAFA')
              this.rankRow('本谱排名', `第 ${this.rankMapRank} / ${this.rankMapPlays} 次`, '#A9BAB5')
            }
            .alignItems(HorizontalAlign.End)

            Column({ space: this.hudY(0.004) }) {
              this.rankRow('本次分数', `${this.resScore}`, '#5FE0E8')
              this.rankRow('准确率', `${this.resAccuracy}%`, '#7ED957')
            }
            .alignItems(HorizontalAlign.Start)
            .width(this.hudX(0.150))
            .margin({ left: this.hudY(0.034) })
          }
          .width('100%')

          // 本次分数占「本谱最佳」的比例
          Stack({ alignContent: Alignment.TopStart }) {
            Row()
              .width('100%')
              .height(this.hudY(0.007))
              .borderRadius(this.hudY(0.004))
              .backgroundColor('#33FFFFFF')
            Row()
              .width(`${this.bestRatio()}%`)
              .height(this.hudY(0.007))
              .borderRadius(this.hudY(0.004))
              .backgroundColor('#5FE0E8')
          }
          .width('100%')
          .margin({ top: this.hudY(0.010) })
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(this.hudY(0.016))
        .borderRadius(this.hudY(0.014))
        .backgroundColor('#B3141A1C')
      }
      .width(this.hudX(0.545))
      .position({ x: this.hudX(0.400), y: this.hudY(0.070) })

      // ---------------- 底部操作条
      // 返回粉块 / 导出绿块 / 重试绿块 / 选歌灰块 / 收藏灰块
      // 比例全部取自录屏：0.051+0.069 → 0.215+0.239 → 0.468+0.240 → 0.718+0.074 → 0.801+0.074
      this.resultButton(0.051, 0.069, '', '返回', '#E5368C', '#FFFFFF', () => {
        this.exitToSelect();
      })
      this.resultButton(0.215, 0.239, '⤓', '导出', '#8CC63E', '#12121A', () => {
        this.exportResult();
      })
      this.resultButton(0.468, 0.240, '⟳', '重试', '#8CC63E', '#12121A', () => {
        this.restart();
      })
      this.resultButton(0.718, 0.074, '≡', '', '#4A4F52', '#E4EFEB', () => {
        this.exitToSelect();
      })
      this.favButton()

      if (this.exportTip.length > 0) {
        Text(this.exportTip)
          .fontSize(this.hudY(0.015))
          .fontColor('#8CC63E')
          .position({ x: this.hudX(0.405), y: this.hudY(0.828) })
      }
    }
    .width('100%')
    .height('100%')
  }


  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      XComponent({ id: 'osuGL', type: XComponentType.SURFACE, libraryname: 'osu' })
        .width('100%')
        .height('100%')
        .onLoad((context: object) => {
          osuNative.attachContext(context);
          osuNative.startRender();
        })
        .onTouch((event: TouchEvent) => {
          if (event.touches.length === 0) {
            return;
          }
          const touch = event.touches[0];
          const renderer = this.renderer;
          const playfield = this.playfield;
          if (renderer === null || playfield === null) {
            return;
          }

          const px = vp2px(touch.x);
          const py = vp2px(touch.y);
          this.cursor = new Vec2(renderer.layout.toPlayfieldX(px), renderer.layout.toPlayfieldY(py));
          this.hasCursor = true;
          // 真人一碰就交出控制权；如果 auto 还按着，先把按下状态放掉，
          // 否则判定引擎会以为手指一直没松开。
          if (this.autoPlay) {
            this.autoPlay = false;
            if (this.auto.isDown) {
              const released = playfield.release(this.clock.now());
              for (let i = 0; i < released.length; i++) {
                this.onJudgement(released[i], renderer, this.clock.now());
              }
            }
            this.auto.reset();
          }

          const time = this.clock.now();

          if (event.type === TouchType.Down) {
            const events = playfield.press(time, this.cursor);
            for (let i = 0; i < events.length; i++) {
              this.onJudgement(events[i], renderer, time);
            }
          } else if (event.type === TouchType.Move) {
            playfield.move(time, this.cursor);
          } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
            const released = playfield.release(time);
            for (let i = 0; i < released.length; i++) {
              this.onJudgement(released[i], renderer, time);
            }
            this.hasCursor = false;
          }
        })

      // ---- 判定文字（居中偏上，放场地中央会挡视线）
      if (this.judgementText.length > 0) {
        Text(this.judgementText)
          .fontSize(46)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.judgementColor)
          .position({ x: '50%', y: '32%' })
          .translate({ x: '-50%' })
          .hitTestBehavior(HitTestMode.None)
      }

      // ---- Argon HUD（整层不参与命中测试，触摸全部交给下面的 XComponent）
      Stack({ alignContent: Alignment.TopStart }) {
        this.argonHud()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      // ---- 暂停按钮（lazer 移动端就这一个圆形 ✕，其它调试开关收进暂停页）
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(this.hudY(0.078))
          .height(this.hudY(0.078))
          .fill('#59000000')
          .stroke('#99FFFFFF')
          .strokeWidth(1.2)
        Text('✕')
          .fontSize(this.hudY(0.032))
          .fontColor('#FFFFFF')
      }
      .width(this.hudY(0.078))
      .height(this.hudY(0.078))
      .position({ x: this.hudX(0.955), y: this.hudY(0.775) })
      .translate({ x: '-50%', y: '-50%' })
      .onClick(() => {
        this.pauseGame();
      })

      // ---- 暂停遮罩（Argon：标题 + 三根斜条 + 底部成绩摘要 + 调试开关）
      if (this.paused) {
        Stack({ alignContent: Alignment.TopStart }) {
          Column()
            .width('100%')
            .height('100%')
            .backgroundColor('#D9070A0C')

          Text('已暂停')
            .fontSize(this.hudY(0.042))
            .fontWeight(FontWeight.Bold)
            .fontColor('#F2C23C')
            .width('100%')
            .textAlign(TextAlign.Center)
            .position({ x: 0, y: this.hudY(0.115) })

          Column({ space: this.hudY(0.010) }) {
            this.pauseBar(0, '继续', () => {
              this.resumeGame();
            })
            this.pauseBar(1, '重试', () => {
              this.restart();
            })
            this.pauseBar(2, '退出', () => {
              this.exitToSelect();
            })
          }
          .width(this.hudX(0.695))
          .position({ x: this.hudX(0.185), y: this.hudY(0.268) })

          // 左下成绩摘要（lazer 暂停页就是这三行）
          Column({ space: this.hudY(0.006) }) {
            Text(`重试次数： ${this.restartCount}`)
              .fontSize(this.hudY(0.021))
              .fontColor('#E8E8EE')
            Text(`歌曲进度： ${Math.round(this.progress01 * 100)}%`)
              .fontSize(this.hudY(0.021))
              .fontColor('#E8E8EE')
            Text(`准确率： ${this.accuracy.toFixed(2)}%`)
              .fontSize(this.hudY(0.021))
              .fontColor('#E8E8EE')
          }
          .alignItems(HorizontalAlign.Start)
          .position({ x: this.hudX(0.395), y: this.hudY(0.795) })

          // 右侧圆形等级徽章
          Stack({ alignContent: Alignment.Center }) {
            Circle()
              .width(this.hudY(0.105))
              .height(this.hudY(0.105))
              .fill('#33000000')
              .stroke('#66FFFFFF')
              .strokeWidth(1.5)
            Text('1')
              .fontSize(this.hudY(0.040))
              .fontColor('#FFFFFF')
          }
          .position({ x: this.hudX(0.735), y: this.hudY(0.795) })
          .translate({ x: '-50%', y: '-50%' })

          // 调试开关：正式 UI 里没有，收在暂停页不挡视线
          Row({ space: this.hudY(0.012) }) {
            this.devButton(this.autoPlay ? 'AUTO 开' : 'AUTO 关', this.autoPlay, () => {
              this.autoPlay = !this.autoPlay;
              this.auto.reset();
              this.hasCursor = false;
            })
            this.devButton('-5ms', false, () => {
              this.setOffset(this.clock.offset - 5);
            })
            this.devButton('+5ms', false, () => {
              this.setOffset(this.clock.offset + 5);
            })
            this.devButton('结算', false, () => {
              this.finishRun();
            })
          }
          .position({ x: this.hudX(0.185), y: this.hudY(0.945) })
        }
        .width('100%')
        .height('100%')
      }

      // ---- 结算（Argon：左卡片 + 右侧面板 + 底部操作条）
      if (this.finished) {
        this.resultScreen()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#07070A')
  }
}
