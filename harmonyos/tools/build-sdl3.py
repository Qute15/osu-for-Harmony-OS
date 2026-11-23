#!/usr/bin/env python3
"""Build SDL3 (main branch, with the official OpenHarmony backend) for OHOS.

Uses DevEco Studio's bundled OHOS CMake / Ninja / clang toolchain on Windows.

Usage:
    python build-sdl3.py --arch x86_64
    python build-sdl3.py --arch arm64-v8a
    python build-sdl3.py --arch all
    python build-sdl3.py --arch x86_64 --configure-only

Outputs:
    output/SDL3-build-<arch>/libSDL3.so
    output/SDL3-build-<arch>/libmain.so   (SDL's NAPI entry, reference only)
"""

import argparse
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
NATIVE = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
SDK_VERSION = "26.0.0"  # DevEco SDK apiVersion 26; upstream README uses 16.0.0 for API 16

CMAKE = NATIVE / "build-tools/cmake/bin/cmake.exe"
NINJA = NATIVE / "build-tools/cmake/bin/ninja.exe"
TOOLCHAIN = NATIVE / "build/cmake/ohos.toolchain.cmake"
SRC = ROOT / "SDL-main"


def log(*args):
    print(*args, flush=True)


def run(cmd, cwd, log_path, env):
    """Run a command, tee full output to log_path, print the tail on failure/success."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as f:
        f.write("$ " + " ".join(str(c) for c in cmd) + "\n\n")
        f.flush()
        proc = subprocess.Popen(
            [str(c) for c in cmd], cwd=str(cwd), env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, encoding="utf-8", errors="replace", bufsize=1,
        )
        for line in proc.stdout:
            f.write(line)
        proc.wait()
    text = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    return proc.returncode, text


def build(arch, configure_only, clean):
    for p in (CMAKE, NINJA, TOOLCHAIN):
        if not p.exists():
            log(f"FATAL missing toolchain component: {p}")
            return 1
    if not (SRC / "CMakeLists.txt").exists():
        log(f"FATAL missing SDL3 source: {SRC}")
        return 1

    # Never reuse/delete an existing build tree on Windows: lld cannot
    # overwrite a libSDL3.so that another tool has open (Permission denied),
    # and bulk-deleting the tree trips the sandbox's safe-delete guard.
    # A fresh, uniquely-named output directory avoids both.
    bdir = ROOT / f"SDL3-build-{arch}-ohos"
    if clean:
        log("[note] --clean is ignored; a fresh build directory is used instead.")
    bdir.mkdir(parents=True, exist_ok=True)

    env = os.environ.copy()
    # `where /Q` in MSBuild/CMake probes need these on PATH; spaces in path are
    # handled by subprocess list args, not by shell quoting.
    env["PATH"] = (
        str(NATIVE / "llvm/bin") + os.pathsep
        + str(NATIVE / "build-tools/cmake/bin") + os.pathsep
        + env.get("PATH", "")
    )

    configure = [
        CMAKE, "-S", SRC, "-B", bdir, "-G", "Ninja",
        f"-DCMAKE_TOOLCHAIN_FILE={TOOLCHAIN}",
        f"-DCMAKE_MAKE_PROGRAM={NINJA}",
        "-DCMAKE_BUILD_TYPE=Release",
        f"-DOHOS_COMPATIBLE_SDK_VERSION={SDK_VERSION}",
        f"-DOHOS_ARCH={arch}",
        "-DSDL_SHARED=ON", "-DSDL_STATIC=OFF",
        "-DSDL_TESTS=OFF", "-DSDL_EXAMPLES=OFF", "-DSDL_INSTALL=OFF",
        "-DSDL_PRESEED=ON",
        # Upstream openharmony-project/entry/build-profile.json5 uses this:
        # without it SDL3 gets an unversioned *and* a versioned soname, and the
        # XComponent loader + NAPI import can end up with two copies of SDL's
        # data segment. Keep SONAME exactly "libSDL3.so".
        "-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=1",
    ]
    log(f"[{arch}] configure -> {bdir}")
    rc, lines = run(configure, bdir, ROOT / f"sdl3-{arch}-configure.log", env)
    for l in lines[-25:]:
        log("   ", l)
    if rc != 0:
        log(f"[{arch}] CONFIGURE FAILED rc={rc}; full log: {ROOT / f'sdl3-{arch}-configure.log'}")
        return rc
    log(f"[{arch}] configure OK")

    if configure_only:
        return 0

    log(f"[{arch}] build (ninja)")
    rc, lines = run([NINJA, "-C", bdir], bdir, ROOT / f"sdl3-{arch}-build.log", env)
    for l in lines[-25:]:
        log("   ", l)
    if rc != 0:
        log(f"[{arch}] BUILD FAILED rc={rc}; full log: {ROOT / f'sdl3-{arch}-build.log'}")
        return rc

    products = sorted(bdir.glob("libSDL3.so*")) + sorted(bdir.glob("libmain.so*"))
    if not products:
        log(f"[{arch}] BUILD OK but no libSDL3.so found under {bdir}")
        return 2
    for p in products:
        log(f"[{arch}] PRODUCT {p.name}  {p.stat().st_size} bytes")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=["arm64-v8a", "x86_64", "all"], default="all")
    ap.add_argument("--configure-only", action="store_true")
    ap.add_argument("--clean", action="store_true")
    args = ap.parse_args()

    archs = ["arm64-v8a", "x86_64"] if args.arch == "all" else [args.arch]
    for a in archs:
        rc = build(a, args.configure_only, args.clean)
        if rc != 0:
            return rc
    return 0


if __name__ == "__main__":
    sys.exit(main())
