// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using System;

namespace osu.Framework.Bindables
{
    /// <summary>
    /// 一个与泛型参数无关的「值已变化」通知通道。
    ///
    /// 存在的唯一理由：<c>InputConfigManager</c> 需要在不认识 <c>T</c> 的前提下
    /// 订阅任意 <see cref="Bindable{T}"/> 的变化，原实现靠
    /// <c>MethodInfo.MakeGenericMethod()</c> 反射调用泛型方法；
    /// 而 NativeAOT 只能在编译期已知泛型实例化时才生成代码，
    /// 该调用在 HarmonyOS 上直接抛 <see cref="NotSupportedException"/>（M1b 实测）。
    ///
    /// 有了这个接口，调用方只需 <c>is IValueChangeNotifier</c> 即可订阅，
    /// 既不需要反射，也不依赖 <c>T</c>。
    /// </summary>
    public interface IValueChangeNotifier
    {
        /// <summary>
        /// 在 <see cref="Bindable{T}.ValueChanged"/> 之后触发，语义与其保持一致。
        /// </summary>
        event Action ValueChangedNonGeneric;
    }
}
