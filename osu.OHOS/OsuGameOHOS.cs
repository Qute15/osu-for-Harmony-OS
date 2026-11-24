// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.
//
// OHOS counterpart of osu.Android.OsuGameAndroid, stripped of Android-only
// PackageInfo / orientation / battery APIs (M4 will re-add equivalents).

using System;
using System.IO;
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

        protected override void LoadComplete()
        {
            base.LoadComplete();

            // base.LoadComplete() 里才把 BeatmapManager 的 notification/present 回调接好，
            // 所以导入必须排到之后再跑；Scheduler 同时保证我们在 update 线程上。
            Scheduler.AddOnce(importStagedBeatmaps);
        }

        /// <summary>
        /// OHOS 上没有桌面版的「拖 .osz 进窗口」也没有文件选择器回调，
        /// 因此采用落地目录约定：ArkTS 侧把 .osz 放到 <c>files/osu/import/</c>，
        /// 这里在启动时扫一遍并交给 upstream 的 BeatmapManager 正常导入流程。
        /// 成功后改后缀为 .imported，避免每次启动重复导入（重复导入本身幂等，但日志很吵）。
        /// </summary>
        private void importStagedBeatmaps()
        {
            string dir = findImportDirectory();
            if (string.IsNullOrEmpty(dir))
            {
                OHOSLog.Warn("beatmap import: no staging directory found (ArkTS side did not create it?)");
                return;
            }

            string[] archives;
            try
            {
                archives = Directory.GetFiles(dir, "*.osz");
            }
            catch (Exception ex)
            {
                OHOSLog.Error($"beatmap import: cannot list {dir}: {ex.Message}");
                return;
            }

            if (archives.Length == 0)
                return;

            OHOSLog.Info($"beatmap import: {archives.Length} archive(s) found in {dir}");

            foreach (string path in archives)
            {
                try
                {
                    OHOSLog.Info($"beatmap import: submitting {Path.GetFileName(path)}");
                    BeatmapManager.Import(new[] { path }).ContinueWith(task =>
                    {
                        if (task.IsFaulted)
                        {
                            OHOSLog.Error($"beatmap import failed for {path}: {task.Exception}");
                            return;
                        }

                        try
                        {
                            // 上游 importer 成功后会删掉源 .osz（ImportTask.DeleteFile），
                            // 所以这里写独立的 .done 标记，ArkTS 侧据此不再重复投递样本。
                            File.WriteAllText(path + ".done", DateTime.UtcNow.ToString("O"));
                            OHOSLog.Info($"beatmap import finished: {Path.GetFileName(path)}");
                        }
                        catch (Exception ex)
                        {
                            OHOSLog.Warn($"beatmap import: write done-marker failed: {ex.Message}");
                        }
                    });
                }
                catch (Exception ex)
                {
                    OHOSLog.Error($"beatmap import: submit failed for {path}: {ex}");
                }
            }
        }

        private static string findImportDirectory()
        {
            // ArkTS 会把真实路径写进这个 manifest，避免我们猜 el1/el2/haps 布局。
            string[] manifests =
            {
                "/data/storage/el2/base/haps/entry/files/osu/import/import-dir.txt",
                "/data/storage/el2/base/files/osu/import/import-dir.txt",
            };

            foreach (string manifest in manifests)
            {
                try
                {
                    if (!File.Exists(manifest))
                        continue;

                    string dir = File.ReadAllText(manifest).Trim();
                    if (Directory.Exists(dir))
                        return dir;
                }
                catch (Exception ex)
                {
                    OHOSLog.Warn($"beatmap import: read {manifest} failed: {ex.Message}");
                }
            }

            foreach (string fallback in manifests)
            {
                string dir = Path.GetDirectoryName(fallback);
                if (Directory.Exists(dir))
                    return dir;
            }

            return null;
        }
    }
}
