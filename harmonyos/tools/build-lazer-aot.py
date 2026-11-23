#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把真 osu!lazer（osu.OHOS）NativeAOT 编译成 SDL3 需要的 libmain.so。

SDL3 的 OpenHarmony 启动链固定 dlopen("libmain.so") 并寻找 "SDL_main"
（SDL-main/src/main/openharmony/SDL_sysmain_runapp.c:54-73），所以产物文件名
必须是 libmain.so，且必须导出 SDL_main（NativeEntry.Main）。

本脚本是 build-aot.py 的薄封装，额外做三件事：
  1. 强制 -p:UseLocalFramework=true，让 osu.Game 与 osu.Framework.OHOS 共用
     同一份本地源码编译的 osu.Framework（否则 CS1704 两份同名程序集）；
  2. 强制 -p:InvariantGlobalization=true -p:PredefinedCulturesOnly=false，
     绕开 OHOS 上缺失 glibc 版 ICU 导致的 GlobalizationMode FailFast；
  3. 把 --sdk-major 设为 10（本机 .NET SDK 10.0.403）；
  4. 校验 SDL_main 符号，strip 后按架构拷进 entry/libs/<abi>/libmain.so
     （未 strip 的原产物保留在 output/aot-tools/libmain-<arch>/ 供崩溃栈符号化）。

用法：
  python build-lazer-aot.py --arch x86_64       # DevEco 模拟器
  python build-lazer-aot.py --arch arm64-v8a    # 真机
  python build-lazer-aot.py --arch x86_64 --skip-publish --no-hap   # 只重链

前置：
  dotnet restore osu.OHOS.csproj -p:UseLocalFramework=true --force
  （或者让本脚本的 publish 步骤自动还原）
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
BUILD_AOT = ROOT / "aot-tools/build-aot.py"
PROJECT = ROOT / "osu-ohos/osu.OHOS/osu.OHOS.csproj"
HAP_LIBS = pathlib.Path("C:/Users/z3306/DevEcoStudioProjects/MyApplication/entry/libs")
OHOS_LLVM_BIN = pathlib.Path(
    "C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native/llvm/bin")
OHOS_READELF = OHOS_LLVM_BIN / "llvm-readelf.exe"
OHOS_STRIP = OHOS_LLVM_BIN / "llvm-strip.exe"

ARCHES = {
    "x86_64": ("linux-musl-x64", "x86_64", 62),
    "arm64-v8a": ("linux-musl-arm64", "arm64-v8a", 183),
}

# 必须和 libmain.so 同目录进 HAP 的原生库：(子目录, 文件名, 生成它的脚本)。
# 这些同时也是 libmain.so 的 DT_NEEDED（见 build-aot.py 的 NATIVE_DEPS），
# 靠 rpath=$ORIGIN 在 libmain.so 同目录解析 —— musl 只按 shortname 复用已加载
# 的库，所以「运行期 dlopen 绝对路径」这条路走不通。
NATIVE_EXTRA = [
    ("bass-shim", "libbass.so", "build-bass-shim.py"),
    ("bass-shim", "libbassmix.so", "build-bass-shim.py"),
    ("bass-shim", "libbass_fx.so", "build-bass-shim.py"),
    ("veldrid-spirv", "libveldrid-spirv.so", "build-veldrid-spirv.py"),
    ("realm-wrappers", "librealm-wrappers.so", "build-realm-wrappers.py"),
    ("sqlite", "libe_sqlite3.so", "build-sqlite.py"),
]


def log(tag, msg):
    print(f"[{tag}] {msg}", flush=True)


def verify_sdl_main(so: pathlib.Path, machine: int) -> bool:
    data = so.read_bytes()
    if data[:4] != b"\x7fELF":
        log("verify", "FAIL 不是 ELF")
        return False
    got = int.from_bytes(data[18:20], "little")
    if got != machine:
        log("verify", f"FAIL 架构 {got} != {machine}")
        return False
    if not OHOS_READELF.exists():
        log("verify", "llvm-readelf 不存在，跳过符号检查")
        return True
    p = subprocess.run([str(OHOS_READELF), "--dyn-syms", str(so)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    syms = [l for l in p.stdout.splitlines() if "SDL_main" in l]
    defined = [l for l in syms if "GLOBAL" in l and "DEFAULT" in l and " UND " not in l]
    for l in syms:
        log("verify", l.strip())
    if not defined:
        log("verify", "FAIL 没有已定义的 SDL_main 导出（检查 [UnmanagedCallersOnly]）")
        return False
    log("verify", f"PASS e_machine={got}, SDL_main 已导出")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=list(ARCHES), default="x86_64")
    ap.add_argument("--skip-publish", action="store_true")
    ap.add_argument("--no-hap", action="store_true")
    a = ap.parse_args()

    rid, abi, machine = ARCHES[a.arch]
    out = ROOT / "aot-tools" / f"libmain-{a.arch}" / "libmain.so"
    out.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        sys.executable, str(BUILD_AOT),
        "--project", str(PROJECT),
        "--rid", rid,
        "--sdk-major", "10",
        "--output", str(out),
        # argparse 会把单独的 "-p:..." 当成新选项，必须用 --opt=value 形式；
        # build-aot.py 会按空白 split 成多个 msbuild 参数。
        "--extra-msbuild=-p:UseLocalFramework=true "
        "-p:InvariantGlobalization=true -p:PredefinedCulturesOnly=false",
    ]
    if a.skip_publish:
        cmd.append("--skip-publish")
    log("aot", " ".join(cmd))
    r = subprocess.run(cmd, capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    print(r.stdout[-6000:], flush=True)
    if r.stderr.strip():
        print("STDERR:\n" + r.stderr[-3000:], flush=True)
    if r.returncode != 0 or not out.exists():
        print(json.dumps({"success": False, "stage": "aot", "arch": a.arch,
                          "log_tail": r.stdout[-2000:]}, ensure_ascii=False))
        sys.exit(1)

    if not verify_sdl_main(out, machine):
        sys.exit(1)

    result = {"success": True, "arch": a.arch, "rid": rid,
              "so": str(out), "bytes": out.stat().st_size}

    if not a.no_hap:
        dst = HAP_LIBS / abi / "libmain.so"
        dst.parent.mkdir(parents=True, exist_ok=True)
        raw = out.stat().st_size
        shutil.copy2(out, dst)
        # HAP 内只放 strip-all 版本（661 MB -> ~223 MB）；out 保留完整符号，
        # 崩溃时的 PC 偏移可以直接用 llvm-symbolizer --obj=out 还原。
        if OHOS_STRIP.exists():
            p = subprocess.run([str(OHOS_STRIP), "--strip-all", str(dst)],
                               capture_output=True, text=True,
                               encoding="utf-8", errors="replace")
            if p.returncode != 0:
                log("hap", f"WARN strip 失败，HAP 内保留未 strip 版本：{p.stderr[-300:]}")
        result["hap_lib"] = str(dst)
        result["hap_bytes"] = dst.stat().st_size
        log("hap", f"已拷入 {dst} ({raw} -> {result['hap_bytes']} bytes)")

        # 额外原生库必须和 libmain.so 同目录：libmain.so 的 DT_NEEDED 靠
        # rpath=$ORIGIN 在这些库的同目录里解析（见 build-aot.py 里 NATIVE_DEPS 的注释）。
        # 缺任何一个都不致命，但对应子系统会在运行期 DllNotFound。
        for subdir, name, how in NATIVE_EXTRA:
            src = ROOT / "osu-ohos/native" / subdir / abi / name
            if src.exists():
                shutil.copy2(src, dst.parent / name)
                log("hap", f"已拷入 {dst.parent / name} ({src.stat().st_size} bytes)")
            else:
                log("hap", f"WARN 缺少 {src}（先跑 {how} --arch {a.arch}）")

    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
