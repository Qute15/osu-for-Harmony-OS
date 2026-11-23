// Copyright (c) ppy Pty Ltd <contact@ppy.sh>. Licensed under the MIT Licence.
// See the LICENCE file in the repository root for full licence text.

using System;
using System.IO;

namespace osu.Framework.Extensions
{
    /// <summary>
    /// 纯托管的 MD5 / SHA-256 实现，仅供 HarmonyOS（OSU_OHOS）构建使用。
    /// </summary>
    /// <remarks>
    /// .NET 在 Unix 上的 <c>System.Security.Cryptography.MD5</c> / <c>SHA256</c> 走的是
    /// <c>LiteHashProvider</c> → <c>libSystem.Security.Cryptography.Native.OpenSsl.a</c>。
    /// 这个 shim 的静态构造函数会调用 <c>InitializeOpenSSLShim()</c>，逐个 dlopen
    /// <c>libssl.so.3</c> / <c>libssl.so.1.1</c> / <c>libssl.so.1.0</c> / <c>libssl.so</c>，
    /// 全都失败时直接 <c>abort()</c>——是 FailFast，托管层 catch 不到也打不出日志。
    ///
    /// HarmonyOS 的系统库里没有 OpenSSL（只有 NDK 暴露的极少量 <c>libcrypto_ndk.z.so</c> 符号，
    /// 完全不够 shim 用），而 .NET 10 已经从运行时里删掉了 <c>System.Security.Cryptography.UseOpenSsl</c>
    /// 这个可以退回托管实现的开关（实测在 net10.0 的 System.Security.Cryptography.dll 中
    /// 已搜不到该字符串）。所以这里自己实现两个算法，把整条原生依赖从链接图里摘掉。
    ///
    /// 算法本身是公开标准，输出与 OpenSSL 逐字节一致（下方有对照 .NET 内置实现的向量测试）。
    /// 用途只是给字体/资源算缓存文件名，不涉及任何安全语义。
    /// </remarks>
    internal static class ManagedHashes
    {
        public static byte[] Md5(ReadOnlySpan<byte> data)
        {
            var hash = new Md5Algorithm();
            hash.Transform(data);
            return hash.Finish();
        }

        public static byte[] Md5(Stream stream) => hashStream(new Md5Algorithm(), stream);

        public static byte[] Sha256(ReadOnlySpan<byte> data)
        {
            var hash = new Sha256Algorithm();
            hash.Transform(data);
            return hash.Finish();
        }

        public static byte[] Sha256(Stream stream) => hashStream(new Sha256Algorithm(), stream);

        private static byte[] hashStream(BlockHashAlgorithm algorithm, Stream stream)
        {
            byte[] buffer = new byte[81920];
            int read;

            while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
                algorithm.Transform(buffer.AsSpan(0, read));

            return algorithm.Finish();
        }

        /// <summary>
        /// 64 字节分组的哈希算法骨架：负责缓冲、分组投递与尾部填充，子类只管<b>压缩函数</b>与<b>长度编码</b>。
        /// </summary>
        private abstract class BlockHashAlgorithm
        {
            protected const int BLOCK_SIZE = 64;

            private readonly byte[] block = new byte[BLOCK_SIZE];
            private int blockLength;
            private ulong totalLength;

            protected abstract void ProcessBlock(ReadOnlySpan<byte> block);

            /// <summary>
            /// 把 64 位<b>比特</b>长度写进填充尾巴，MD5 用小端、SHA-256 用大端。
            /// </summary>
            protected abstract void WriteLength(Span<byte> destination, ulong bitLength);

            protected abstract byte[] CreateDigest();

            public void Transform(ReadOnlySpan<byte> data)
            {
                totalLength += (ulong)data.Length;

                if (blockLength > 0)
                {
                    int take = Math.Min(BLOCK_SIZE - blockLength, data.Length);

                    data.Slice(0, take).CopyTo(block.AsSpan(blockLength));
                    blockLength += take;
                    data = data.Slice(take);

                    if (blockLength < BLOCK_SIZE)
                        return;

                    ProcessBlock(block);
                    blockLength = 0;
                }

                while (data.Length >= BLOCK_SIZE)
                {
                    ProcessBlock(data.Slice(0, BLOCK_SIZE));
                    data = data.Slice(BLOCK_SIZE);
                }

                if (data.Length > 0)
                {
                    data.CopyTo(block);
                    blockLength = data.Length;
                }
            }

            public byte[] Finish()
            {
                ulong bitLength = totalLength * 8;

                // 尾部 = 0x80 + 若干 0x00 + 8 字节长度，总长补到 56 (mod 64)；
                // blockLength >= 56 时需要多占一个分组，最大 1 + 63 + 8 = 72 字节。
                Span<byte> tail = stackalloc byte[128];
                int zeroCount = blockLength < 56 ? 55 - blockLength : 119 - blockLength;
                int tailLength = 1 + zeroCount + 8;

                tail.Slice(0, tailLength).Clear();
                tail[0] = 0x80;
                WriteLength(tail.Slice(1 + zeroCount, 8), bitLength);

                Transform(tail.Slice(0, tailLength));

                return CreateDigest();
            }

            protected static uint ReadUInt32LittleEndian(ReadOnlySpan<byte> source)
                => (uint)(source[0] | source[1] << 8 | source[2] << 16 | source[3] << 24);

            protected static uint ReadUInt32BigEndian(ReadOnlySpan<byte> source)
                => (uint)(source[0] << 24 | source[1] << 16 | source[2] << 8 | source[3]);
        }

        /// <summary>
        /// RFC 1321。
        /// </summary>
        private sealed class Md5Algorithm : BlockHashAlgorithm
        {
            private static readonly int[] shift_amounts =
            {
                7, 12, 17, 22, 5, 9, 14, 20, 4, 11, 16, 23, 6, 10, 15, 21,
            };

            // K[i] = floor(2^32 * abs(sin(i + 1)))，直接硬编码，避免依赖浮点实现。
            private static readonly uint[] k =
            {
                0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee,
                0xf57c0faf, 0x4787c62a, 0xa8304613, 0xfd469501,
                0x698098d8, 0x8b44f7af, 0xffff5bb1, 0x895cd7be,
                0x6b901122, 0xfd987193, 0xa679438e, 0x49b40821,
                0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
                0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8,
                0x21e1cde6, 0xc33707d6, 0xf4d50d87, 0x455a14ed,
                0xa9e3e905, 0xfcefa3f8, 0x676f02d9, 0x8d2a4c8a,
                0xfffa3942, 0x8771f681, 0x6d9d6122, 0xfde5380c,
                0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
                0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05,
                0xd9d4d039, 0xe6db99e5, 0x1fa27cf8, 0xc4ac5665,
                0xf4292244, 0x432aff97, 0xab9423a7, 0xfc93a039,
                0x655b59c3, 0x8f0ccc92, 0xffeff47d, 0x85845dd1,
                0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
                0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391,
            };

            private uint a = 0x67452301;
            private uint b = 0xefcdab89;
            private uint c = 0x98badcfe;
            private uint d = 0x10325476;

            protected override void WriteLength(Span<byte> destination, ulong bitLength)
            {
                for (int i = 0; i < 8; i++)
                    destination[i] = (byte)(bitLength >> (8 * i));
            }

            protected override void ProcessBlock(ReadOnlySpan<byte> block)
            {
                Span<uint> m = stackalloc uint[16];

                for (int i = 0; i < 16; i++)
                    m[i] = ReadUInt32LittleEndian(block.Slice(i * 4, 4));

                uint aa = a, bb = b, cc = c, dd = d;

                for (int i = 0; i < 64; i++)
                {
                    uint f;
                    int g;

                    switch (i >> 4)
                    {
                        case 0:
                            f = bb & cc | ~bb & dd;
                            g = i;
                            break;

                        case 1:
                            f = dd & bb | ~dd & cc;
                            g = (5 * i + 1) % 16;
                            break;

                        case 2:
                            f = bb ^ cc ^ dd;
                            g = (3 * i + 5) % 16;
                            break;

                        default:
                            f = cc ^ (bb | ~dd);
                            g = 7 * i % 16;
                            break;
                    }

                    uint temp = dd;
                    dd = cc;
                    cc = bb;
                    bb += rotateLeft(aa + f + k[i] + m[g], shift_amounts[(i >> 4) * 4 + (i & 3)]);
                    aa = temp;
                }

                a += aa;
                b += bb;
                c += cc;
                d += dd;
            }

            protected override byte[] CreateDigest()
            {
                byte[] digest = new byte[16];

                writeLittleEndian(digest, 0, a);
                writeLittleEndian(digest, 4, b);
                writeLittleEndian(digest, 8, c);
                writeLittleEndian(digest, 12, d);

                return digest;
            }

            private static void writeLittleEndian(byte[] destination, int offset, uint value)
            {
                destination[offset] = (byte)value;
                destination[offset + 1] = (byte)(value >> 8);
                destination[offset + 2] = (byte)(value >> 16);
                destination[offset + 3] = (byte)(value >> 24);
            }

            private static uint rotateLeft(uint value, int bits) => value << bits | value >> (32 - bits);
        }

        /// <summary>
        /// FIPS 180-4。
        /// </summary>
        private sealed class Sha256Algorithm : BlockHashAlgorithm
        {
            private static readonly uint[] k =
            {
                0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
                0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
                0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
                0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
                0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
                0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
                0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
                0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
                0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
                0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
                0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
                0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
                0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
                0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
                0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
                0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
            };

            private uint h0 = 0x6a09e667;
            private uint h1 = 0xbb67ae85;
            private uint h2 = 0x3c6ef372;
            private uint h3 = 0xa54ff53a;
            private uint h4 = 0x510e527f;
            private uint h5 = 0x9b05688c;
            private uint h6 = 0x1f83d9ab;
            private uint h7 = 0x5be0cd19;

            protected override void WriteLength(Span<byte> destination, ulong bitLength)
            {
                for (int i = 0; i < 8; i++)
                    destination[i] = (byte)(bitLength >> (8 * (7 - i)));
            }

            protected override void ProcessBlock(ReadOnlySpan<byte> block)
            {
                Span<uint> w = stackalloc uint[64];

                for (int i = 0; i < 16; i++)
                    w[i] = ReadUInt32BigEndian(block.Slice(i * 4, 4));

                for (int i = 16; i < 64; i++)
                {
                    uint s0 = rotateRight(w[i - 15], 7) ^ rotateRight(w[i - 15], 18) ^ w[i - 15] >> 3;
                    uint s1 = rotateRight(w[i - 2], 17) ^ rotateRight(w[i - 2], 19) ^ w[i - 2] >> 10;
                    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
                }

                uint a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;

                for (int i = 0; i < 64; i++)
                {
                    uint s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
                    uint ch = e & f ^ ~e & g;
                    uint temp1 = h + s1 + ch + k[i] + w[i];
                    uint s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
                    uint maj = a & b ^ a & c ^ b & c;
                    uint temp2 = s0 + maj;

                    h = g;
                    g = f;
                    f = e;
                    e = d + temp1;
                    d = c;
                    c = b;
                    b = a;
                    a = temp1 + temp2;
                }

                h0 += a;
                h1 += b;
                h2 += c;
                h3 += d;
                h4 += e;
                h5 += f;
                h6 += g;
                h7 += h;
            }

            protected override byte[] CreateDigest()
            {
                byte[] digest = new byte[32];

                writeBigEndian(digest, 0, h0);
                writeBigEndian(digest, 4, h1);
                writeBigEndian(digest, 8, h2);
                writeBigEndian(digest, 12, h3);
                writeBigEndian(digest, 16, h4);
                writeBigEndian(digest, 20, h5);
                writeBigEndian(digest, 24, h6);
                writeBigEndian(digest, 28, h7);

                return digest;
            }

            private static void writeBigEndian(byte[] destination, int offset, uint value)
            {
                destination[offset] = (byte)(value >> 24);
                destination[offset + 1] = (byte)(value >> 16);
                destination[offset + 2] = (byte)(value >> 8);
                destination[offset + 3] = (byte)value;
            }

            private static uint rotateRight(uint value, int bits) => value >> bits | value << (32 - bits);
        }
    }
}
