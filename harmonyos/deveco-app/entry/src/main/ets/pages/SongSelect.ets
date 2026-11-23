import { picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { display } from '@kit.ArkUI';

import { SongEntry, ImportResult } from '../osu/library/SongEntry';
import { SongLibrary } from '../osu/library/SongLibrary';
import { SongBridge } from '../osu/library/SongBridge';
import { SongGroup, SongGrouping } from '../osu/library/SongGrouping';

/**
 * 选歌页 —— 按 osu!lazer 移动端（Argon 皮肤）的 SongSelect 复刻。
 *
 * 布局直接对着真机录屏量的比例：
 *   左栏（宽 30%）：谱面详情卡 —— 标题/艺术家、统计行、mapped by、判定参数表、
 *                   详情/排行榜标签、范围/排序/已选模组、成绩占位。
 *   右栏（宽 41%）：搜索框 + 筛选行，下面是**竖向轮播**：
 *                   选中那首展开成"头部 + 若干难度行"，其余只显示一行。
 *   底部工具条：返回 / 模组 / 随机 / 设置 四个斜切按钮，右下角压一个大 osu! logo。
 *   背景：当前谱面封面，模糊 + 压暗。
 *
 * 所有尺寸按屏幕高/宽的百分比给（vh/vw），换分辨率比例不变 —— lazer 自己也全是
 * RelativeSizeAxes，量的比例和它的设计意图是同一回事。
 */
@Entry
@Component
struct SongSelect {
  @State groups: SongGroup[] = [];
  @State shown: SongGroup[] = [];
  @State index: number = 0;
  @State query: string = '';
  @State importing: boolean = false;
  @State message: string = '';
  @State vw: number = 948;
  @State vh: number = 420;

  private library: SongLibrary | null = null;
  private listScroller: Scroller = new Scroller();
  private settings: RenderingContextSettings = new RenderingContextSettings(true);
  /** 底部四个斜切按钮各一块画布 */
  private toolCtx: CanvasRenderingContext2D[] = [
    new CanvasRenderingContext2D(this.settings),
    new CanvasRenderingContext2D(this.settings),
    new CanvasRenderingContext2D(this.settings),
    new CanvasRenderingContext2D(this.settings)
  ];

  aboutToAppear(): void {
    this.measureScreen();
    this.library = new SongLibrary(getContext(this).filesDir);
    this.reload();
  }

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

  private px(f: number): number {
    return this.vw * f;
  }

  private py(f: number): number {
    return this.vh * f;
  }

  // ------------------------------------------------------------ 数据

  private reload(): void {
    const lib = this.library;
    if (lib === null) {
      return;
    }
    const songs = lib.load();
    this.groups = SongGrouping.group(songs);
    this.applyFilter();
  }

  private applyFilter(): void {
    this.shown = SongGrouping.filter(this.groups, this.query);
    if (this.index >= this.shown.length) {
      this.index = 0;
    }
  }

  private current(): SongGroup | null {
    if (this.shown.length === 0) {
      return null;
    }
    return this.shown[Math.min(this.index, this.shown.length - 1)];
  }

  /** 沙箱文件给 Image 用 file:// 前缀；空路径返回空串，调用方据此走占位 */
  private coverUri(folderId: string, fileName: string): string {
    if (folderId.length === 0 || fileName.length === 0) {
      return '';
    }
    const lib = this.library;
    if (lib === null) {
      return '';
    }
    const entry = new SongEntry();
    entry.id = folderId;
    entry.backgroundFile = fileName;
    const p = lib.backgroundPath(entry);
    return p.length === 0 ? '' : `file://${p}`;
  }

  private coverOf(g: SongGroup): string {
    return this.coverUri(g.id, g.backgroundFile);
  }

  /** 没有封面时的占位色：按标题哈希取色，同一首歌永远同一个色 */
  private placeholder(g: SongGroup): string {
    const key = `${g.title}|${g.artist}`;
    let h = 0;
    for (let i = 0; i < key.length; i++) {
      h = (h * 31 + key.charCodeAt(i)) % 360;
    }
    return `hsl(${h}, 34%, 26%)`;
  }

  private primaryOf(g: SongGroup): SongEntry {
    return g.primary();
  }

  // ------------------------------------------------------------ 交互

  private play(song: SongEntry): void {
    SongBridge.select(song.id, `${song.displayTitle()} [${song.version}]`, song.osuFile);
    this.getUIContext().getRouter().pushUrl({ url: 'pages/Play' });
  }

  private playBuiltin(): void {
    SongBridge.select('', '内置测试谱 Renatus [Insane]', '');
    this.getUIContext().getRouter().pushUrl({ url: 'pages/Play' });
  }

  private randomPick(): void {
    if (this.shown.length === 0) {
      return;
    }
    this.index = Math.floor(Math.random() * this.shown.length) % this.shown.length;
    this.listScroller.scrollToIndex(this.index);
  }

  private async importOsz(): Promise<void> {
    if (this.importing) {
      return;
    }
    this.importing = true;
    this.message = '选择 .osz 文件…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const documentPicker = new picker.DocumentViewPicker(ctx);
      const uris = await documentPicker.select({
        maxSelectNumber: 1,
        fileSuffixFilters: ['.osz']
      });
      if (uris.length === 0) {
        this.message = '已取消';
        return;
      }
      const lib = this.library;
      if (lib === null) {
        return;
      }
      this.message = '正在解压…';
      const result: ImportResult = await lib.importOsz(uris[0]);
      this.message = result.message;
      this.reload();
    } catch (err) {
      this.message = `导入出错: ${JSON.stringify(err)}`;
      hilog.error(0x0F0F, 'OSU-LIB', 'picker/import failed: %{public}s', JSON.stringify(err));
    } finally {
      this.importing = false;
    }
  }

  /**
   * 导入内置示例谱面。
   *
   * 真机上没法自动把 .osz 放进相册/下载（hdc 推不进 /sdcard），所以示例谱
   * 直接打进 HAP 的 rawfile。除了字节来源，解压/解析/索引跟 picker 导入
   * 是同一条路径 —— 示例跑通即代表真实 .osz 也能跑通。
   */
  private async importSample(): Promise<void> {
    if (this.importing) {
      return;
    }
    const lib = this.library;
    if (lib === null) {
      return;
    }
    this.importing = true;
    this.message = '正在解压示例谱面…';
    try {
      const ctx = getContext(this);
      const bytes = await ctx.resourceManager.getRawFileContent('sample_beats.osz');
      // getRawFileContent 给的可能是共享 buffer 的视图，拷一份保证起始偏移为 0
      const ab: ArrayBuffer = bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength);
      const result: ImportResult = await lib.importFromBytes(ab);
      this.message = result.message;
      this.reload();
    } catch (err) {
      this.message = `示例谱面导入出错: ${JSON.stringify(err)}`;
      hilog.error(0x0F0F, 'OSU-LIB', 'sample import failed: %{public}s', JSON.stringify(err));
    } finally {
      this.importing = false;
    }
  }

  // ------------------------------------------------------------ 绘制

  /** 底部工具条按钮：Argon 的斜切平行四边形 */
  private drawTool(index: number, colour: string): void {
    const c = this.toolCtx[index];
    const w = c.width;
    const h = c.height;
    if (w <= 0 || h <= 0) {
      return;
    }
    c.clearRect(0, 0, w, h);
    const skew = h * 0.34;
    c.fillStyle = colour;
    c.beginPath();
    c.moveTo(skew, 0);
    c.lineTo(w, 0);
    c.lineTo(w - skew, h);
    c.lineTo(0, h);
    c.closePath();
    c.fill();
  }

  /** 难度点：一首歌有几个难度就几个点，颜色按 AR 从绿到红 */
  private spreadColour(ar: number): string {
    if (ar < 8) {
      return '#7ED957';
    }
    if (ar < 9) {
      return '#FFD24D';
    }
    if (ar < 9.7) {
      return '#FF9F4D';
    }
    return '#FF4D6A';
  }

  // ------------------------------------------------------------ 左栏

  @Builder
  statChip(label: string, value: string) {
    Row({ space: this.py(0.004) }) {
      Text(value)
        .fontSize(this.py(0.020))
        .fontWeight(FontWeight.Medium)
        .fontColor('#E4EFEB')
      Text(label)
        .fontSize(this.py(0.015))
        .fontColor('#8FA8A2')
    }
    .margin({ right: this.px(0.016) })
  }

  @Builder
  paramCell(label: string, value: string) {
    Column({ space: this.py(0.002) }) {
      Text(label)
        .fontSize(this.py(0.016))
        .fontColor('#8FA8A2')
      Text(value)
        .fontSize(this.py(0.020))
        .fontColor('#E4EFEB')
    }
    .alignItems(HorizontalAlign.Start)
    .margin({ right: this.px(0.014) })
  }

  @Builder
  leftPanel() {
    Column({ space: this.py(0.006) }) {
      if (this.current() !== null) {
        Text((this.current() as SongGroup).title)
          .fontSize(this.py(0.034))
          .fontWeight(FontWeight.Bold)
          .fontColor('#F4FAFA')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.current() as SongGroup).artist)
          .fontSize(this.py(0.022))
          .fontColor('#C6D6D1')

        Row() {
          this.statChip('物件', `${this.primaryOf(this.current() as SongGroup).objectCount}`)
          this.statChip('时长', this.primaryOf(this.current() as SongGroup).lengthText())
          this.statChip('BPM', `${Math.round(this.primaryOf(this.current() as SongGroup).bpm)}`)
        }
        .margin({ top: this.py(0.006) })

        Row({ space: this.py(0.005) }) {
          Text('✦')
            .fontSize(this.py(0.018))
            .fontColor('#7ED957')
          Text(`mapped by ${this.primaryOf(this.current() as SongGroup).creator}`)
            .fontSize(this.py(0.019))
            .fontColor('#7ED957')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .margin({ top: this.py(0.004), bottom: this.py(0.006) })

        Divider().color('#22FFFFFF')

        // 判定参数表（lazer 详情区的 7 个格子，这里给能算出来的几项）
        Row() {
          this.paramCell('物件', `${this.primaryOf(this.current() as SongGroup).objectCount}`)
          this.paramCell('圆圈大小', `${this.primaryOf(this.current() as SongGroup).cs.toFixed(0)}`)
          this.paramCell('圆圈速度', `${this.primaryOf(this.current() as SongGroup).ar.toFixed(1)}`)
          this.paramCell('准度要求', `${this.primaryOf(this.current() as SongGroup).od.toFixed(0)}`)
          this.paramCell('掉血速度', `${this.primaryOf(this.current() as SongGroup).hp.toFixed(0)}`)
        }
        .margin({ top: this.py(0.008) })

        // 详情 / 排行榜
        Row({ space: this.py(0.014) }) {
          Text('详情')
            .fontSize(this.py(0.019))
            .fontColor('#F4FAFA')
            .fontWeight(FontWeight.Bold)
          Text('排行榜')
            .fontSize(this.py(0.019))
            .fontColor('#7E8F8A')
        }
        .margin({ top: this.py(0.012) })

        // 范围 / 排序 / 已选模组（lazer 的筛选行，这里只做展示）
        Row({ space: this.py(0.006) }) {
          Text('范围  本地')
            .fontSize(this.py(0.017))
            .fontColor('#C6D6D1')
            .backgroundColor('#33FFFFFF')
            .borderRadius(this.py(0.004))
            .padding({
              left: this.py(0.008), right: this.py(0.008),
              top: this.py(0.004), bottom: this.py(0.004)
            })
          Text('排序  分数')
            .fontSize(this.py(0.017))
            .fontColor('#C6D6D1')
            .backgroundColor('#33FFFFFF')
            .borderRadius(this.py(0.004))
            .padding({
              left: this.py(0.008), right: this.py(0.008),
              top: this.py(0.004), bottom: this.py(0.004)
            })
          Text('已选模组')
            .fontSize(this.py(0.017))
            .fontColor('#8FA8A2')
            .padding({
              left: this.py(0.006), right: this.py(0.006),
              top: this.py(0.004), bottom: this.py(0.004)
            })
        }
        .margin({ top: this.py(0.008) })

        Text('ⓘ  暂无成绩！')
          .fontSize(this.py(0.019))
          .fontColor('#C6D6D1')
          .margin({ top: this.py(0.014) })
      } else {
        Text('谱面库为空')
          .fontSize(this.py(0.024))
          .fontColor('#C6D6D1')
        Text('用右侧「导入」加一首，或者点「示例谱面」')
          .fontSize(this.py(0.018))
          .fontColor('#8FA8A2')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width(this.px(0.300))
    .padding(this.py(0.014))
    .borderRadius(this.py(0.014))
    .backgroundColor('#A6141818')
  }

  // ------------------------------------------------------------ 右栏：搜索 + 轮播

  @Builder
  difficultyRow(g: SongGroup, e: SongEntry) {
    Row() {
      Text(e.version)
        .fontSize(this.py(0.019))
        .fontColor('#E4EFEB')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      Text(`${e.ar.toFixed(1)}★`)
        .fontSize(this.py(0.017))
        .fontColor(this.spreadColour(e.ar))
        .margin({ left: this.py(0.008) })
      Text(`${e.objectCount}`)
        .fontSize(this.py(0.016))
        .fontColor('#8FA8A2')
        .width(this.px(0.030))
        .textAlign(TextAlign.End)
    }
    .width('100%')
    .height(this.py(0.058))
    .padding({ left: this.py(0.014), right: this.py(0.012) })
    .borderRadius(this.py(0.008))
    .backgroundColor('#4D1A2224')
    .margin({ top: this.py(0.004) })
    .onClick(() => {
      this.play(e);
    })
  }

  @Builder
  songRow(g: SongGroup, i: number) {
    if (i === this.index) {
      Column() {
        // 头部：封面小图 + 标题 + 难度点
        Row({ space: this.py(0.010) }) {
          Stack() {
            if (this.coverOf(g).length > 0) {
              Image(this.coverOf(g))
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            } else {
              Column().width('100%').height('100%').backgroundColor(this.placeholder(g))
            }
          }
          .width(this.py(0.070))
          .height(this.py(0.070))
          .borderRadius(this.py(0.008))
          .clip(true)

          Column({ space: this.py(0.003) }) {
            Text(g.title)
              .fontSize(this.py(0.024))
              .fontWeight(FontWeight.Bold)
              .fontColor('#F4FAFA')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(g.artist)
              .fontSize(this.py(0.017))
              .fontColor('#C6D6D1')
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Row({ space: this.py(0.003) }) {
              ForEach(g.difficulties, (d: SongEntry) => {
                Circle()
                  .width(this.py(0.009))
                  .height(this.py(0.009))
                  .fill(this.spreadColour(d.ar))
              }, (d: SongEntry) => `${d.version}`)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding(this.py(0.010))

        // 难度行
        ForEach(g.difficulties, (d: SongEntry) => {
          this.difficultyRow(g, d)
        }, (d: SongEntry) => `${d.id}-${d.version}`)
      }
      .width('100%')
      .padding({ left: this.py(0.008), right: this.py(0.008), bottom: this.py(0.008) })
      .borderRadius(this.py(0.010))
      .backgroundColor('#CC141A1C')
      .onClick(() => {
        this.index = i;
      })
    } else {
      Row() {
        Column({ space: this.py(0.002) }) {
          Text(g.title)
            .fontSize(this.py(0.020))
            .fontColor('#DCE8E4')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(g.artist)
            .fontSize(this.py(0.016))
            .fontColor('#8FA8A2')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: this.py(0.014), right: this.py(0.014),
        top: this.py(0.008), bottom: this.py(0.008)
      })
      .borderRadius(this.py(0.008))
      .backgroundColor('#7A141A1C')
      .margin({ top: this.py(0.005) })
      .onClick(() => {
        this.index = i;
      })
    }
  }

  @Builder
  rightPanel() {
    Column({ space: this.py(0.008) }) {
      // 搜索 + 计数 + 导入
      Row({ space: this.py(0.008) }) {
        TextInput({ placeholder: '搜索……', text: this.query })
          .placeholderColor('#66FFFFFF')
          .fontSize(this.py(0.019))
          .fontColor('#F4FAFA')
          .backgroundColor('#33FFFFFF')
          .borderRadius(this.py(0.006))
          .height(this.py(0.048))
          .layoutWeight(1)
          .onChange((v: string) => {
            this.query = v;
            this.applyFilter();
          })
        Text(this.importing ? '…' : '导入')
          .fontSize(this.py(0.019))
          .fontColor('#12121A')
          .backgroundColor('#5FE0E8')
          .borderRadius(this.py(0.006))
          .padding({
            left: this.py(0.014), right: this.py(0.014),
            top: this.py(0.008), bottom: this.py(0.008)
          })
          .onClick(() => {
            this.importOsz();
          })
      }
      .width('100%')

      Row({ space: this.py(0.008) }) {
        Text(`${this.shown.length} 张图 / ${SongGrouping.difficultyCount(this.shown)} 个难度`)
          .fontSize(this.py(0.017))
          .fontColor('#8FA8A2')
        Blank()
        Text('示例谱面')
          .fontSize(this.py(0.016))
          .fontColor('#8FC7E8')
          .onClick(() => {
            this.importSample();
          })
        Text('内置测试谱')
          .fontSize(this.py(0.016))
          .fontColor('#8FC7E8')
          .onClick(() => {
            this.playBuiltin();
          })
      }
      .width('100%')

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(this.py(0.016))
          .fontColor('#8FA8A2')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }

      // 竖向轮播
      List({ scroller: this.listScroller }) {
        ForEach(this.shown, (g: SongGroup, i: number) => {
          ListItem() {
            this.songRow(g, i)
          }
        }, (g: SongGroup) => g.id)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width(this.px(0.395))
    .height(this.py(0.80))
    .padding(this.py(0.010))
    .borderRadius(this.py(0.014))
    .backgroundColor('#A6141818')
  }

  // ------------------------------------------------------------ 底部工具条

  @Builder
  toolButton(index: number, icon: string, label: string, colour: string, action: () => void) {
    Stack({ alignContent: Alignment.Center }) {
      Canvas(this.toolCtx[index])
        .width(this.px(0.115))
        .height(this.py(0.085))
        .onReady(() => {
          this.drawTool(index, colour);
        })
      Column({ space: this.py(0.002) }) {
        Text(icon)
          .fontSize(this.py(0.024))
          .fontColor('#F4FAFA')
        Text(label)
          .fontSize(this.py(0.016))
          .fontColor('#F4FAFA')
      }
    }
    .width(this.px(0.115))
    .height(this.py(0.085))
    .onClick(action)
  }

  @Builder
  bottomBar() {
    Stack({ alignContent: Alignment.TopStart }) {
      Row({ space: this.py(0.010) }) {
        this.toolButton(0, '‹', '返回', '#E5368C', () => {
          this.getUIContext().getRouter().back();
        })
        this.toolButton(1, '⚙', '模组', '#2E3A3A', () => {
        })
        this.toolButton(2, '🔀', '随机', '#2E3A3A', () => {
          this.randomPick();
        })
        this.toolButton(3, '⚙', '设置', '#2E3A3A', () => {
        })
      }
      .position({ x: this.px(0.055), y: 0 })

      // 右下角大 osu! logo，故意压出屏幕外
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(this.px(0.150))
          .height(this.px(0.150))
          .fill('#E5368C')
        Text('osu!')
          .fontSize(this.px(0.048))
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .position({ x: this.px(0.905), y: this.py(0.020) })
    }
    .width('100%')
    .height(this.py(0.10))
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 背景：当前谱面封面，模糊 + 压暗
      if (this.current() !== null && this.coverOf(this.current() as SongGroup).length > 0) {
        Image(this.coverOf(this.current() as SongGroup))
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .blur(26)
          .scale({ x: 1.16, y: 1.16 })
          .opacity(0.55)
      } else {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#101416')
      }
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#9A0A0E10')

      Stack({ alignContent: Alignment.TopStart }) {
        Column() {
          this.leftPanel()
        }
        .position({ x: this.px(0.022), y: this.py(0.030) })

        Column() {
          this.rightPanel()
        }
        .position({ x: this.px(0.575), y: this.py(0.030) })

        Column() {
          this.bottomBar()
        }
        .position({ x: 0, y: this.py(0.880) })
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0A0E10')
  }
}
