// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using osu.Framework.Platform;

namespace osu.Framework.OHOS
{
    /// <summary>
    /// NativeStorage is platform-agnostic; AndroidStorage is an empty subclass,
    /// so the OHOS version is identical in behaviour.
    /// </summary>
    public class OHOSStorage : NativeStorage
    {
        public OHOSStorage(string path, GameHost host)
            : base(path, host)
        {
        }
    }
}
