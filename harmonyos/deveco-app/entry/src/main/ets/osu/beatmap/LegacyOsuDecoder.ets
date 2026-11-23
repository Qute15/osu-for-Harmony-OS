import {
  BeatmapColours,
  BeatmapDifficulty,
  BeatmapMetadata,
  BreakPeriod,
  DecodedBeatmap,
  GeneralSettings,
  LegacyHitObject,
  SampleInfo,
  StoryboardBackground
} from './BeatmapModel';
import {
  ControlPointInfo,
  DifficultyControlPoint,
  EffectControlPoint,
  SampleControlPoint,
  TimingControlPoint
} from './ControlPoints';

/**
 * .osu 文件解码器 —— 对应 osu.Game/Beatmaps/Formats/LegacyBeatmapDecoder.cs。
 *
 * 覆盖格式 v3 ~ v14。老格式的差异（缺 hitSample、TimingPoints 只有 2 字段、
 * 缺 ApproachRate、comma 内嵌引号）都按 stable 的宽容策略处理，不抛异常，
 * 保证任何能进 stable 的谱面都能被吃下来。
 */
export class LegacyOsuDecoder {
  static decode(text: string): DecodedBeatmap {
    const beatmap = new DecodedBeatmap();
    let hasApproachRate = false;

    // 去 BOM + 统一换行
    let src = text;
    if (src.length > 0 && src.charCodeAt(0) === 0xFEFF) {
      src = src.substring(1);
    }
    const lines = src.replace(/\r\n/g, '\n').replace(/\r/g, '\n').split('\n');

    let section = '';

    for (let i = 0; i < lines.length; i++) {
      const raw = lines[i];
      const line = raw.trim();
      if (line.length === 0) {
        continue;
      }

      if (line.startsWith('osu file format v')) {
        const v = parseInt(line.substring('osu file format v'.length).trim(), 10);
        beatmap.formatVersion = isNaN(v) ? 14 : v;
        continue;
      }

      if (line.startsWith('[') && line.endsWith(']')) {
        section = line.substring(1, line.length - 1);
        continue;
      }

      if (section === 'General') {
        LegacyOsuDecoder.readGeneral(beatmap, line);
      } else if (section === 'Metadata') {
        LegacyOsuDecoder.readMetadata(beatmap.metadata, line);
      } else if (section === 'Difficulty') {
        const kv = LegacyOsuDecoder.splitKeyValue(line);
        if (kv === null) {
          continue;
        }
        const value = parseFloat(kv[1]);
        if (isNaN(value)) {
          continue;
        }
        switch (kv[0]) {
          case 'HPDrainRate':
            beatmap.difficulty.drainRate = value;
            break;
          case 'CircleSize':
            beatmap.difficulty.circleSize = value;
            break;
          case 'OverallDifficulty':
            beatmap.difficulty.overallDifficulty = value;
            break;
          case 'ApproachRate':
            beatmap.difficulty.approachRate = value;
            hasApproachRate = true;
            break;
          case 'SliderMultiplier':
            beatmap.difficulty.sliderMultiplier = value;
            break;
          case 'SliderTickRate':
            beatmap.difficulty.sliderTickRate = value;
            break;
          default:
            break;
        }
      } else if (section === 'TimingPoints') {
        LegacyOsuDecoder.readTimingPoint(beatmap.controlPoints, line);
      } else if (section === 'HitObjects') {
        const obj = LegacyOsuDecoder.readHitObject(line);
        if (obj !== null) {
          beatmap.hitObjects.push(obj);
        }
      } else if (section === 'Events') {
        beatmap.eventLines.push(line);
        LegacyOsuDecoder.readEvent(beatmap, line);
      } else if (section === 'Colours') {
        LegacyOsuDecoder.readColour(beatmap.colours, line);
      }
    }

    // v8 之前的谱面没有 ApproachRate 字段，stable 用 OD 顶上
    if (!hasApproachRate) {
      beatmap.difficulty.approachRate = beatmap.difficulty.overallDifficulty;
    }

    // 时间序（部分谱面物件顺序错乱）
    beatmap.controlPoints.timingPoints.sort((a: TimingControlPoint, b: TimingControlPoint) => a.time - b.time);
    beatmap.controlPoints.difficultyPoints.sort((a: DifficultyControlPoint, b: DifficultyControlPoint) => a.time - b.time);
    beatmap.controlPoints.samplePoints.sort((a: SampleControlPoint, b: SampleControlPoint) => a.time - b.time);
    beatmap.controlPoints.effectPoints.sort((a: EffectControlPoint, b: EffectControlPoint) => a.time - b.time);

    if (beatmap.controlPoints.timingPoints.length === 0) {
      // 没有任何 timing point 的坏谱面：给一个 120BPM 的兜底，避免除零
      const fallback = new TimingControlPoint();
      fallback.time = 0;
      fallback.beatLength = 500;
      beatmap.controlPoints.timingPoints.push(fallback);
    }

    return beatmap;
  }

  // ------------------------------------------------------------------ 小节

  private static readGeneral(beatmap: DecodedBeatmap, line: string): void {
    const general = beatmap.general;
    const kv = LegacyOsuDecoder.splitKeyValue(line);
    if (kv === null) {
      return;
    }
    const key = kv[0];
    const value = kv[1].trim();

    switch (key) {
      case 'AudioFilename':
        beatmap.metadata.audioFile = value;
        break;
      case 'AudioLeadIn':
        general.audioLeadIn = LegacyOsuDecoder.toNumber(value, 0);
        break;
      case 'PreviewTime':
        general.previewTime = LegacyOsuDecoder.toNumber(value, -1);
        break;
      case 'Countdown':
        general.countdown = LegacyOsuDecoder.toNumber(value, 0);
        break;
      case 'SampleSet':
        general.sampleSet = value.toLowerCase();
        break;
      case 'StackLeniency':
        general.stackLeniency = LegacyOsuDecoder.toNumber(value, 0.7);
        break;
      case 'Mode':
        general.mode = LegacyOsuDecoder.toNumber(value, 0);
        break;
      case 'LetterboxInBreaks':
        general.letterboxInBreaks = LegacyOsuDecoder.toNumber(value, 0) !== 0;
        break;
      case 'WidescreenStoryboard':
        general.widescreenStoryboard = LegacyOsuDecoder.toNumber(value, 0) !== 0;
        break;
      case 'EpilepsyWarning':
        general.epilepsyWarning = LegacyOsuDecoder.toNumber(value, 0) !== 0;
        break;
      case 'SpecialStyle':
        general.specialStyle = LegacyOsuDecoder.toNumber(value, 0) !== 0;
        break;
      default:
        break;
    }
  }

  private static readMetadata(metadata: BeatmapMetadata, line: string): void {
    const kv = LegacyOsuDecoder.splitKeyValue(line);
    if (kv === null) {
      return;
    }
    const value = kv[1].trim();

    switch (kv[0]) {
      case 'Title':
        metadata.title = value;
        break;
      case 'TitleUnicode':
        metadata.titleUnicode = value;
        break;
      case 'Artist':
        metadata.artist = value;
        break;
      case 'ArtistUnicode':
        metadata.artistUnicode = value;
        break;
      case 'Creator':
        metadata.creator = value;
        break;
      case 'Version':
        metadata.version = value;
        break;
      case 'Source':
        metadata.source = value;
        break;
      case 'Tags':
        metadata.tags = value.length === 0 ? [] : value.split(' ').filter((t: string) => t.length > 0);
        break;
      case 'BeatmapID':
        metadata.beatmapId = LegacyOsuDecoder.toNumber(value, 0);
        break;
      case 'BeatmapSetID':
        metadata.beatmapSetId = LegacyOsuDecoder.toNumber(value, -1);
        break;
      default:
        break;
    }
  }

  private static readTimingPoint(cps: ControlPointInfo, line: string): void {
    const split = line.split(',');
    if (split.length < 2) {
      return;
    }

    const time = parseFloat(split[0]);
    const beatLength = parseFloat(split[1]);
    if (isNaN(time) || isNaN(beatLength)) {
      return;
    }

    const meter = split.length > 2 ? LegacyOsuDecoder.toNumber(split[2], 4) : 4;
    const sampleSet = split.length > 3 ? LegacyOsuDecoder.toNumber(split[3], 0) : 0;
    const sampleIndex = split.length > 4 ? LegacyOsuDecoder.toNumber(split[4], 0) : 0;
    const volume = split.length > 5 ? LegacyOsuDecoder.toNumber(split[5], 100) : 100;
    // 老格式没有 uninherited 字段，用 beatLength 的正负判断
    const uninherited = split.length > 6 ? (LegacyOsuDecoder.toNumber(split[6], 1) !== 0) : beatLength > 0;
    const effects = split.length > 7 ? LegacyOsuDecoder.toNumber(split[7], 0) : 0;

    if (uninherited && beatLength > 0) {
      const tp = new TimingControlPoint();
      tp.time = time;
      tp.beatLength = beatLength;
      tp.meter = meter;
      cps.timingPoints.push(tp);
    }

    const dp = new DifficultyControlPoint();
    dp.time = time;
    // stable 的 SV 编码：beatLength = -100 / SV，夹到 [0.1, 10]
    if (!uninherited && beatLength < 0) {
      dp.sliderVelocityMultiplier = Math.min(10, Math.max(0.1, -100 / beatLength));
    } else {
      dp.sliderVelocityMultiplier = 1;
    }
    dp.generateTicks = (effects & 8) === 0;
    // mania / taiko 的滚动速度（bit4 起），osu! 模式不使用
    if ((effects & 16) > 0) {
      dp.scrollSpeed = 1.4;
    } else if ((effects & 32) > 0) {
      dp.scrollSpeed = 1.4;
    }
    cps.difficultyPoints.push(dp);

    const sp = new SampleControlPoint();
    sp.time = time;
    sp.sampleBank = LegacyOsuDecoder.bankFromIndex(sampleSet);
    sp.volume = volume;
    sp.index = sampleIndex;
    cps.samplePoints.push(sp);

    if ((effects & 1) > 0 || (effects & 8) > 0) {
      const ep = new EffectControlPoint();
      ep.time = time;
      ep.kiai = (effects & 1) > 0;
      ep.omitFirstBarline = (effects & 8) > 0;
      cps.effectPoints.push(ep);
    }
  }

  private static readHitObject(line: string): LegacyHitObject | null {
    const f = line.split(',');
    if (f.length < 4) {
      return null;
    }

    const obj = new LegacyHitObject();
    obj.x = LegacyOsuDecoder.toNumber(f[0], 0);
    obj.y = LegacyOsuDecoder.toNumber(f[1], 0);
    obj.time = LegacyOsuDecoder.toNumber(f[2], 0);
    obj.typeFlags = LegacyOsuDecoder.toNumber(f[3], 1);

    obj.newCombo = (obj.typeFlags & 4) > 0;
    obj.comboOffset = (obj.typeFlags >> 4) & 7;

    if (f.length > 4) {
      obj.hitSound = LegacyOsuDecoder.toNumber(f[4], 0);
    }

    if (obj.isCircle()) {
      if (f.length > 5) {
        obj.sample = LegacyOsuDecoder.parseSample(f[5]);
      }
      return obj;
    }

    if (obj.isSlider()) {
      // x,y,time,type,hitSound,curve,slides,length,edgeSounds,edgeSets,hitSample
      if (f.length > 5) {
        LegacyOsuDecoder.parseCurve(obj, f[5]);
      }
      obj.slides = f.length > 6 ? Math.max(1, LegacyOsuDecoder.toNumber(f[6], 1)) : 1;
      obj.length = f.length > 7 ? Math.max(0, parseFloat(f[7])) : 0;
      if (isNaN(obj.length)) {
        obj.length = 0;
      }
      if (f.length > 8 && f[8].length > 0) {
        const es = f[8].split('|');
        for (let i = 0; i < es.length; i++) {
          obj.edgeSounds.push(LegacyOsuDecoder.toNumber(es[i], 0));
        }
      }
      if (f.length > 9 && f[9].length > 0) {
        const sets = f[9].split('|');
        for (let i = 0; i < sets.length; i++) {
          const parts = sets[i].split(':');
          const normal = LegacyOsuDecoder.toNumber(parts[0], 0);
          const addition = parts.length > 1 ? LegacyOsuDecoder.toNumber(parts[1], 0) : normal;
          // 编码成 bit 组合，方便后面解出两个 bank
          obj.edgeSets.push((normal & 0xFF) | ((addition & 0xFF) << 8));
        }
      }
      obj.endTime = obj.time;
      if (f.length > 10) {
        obj.sample = LegacyOsuDecoder.parseSample(f[10]);
      }
      return obj;
    }

    if (obj.isSpinner()) {
      obj.endTime = f.length > 5 ? LegacyOsuDecoder.toNumber(f[5], obj.time) : obj.time;
      if (f.length > 6) {
        obj.sample = LegacyOsuDecoder.parseSample(f[6]);
      }
      return obj;
    }

    if (obj.isHold()) {
      // endTime:hitSample
      if (f.length > 5) {
        const parts = f[5].split(':');
        obj.endTime = LegacyOsuDecoder.toNumber(parts[0], obj.time);
        if (parts.length > 1) {
          obj.sample = LegacyOsuDecoder.parseSample(parts.slice(1).join(':'));
        }
      } else {
        obj.endTime = obj.time;
      }
      return obj;
    }

    return null;
  }

  /** "B|100:200|300:400" → curveType 'B' + 展平坐标 */
  private static parseCurve(obj: LegacyHitObject, curveStr: string): void {
    const parts = curveStr.split('|');
    if (parts.length === 0) {
      obj.curveType = 'L';
      return;
    }

    const head = parts[0].trim();
    if (head.length > 0) {
      const t = head.charAt(0).toUpperCase();
      obj.curveType = (t === 'B' || t === 'C' || t === 'L' || t === 'P') ? t : 'L';
    } else {
      obj.curveType = 'L';
    }

    for (let i = 1; i < parts.length; i++) {
      const p = parts[i].split(':');
      if (p.length < 2) {
        continue;
      }
      obj.curvePoints.push(parseFloat(p[0]));
      obj.curvePoints.push(parseFloat(p[1]));
    }
  }

  /** "1:2:0:80:soft-hitclap.wav"（filename 可能带冒号，只取前 4 段） */
  private static parseSample(str: string): SampleInfo {
    const s = new SampleInfo();
    if (str === undefined || str === null || str.length === 0) {
      return s;
    }
    const parts = str.split(':');
    const normal = LegacyOsuDecoder.toNumber(parts[0], 0);
    const addition = parts.length > 1 ? LegacyOsuDecoder.toNumber(parts[1], 0) : 0;
    s.bank = LegacyOsuDecoder.bankFromIndex(normal);
    s.additionBank = LegacyOsuDecoder.bankFromIndex(addition);
    s.index = parts.length > 2 ? LegacyOsuDecoder.toNumber(parts[2], 0) : 0;
    s.volume = parts.length > 3 ? LegacyOsuDecoder.toNumber(parts[3], 0) : 0;
    s.filename = parts.length > 4 ? parts.slice(4).join(':') : '';
    return s;
  }

  private static readEvent(beatmap: DecodedBeatmap, line: string): void {
    const fields = LegacyOsuDecoder.splitCsv(line);
    if (fields.length === 0) {
      return;
    }

    const type = fields[0].trim();

    if (type === '0' && fields.length >= 3) {
      // 0,0,"bg.jpg",0,0
      const bg = new StoryboardBackground();
      bg.filename = LegacyOsuDecoder.unquote(fields[2]);
      bg.x = fields.length > 3 ? LegacyOsuDecoder.toNumber(fields[3], 0) : 0;
      bg.y = fields.length > 4 ? LegacyOsuDecoder.toNumber(fields[4], 0) : 0;
      // 只有最前面的有效背景生效（后面的是 storyboard 叠加）
      if (beatmap.background.filename.length === 0 && bg.filename.length > 0) {
        beatmap.background = bg;
      }
    } else if (type === '2' && fields.length >= 3) {
      const start = LegacyOsuDecoder.toNumber(fields[1], 0);
      const end = LegacyOsuDecoder.toNumber(fields[2], 0);
      if (end > start) {
        beatmap.breaks.push(new BreakPeriod(start, end));
      }
    }
  }

  private static readColour(colours: BeatmapColours, line: string): void {
    const kv = LegacyOsuDecoder.splitKeyValue(line);
    if (kv === null) {
      return;
    }
    const rgb = LegacyOsuDecoder.parseColour(kv[1]);
    if (rgb < 0) {
      return;
    }

    if (kv[0].startsWith('Combo')) {
      colours.comboColours.push(rgb);
    } else if (kv[0] === 'SliderBorder') {
      colours.sliderBorder = rgb;
    } else if (kv[0] === 'SliderTrackOverride') {
      colours.sliderTrackOverride = rgb;
    }
  }

  // ------------------------------------------------------------------ 工具

  private static splitKeyValue(line: string): string[] | null {
    const idx = line.indexOf(':');
    if (idx < 0) {
      return null;
    }
    return [line.substring(0, idx).trim(), line.substring(idx + 1)];
  }

  /** 尊重引号的 CSV 切分（[Events] 的背景名可能含逗号） */
  static splitCsv(line: string): string[] {
    const out: string[] = [];
    let cur = '';
    let inQuote = false;

    for (let i = 0; i < line.length; i++) {
      const ch = line.charAt(i);
      if (ch === '"') {
        inQuote = !inQuote;
        cur += ch;
      } else if (ch === ',' && !inQuote) {
        out.push(cur);
        cur = '';
      } else {
        cur += ch;
      }
    }
    out.push(cur);
    return out;
  }

  private static unquote(s: string): string {
    let r = s.trim();
    if (r.startsWith('"')) {
      r = r.substring(1);
    }
    if (r.endsWith('"')) {
      r = r.substring(0, r.length - 1);
    }
    return r;
  }

  /** "255,128,0" → 0x0080FF (0xRRGGBB) */
  private static parseColour(s: string): number {
    const parts = s.split(',');
    if (parts.length < 3) {
      return -1;
    }
    const r = Math.min(255, Math.max(0, LegacyOsuDecoder.toNumber(parts[0], 0)));
    const g = Math.min(255, Math.max(0, LegacyOsuDecoder.toNumber(parts[1], 0)));
    const b = Math.min(255, Math.max(0, LegacyOsuDecoder.toNumber(parts[2], 0)));
    return (r << 16) | (g << 8) | b;
  }

  static bankFromIndex(idx: number): string {
    switch (idx) {
      case 1:
        return 'normal';
      case 2:
        return 'soft';
      case 3:
        return 'drum';
      default:
        return '';
    }
  }

  static toNumber(value: string, fallback: number): number {
    if (value === undefined || value === null) {
      return fallback;
    }
    const v = parseFloat(value);
    return isNaN(v) ? fallback : v;
  }
}
