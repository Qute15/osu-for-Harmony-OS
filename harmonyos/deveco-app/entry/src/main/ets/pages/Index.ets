/**
 * 路径 B：唯一的 UI 就是 SDL3 的 XComponent，画面全部由真 osu!lazer 绘制。
 *
 * libraryname: 'SDL3' 让系统加载 libSDL3.so 并把 OH_NativeXComponent 交给它；
 * SDL3 的 OPENHARMONY_CreateWindow() 会用这个 surface 建 EGL 上下文。
 * XComponent 的 id 必须和 SDL3 官方模板一致（SDL_XComponent）。
 *
 * 旧的 ArkTS 手绘主菜单已备份到 output/legacy-ts/Index.ets，
 * SongSelect.ets / Play.ets 仍留在工程里但不再作为入口。
 */
@Entry
@Component
struct Index {
  build() {
    Row() {
      Column() {
        XComponent({ id: 'SDL_XComponent', type: XComponentType.SURFACE, libraryname: 'SDL3' })
          .id('SDL_XComponent')
      }
      .width('100%')
    }
    .height('100%')
  }
}
