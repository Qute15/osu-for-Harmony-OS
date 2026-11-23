import { fileIo as fs } from '@kit.CoreFileKit';
import { zlib } from '@kit.BasicServicesKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

import { SongEntry, ImportResult } from './SongEntry';
import { LegacyOsuDecoder } from '../beatmap/LegacyOsuDecoder';
import { DecodedBeatmap } from '../beatmap/BeatmapModel';

const DOMAIN = 0x0F0F;
const TAG = 'OSU-LIB';

/** 音频文件按这两类找，其余一律不认 */
const AUDIO_EXT: string[] = ['.mp3', '.ogg'];

/** 封面能认的图片格式 */
const IMAGE_EXT: string[] = ['.jpg', '.jpeg', '.png', '.webp', '.bmp'];

/**
 * 本地歌曲库。
 *
 * 目录结构（全部在应用沙箱内，卸载即清理）：
 *   files/osu/songbook.tsv          索引，一行一首
 *   files/osu/Songs/<id>/xxx.osu    谱面
 *   files/osu/Songs/<id>/audio.mp3  音频（.osz 自带）
 *
 * 为什么自己做索引而不是每次启动全量扫描：一张 .osz 可能有 8 个难度、
 * 每个都要跑一遍完整解码才能拿到标题/BPM/时长，几十张图就会卡启动。
 * 索引只在导入时写一次。
 */
export class SongLibrary {
  private root: string;
  private songsDir: string;
  private indexPath: string;
  private songs: SongEntry[] = [];

  constructor(filesDir: string) {
    this.root = filesDir + '/osu';
    this.songsDir = this.root + '/Songs';
    this.indexPath = this.root + '/songbook.tsv';
  }

  list(): SongEntry[] {
    return this.songs;
  }

  getById(id: string): SongEntry | null {
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === id) {
        return this.songs[i];
      }
    }
    return null;
  }

  /**
   * 按 id + 谱面文件定位。同一张 .osz 的多个难度 id 相同，必须再比 osuFile，
   * 否则点任何一行都会进第一个难度。osuFile 为空时退化成 getById。
   */
  getByIdAndFile(id: string, osuFile: string): SongEntry | null {
    if (osuFile.length === 0) {
      return this.getById(id);
    }
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === id && this.songs[i].osuFile === osuFile) {
        return this.songs[i];
      }
    }
    return null;
  }

  /** 谱面文件的绝对路径 */
  osuPath(entry: SongEntry): string {
    return `${this.songsDir}/${entry.id}/${entry.osuFile}`;
  }

  audioPath(entry: SongEntry): string {
    return `${this.songsDir}/${entry.id}/${entry.audioFile}`;
  }

  /**
   * 背景图绝对路径。没有背景（老索引 / 谱面没带图）时返回空串，
   * 调用方据此回落到渐变占位 —— 不要返回一个不存在的路径给 Image，
   * 那样会在界面上留一块灰色错误图。
   */
  backgroundPath(entry: SongEntry): string {
    if (entry.backgroundFile.length === 0) {
      return '';
    }
    return `${this.songsDir}/${entry.id}/${entry.backgroundFile}`;
  }

  // ---------------------------------------------------------------- 初始化

  private ensureDirs(): void {
    if (!fs.accessSync(this.root)) {
      fs.mkdirSync(this.root, true);
    }
    if (!fs.accessSync(this.songsDir)) {
      fs.mkdirSync(this.songsDir, true);
    }
  }

  /** 读索引。索引损坏时不影响使用，只是要重新导入。 */
  load(): SongEntry[] {
    this.songs = [];
    let migrated = false;
    try {
      this.ensureDirs();
      if (!fs.accessSync(this.indexPath)) {
        return this.songs;
      }
      const text = fs.readTextSync(this.indexPath);
      const lines = text.split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].trim();
        if (line.length === 0) {
          continue;
        }
        const e = SongEntry.fromTsv(line);
        const osuPath = e === null ? '' : `${this.songsDir}/${e.id}/${e.osuFile}`;
        // 目录被外部删掉的情况要能自愈，否则点进去才报错
        if (e !== null && fs.accessSync(osuPath)) {
          // v1 索引没有封面列。这里按目录补一次并回写，用户不用重新导入
          // 才能看到封面 —— 否则升级后所有人的选歌页都是占位色块。
          if (e.backgroundFile.length === 0) {
            const bg = this.resolveBackground(SongLibrary.parentDir(osuPath), '');
            if (bg.length > 0) {
              e.backgroundFile = bg;
              migrated = true;
            }
          }
          this.songs.push(e);
        }
      }
      if (migrated) {
        hilog.info(DOMAIN, TAG, 'index migrated: filled background for old entries');
        this.save();
      }
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'load index failed: %{public}s', JSON.stringify(err));
    }
    this.sort();
    return this.songs;
  }

  private static parentDir(path: string): string {
    const i = path.lastIndexOf('/');
    return i > 0 ? path.substring(0, i) : '';
  }

  private save(): void {
    try {
      this.ensureDirs();
      const lines: string[] = [];
      for (let i = 0; i < this.songs.length; i++) {
        lines.push(this.songs[i].toTsv());
      }
      const file = fs.openSync(this.indexPath, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, lines.join('\n'));
      fs.closeSync(file);
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'save index failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 按标题+难度排序，稳定的展示顺序 */
  private sort(): void {
    this.songs.sort((a: SongEntry, b: SongEntry) => {
      const ta = a.displayTitle().toLowerCase();
      const tb = b.displayTitle().toLowerCase();
      if (ta !== tb) {
        return ta < tb ? -1 : 1;
      }
      return a.version < b.version ? -1 : 1;
    });
  }

  // ------------------------------------------------------------------ 导入

  /**
   * 导入一个 .osz（本质是 zip）。picker 选中的文件走这里。
   *
   * 流程：picker 给的 uri → 复制进沙箱并改名 .zip（zlib 只认 .zip 后缀）
   * → 解到 Songs/<id>/ → 扫描并解析 .osu → 写索引。
   */
  async importOsz(uri: string): Promise<ImportResult> {
    const id = `s${Date.now()}`;
    const tmpZip = `${this.root}/import_${id}.zip`;
    try {
      this.ensureDirs();
      // picker 返回的 uri 只保证可读，zlib 要的是沙箱路径 + .zip 后缀
      const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      try {
        fs.copyFileSync(src.fd, tmpZip);
      } finally {
        fs.closeSync(src);
      }
    } catch (err) {
      this.removeFile(tmpZip);
      const be = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'read uri failed: %{public}s', JSON.stringify(err));
      const r = new ImportResult();
      r.message = `读取文件失败: ${be.code} ${be.message}`;
      return r;
    }
    const result = await this.extractInto(tmpZip, id);
    this.removeFile(tmpZip);
    return result;
  }

  /**
   * 从内存字节导入，给内置示例谱面用（rawfile → Uint8Array）。
   *
   * hdc 推不进 /sdcard（shell 用户只读），真机上没法自动放 .osz，
   * 所以示例谱面直接打进 HAP 的 rawfile。除了字节来源，后面解压/解析/索引
   * 跟 picker 导入是完全同一条代码路径 —— 示例能玩，就说明真实导入也能玩。
   */
  async importFromBytes(bytes: ArrayBuffer): Promise<ImportResult> {
    const id = `s${Date.now()}`;
    const tmpZip = `${this.root}/import_${id}.zip`;
    try {
      this.ensureDirs();
      const file = fs.openSync(tmpZip, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        fs.writeSync(file.fd, bytes);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      this.removeFile(tmpZip);
      const be = err as BusinessError;
      hilog.error(DOMAIN, TAG, 'write tmp zip failed: %{public}s', JSON.stringify(err));
      const r = new ImportResult();
      r.message = `写入临时文件失败: ${be.code} ${be.message}`;
      return r;
    }
    const result = await this.extractInto(tmpZip, id);
    this.removeFile(tmpZip);
    return result;
  }

  /** 解压 + 扫描 + 落索引。tmpZip 的生命周期由调用方管。 */
  private async extractInto(tmpZip: string, id: string): Promise<ImportResult> {
    const result = new ImportResult();
    const targetDir = `${this.songsDir}/${id}`;
    try {
      // 目标目录必须已存在，否则 decompressFile 报 900002
      fs.mkdirSync(targetDir, true);
      await zlib.decompressFile(tmpZip, targetDir);

      const parsed: SongEntry[] = [];
      this.scanDir(targetDir, id, '', 0, parsed);

      if (parsed.length === 0) {
        this.removeDir(targetDir);
        result.message = '这个 .osz 里没有可用的 osu!standard 谱面';
        return result;
      }

      // 按 标题+难度名 去重：重复导入同一张 .osz（比如连点两次示例按钮）
      // 不应该在列表里堆出两行。osu! 自己也是按目录去重的思路。
      let added = 0;
      let skipped = 0;
      for (let i = 0; i < parsed.length; i++) {
        if (this.findByTitleVersion(parsed[i].title, parsed[i].version) !== null) {
          skipped++;
          continue;
        }
        this.songs.push(parsed[i]);
        added++;
      }

      if (added === 0) {
        // 一个都没新增，刚解压出来的目录就是纯垃圾，删掉
        this.removeDir(targetDir);
        result.ok = true;
        result.imported = parsed;
        result.total = this.songs.length;
        result.message = '这张图已经在库里了';
        return result;
      }

      this.sort();
      this.save();

      result.ok = true;
      result.imported = parsed;
      result.total = this.songs.length;
      result.message = skipped > 0 ? `导入 ${added} 个难度（${skipped} 个已存在）` : `导入 ${added} 个难度`;
      hilog.info(DOMAIN, TAG, 'imported %{public}d beatmaps into %{public}s', added, id);
      return result;
    } catch (err) {
      const be = err as BusinessError;
      result.message = `导入失败: ${be.code} ${be.message}`;
      hilog.error(DOMAIN, TAG, 'import failed: %{public}s', JSON.stringify(err));
      this.removeDir(targetDir);
      return result;
    }
  }

  private removeFile(path: string): void {
    if (path.length === 0) {
      return;
    }
    try {
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      // 临时文件删不掉不影响主流程
    }
  }

  /**
   * 递归找 .osu 并解析。
   * relDir 是相对歌库目录的子路径（有些 .osz 会多包一层文件夹）。
   */
  private scanDir(dir: string, id: string, relDir: string, depth: number, out: SongEntry[]): void {
    if (depth > 3) {
      return;
    }
    let names: string[] = [];
    try {
      names = fs.listFileSync(dir);
    } catch (err) {
      return;
    }

    for (let i = 0; i < names.length; i++) {
      const name = names[i];
      const full = `${dir}/${name}`;
      const rel = relDir.length === 0 ? name : `${relDir}/${name}`;

      let isDir = false;
      try {
        isDir = fs.statSync(full).isDirectory();
      } catch (err) {
        continue;
      }

      if (isDir) {
        this.scanDir(full, id, rel, depth + 1, out);
        continue;
      }
      if (!name.toLowerCase().endsWith('.osu')) {
        continue;
      }

      const entry = this.parseOsu(dir, name, rel, id);
      if (entry !== null) {
        out.push(entry);
      }
    }
  }

  private parseOsu(dir: string, fileName: string, relPath: string, id: string): SongEntry | null {
    const full = `${dir}/${fileName}`;
    try {
      const text = fs.readTextSync(full);
      const decoded: DecodedBeatmap = LegacyOsuDecoder.decode(text);

      // 只收 osu!standard。taiko/catch/mania 的物件模型完全不同，现在导进来也玩不了，
      // 与其放着点了就崩，不如直接跳过并计数。
      if (decoded.general.mode !== 0) {
        hilog.info(DOMAIN, TAG, 'skip non-standard beatmap: %{public}s mode=%{public}d',
          fileName, decoded.general.mode);
        return null;
      }
      if (decoded.hitObjects.length === 0) {
        return null;
      }

      const e = new SongEntry();
      e.id = id;
      e.title = decoded.metadata.title.length > 0 ? decoded.metadata.title : fileName;
      e.artist = decoded.metadata.artist;
      e.creator = decoded.metadata.creator;
      e.version = decoded.metadata.version;
      e.osuFile = relPath;
      e.objectCount = decoded.hitObjects.length;

      // 时长 = 最后一个物件的结束时间（spinner 取 endTime）
      let last = 0;
      for (let i = 0; i < decoded.hitObjects.length; i++) {
        const o = decoded.hitObjects[i];
        const t = o.endTime > 0 ? o.endTime : o.time;
        if (t > last) {
          last = t;
        }
      }
      e.lengthMs = last;

      const timing = decoded.controlPoints.timingPointAt(0);
      e.bpm = timing.beatLength > 0 ? 60000 / timing.beatLength : 0;

      e.ar = decoded.difficulty.approachRate;
      e.od = decoded.difficulty.overallDifficulty;
      e.cs = decoded.difficulty.circleSize;
      e.hp = decoded.difficulty.drainRate;
      e.mode = decoded.general.mode;

      e.audioFile = this.resolveAudio(dir, decoded.metadata.audioFile);
      if (e.audioFile.length === 0) {
        hilog.warn(DOMAIN, TAG, 'no audio found for %{public}s', fileName);
      }
      // [Events] 的 0,0,"bg.jpg" 那行已经解码进 background.filename
      e.backgroundFile = this.resolveBackground(dir, decoded.background.filename);
      return e;
    } catch (err) {
      hilog.error(DOMAIN, TAG, 'parse failed: %{public}s %{public}s', fileName, JSON.stringify(err));
      return null;
    }
  }

  /**
   * 找到实际存在的音频文件。
   * .osu 里写的 AudioFilename 大小写常和实际文件名不一致（Windows 不敏感、这里敏感），
   * 所以要按不区分大小写再匹配一次；再不行就退到目录里第一个 mp3/ogg。
   */
  private resolveAudio(dir: string, declared: string): string {
    return this.resolveAsset(dir, declared, AUDIO_EXT, '');
  }

  /**
   * 找背景图（选歌封面）。
   *
   * 和音频不同，这里**不做"随便挑一张图"的兜底**：.osz 里通常还有一堆皮肤贴图
   * （hitcircle.png、sliderb.png…），乱挑会把判定圈当封面贴出来。
   * 所以只在"声明缺失"时退一步找 `bg` 开头的图片，找不到就给空串，
   * 让 UI 回落到渐变色块 —— 难看一点，但不会错。
   */
  private resolveBackground(dir: string, declared: string): string {
    const found = this.resolveAsset(dir, declared, IMAGE_EXT, '');
    if (found.length > 0) {
      return found;
    }
    const names = this.listNames(dir);
    for (let i = 0; i < names.length; i++) {
      const lower = names[i].toLowerCase();
      if (!lower.startsWith('bg') || !SongLibrary.hasAnyExt(lower, IMAGE_EXT)) {
        continue;
      }
      return names[i];
    }
    return '';
  }

  private static hasAnyExt(name: string, exts: string[]): boolean {
    for (let i = 0; i < exts.length; i++) {
      if (name.endsWith(exts[i])) {
        return true;
      }
    }
    return false;
  }

  private listNames(dir: string): string[] {
    try {
      return fs.listFileSync(dir);
    } catch (err) {
      return [];
    }
  }

  /**
   * 在 dir 里找 declared 指向的文件：先精确匹配文件名（忽略大小写），
   * 再往同名子目录钻一层（有些包会多包一层文件夹），最后按扩展名兜底。
   * fallbackPrefix 非空时，最后一步只认这个前缀的文件名。
   */
  private resolveAsset(dir: string, declared: string, exts: string[], fallbackPrefix: string): string {
    const names = this.listNames(dir);

    if (declared.length > 0) {
      const want = declared.toLowerCase();
      for (let i = 0; i < names.length; i++) {
        if (names[i].toLowerCase() === want) {
          return names[i];
        }
      }
      // 有些包会把文件放在同名子目录里，再找一层
      for (let i = 0; i < names.length; i++) {
        const sub = `${dir}/${names[i]}`;
        try {
          if (!fs.statSync(sub).isDirectory()) {
            continue;
          }
          const subNames = fs.listFileSync(sub);
          for (let k = 0; k < subNames.length; k++) {
            if (subNames[k].toLowerCase() === want) {
              return `${names[i]}/${subNames[k]}`;
            }
          }
        } catch (err) {
          continue;
        }
      }
    }

    for (let i = 0; i < names.length; i++) {
      const lower = names[i].toLowerCase();
      if (SongLibrary.hasAnyExt(lower, exts)) {
        if (fallbackPrefix.length === 0 || lower.startsWith(fallbackPrefix)) {
          return names[i];
        }
      }
    }
    return '';
  }

  /** 判断某个难度是否已经在库里（标题 + 难度名，忽略大小写） */
  private findByTitleVersion(title: string, version: string): SongEntry | null {
    const t = title.toLowerCase();
    const v = version.toLowerCase();
    for (let i = 0; i < this.songs.length; i++) {
      const s = this.songs[i];
      if (s.title.toLowerCase() === t && s.version.toLowerCase() === v) {
        return s;
      }
    }
    return null;
  }

  private removeDir(dir: string): void {
    try {
      if (fs.accessSync(dir)) {
        fs.rmdirSync(dir);
      }
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'removeDir failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 删除一首（含磁盘目录）。同一 id 下最后一个难度被删时目录一起删。 */
  deleteSong(entry: SongEntry): void {
    // 空 id 是"没有难度"的占位对象：继续走下去会算到 Songs/ 本身，
    // 把整个谱面库目录删掉。
    if (entry.id.length === 0) {
      return;
    }
    for (let i = this.songs.length - 1; i >= 0; i--) {
      if (this.songs[i].id === entry.id && this.songs[i].version === entry.version
        && this.songs[i].osuFile === entry.osuFile) {
        this.songs.splice(i, 1);
      }
    }
    let stillUsed = false;
    for (let i = 0; i < this.songs.length; i++) {
      if (this.songs[i].id === entry.id) {
        stillUsed = true;
        break;
      }
    }
    if (!stillUsed) {
      this.removeDir(`${this.songsDir}/${entry.id}`);
    }
    this.save();
  }
}
