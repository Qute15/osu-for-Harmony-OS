// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace osu.Framework.Extensions
{
    /// <summary>
    /// 计算结构体在非托管内存中的大小，且**不依赖运行时封送数据**。
    ///
    /// 背景：<c>Marshal.SizeOf&lt;T&gt;()</c> / <c>Marshal.SizeOf(Type)</c> 需要
    /// 该类型的「结构体封送数据」，而 NativeAOT 只为确实出现在 P/Invoke 或
    /// Marshal 调用中的类型生成这些数据。对纯托管结构体调用会抛
    /// <c>NotSupportedException: '...' is missing structure marshalling data</c>
    /// （HarmonyOS NativeAOT 上实测，崩在 GLRenderer.BeginFrame）。
    ///
    /// 这里的两条路径都不需要封送数据：
    /// 1. 显式声明了 <c>[StructLayout(Size = N)]</c> 的类型，直接取该 N —— 语义完全一致
    ///    （例如 <c>UniformBool</c> 声明 Size = 4，而托管布局只有 1 字节的 bool）。
    /// 2. 其余 blittable 结构体（如 TexturedVertex2D）用 <see cref="Unsafe.SizeOf{T}"/>，
    ///    它按托管布局计算，对 blittable 类型等同于非托管布局。
    /// </summary>
    internal static class StructSize
    {
        public static int Of<T>()
        {
            StructLayoutAttribute? layout = typeof(T).StructLayoutAttribute;

            if (layout != null && layout.Size > 0)
                return layout.Size;

            return Unsafe.SizeOf<T>();
        }

        public static int Of(Type type)
        {
            StructLayoutAttribute? layout = type.StructLayoutAttribute;

            if (layout != null && layout.Size > 0)
                return layout.Size;

            // 走到这里说明类型既没有显式 Size，也不是编译期已知的泛型参数，
            // 只能用运行时封送反射（AOT 下可能失败），保留作为兜底。
            return Marshal.SizeOf(type);
        }
    }
}
