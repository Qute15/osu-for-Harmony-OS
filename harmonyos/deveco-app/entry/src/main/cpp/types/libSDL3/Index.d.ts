/**
 * libSDL3.so 的 ArkTS 类型声明（SDL3 官方 OpenHarmony 后端的 NAPI 入口）。
 *
 * 参数个数必须与 SDL-main/src/core/openharmony/SDL_openharmony.c:1076-1095 一致：
 *   SDL_JS_ProvideArkTSObjects() 里 expected_argc = 5，少一个会直接 exit(1)。
 * 顺序：ability / atManager / i18n.System / pointer.setPointerVisibleSync /
 *       inputMethod.getController()
 *
 * 官方 openharmony-project 模板里的 Index.d.ts 只声明了 3 个参数，是模板的疏漏；
 * 这里按 C 实现补全为 5 个。
 */
export const provideArkTSObjects: (
  ability: Object,
  atManager: Object,
  i18nSystem: Object,
  setPointerVisible: Object,
  imeController: Object
) => void;
