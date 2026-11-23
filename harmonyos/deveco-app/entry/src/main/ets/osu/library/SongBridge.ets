/**
 * 选歌页 → 游玩页的传参通道。
 *
 * 为什么不用 router 参数：`getParams()` 返回 Object，ArkTS 严格模式下
 * 取字段要写一堆断言；AppStorage 直接用泛型读，类型干净。
 * 单独放一个文件是为了避免 Play 反过来 import SongSelect（页面互相引用）。
 */
export class SongBridge {
  /** 空字符串表示用内建测试谱 */
  static readonly ID_KEY: string = 'osu.songId';
  static readonly LABEL_KEY: string = 'osu.songLabel';
  /**
   * 谱面文件相对路径。同一张 .osz 的 8 个难度共享一个 id（同一个目录），
   * 光靠 id 只能定位到目录、拿到的永远是第一个难度，所以必须再带上 osuFile。
   */
  static readonly FILE_KEY: string = 'osu.songFile';

  static select(id: string, label: string, osuFile: string): void {
    AppStorage.setOrCreate<string>(SongBridge.ID_KEY, id);
    AppStorage.setOrCreate<string>(SongBridge.LABEL_KEY, label);
    AppStorage.setOrCreate<string>(SongBridge.FILE_KEY, osuFile);
  }

  static currentId(): string {
    const v = AppStorage.get<string>(SongBridge.ID_KEY);
    return v === undefined ? '' : v;
  }

  static currentLabel(): string {
    const v = AppStorage.get<string>(SongBridge.LABEL_KEY);
    return v === undefined ? '' : v;
  }

  static currentFile(): string {
    const v = AppStorage.get<string>(SongBridge.FILE_KEY);
    return v === undefined ? '' : v;
  }
}
