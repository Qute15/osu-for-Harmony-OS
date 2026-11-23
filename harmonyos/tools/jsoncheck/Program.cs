using System;
using System.Linq;
using Newtonsoft.Json;
using Veldrid;
using Veldrid.SPIRV;

// 复现 osu.Framework ShaderCompilationStore 的缓存往返：
//   JsonConvert.SerializeObject(VertexFragmentShaderCompilation) -> JsonConvert.DeserializeObject<>
// 重点看 SpirvReflection 的两个只读属性（VertexElements / ResourceLayouts）能不能活下来。
public class VertexFragmentShaderCompilation
{
    public bool WasCached { get; set; }
    public byte[] VertexBytes { get; set; }
    public byte[] FragmentBytes { get; set; }
    public string VertexText { get; set; }
    public string FragmentText { get; set; }
    public SpirvReflection Reflection { get; set; }
}

public static class Program
{
    public static void Main()
    {
        var reflection = new SpirvReflection(
            new[] { new VertexElementDescription("a_Position", VertexElementSemantic.TextureCoordinate, VertexElementFormat.Float2) },
            new[]
            {
                new ResourceLayoutDescription
                {
                    Elements = new[]
                    {
                        new ResourceLayoutElementDescription("g_Texture", ResourceKind.TextureReadOnly, ShaderStages.Fragment),
                        new ResourceLayoutElementDescription("g_Sampler", ResourceKind.Sampler, ShaderStages.Fragment),
                    }
                }
            });

        var compilation = new VertexFragmentShaderCompilation
        {
            VertexBytes = new byte[] { 1, 2, 3, 4 },
            FragmentBytes = new byte[] { 5, 6, 7, 8 },
            VertexText = "void main(){}",
            FragmentText = "void main(){}",
            Reflection = reflection
        };

        string json = JsonConvert.SerializeObject(compilation);
        Console.WriteLine("JSON = " + json);

        var back = JsonConvert.DeserializeObject<VertexFragmentShaderCompilation>(json);

        int fail = 0;

        if (back == null)
        {
            Console.WriteLine("FAIL: 反序列化返回 null");
            Environment.Exit(1);
        }

        if (back.Reflection == null)
        {
            Console.WriteLine("FAIL: Reflection == null");
            fail++;
        }
        else
        {
            Console.WriteLine("Reflection.VertexElements = " + (back.Reflection.VertexElements == null ? "null" : back.Reflection.VertexElements.Length.ToString()));
            Console.WriteLine("Reflection.ResourceLayouts = " + (back.Reflection.ResourceLayouts == null ? "null" : back.Reflection.ResourceLayouts.Length.ToString()));

            if (back.Reflection.VertexElements == null)
            {
                Console.WriteLine("FAIL: VertexElements == null");
                fail++;
            }
            else if (back.Reflection.VertexElements.Length != 1 || back.Reflection.VertexElements[0].Name != "a_Position")
            {
                Console.WriteLine("FAIL: VertexElements 内容不对");
                fail++;
            }

            if (back.Reflection.ResourceLayouts == null)
            {
                Console.WriteLine("FAIL: ResourceLayouts == null");
                fail++;
            }
            else if (back.Reflection.ResourceLayouts.Length != 1)
            {
                Console.WriteLine("FAIL: ResourceLayouts 长度不对");
                fail++;
            }
            else
            {
                var layout = back.Reflection.ResourceLayouts[0];
                if (layout.Elements == null)
                {
                    Console.WriteLine("FAIL: layout.Elements == null");
                    fail++;
                }
                else if (layout.Elements.Length != 2)
                {
                    Console.WriteLine("FAIL: layout.Elements 长度不对 = " + layout.Elements.Length);
                    fail++;
                }
                else
                {
                    Console.WriteLine("Elements[0] = " + layout.Elements[0].Name + " / " + layout.Elements[0].Kind + " / " + layout.Elements[0].Stages);
                    if (layout.Elements[0].Name != "g_Texture" || layout.Elements[0].Kind != ResourceKind.TextureReadOnly)
                    {
                        Console.WriteLine("FAIL: Elements 内容不对");
                        fail++;
                    }
                }
            }
        }

        Console.WriteLine(fail == 0 ? "RESULT: PASS" : "RESULT: FAIL (" + fail + ")");
        Environment.Exit(fail == 0 ? 0 : 1);
    }
}
