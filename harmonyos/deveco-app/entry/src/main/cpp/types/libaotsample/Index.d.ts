/**
 * libaotsample.so 的 ArkTS 类型声明。
 * M0 尖刀：验证 .NET NativeAOT 产物（Hello.so）能否在 OHOS 进程里加载并执行。
 * 通过后和 cpp/aot_sample.cpp、EntryAbility 里的调用一起删。
 */

/**
 * 调用 Hello.so 里 [UnmanagedCallersOnly(EntryPoint="ohos_hello")] 导出的函数。
 * 内部 dlopen("Hello.so") → dlsym("ohos_hello") → 传 21，期望返回 84。
 * dlopen 或 dlsym 失败会抛 JS 异常（napi_throw_error）。
 */
export const hello: () => number;
export const sdlGate: () => string;
