#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 HarmonyOS 交叉编译 libveldrid-spirv.so（osu!lazer 的着色器编译器）。

为什么必须自编
--------------
osu.Framework 的全部着色器都走 GLSL --glslang--> SPIR-V --SPIRV-Cross--> ESSL
（见 Graphics/Shaders/ShaderCompilationStore.cs，Veldrid.SPIRV 的
CrossCompile / CompileGlslToSpirv / FreeResult 三个 C 导出）。
NuGet 里的 ppy.veldrid.spirv 只发 glibc/GLIBCXX 版本，DT_NEEDED 带
libstdc++/GLIBC_2.2.5 版本化符号，OHOS musl 无法加载，因此从源码重编。

源码布局（本脚本假定已按此组装，见 ensure_sources()）
----------------------------------------------------
  native-src/veldrid-spirv-<sha>/
    ext/shaderc/                                   google/shaderc
    ext/shaderc/third_party/glslang                KhronosGroup/glslang
    ext/shaderc/third_party/spirv-tools            KhronosGroup/SPIRV-Tools
    ext/shaderc/third_party/spirv-tools/external/spirv-headers
                                                   KhronosGroup/SPIRV-Headers
    ext/SPIRV-Cross                                KhronosGroup/SPIRV-Cross

必须的两处源码补丁（本脚本幂等施加）
------------------------------------
  ① SPIRV-Tools/CMakeLists.txt：无 OHOS 分支，会落到 else() 报
     "Unknown platform" 并中断配置。补一个与 Linux 同构的分支。
  ② glslang/OSDependent/Unix/ossource.cpp：线程取消清理用
     pthread_setcanceltype/pthread_testcancel，OHOS musl 未导出这两个符号；
     Android/Fuchsia 已有同样豁免，把 __OHOS__ 加进去。

用法：
  python build-veldrid-spirv.py --arch x86_64
  python build-veldrid-spirv.py --arch arm64-v8a
"""
from __future__ import annotations

import argparse
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OHOS = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
CMAKE = OHOS / "build-tools/cmake/bin/cmake.exe"
NINJA = ROOT / "native-src/dl/ninja.exe"
TOOLCHAIN = OHOS / "build/cmake/ohos.toolchain.cmake"
STRIP = OHOS / "llvm/bin/llvm-strip.exe"

SRC = ROOT / "native-src/veldrid-spirv-5911265ec3"
DEST = ROOT / "osu-ohos/native/veldrid-spirv"

# arch -> (OHOS_ARCH, hap abi 目录名, ELF e_machine)
ARCHES = {
    "x86_64": ("x86_64", "x86_64", 62),
    "arm64-v8a": ("arm64", "arm64-v8a", 183),
}


def log(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def patch_sources() -> None:
    """幂等地施加两处必需补丁。"""
    pt = SRC / "ext/shaderc/third_party/spirv-tools/CMakeLists.txt"
    if not pt.exists():
        die(f"缺少源文件 {pt}")
    text = pt.read_text(encoding="utf-8", errors="replace")
    if "STREQUAL \"OHOS\"" not in text:
        anchor = 'elseif("${CMAKE_SYSTEM_NAME}" STREQUAL "FreeBSD")'
        if anchor not in text:
            die("SPIRV-Tools/CMakeLists.txt 结构变化，找不到 FreeBSD 分支作为插入点")
        text = text.replace(
            anchor,
            'elseif("${CMAKE_SYSTEM_NAME}" STREQUAL "OHOS")\n'
            '  # HarmonyOS 的 C 运行库是 musl，系统服务与 Linux 同构；\n'
            '  # 上游没有这个分支会落到 else() 里报 Unknown platform。\n'
            '  add_definitions(-DSPIRV_LINUX)\n'
            '  set(SPIRV_TIMER_ENABLED ${SPIRV_ALLOW_TIMERS})\n'
            + anchor,
            1,
        )
        pt.write_text(text, encoding="utf-8")
        log("patch", "SPIRV-Tools/CMakeLists.txt 已加 OHOS 平台分支")
    else:
        log("patch", "SPIRV-Tools/CMakeLists.txt 已有 OHOS 分支，跳过")

    po = SRC / "ext/shaderc/third_party/glslang/glslang/OSDependent/Unix/ossource.cpp"
    if not po.exists():
        die(f"缺少源文件 {po}")
    text = po.read_text(encoding="utf-8", errors="replace")
    old = "#if defined(__ANDROID__) || defined(__Fuchsia__)"
    if "|| defined(__OHOS__)" in text:
        log("patch", "glslang ossource.cpp 已有 __OHOS__ 豁免，跳过")
    elif old not in text:
        die("glslang ossource.cpp 结构变化，找不到 __ANDROID__ 判断")
    else:
        text = text.replace(old, old + " || defined(__OHOS__)", 1)
        po.write_text(text, encoding="utf-8")
        log("patch", "glslang ossource.cpp 已加 __OHOS__ 豁免")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=list(ARCHES), default="x86_64")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()

    ohos_arch, abi, machine = ARCHES[a.arch]
    if not SRC.exists():
        die(f"源码目录不存在：{SRC}\n"
            "  先按文件头注释的结构下载并解包 "
            "(shaderc / glslang / SPIRV-Tools / SPIRV-Headers / SPIRV-Cross)")
    if not NINJA.exists():
        die(f"缺少 ninja：{NINJA}（解压到 native-src/dl/ninja.exe）")

    patch_sources()

    build = SRC / "build" / abi
    cfg = [
        str(CMAKE), "-G", "Ninja", "-S", str(SRC), "-B", str(build),
        f"-DCMAKE_MAKE_PROGRAM={NINJA}",
        f"-DCMAKE_TOOLCHAIN_FILE={TOOLCHAIN}",
        f"-DOHOS_ARCH={ohos_arch}",
        "-DOHOS_STL=c++_static",
        "-DOHOS_PLATFORM=phone",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DSHADERC_SKIP_TESTS=ON",
        "-DSHADERC_SKIP_INSTALL=ON",
        "-DSHADERC_SKIP_EXAMPLES=ON",
        "-DSHADERC_SKIP_COPYRIGHT_CHECK=ON",
        # OHOS 工具链会注入 --gcc-toolchain，clang 视其为未使用参数并给警告，
        # 而 shaderc 系列 target 开了 -Werror，必须关掉这条警告。
        "-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument",
        "-DCMAKE_CXX_FLAGS=-Wno-unused-command-line-argument",
    ]
    log("cmake", f"configure -> {build}")
    p = subprocess.run(cfg, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-4000:], file=sys.stderr)
        die(f"cmake 配置失败 (exit={p.returncode})")

    log("ninja", f"build target veldrid-spirv -j {a.jobs}")
    p = subprocess.run([str(NINJA), "-C", str(build), "veldrid-spirv", "-j", str(a.jobs)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        errs = [l for l in (p.stdout + p.stderr).splitlines() if "error:" in l or l.startswith("FAILED")]
        print("\n".join(errs[:40]) or (p.stdout + p.stderr)[-3000:], file=sys.stderr)
        die(f"ninja 编译失败 (exit={p.returncode})")

    so = build / "libveldrid-spirv.so"
    if not so.exists():
        die(f"编译结束但产物不存在：{so}")

    dest = DEST / abi / "libveldrid-spirv.so"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(so, dest)
    raw = dest.stat().st_size
    if STRIP.exists():
        subprocess.run([str(STRIP), "--strip-unneeded", str(dest)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    log("ok", f"{dest} ({raw} -> {dest.stat().st_size} bytes)")
    log("ok", f"目标架构 e_machine={machine}（{abi}）")


if __name__ == "__main__":
    main()
