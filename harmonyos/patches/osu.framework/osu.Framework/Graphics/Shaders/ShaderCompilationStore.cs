// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using System;
using System.Collections.Generic;
using System.Diagnostics.CodeAnalysis;
using System.IO;
using System.Threading;
using Newtonsoft.Json;
using osu.Framework.Extensions;
using osu.Framework.Logging;
using osu.Framework.Platform;
using Veldrid;
using Veldrid.SPIRV;

namespace osu.Framework.Graphics.Shaders
{
    public class ShaderCompilationStore
    {
        /// <summary>
        /// A cache-busting mechanism to be used for when the cross-compilation output changes (i.e. a change to the cross-compiler itself), but the input is not affected.
        /// </summary>
        private const int cache_version = 1;

        public Storage? CacheStorage { private get; set; }

        public VertexFragmentShaderCompilation CompileVertexFragment(string vertexText, string fragmentText, CrossCompileTarget target)
        {
            // vertexHash#fragmentHash#target
            string filename = $"{vertexText.ComputeMD5Hash()}#{fragmentText.ComputeMD5Hash()}#{(int)target}#{cache_version}";

            if (tryGetCached(filename, out VertexFragmentShaderCompilation? existing))
            {
                existing.WasCached = true;
                return existing;
            }

            // Debug preserves names for reflection.
            byte[] vertexBytes = SpirvCompilation.CompileGlslToSpirv(vertexText, null, ShaderStages.Vertex, new GlslCompileOptions(true)).SpirvBytes;
            byte[] fragmentBytes = SpirvCompilation.CompileGlslToSpirv(fragmentText, null, ShaderStages.Fragment, new GlslCompileOptions(true)).SpirvBytes;

            VertexFragmentCompilationResult crossResult = SpirvCompilation.CompileVertexFragment(vertexBytes, fragmentBytes, target, new CrossCompileOptions());
            VertexFragmentShaderCompilation compilation = new VertexFragmentShaderCompilation
            {
                VertexBytes = vertexBytes,
                FragmentBytes = fragmentBytes,
                VertexText = crossResult.VertexShader,
                FragmentText = crossResult.FragmentShader,
                Reflection = crossResult.Reflection
            };

            saveToCache(filename, compilation);

            return compilation;
        }

        public ComputeProgramCompilation CompileCompute(string programText, CrossCompileTarget target)
        {
            // programHash#target
            string filename = $"{programText.ComputeMD5Hash()}#{(int)target}#{cache_version}";

            if (tryGetCached(filename, out ComputeProgramCompilation? existing))
            {
                existing.WasCached = true;
                return existing;
            }

            // Debug preserves names for reflection.
            byte[] programBytes = SpirvCompilation.CompileGlslToSpirv(programText, null, ShaderStages.Compute, new GlslCompileOptions(true)).SpirvBytes;

            ComputeCompilationResult crossResult = SpirvCompilation.CompileCompute(programBytes, target, new CrossCompileOptions());
            ComputeProgramCompilation compilation = new ComputeProgramCompilation
            {
                ProgramBytes = programBytes,
                ProgramText = crossResult.ComputeShader,
                Reflection = crossResult.Reflection
            };

            saveToCache(filename, compilation);

            return compilation;
        }

        private bool tryGetCached<T>(string filename, [NotNullWhen(true)] out T? compilation)
            where T : class
        {
            primeAotReflection();

            compilation = null;

            try
            {
                if (CacheStorage == null)
                    return false;

                string checksum;
                string data;

                lock (save_lock)
                {
                    if (!CacheStorage.Exists(filename))
                        return false;

                    using var stream = CacheStorage.GetStream(filename);

                    using var br = new BinaryReader(stream);

                    checksum = br.ReadString();
                    data = br.ReadString();
                }

                if (data.ComputeMD5Hash() != checksum)
                {
                    // Data corrupted..
                    Logger.Log("Cached shader data is corrupted - recompiling.");
                    return false;
                }

                compilation = JsonConvert.DeserializeObject<T>(data)!;

                // OHOS 移植补丁：缓存的完整性自检。
                //
                // 缓存里存的是 Newtonsoft 序列化后的 VertexFragmentShaderCompilation，
                // 其中 Reflection 是 Veldrid.SPIRV.SpirvReflection（只有只读属性 +
                // 带参构造的不可变类）。在 NativeAOT 下，只要 ILC 的依赖分析没有
                // 保住这些成员，写入端就会得到 "Reflection": {}，而读取端**不会报错**，
                // 只会拿回一个 VertexElements / ResourceLayouts 全为 null 的对象。
                // 这个坏对象会一路传到 GLShader.CompileInternal()，在遍历
                // ResourceLayouts 时 NRE —— 表现为「每帧一条未处理异常，最终崩」，
                // 而且异常点离真正原因很远，极难定位（M2 实测花了很久）。
                //
                // 这里把「缓存」严格当成**加速手段**：内容不完整就当作未命中，
                // 走完整的原生 cross-compile 重新生成。宁可慢一点，也不能把
                // 半截数据喂给渲染器。
                if (!isUsable(compilation))
                {
                    Logger.Log($"Cached {typeof(T).Name} is incomplete (shader reflection lost in serialisation) - recompiling.");
                    compilation = null;
                    return false;
                }

                return true;
            }
            catch (Exception e)
            {
                Logger.Error(e, "Failed to read cached shader compilation - recompiling.");
            }

            return false;
        }

        /// <summary>
        /// 让 NativeAOT 为 Newtonsoft 反序列化数组时用到的泛型集合实例生成代码。
        /// </summary>
        /// <remarks>
        /// Newtonsoft 把 JSON 数组读成 <c>List&lt;T&gt;</c> 再 ToArray()。ILC 的
        /// 依赖分析看不到这个「按 JSON 内容临时决定的泛型实例化」，于是运行期抛：
        ///   NotSupportedException: 'List`1[Veldrid.ResourceLayoutDescription]'
        ///   is missing native code or metadata
        /// 这里显式声明依赖。放在一个真实被调用的方法上（而不是只在特性里），
        /// 保证这个方法本身不会被裁掉，特性才会生效。
        /// </remarks>
        // 注意 global:: —— 本命名空间下有个 osu.Framework.Graphics.Veldrid 子命名空间，
        // 裸写 Veldrid.X 会被解析成它，编译器会报「类型不存在」。
        [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.ResourceLayoutDescription>))]
        [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.ResourceLayoutElementDescription>))]
        [DynamicDependency(DynamicallyAccessedMemberTypes.All, typeof(List<global::Veldrid.VertexElementDescription>))]
        private static void primeAotReflection()
        {
            // 真实调用构造与 Add，确保 ILC 生成这三个泛型实例的代码和元数据。
            // 仅靠 [DynamicDependency] 在这里不足以保证 List<ResourceLayoutDescription> 活下来。
            var resourceLayouts = new List<global::Veldrid.ResourceLayoutDescription>();
            resourceLayouts.Add(default);
            if (resourceLayouts.Count == int.MinValue)
                throw new InvalidOperationException();

            var resourceElements = new List<global::Veldrid.ResourceLayoutElementDescription>();
            resourceElements.Add(default);
            if (resourceElements.Count == int.MinValue)
                throw new InvalidOperationException();

            var vertexElements = new List<global::Veldrid.VertexElementDescription>();
            vertexElements.Add(default);
            if (vertexElements.Count == int.MinValue)
                throw new InvalidOperationException();
        }

        /// <summary>
        /// 判断从缓存反序列化出来的编译结果是否**真的可用**。
        /// </summary>
        /// <remarks>
        /// 只检查那些「缺失了也不会在反序列化阶段报错、但一定会让渲染器崩溃」的字段。
        /// 原生 cross-compile 的产物里这几个字段恒非 null（哪怕是长度 0 的数组），
        /// 所以这里判 null 不会误杀正常缓存。
        /// </remarks>
        private static bool isUsable<T>(T? compilation)
            where T : class
        {
            switch (compilation)
            {
                case VertexFragmentShaderCompilation vf:
                    return vf.VertexText != null
                           && vf.FragmentText != null
                           && vf.Reflection != null
                           && vf.Reflection.VertexElements != null
                           && vf.Reflection.ResourceLayouts != null;

                case ComputeProgramCompilation compute:
                    return compute.ProgramText != null
                           && compute.Reflection != null
                           && compute.Reflection.VertexElements != null
                           && compute.Reflection.ResourceLayouts != null;

                default:
                    return compilation != null;
            }
        }

        private static readonly Lock save_lock = new Lock();

        private void saveToCache(string filename, object compilation)
        {
            // Multiple save operations could happen in parallel due to the asynchronous
            // and unguarded nature of this store. Without locking, errors may be thrown
            // as two operations attempt to write to the same destination file.
            //
            // Saving to disk is the least expensive part of the process, so locking on
            // this should be very minimal contention.
            lock (save_lock)
            {
                if (CacheStorage == null)
                    return;

                try
                {
                    // ensure any stale cached versions are deleted.
                    CacheStorage.Delete(filename);

                    using var stream = CacheStorage.CreateFileSafely(filename);
                    using var bw = new BinaryWriter(stream);

                    string data = JsonConvert.SerializeObject(compilation);
                    string checksum = data.ComputeMD5Hash();

                    bw.Write(checksum);
                    bw.Write(data);
                }
                catch (Exception ex)
                {
                    Logger.Error(ex, "Failed to save shader to cache.");
                }
            }
        }
    }
}
