using System;
using System.IO;
using System.Security.Cryptography;
using osu.Framework.Extensions;

internal static class Program
{
    private static int failures;

    private static void Main()
    {
        // 覆盖所有分组边界：0..200 覆盖 <56、==55、==56、==63、==64、==120 等关键长度
        for (int length = 0; length <= 200; length++)
            check(length);

        // 大块 + 非对齐长度，验证流式分块投递
        foreach (int length in new[] { 1000, 4095, 4096, 8191, 8192, 65536, 1_000_003 })
            check(length);

        // 已知向量（RFC 1321 / FIPS 180-4 + 中文 UTF-8）
        checkVector("", "d41d8cd98f00b204e9800998ecf8427e", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        checkVector("abc", "900150983cd24fb0d6963f7d28e17f72", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");

        Console.WriteLine(failures == 0 ? "ALL PASS" : $"FAILURES: {failures}");
        Environment.Exit(failures == 0 ? 0 : 1);
    }

    private static void check(int length)
    {
        byte[] data = new byte[length];
        new Random(length * 7919 + 13).NextBytes(data);

        compare($"md5(span,{length})", MD5.HashData(data), ManagedHashes.Md5(data));
        compare($"sha256(span,{length})", SHA256.HashData(data), ManagedHashes.Sha256(data));

        using var stream = new MemoryStream(data, false);
        compare($"md5(stream,{length})", MD5.HashData(new MemoryStream(data, false)), ManagedHashes.Md5(stream));

        using var stream2 = new MemoryStream(data, false);
        compare($"sha256(stream,{length})", SHA256.HashData(new MemoryStream(data, false)), ManagedHashes.Sha256(stream2));
    }

    private static void checkVector(string input, string md5, string sha256)
    {
        byte[] data = System.Text.Encoding.UTF8.GetBytes(input);

        compare($"md5(vec,'{input}')", Convert.FromHexString(md5), ManagedHashes.Md5(data));
        compare($"sha256(vec,'{input}')", Convert.FromHexString(sha256), ManagedHashes.Sha256(data));
    }

    private static void compare(string label, byte[] expected, byte[] actual)
    {
        if (expected.AsSpan().SequenceEqual(actual))
            return;

        failures++;
        Console.WriteLine($"MISMATCH {label}: expected {Convert.ToHexString(expected)} got {Convert.ToHexString(actual)}");
    }
}
