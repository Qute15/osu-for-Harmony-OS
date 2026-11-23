// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using System;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using osu.Framework.OHOS;

namespace osu.OHOS
{
    public static class NativeEntry
    {
        /// <summary>
        /// SDL3 for OpenHarmony calls this from a freshly-created thread
        /// (SDL_sysmain_runapp.c:61-73). Returning causes exit(), so Run() must block
        /// for the whole app lifetime.
        /// </summary>
        [UnmanagedCallersOnly(EntryPoint = "SDL_main")]
        public static unsafe int Main(int argc, byte** argv)
        {
            OHOSLog.Info("SDL_main entered (NativeAOT osu!lazer)");
            OHOSLog.Info($"invariant-globalization={OHOSLog.InvariantGlobalization}, "
                         + $"culture='{CultureInfo.CurrentCulture.Name}', "
                         + $"base='{AppContext.BaseDirectory}', cwd='{Environment.CurrentDirectory}'");

            AppDomain.CurrentDomain.UnhandledException += (_, e) =>
                OHOSLog.Error("UnhandledException: " + e.ExceptionObject);

            // 不要用 using：GameHost.Dispose() 在异常路径上也会抛
            // （LoadingComponentsLogger -> DebugUtils -> RuntimeInfo..cctor），
            // 会把 host.Run() 的原始异常整个盖掉，之前就吃过这个亏。
            OHOSGameHost host = null;
            bool runFailed = false;

            string mode = ReadMode();
            OHOSLog.Info($"osu-mode = '{mode}'");

            AttachFrameworkLogger();
            ProbeReflection();

            // 同样要全限定：osu.* 命名空间下裸写 Game 会命中 osu.Game 命名空间。
            osu.Framework.Game game = mode == "selftest" ? new SelfTestGame() : new OsuGameOHOS();

            try
            {
                host = new OHOSGameHost();
                host.Run(game);
                OHOSLog.Warn("GameHost.Run returned unexpectedly");
            }
            catch (Exception ex)
            {
                runFailed = true;
                OHOSLog.Error("host.Run failed: " + ex);
            }
            finally
            {
                if (host != null)
                {
                    try
                    {
                        host.Dispose();
                    }
                    catch (Exception ex)
                    {
                        // 单独记录，绝不让它掩盖 host.Run() 的异常。
                        OHOSLog.Error("host.Dispose failed (secondary): " + ex);
                    }
                }
            }

            // SDL3 OHOS 后端在 SDL_main 返回后固定调 exit()；返回非 0 会
            // 被系统记成 SIGABRT/[appspawn] Unexpected call: exit(1)，
            // 这是 SDL3 的正常行为，不是原生崩溃。
            return runFailed ? 1 : 0;
        }

        /// <summary>
        /// 反射可见性探针。
        ///
        /// NativeAOT 的裁剪会让「只被反射用到」的成员静默消失：`type.GetProperties()`
        /// 直接返回空，写入端于是序列化出 `{}`，读取端拿回一堆 null，
        /// 而抛异常的地方离真正原因很远（见 rd.xml 里关于 SpirvReflection 的说明）。
        ///
        /// 教训：一个属性的**任一**访问器被裁掉，NativeAOT 会连整个 Property
        /// 元数据记录一起丢掉——所以「有一个 getter 还在」并不代表这个属性可见。
        /// 启动时打一行成员名，就能区分「裁剪描述符生效了」和「描述符写错/漏了」，
        /// 不用再靠崩溃栈反推。
        /// </summary>
        private static void ProbeReflection()
        {
            try
            {
                Type reflectionType = typeof(Veldrid.SPIRV.SpirvReflection);
                var properties = reflectionType.GetProperties(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
                string propertyNames = string.Join(",", Array.ConvertAll(properties, p => p.Name));

                Type layoutType = typeof(Veldrid.ResourceLayoutDescription);
                string fieldNames = string.Join(",", Array.ConvertAll(layoutType.GetFields(), f => f.Name));

                Type elementType = typeof(Veldrid.ResourceLayoutElementDescription);
                string elementFieldNames = string.Join(",", Array.ConvertAll(elementType.GetFields(), f => f.Name));

                OHOSLog.Info($"reflection-probe: {reflectionType.Name}.props=[{propertyNames}]"
                             + $" | {layoutType.Name}.fields=[{fieldNames}]"
                             + $" | {elementType.Name}.fields=[{elementFieldNames}]");
            }
            catch (Exception ex)
            {
                OHOSLog.Warn("reflection-probe failed: " + ex);
            }
        }

        /// <summary>
        /// 把 osu.Framework 的 Logger 桥接到 hilog。
        ///
        /// 为什么必须做：lazer 大量使用「异步加载组件」
        /// （<c>loadComponentSingleFile</c>），异步加载里抛的异常不会中断游戏，
        /// 只由 <see cref="osu.Framework.Logging.Logger"/> 记一条 Error 就继续跑。
        /// 在 OHOS 上 Logger 的输出默认只写到 Storage 里的文件（或不写），
        /// hilog 完全看不到——于是表现为「某个子控件莫名其妙是 null」，
        /// 例如 M2 实测 `OsuGame.Settings` 为 null，导致
        /// `adjustGlobalScreenOffset()` 每帧 NRE。真正的报错在 Logger 里。
        ///
        /// 只转发 Important / Error，以及任何带 Exception 的条目：
        /// 全部转发会被 lazer 的 Verbose 日志刷爆 hilog（每帧几条）。
        /// </summary>
        private static void AttachFrameworkLogger()
        {
            osu.Framework.Logging.Logger.NewEntry += entry =>
            {
                try
                {
                    if (entry.Exception == null && entry.Level < osu.Framework.Logging.LogLevel.Important)
                        return;

                    string where = entry.LoggerName ?? entry.Target?.ToString() ?? "-";
                    string line = $"[{entry.Level}] {where}: {entry.Message}";

                    if (entry.Exception != null)
                        line += Environment.NewLine + entry.Exception;

                    OHOSLog.Info(line);
                }
                catch
                {
                    // 日志桥本身绝不能影响游戏运行。
                }
            };
        }

        /// <summary>
        /// 启动模式由 ArkTS 侧写进沙箱的一个小文本文件决定，
        /// 这样同一个 HAP 无需重编就能在「完整 lazer」与「平台自检」之间切换：
        ///   hdc shell aa start ... --ps osu_mode selftest
        /// EntryAbility 会把 want 参数落到这个文件；缺省即 lazer。
        /// </summary>
        private static string ReadMode()
        {
            // EntryAbility 侧用的是 context.filesDir，在 HarmonyOS 上实际是
            // /data/storage/el2/base/haps/<module>/files（实测日志确认）。
            // 旧路径保留作为兜底，避免以后目录布局调整时又静默回落。
            string[] candidates =
            {
                "/data/storage/el2/base/haps/entry/files/osu-mode.txt",
                "/data/storage/el2/base/files/osu-mode.txt",
            };

            foreach (string path in candidates)
            {
                try
                {
                    if (!File.Exists(path))
                        continue;

                    string text = File.ReadAllText(path).Trim().ToLowerInvariant();
                    if (text.Length > 0)
                        return text;
                }
                catch (Exception ex)
                {
                    OHOSLog.Warn($"ReadMode failed for {path}: {ex.Message}");
                }
            }

            return "lazer";
        }
    }

    /// <summary>
    /// 托管侧 hilog 通道。用 OH_LOG_PrintMsg（API 18+，固定 5 参数、非变参），
    /// 避开 C# P/Invoke 调 printf 风格可变参数函数的 ABI 坑。
    /// </summary>
    internal static class OHOSLog
    {
        private const string HILIB = "libhilog_ndk.z.so";
        private const int LOG_APP = 0;
        private const int LOG_INFO = 4;
        private const int LOG_WARN = 5;
        private const int LOG_ERROR = 6;
        private const uint DOMAIN = 0xA0A0;
        private const string TAG = "OSU-CS";

        [DllImport(HILIB, EntryPoint = "OH_LOG_PrintMsg", CallingConvention = CallingConvention.Cdecl)]
        private static extern int PrintMsg(
            int type, int level, uint domain,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string tag,
            [MarshalAs(UnmanagedType.LPUTF8Str)] string message);

        internal static bool InvariantGlobalization
            => AppContext.TryGetSwitch("System.Globalization.Invariant", out bool enabled) && enabled;

        private static void Write(int level, string message)
        {
            try
            {
                // hilog 单行长度有限，异常堆栈分段打印，避免被截断。
                foreach (string part in Chunk(message, 900))
                    PrintMsg(LOG_APP, level, DOMAIN, TAG, part);
            }
            catch
            {
                // 日志通道本身不能再抛异常（SDL_main 线程上抛会直接 failfast）。
            }
        }

        private static System.Collections.Generic.IEnumerable<string> Chunk(string s, int size)
        {
            for (int i = 0; i < s.Length; i += size)
                yield return s.Substring(i, Math.Min(size, s.Length - i));
        }

        internal static void Info(string m) => Write(LOG_INFO, m);
        internal static void Warn(string m) => Write(LOG_WARN, m);
        internal static void Error(string m) => Write(LOG_ERROR, m);
    }
}
