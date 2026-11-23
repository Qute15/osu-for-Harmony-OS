// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.
//
// ArkTS <-> native 桥接的托管侧占位（M2/Task #4）。
// M1 先给出不依赖任何 native symbol 的可用默认值，保证 C# 层能独立编译运行；
// 后续换成 P/Invoke 进 libohos_host.so 由 ArkTS 传真实 filesDir / nativeWindow。

using System;
using System.IO;
using System.Runtime.InteropServices;

namespace osu.Framework.OHOS
{
    internal static class OHOSHostBridge
    {
        private const string HILIB = "libhilog_ndk.z.so";
        private const int LOG_APP = 0;
        private const int LOG_ERROR = 6;
        private const uint DOMAIN = 0xA0A0;

        [DllImport(HILIB, EntryPoint = "OH_LOG_PrintMsg", CallingConvention = CallingConvention.Cdecl)]
        private static extern int PrintMsg(
            int type, int level, uint domain,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string tag,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string message);

        /// <summary>
        /// 平台层的诊断日志通道。
        /// 必须存在的原因：GameHost.ChooseAndSetupRenderer() 会 catch 掉所有渲染/窗口初始化异常，
        /// 只留一句 "No usable renderer was found!"，在 OHOS 上完全看不出是
        /// XComponent 没就绪、EGL 失败还是 SDL_CreateWindow 返回 null。
        /// </summary>
        internal static void LogError(string message)
        {
            try
            {
                foreach (string part in Chunk(message, 900))
                    PrintMsg(LOG_APP, LOG_ERROR, DOMAIN, "OSU-OHOS", part);
            }
            catch
            {
                // 日志通道自身不能再抛（否则会把真实异常盖掉）。
            }
        }

        private static System.Collections.Generic.IEnumerable<string> Chunk(string s, int size)
        {
            for (int i = 0; i < s.Length; i += size)
                yield return s.Substring(i, Math.Min(size, s.Length - i));
        }

        /// <summary>Set by XComponent OnSurfaceCreated/OnSurfaceDestroyed.</summary>
        internal static bool IsSurfaceReady { get; set; } = true;

        /// <summary>
        /// ArkTS 应通过 NAPI 传 context.filesDir。当前使用 OHOS 应用沙箱的标准可写路径
        /// /data/storage/el2/base/files（设备日志 Recovery: fileDir 已确认）。
        /// 注意 AppContext.BaseDirectory 在 NativeAOT .so 里是 /system/bin/，不可写，
        /// 不能拿来当 storage 根目录。
        /// </summary>
        internal static string UserStoragePath()
        {
            string fromEnv = Environment.GetEnvironmentVariable("OSU_OHOS_FILES_DIR");
            if (!string.IsNullOrEmpty(fromEnv))
                return fromEnv;

            return Path.Combine("/data/storage/el2/base/files", "osu");
        }

        /// <summary>
        /// HAP 内原生库目录。崩溃栈里实测为 /data/storage/el1/bundle/libs/&lt;abi&gt;。
        /// 供 AppContext 的 NATIVE_DLL_SEARCH_DIRECTORIES 使用（冒号分隔列表）。
        /// </summary>
        internal static string NativeLibraryPath()
        {
            string fromEnv = Environment.GetEnvironmentVariable("OSU_OHOS_LIBS_DIR");
            if (!string.IsNullOrEmpty(fromEnv))
                return fromEnv;

            string abi = RuntimeInformation.ProcessArchitecture switch
            {
                Architecture.X64 => "x86_64",
                Architecture.Arm64 => "arm64-v8a",
                Architecture.X86 => "x86",
                Architecture.Arm => "armeabi-v7a",
                _ => "arm64-v8a",
            };

            return $"/data/storage/el1/bundle/libs/{abi}";
        }
    }
}
