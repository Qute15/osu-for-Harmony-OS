// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.
//
// M1b 渲染链自检用的最小 Game。
//
// 为什么需要它：osu!lazer 的 OsuGame 一上来就依赖 Realm / SQLite / BASS
// 这些必须重新交叉编译的原生库，任何一项没就位都会在 load 阶段抛异常，
// 从而掩盖「SDL3 窗口 + GL 渲染 + 帧循环 + 输入」这条平台链本身是否健康。
// 先用一个零依赖的 Game 把平台链单独验证，可以把两类问题彻底隔离开：
//   · 自检失败  -> 平台层（OHOSGameHost / SDL3 / EGL）有问题
//   · 自检通过  -> 平台层没问题，问题在 lazer 的原生依赖
// 这是标准的「隔离变量」排障手法。

using System;
using osu.Framework;
using osu.Framework.Allocation;
using osu.Framework.Graphics;
using osu.Framework.Graphics.Shapes;
using osuTK;
using osuTK.Graphics;

namespace osu.OHOS
{
    // 注意必须写全限定名：在 osu.* 命名空间下，裸写 Game 会被解析成
    // osu.Game 命名空间（本工程引用了 osu.Game 程序集），报 CS0118。
    public class SelfTestGame : osu.Framework.Game
    {
        private Box square;

        private int frames;

        /// <summary>
        /// 跑够这么多帧就退出，方便 Gate 脚本判定「帧循环确实在转」。
        /// </summary>
        private const int exit_after_frames = 240;

        [BackgroundDependencyLoader]
        private void load()
        {
            Add(new Box
            {
                RelativeSizeAxes = Axes.Both,
                Colour = new Color4(0.11f, 0.12f, 0.14f, 1f),
            });

            Add(square = new Box
            {
                Size = new Vector2(140),
                Anchor = Anchor.Centre,
                Origin = Anchor.Centre,
                Colour = new Color4(1f, 0.41f, 0.71f, 1f),
            });

            OHOSLog.Info("selftest scene graph loaded (2 boxes)");
        }

        protected override void Update()
        {
            base.Update();

            frames++;

            // 让方块绕屏幕转，确保每一帧都真的重绘了（而不是卡在第一帧）。
            float phase = frames / 60f;
            square.Position = new Vector2(
                (float)Math.Sin(phase) * 220,
                (float)Math.Cos(phase) * 220);
            square.Rotation = frames * 1.5f;

            if (frames % 60 == 0)
                OHOSLog.Info($"selftest frame={frames}");

            if (frames >= exit_after_frames)
            {
                OHOSLog.Info($"selftest completed {frames} frames -> requesting exit");
                Exit();
            }
        }
    }
}
