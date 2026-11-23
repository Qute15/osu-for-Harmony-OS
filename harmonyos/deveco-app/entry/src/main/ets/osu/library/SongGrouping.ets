import { SongEntry } from './SongEntry';

/**
 * 一组难度（= 一张 .osz / 一首歌）。
 *
 * 为什么需要它：库索引是"一个难度一行"，一张 8 难度的图会铺出 8 行，
 * 选歌页做成封面轮播就变成了"同一张封面轮播 8 次"。轮播必须按歌分组，
 * 组内再列难度 —— 这也是 osu! 选歌页的真实结构（左边一首歌，右边难度条）。
 */
export class SongGroup {
  id: string = '';
  title: string = '';
  artist: string = '';
  creator: string = '';
  /** 组内统一用第一个难度的背景图（同一 .osz 里各难度背景一般相同） */
  backgroundFile: string = '';
  /** 组内难度，已按"从易到难"排好 */
  difficulties: SongEntry[] = [];

  displayTitle(): string {
    if (this.artist.length === 0) {
      return this.title;
    }
    return `${this.artist} - ${this.title}`;
  }

  /** 代表难度：物件最多那个，用来显示 BPM / 时长这种"整首歌"的指标 */
  primary(): SongEntry {
    return this.difficulties.length > 0 ? this.difficulties[this.difficulties.length - 1] : new SongEntry();
  }
}

/**
 * 把"一个难度一行"的索引折成"一首歌一组"。
 *
 * 排序规则：组按标题（不含艺术家）字母序 —— 和 osu! 的 Title 排序一致；
 * 艺术家相同的歌自然挨在一起，比按 "艺术家 - 标题" 拼串排序更接近直觉。
 * 组内难度按 AR → 物件数升序，让"从易到难"在视觉上成立。
 */
export class SongGrouping {
  static group(songs: SongEntry[]): SongGroup[] {
    const groups: SongGroup[] = [];
    const byId: Map<string, SongGroup> = new Map<string, SongGroup>();

    for (let i = 0; i < songs.length; i++) {
      const s = songs[i];
      const key = s.id.length > 0 ? s.id : s.title;
      let g = byId.get(key);
      if (g === undefined) {
        g = new SongGroup();
        g.id = s.id;
        g.title = s.title;
        g.artist = s.artist;
        g.creator = s.creator;
        g.backgroundFile = s.backgroundFile;
        byId.set(key, g);
        groups.push(g);
      }
      // 组内所有难度共享封面：第一个带图的难度决定整组的封面
      if (g.backgroundFile.length === 0 && s.backgroundFile.length > 0) {
        g.backgroundFile = s.backgroundFile;
      }
      g.difficulties.push(s);
    }

    for (let i = 0; i < groups.length; i++) {
      SongGrouping.sortDifficulties(groups[i].difficulties);
    }
    groups.sort((a: SongGroup, b: SongGroup) => {
      const ta = a.title.toLowerCase();
      const tb = b.title.toLowerCase();
      if (ta !== tb) {
        return ta < tb ? -1 : 1;
      }
      const aa = a.artist.toLowerCase();
      const ab = b.artist.toLowerCase();
      if (aa !== ab) {
        return aa < ab ? -1 : 1;
      }
      return a.id < b.id ? -1 : 1;
    });
    return groups;
  }

  /** AR 高 = 难；AR 相同再比物件数。只做展示排序，不参与判定。 */
  static sortDifficulties(list: SongEntry[]): void {
    list.sort((a: SongEntry, b: SongEntry) => {
      if (a.ar !== b.ar) {
        return a.ar < b.ar ? -1 : 1;
      }
      if (a.objectCount !== b.objectCount) {
        return a.objectCount < b.objectCount ? -1 : 1;
      }
      return a.version < b.version ? -1 : 1;
    });
  }

  /**
   * 按关键词过滤（标题 / 艺术家 / 谱师 / 难度名），空串返回原数组。
   * 大小写不敏感 —— 手机上打字很难保证大小写。
   */
  static filter(groups: SongGroup[], query: string): SongGroup[] {
    const q = query.trim().toLowerCase();
    if (q.length === 0) {
      return groups;
    }
    const out: SongGroup[] = [];
    for (let i = 0; i < groups.length; i++) {
      const g = groups[i];
      const hay = `${g.title} ${g.artist} ${g.creator} ${g.backgroundFile}`.toLowerCase();
      let hit = hay.indexOf(q) >= 0;
      if (!hit) {
        for (let k = 0; k < g.difficulties.length; k++) {
          if (g.difficulties[k].version.toLowerCase().indexOf(q) >= 0) {
            hit = true;
            break;
          }
        }
      }
      if (hit) {
        out.push(g);
      }
    }
    return out;
  }

  /** 难度总数（顶部统计用） */
  static difficultyCount(groups: SongGroup[]): number {
    let n = 0;
    for (let i = 0; i < groups.length; i++) {
      n += groups[i].difficulties.length;
    }
    return n;
  }
}
