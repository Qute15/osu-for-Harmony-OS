#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Windows 本机闭环：把 C# 工程 NativeAOT 成 HarmonyOS 可加载的 .so。

两段式（M0 已验证，见 output/ROUTE-A-PLAN.md 第四章）：
  ① dotnet publish -r <RID> -p:DisableUnsupportedError=true
     → ILCompiler 在 Windows 上产出目标架构 ELF 的 <name>.o
     （publish 的最终链接步骤会因 OHOS lld/CRT 差异失败，忽略退出码，只认 .o）
  ② DevEco 自带 OHOS clang 手工链接
     --target=<OHOS triple> --sysroot=<OHOS musl sysroot>
     + ILCompiler runtime 包的 .a + libclang_rt.builtins.a（OHOS 无 libgcc）
     → DT_NEEDED 仅 libc.so 的 .so

支持双架构（真机 aarch64 / DevEco 模拟器 x86_64）：
  --rid linux-musl-arm64  → --target aarch64-linux-ohos → libs/arm64-v8a
  --rid linux-musl-x64    → --target x86_64-linux-ohos  → libs/x86_64

用法：
  python build-aot.py --project <dir or .csproj> [--output <file.so>]
                      [--hap-libs <entry/libs/<abi>>] [--skip-publish]
                      [--rid linux-musl-x64]

不依赖 bash PATH：所有外部程序用绝对路径调用。
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import subprocess
import sys

DOTNET = pathlib.Path("C:/Program Files/dotnet/dotnet.exe")
OHOS = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
NUGET_ROOT = pathlib.Path("C:/Users/z3306/.nuget/packages")

# 由 --rid 在 main() 中改写
RID = "linux-musl-arm64"
TARGET = "aarch64-linux-ohos"
MACHINE = 183
MACHINE_NAME = "AArch64"
# ---------------------------------------------------------------------------
# 必须随 libmain.so 一起进 HAP 的原生库
# ---------------------------------------------------------------------------
# 为什么不能只靠「运行期 dlopen 绝对路径」：musl 的 load_library() 在用带 '/'
# 的路径加载时**不写 shortname**，而 DllImport / NativeLibrary.Load 走的是裸名
# 查找，只按 shortname 或 inode 复用已加载对象。因此「先绝对路径加载、再裸名
# 引用」在 musl 上一定失败。
#
# 唯一可靠的办法：让这些库成为 libmain.so 的 DT_NEEDED（名字里没有 '/'，
# musl 会补 shortname），再配 rpath=$ORIGIN 在 libmain.so 同目录找。
#
# 每一项是 (目录, 文件名)；-l 参数由文件名去掉 lib 前缀与 .so 后缀得到。
NATIVE_DEPS: list[tuple[pathlib.Path, str]] = []

# 音频：BASS 官方 Linux 版是 glibc 二进制（libdl.so.2 / libpthread.so.0 /
# GLIBC_2.2.5 / __fxstat64），musl 完全无法加载，故自建兼容层。
BASS_DIR: pathlib.Path | None = None
BASS_LIBS = ("libbass.so", "libbassmix.so", "libbass_fx.so")

# 着色器编译器：osu.Framework 所有着色器都走 GLSL→SPIRV→ESSL（Veldrid.SPIRV）。
# NuGet 里的 libveldrid-spirv.so 是 glibc/GLIBCXX 二进制，同样加载不了。
VELDRID_DIR: pathlib.Path | None = None
VELDRID_LIB = "libveldrid-spirv.so"

# 数据库：Realm 的托管包只 P/Invoke realm-wrappers，原生二进制是 glibc 版，
# 需从 realm-core + realm-dotnet wrappers 源码交叉编译。
REALM_DIR: pathlib.Path | None = None
REALM_LIB = "librealm-wrappers.so"

# osu.Game/Beatmaps/LocalCachedBeatmapMetadataSource.cs 用 Microsoft.Data.Sqlite，
# 原生库是 libe_sqlite3（纯 C amalgamation，交叉编译成本低）。
SQLITE_DIR: pathlib.Path | None = None
SQLITE_LIB = "libe_sqlite3.so"


def log(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}", flush=True)


def fail(msg: str):
    print(json.dumps({"success": False, "error": msg}, ensure_ascii=False), file=sys.stderr)
    sys.exit(1)


def find_ilcompiler(sdk_major: int) -> pathlib.Path:
    root = NUGET_ROOT / f"runtime.{RID}.microsoft.dotnet.ilcompiler"
    if not root.exists():
        fail(f"ILCompiler runtime 包不存在：{root}（先跑一次 dotnet publish -r {RID} 让它还原）")
    versions = [d for d in root.iterdir() if d.is_dir()]
    matched = [d for d in versions if d.name.startswith(f"{sdk_major}.")]
    pool = matched or versions
    if not pool:
        fail(f"{root} 下没有可用版本")
    chosen = sorted(pool, key=lambda d: [int(x) for x in d.name.split(".")[:3] if x.isdigit()])[-1]
    log("ilc", f"使用 {chosen.name}（SDK major={sdk_major}, RID={RID}）")
    return chosen


def find_builtins() -> pathlib.Path:
    base = OHOS / "llvm/lib/clang"
    hits = sorted(base.glob(f"*/lib/{TARGET}/libclang_rt.builtins.a"))
    if not hits:
        fail(f"找不到 libclang_rt.builtins.a：{base}/*/lib/{TARGET}/")
    return hits[-1]


def native_dir(project: pathlib.Path) -> pathlib.Path:
    hits = sorted((project / "obj/Release").glob(f"net*/{RID}/native"))
    if not hits:
        fail(f"未找到 native 产物目录：{project}/obj/Release/net*/{RID}/native")
    return hits[-1]


def run_publish(project: pathlib.Path, extra: list[str]):
    proj_dir = project if project.is_dir() else project.parent

    # 关键：publish 前必须清掉旧 .o / .exports。
    # 否则一旦 publish 在 ILCompiler 之前就失败（编译错误、文件锁等），
    # 下面的 "if not list(nd.glob('*.o'))" 会看到上一轮遗留的 .o 而误判成功，
    # 最终打出一个「代码已改、二进制却是旧的」的 HAP。这种假阳性极难排查，
    # 本轮已经踩过一次（改了 InputConfigManager 却仍跑到泛型反射分支）。
    for cand in (proj_dir / "obj/Release").glob(f"net*/{RID}/native"):
        for pattern in ("*.o", "*.exports"):
            for stale in cand.glob(pattern):
                try:
                    stale.unlink()
                    log("publish", f"已删除旧产物 {stale.name}")
                except OSError as e:
                    fail(f"无法删除旧产物 {stale}：{e}")

    env = os.environ.copy()
    env["PATH"] = str(OHOS / "llvm/bin") + os.pathsep + env.get("PATH", "")
    env["DEVECO_SDK_HOME"] = str(OHOS.parent.parent)
    cmd = [
        str(DOTNET), "publish", str(project), "-c", "Release", "-r", RID,
        "-p:DisableUnsupportedError=true",
        "-p:CppCompilerAndLinker=clang.exe",
        "-p:CompressSymbols=false",
        "--nologo",
    ] + extra
    log("publish", " ".join(cmd))
    # 最终链接步骤注定失败（OHOS lld 无 zlib / CRT 路径差异），只要 .o 产出即继续
    p = subprocess.run(cmd, env=env, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    log("publish", f"exit={p.returncode}")
    for line in (p.stdout + p.stderr).strip().splitlines()[-14:]:
        print("    " + line, flush=True)
    nd = native_dir(proj_dir)
    if not list(nd.glob("*.o")):
        fail("publish 未产出 .o，检查上方输出")
    return nd


def link(nd: pathlib.Path, output: pathlib.Path, ilc: pathlib.Path, builtins: pathlib.Path):
    objs = sorted(nd.glob("*.o"))
    exports = sorted(nd.glob("*.exports"))
    sections = sorted(nd.glob("sections.ld"))
    if len(objs) != 1:
        fail(f"期望恰好 1 个 .o，实际 {[x.name for x in objs]}")
    if not exports:
        fail("缺少 .exports")
    if not sections:
        # linux-musl-x64 的 ILCompiler 不生成 sections.ld；该脚本与架构无关，补写即可
        sec = nd / "sections.ld"
        sec.write_text("OVERWRITE_SECTIONS { __modules : { KEEP(*(__modules)) } }\n",
                       encoding="utf-8")
        sections = [sec]
        log("link", "已补写 sections.ld（x64 RID 不自带）")

    sdk = ilc / "sdk"
    framework = ilc / "framework"

    # .NET 10 起，ILCompiler 的运行时静态库不再放在
    #   runtime.<rid>.microsoft.dotnet.ilcompiler/<ver>/sdk/
    # 而是搬到
    #   microsoft.netcore.app.runtime.nativeaot.<rid>/<ver>/runtimes/<rid>/native/
    # 且新增 libSystem.Native / libaotminipal / libbrotli* 等。直接从 publish 的
    # 链接命令里抄出来的顺序（缺失的跳过），再用 glob 兜底，避免版本差异。
    native = (NUGET_ROOT / f"microsoft.netcore.app.runtime.nativeaot.{RID}"
              / ilc.name / "runtimes" / RID / "native")

    if native.is_dir():
        ordered = [
            "libSystem.Native.a",
            "libSystem.Globalization.Native.a",
            "libSystem.IO.Compression.Native.a",
            "libSystem.Net.Security.Native.a",
            "libSystem.Security.Cryptography.Native.OpenSsl.a",
            "libbootstrapperdll.o",
            "libRuntime.WorkstationGC.a",
            "libeventpipe-disabled.a",
            "libRuntime.VxsortEnabled.a",
            "libRuntime.VxsortDisabled.a",
            "libstandalonegc-disabled.a",
            "libaotminipal.a",
            "libstdc++compat.a",
            "libz.a",
            "libbrotlienc.a",
            "libbrotlidec.a",
            "libbrotlicommon.a",
        ]
        libs = [native / n for n in ordered if (native / n).exists()]
        known = {p.name for p in libs}
        libs += sorted(p for p in native.glob("lib*.a") if p.name not in known)
        libs.append(builtins)
        log("link", f".NET 10 运行时布局：{native}（{len(libs)} 个库/对象）")
    else:
        # .NET 9 / M0 的旧布局
        libs = [
            sdk / "libbootstrapperdll.o",
            sdk / "libRuntime.WorkstationGC.a",
            sdk / "libeventpipe-disabled.a",
            *([sdk / "libRuntime.VxsortEnabled.a"]
              if RID == "linux-musl-x64" and (sdk / "libRuntime.VxsortEnabled.a").exists() else []),
            sdk / "libstandalonegc-disabled.a",
            sdk / "libstdc++compat.a",
            *sorted(framework.glob("libSystem.*.a")),
            sdk / "libz.a",
            builtins,
        ]
        log("link", "旧 ILCompiler 布局：ilcompiler/sdk/")

    missing = [str(x) for x in libs if not x.exists()]
    if missing:
        fail("ILCompiler runtime 静态库缺失：\n  " + "\n  ".join(missing))

    # 静态库之间有交叉引用，用 --start-group / --end-group 让 lld 反复扫描。
    lib_args = ["-Wl,--start-group", *[str(x) for x in libs], "-Wl,--end-group"]

    # 额外原生库统一按 NATIVE_DEPS 表挂成 DT_NEEDED，原因见文件头该表的注释。
    # 同一目录只加一次 -L，但要省掉重复的 --no-as-needed。
    extra: list[str] = []
    linked: set[pathlib.Path] = set()
    linked_dirs: set[pathlib.Path] = set()

    for directory, filename in NATIVE_DEPS:
        path = directory / filename
        if not path.exists():
            # 缺失不致命：对应子系统会在运行期 DllNotFoundException，
            # 让「其它层」还能继续验证。日志里说清楚缺什么。
            log("dep", f"缺失 {path}，跳过（相关功能将在运行期 DllNotFound）")
            continue

        if not filename.startswith("lib") or not filename.endswith(".so"):
            fail(f"NATIVE_DEPS 里的文件名必须形如 libFoo.so：{filename}")

        short = filename[3:-3]  # libFoo.so -> Foo

        if directory not in linked_dirs:
            linked_dirs.add(directory)
            extra += ["-Wl,--no-as-needed", f"-L{directory}"]

        extra += [f"-l{short}"]
        linked.add(path)
        log("dep", f"DT_NEEDED <- {filename}")

    if linked:
        # $ORIGIN 让加载器在 libmain.so 同目录找这些库（它们随 HAP 一起解压到 libs/<abi>）。
        extra += ["-Wl,-rpath,$ORIGIN", "-Wl,--enable-new-dtags"]
    else:
        log("dep", "没有任何额外原生库，libmain.so 将只有 libc.so 依赖")

    clang = OHOS / "llvm/bin/clang.exe"
    cmd = [
        str(clang), str(objs[0]), "-o", str(output),
        f"-Wl,--version-script={exports[0]}", "-Wl,--export-dynamic",
        f"--target={TARGET}", f"--sysroot={OHOS / 'sysroot'}",
        *lib_args,
        *extra,
        f"-L{OHOS / 'sysroot/usr/lib/{TARGET}'}",
        "-pthread", "-ldl", "-lrt", "-lm", "-lc", "-shared",
        "-Wl,-z,relro", "-Wl,-z,now", "-Wl,-z,stack-size=1572864",
        "-Wl,--eh-frame-hdr", "-Wl,--discard-all", "-Wl,--gc-sections",
        f"-Wl,-T,{sections[0]}", "-g",
    ]
    log("link", f"clang ({TARGET}) -> {output}")
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0 or not output.exists():
        print((p.stdout + p.stderr)[-4000:], file=sys.stderr)
        fail(f"clang 链接失败 (exit={p.returncode})")
    log("link", f"OK  {output.stat().st_size} bytes")


def verify(output: pathlib.Path):
    data = output.read_bytes()
    if data[:4] != b"\x7fELF":
        fail("产物不是 ELF")
    machine = int.from_bytes(data[18:20], "little")
    log("verify", f"ELF magic OK, e_machine={machine} (期望 {MACHINE}={MACHINE_NAME})")
    if machine != MACHINE:
        fail(f"架构不符：得到 {machine}，期望 {MACHINE}")

    readelf = OHOS / "llvm/bin/llvm-readelf.exe"
    if not readelf.exists():
        return
    p = subprocess.run([str(readelf), "-d", str(output)], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    needed = [l.strip() for l in p.stdout.splitlines() if "NEEDED" in l]
    log("verify", "DT_NEEDED: " + (", ".join(needed) or "(none)"))

    p = subprocess.run([str(readelf), "--dyn-syms", str(output)], capture_output=True,
                       text=True, encoding="utf-8", errors="replace")
    defined = [l.split()[-1] for l in p.stdout.splitlines()
               if "GLOBAL" in l and "DEFAULT" in l and "FUNC" in l and " UND " not in l]
    log("verify", f"已定义导出函数 {len(defined)} 个；样例：" + ", ".join(defined[:6]))


def main():
    global RID, TARGET, MACHINE, MACHINE_NAME, BASS_DIR, VELDRID_DIR, REALM_DIR, SQLITE_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", required=True)
    ap.add_argument("--output")
    ap.add_argument("--hap-libs")
    ap.add_argument("--rid", default="linux-musl-arm64",
                    choices=["linux-musl-arm64", "linux-musl-x64"])
    ap.add_argument("--sdk-major", type=int, default=9)
    ap.add_argument("--skip-publish", action="store_true")
    ap.add_argument("--extra-msbuild", default="")
    a = ap.parse_args()

    RID = a.rid
    native_root = pathlib.Path(__file__).resolve().parent.parent / "osu-ohos/native"
    if RID == "linux-musl-x64":
        TARGET, MACHINE, MACHINE_NAME = "x86_64-linux-ohos", 62, "x86-64"
        abi = "x86_64"
    else:
        TARGET, MACHINE, MACHINE_NAME = "aarch64-linux-ohos", 183, "AArch64"
        abi = "arm64-v8a"

    BASS_DIR = native_root / "bass-shim" / abi
    VELDRID_DIR = native_root / "veldrid-spirv" / abi
    REALM_DIR = native_root / "realm-wrappers" / abi
    SQLITE_DIR = native_root / "sqlite" / abi

    NATIVE_DEPS[:] = [
        *[(BASS_DIR, n) for n in BASS_LIBS],
        (VELDRID_DIR, VELDRID_LIB),
        (REALM_DIR, REALM_LIB),
        (SQLITE_DIR, SQLITE_LIB),
    ]

    project = pathlib.Path(a.project).resolve()
    if project.is_file():
        csproj = project
        project = project.parent
    else:
        hits = sorted(project.glob("*.csproj"))
        if not hits:
            fail(f"{project} 下没有 .csproj")
        csproj = hits[0]

    for p, label in [(DOTNET, "dotnet"), (OHOS / "llvm/bin/clang.exe", "OHOS clang"),
                     (OHOS / f"sysroot/usr/lib/{TARGET}", "OHOS sysroot target")]:
        if not p.exists():
            fail(f"{label} 不存在：{p}")

    output = (pathlib.Path(a.output).resolve() if a.output
              else (project / f"{csproj.stem}.so"))
    output.parent.mkdir(parents=True, exist_ok=True)

    nd = native_dir(project) if a.skip_publish else run_publish(
        csproj, a.extra_msbuild.split() if a.extra_msbuild else [])
    ilc = find_ilcompiler(a.sdk_major)
    builtins = find_builtins()
    log("builtins", str(builtins))

    link(nd, output, ilc, builtins)
    verify(output)

    if a.hap_libs:
        dest = pathlib.Path(a.hap_libs) / output.name
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(output.read_bytes())
        log("hap", f"已拷入 {dest}")

        # 额外原生库必须和 libmain.so 同目录：DT_NEEDED 靠 rpath=$ORIGIN 找它们
        for directory, name in NATIVE_DEPS:
            src = directory / name
            if src.exists():
                (dest.parent / name).write_bytes(src.read_bytes())
                log("hap", f"已拷入 {dest.parent / name}")

        vd = VELDRID_DIR / f"lib{VELDRID_LIB}.so" if VELDRID_DIR else None
        if vd and vd.exists():
            (dest.parent / vd.name).write_bytes(vd.read_bytes())
            log("hap", f"已拷入 {dest.parent / vd.name}")

    print(json.dumps({"success": True, "so": str(output), "rid": RID,
                      "target": TARGET, "bytes": output.stat().st_size},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
