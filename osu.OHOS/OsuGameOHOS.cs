// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.
//
// OHOS counterpart of osu.Android.OsuGameAndroid, stripped of Android-only
// PackageInfo / orientation / battery APIs (M4 will re-add equivalents).

using osu.Framework.Platform;
using osu.Game;
using osuTK;

namespace osu.OHOS
{
    public partial class OsuGameOHOS : OsuGame
    {
        public override Vector2 ScalingContainerTargetDrawSize
            => new Vector2(1024, 1024 * DrawHeight / DrawWidth);

        public OsuGameOHOS()
            : base(null)
        {
        }

        public override void SetHost(GameHost host)
        {
            base.SetHost(host);
            host.Window.CursorState |= CursorState.Hidden;
        }
    }
}
