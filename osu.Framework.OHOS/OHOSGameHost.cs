// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.
//
// HarmonyOS counterpart of osu.Framework.Android.AndroidGameHost.
// Derives from SDLGameHost: windowing / GL / input are all handled by SDL3's
// official OpenHarmony backend, so this layer only supplies platform policy.

using System;
using System.Collections.Generic;
using osu.Framework;
using osu.Framework.Configuration;
using osu.Framework.Platform;

namespace osu.Framework.OHOS
{
    public class OHOSGameHost : SDLGameHost
    {
        public OHOSGameHost()
            : base(string.Empty)
        {
            // NativeAOT 共享库宿主里 Assembly.GetEntryAssembly() 为 null。
            // framework 在 GameHost.Run / UpdateManager 里会直接对 EntryAssembly
            // 调 GetName() / GetCustomAttribute()，不填就是 NullReferenceException。
            // AssemblyInfo.cs 已给 osu.Framework.OHOS 开 InternalsVisibleTo，可写这个 internal setter。
            RuntimeInfo.EntryAssembly = typeof(OHOSGameHost).Assembly;

            // 同理，桌面版 Library.Load 依赖这个 AppContext 数据；虽然 OSU_OHOS 分支
            // 已不读它，但其它依赖（NuGet 原生库解析逻辑）可能仍会查询，给个可用值。
            AppContext.SetData("NATIVE_DLL_SEARCH_DIRECTORIES", OHOSHostBridge.NativeLibraryPath());
        }

        protected override void SetupConfig(IDictionary<FrameworkSetting, object> defaultOverrides)
        {
            // Mobile backends must run single-threaded (same as AndroidGameHost.cs:37-43).
            if (!defaultOverrides.ContainsKey(FrameworkSetting.ExecutionMode))
                defaultOverrides.Add(FrameworkSetting.ExecutionMode, ExecutionMode.SingleThread);

            base.SetupConfig(defaultOverrides);
        }

        protected override IWindow CreateWindow(GraphicsSurfaceType preferredSurface)
            => new OHOSGameWindow(preferredSurface, Options.FriendlyGameName);

        /// <summary>
        /// OHOS 只有 SDL3 + OpenGL ES 一条渲染路径，Veldrid / Deferred 回退没有意义。
        /// 这里直接建 GL renderer 与窗口，并且**把失败原因完整抛出去**：
        /// 基类实现会把所有异常 catch 掉，最后只留一句
        /// "No usable renderer was found!"，随后 GameHost.Run 因 Window == null 静默 return，
        /// 在设备上表现为「SDL_main 进去了、0.7 秒后正常返回」，完全看不到根因（实测）。
        /// </summary>
        protected override void ChooseAndSetupRenderer()
        {
            try
            {
                SetupRendererAndWindow(CreateGLRenderer(), GraphicsSurfaceType.OpenGL);
            }
            catch (Exception e)
            {
                OHOSHostBridge.LogError("ChooseAndSetupRenderer failed: " + e);
                throw;
            }
        }

        protected override void DrawFrame()
        {
            // SDL3's OHOS backend receives the XComponent surface callbacks and
            // gates rendering itself; only skip while no surface exists yet.
            if (OHOSHostBridge.IsSurfaceReady)
                base.DrawFrame();
        }

        protected override void Swap()
        {
            // Android waits on Choreographer here. On OHOS the XComponent OnFrame
            // callback already drives frame pacing; do not add a second wait.
            base.Swap();
        }

        public override bool CanExit => false;

        public override bool CanSuspendToBackground => true;

        public override bool OnScreenKeyboardOverlapsGameWindow => true;

        public override Storage GetStorage(string path) => new OHOSStorage(path, this);

        public override IEnumerable<string> UserStoragePaths
            => new[] { OHOSHostBridge.UserStoragePath() };

        public override bool OpenFileExternally(string filename) => false;

        public override bool PresentFileExternally(string filename) => false;

        public override void OpenUrlExternally(string url)
        {
            // TODO(M4): route through OHOS Want / startAbility.
        }
    }
}
