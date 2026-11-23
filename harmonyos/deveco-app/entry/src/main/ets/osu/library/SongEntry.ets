/**
 * 歌曲库条目的磁盘格式是 TSV，一行一首。
 *
 * 不用 JSON 的原因：ArkTS 严格模式下 JSON.parse 返回 Object，
 * 取字段要么写一堆 as 断言、要么反射，反而比手写一行一行的 TSV 更容易出错。
 * 字段里本来就不允许出现 tab（标题带 tab 的情况闻所未闻），清洗一下即可。
 */

/**
 * 索引字段数。
 *
 * 15 是 v1 的格式（没有背景图列），16 是 v2。这里按 **最小可读列数** 校验，
 * 第 16 列读不到就当空 —— 这样旧索引不用迁移、也不会因为升级而整库消失。
 */
const FIELD_COUNT = 15;
/** 背景图列（v2 追加在最后，所以列序不需要重排） */
const FIELD_BACKGROUND = 15;

export class SongEntry {
  /** 目录名，同时作为唯一 id */
  id: string = '';
  title: string = '';
  artist: string = '';
  creator: string = '';
  version: string = '';
  /** 相对歌库根目录的文件名 */
  osuFile: string = '';
  audioFile: string = '';
  /** 背景图（相对目录），没有就是空串 —— 选歌封面用它 */
  backgroundFile: string = '';
  objectCount: number = 0;
  /** 谱面时长（ms） */
  lengthMs: number = 0;
  bpm: number = 0;
  ar: number = 0;
  od: number = 0;
  cs: number = 0;
  hp: number = 0;
  /** 0=osu! 1=taiko 2=catch 3=mania */
  mode: number = 0;

  displayTitle(): string {
    return `${this.artist} - ${this.title}`;
  }

  /** mm:ss */
  lengthText(): string {
    const total = Math.max(0, Math.floor(this.lengthMs / 1000));
    const m = Math.floor(total / 60);
    const s = total % 60;
    return `${m}:${s < 10 ? '0' : ''}${s}`;
  }

  toTsv(): string {
    const clean = (s: string): string => s.split('\t').join(' ').split('\r').join(' ').split('\n').join(' ');
    return [
      this.id, clean(this.title), clean(this.artist), clean(this.creator), clean(this.version),
      clean(this.osuFile), clean(this.audioFile), this.objectCount, Math.round(this.lengthMs),
      this.bpm.toFixed(2), this.ar, this.od, this.cs, this.hp, this.mode,
      clean(this.backgroundFile)
    ].join('\t');
  }

  static fromTsv(line: string): SongEntry | null {
    const f = line.split('\t');
    if (f.length < FIELD_COUNT) {
      return null;
    }
    const e = new SongEntry();
    e.id = f[0];
    e.title = f[1];
    e.artist = f[2];
    e.creator = f[3];
    e.version = f[4];
    e.osuFile = f[5];
    e.audioFile = f[6];
    e.objectCount = Number(f[7]) || 0;
    e.lengthMs = Number(f[8]) || 0;
    e.bpm = Number(f[9]) || 0;
    e.ar = Number(f[10]) || 0;
    e.od = Number(f[11]) || 0;
    e.cs = Number(f[12]) || 0;
    e.hp = Number(f[13]) || 0;
    e.mode = Number(f[14]) || 0;
    e.backgroundFile = f.length > FIELD_BACKGROUND ? f[FIELD_BACKGROUND] : '';
    return e.id.length > 0 ? e : null;
  }
}

export class ImportResult {
  ok: boolean = false;
  message: string = '';
  /** 本次导入成功解析的谱面 */
  imported: SongEntry[] = [];
  /** 总共导入后库里的数量 */
  total: number = 0;
}
