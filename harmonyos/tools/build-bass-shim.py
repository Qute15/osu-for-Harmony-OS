#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""编译 BASS 兼容垫片（libbass / libbassmix / libbass_fx）为 OpenHarmony 动态库。

为什么需要垫片：见 bass_shim.c 顶部注释。核心是 OHOS 上无法加载任何官方
libbass*.so（Bionic / glibc ABI），BASS 又闭源，只能按同一套 C ABI 重写。

用法：
    python build-bass-shim.py --arch x86_64
    python build-bass-shim.py --arch arm64-v8a
    python build-bass-shim.py --arch all

产物（随后由 build-aot.py 以 DT_NEEDED 方式挂到 libmain.so，并拷进 HAP）：
    osu-ohos/native/bass-shim/<abi>/libbass.so
    osu-ohos/native/bass-shim/<abi>/libbassmix.so
    osu-ohos/native/bass-shim/<abi>/libbass_fx.so
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
CLANG = NATIVE / "llvm/bin/clang.exe"
SYSROOT = NATIVE / "sysroot"
SRC = ROOT / "osu-ohos/native/bass-shim/bass_shim.c"
# 解码层（miniaudio + stb_vorbis）只编进 libbass.so。mix / fx 只是转发，
# 单独编会白多出几十 KB，而且在 musl 上多一份解码器没有任何意义。
DEC_SRC = ROOT / "osu-ohos/native/bass-shim/ma_decode.c"
THIRD_PARTY = ROOT / "osu-ohos/native/bass-shim/third_party"
OUT_ROOT = ROOT / "osu-ohos/native/bass-shim"

TARGETS = {
    "x86_64": "x86_64-linux-ohos",
    "arm64-v8a": "aarch64-linux-ohos",
}

# (输出库名, SHIM_MODULE, 额外链接参数)
MODULES = [
    ("libbass.so", 0, []),
    ("libbassmix.so", 1, ["-L{dir}", "-lbass", "-Wl,-rpath,$ORIGIN"]),
    ("libbass_fx.so", 2, ["-L{dir}", "-lbass", "-Wl,-rpath,$ORIGIN"]),
]


def build(abi: str) -> int:
    triple = TARGETS[abi]
    out_dir = OUT_ROOT / abi
    out_dir.mkdir(parents=True, exist_ok=True)

    for name, module, extra in MODULES:
        cmd = [
            str(CLANG), str(SRC), "-o", str(out_dir / name),
            f"--target={triple}", f"--sysroot={SYSROOT}", "-D__MUSL__",
            f"-DSHIM_MODULE={module}",
            "-O2", "-fPIC", "-shared", "-fvisibility=default",
            "-Wall", "-Wextra", "-Wno-unused-parameter", "-Wno-strict-prototypes",
            f"-Wl,-soname,{name}",
            *[a.format(dir=out_dir) for a in extra],
        ]

        if module == 0:
            # 解码层一并编进 libbass.so。
            # -Wno-unused-function / -Wno-sign-compare 是给 stb_vorbis 与 dr_mp3 的：
            # 它们是第三方单文件库，自己内部就有大量未使用静态函数，
            # 开着 -Wall -Wextra 会被刷屏（不是我们代码的问题）。
            cmd += [
                str(DEC_SRC),
                f"-I{THIRD_PARTY}",
                "-Wno-unused-function", "-Wno-sign-compare", "-Wno-unused-variable",
                # OH_AudioRenderer 由系统提供（sysroot 里是桩库），
                # DT_NEEDED 会写 libohaudio.so，运行时由系统解析，不进 HAP。
                "-lohaudio",
            ]

        print(f"[{abi}] {name}  <- SHIM_MODULE={module}", flush=True)
        p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        out = (p.stdout + p.stderr).strip()
        if out:
            print(out, flush=True)
        if p.returncode != 0 or not (out_dir / name).exists():
            print(f"[{abi}] FAILED {name}", file=sys.stderr)
            return 1

    readelf = NATIVE / "llvm/bin/llvm-readelf.exe"
    if readelf.exists():
        for name, _, _ in MODULES:
            p = subprocess.run([str(readelf), "-d", str(out_dir / name)],
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            needed = [l.split("[")[-1].rstrip("]") for l in p.stdout.splitlines()
                      if "NEEDED" in l or "SONAME" in l or "RUNPATH" in l]
            size = (out_dir / name).stat().st_size
            print(f"[{abi}] {name}: {size} bytes  {' '.join(needed)}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", default="all", choices=["x86_64", "arm64-v8a", "all"])
    a = ap.parse_args()

    for p in (CLANG, SYSROOT, SRC):
        if not p.exists():
            print(f"缺少 {p}", file=sys.stderr)
            return 1

    arches = list(TARGETS) if a.arch == "all" else [a.arch]
    for abi in arches:
        if build(abi) != 0:
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
