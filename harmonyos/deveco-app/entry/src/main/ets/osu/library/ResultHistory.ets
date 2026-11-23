import { fileIo as fs } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const TAG: string = 'osu-hist';

/** 历史最多留这么多条，防止文件无限长（超了丢最旧的）。 */
const MAX_RECORDS: number = 400;

/** 一局成绩。`key` 是谱面标识（artist - title），用来算「本谱第几次打 / 本谱最佳」。 */
export interface ResultRecord {
  key: string;
  score: number;
  accuracy: number;
  pp: number;
  grade: string;
  time: number;
}

/** 结算页 Overall Ranking 面板需要的统计量。 */
export interface HistoryStats {
  /** 本次分数在全部记录里的名次（1 开始，越大越差） */
  overallRank: number;
  /** 全部记录条数（含本次） */
  overallTotal: number;
  /** 本次在本谱面记录里的名次 */
  mapRank: number;
  /** 本谱面一共打过几次 */
  mapPlays: number;
  /** 本谱面历史最高分 */
  mapBest: number;
  /** 全部记录最高分 */
  globalBest: number;
}

/**
 * 本地成绩历史。
 *
 * 存成一个纯文本文件（一行一局，`key \t score \t acc \t pp \t grade \t time`），
 * 和 `SongLibrary` 的索引同一个路子 —— 不用 JSON，省掉 ArkTS 里
 * `JSON.parse` 之后 `as` 到 interface 数组的类型麻烦，也方便用 Device File Explorer 直接看。
 *
 * 注意：这是单机存档，不是服务器排行榜。Overall Ranking 面板显示的就是这个本地名次。
 */
export class ResultHistory {
  records: ResultRecord[] = [];
  private path: string = '';

  load(dir: string): void {
    this.records = [];
    this.path = `${dir}/history.txt`;
    let text: string = '';
    try {
      text = fs.readTextSync(this.path);
    } catch (err) {
      // 第一次跑没有文件，正常。
      return;
    }
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const parts: string[] = line.split('\t');
      if (parts.length < 6) {
        continue;
      }
      this.records.push({
        key: parts[0],
        score: this.num(parts[1]),
        accuracy: this.num(parts[2]),
        pp: this.num(parts[3]),
        grade: parts[4],
        time: this.num(parts[5])
      });
    }
    hilog.info(0x0000, TAG, 'loaded %{public}d records', this.records.length);
  }

  /**
   * 追加一局并落盘，返回更新后的统计量。
   * 落盘失败不抛（成绩还是要显示的），只记日志。
   */
  add(record: ResultRecord): HistoryStats {
    this.records.push(record);
    while (this.records.length > MAX_RECORDS) {
      this.records.shift();
    }
    const stats: HistoryStats = this.statsFor(record);
    this.save();
    return stats;
  }

  /** 只读：不存在的谱面返回 0。 */
  bestOfMap(key: string): number {
    let best: number = 0;
    for (let i = 0; i < this.records.length; i++) {
      const r: ResultRecord = this.records[i];
      if (r.key === key && r.score > best) {
        best = r.score;
      }
    }
    return best;
  }

  total(): number {
    return this.records.length;
  }

  private statsFor(record: ResultRecord): HistoryStats {
    let overallRank: number = 1;
    let mapRank: number = 1;
    let mapPlays: number = 0;
    let mapBest: number = 0;
    let globalBest: number = 0;
    for (let i = 0; i < this.records.length; i++) {
      const r: ResultRecord = this.records[i];
      if (r.score > record.score) {
        overallRank++;
      }
      if (r.score > globalBest) {
        globalBest = r.score;
      }
      if (r.key === record.key) {
        mapPlays++;
        if (r.score > record.score) {
          mapRank++;
        }
        if (r.score > mapBest) {
          mapBest = r.score;
        }
      }
    }
    return {
      overallRank: overallRank,
      overallTotal: this.records.length,
      mapRank: mapRank,
      mapPlays: mapPlays,
      mapBest: mapBest,
      globalBest: globalBest
    };
  }

  private save(): void {
    if (this.path.length === 0) {
      return;
    }
    const lines: string[] = [];
    for (let i = 0; i < this.records.length; i++) {
      const r: ResultRecord = this.records[i];
      lines.push(`${r.key}\t${r.score}\t${r.accuracy.toFixed(2)}\t${r.pp}\t${r.grade}\t${r.time}`);
    }
    try {
      const file = fs.openSync(this.path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, lines.join('\n'));
      fs.closeSync(file);
    } catch (err) {
      hilog.error(0x0000, TAG, 'save failed: %{public}s', `${(err as Error).message}`);
    }
  }

  private num(text: string): number {
    const v: number = Number.parseFloat(text);
    return Number.isNaN(v) ? 0 : v;
  }
}

/**
 * 收藏谱面（结算页那个心）。
 *
 * 一行一个谱面 key，跟历史记录共用 `dir`。收藏状态是纯本地的，
 * 换设备不会同步 —— 没接服务器之前只能这样。
 */
export class Favourites {
  private keys: string[] = [];
  private path: string = '';

  load(dir: string): void {
    this.keys = [];
    this.path = `${dir}/favourites.txt`;
    let text: string = '';
    try {
      text = fs.readTextSync(this.path);
    } catch (err) {
      return;
    }
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line: string = lines[i].trim();
      if (line.length > 0 && this.keys.indexOf(line) < 0) {
        this.keys.push(line);
      }
    }
  }

  has(key: string): boolean {
    return this.keys.indexOf(key) >= 0;
  }

  /** 返回切换后的状态。 */
  toggle(key: string): boolean {
    const idx: number = this.keys.indexOf(key);
    let on: boolean = false;
    if (idx >= 0) {
      this.keys.splice(idx, 1);
    } else {
      this.keys.push(key);
      on = true;
    }
    this.save();
    return on;
  }

  count(): number {
    return this.keys.length;
  }

  private save(): void {
    if (this.path.length === 0) {
      return;
    }
    try {
      const file = fs.openSync(this.path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, this.keys.join('\n'));
      fs.closeSync(file);
    } catch (err) {
      hilog.error(0x0000, TAG, 'fav save failed: %{public}s', `${(err as Error).message}`);
    }
  }
}
