// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using osu.Framework.Platform;
using osu.Framework.Platform.SDL3;

namespace osu.Framework.OHOS
{
    /// <summary>
    /// Thin OHOS counterpart of <c>AndroidGameWindow</c>.
    ///
    /// No SurfaceHandle override is needed: OPENHARMONY_CreateWindow()
    /// (SDL-main/src/video/openharmony/SDL_openharmonywindow.c:44) fetches the
    /// XComponent's OHNativeWindow itself when framework calls SDL_CreateWindow()
    /// (SDL3Window.cs:228) and creates the EGL surface there.
    /// </summary>
    internal class OHOSGameWindow : SDL3MobileWindow
    {
        public OHOSGameWindow(GraphicsSurfaceType surfaceType, string appName)
            : base(surfaceType, appName)
        {
        }
    }
}
