#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 HarmonyOS 交叉编译 librealm-wrappers.so（osu!lazer 的数据库层）。

为什么必须自编
--------------
`Realm` 托管包只做一件事：P/Invoke `realm-wrappers`（1169 个 C 导出），
真正的存储引擎 realm-core 是**静态链接**进这个 .so 的。
NuGet 发的是 glibc 二进制：DT_NEEDED 含 ld-linux-x86-64.so.2 / libc.so.6 /
libpthread.so.0 / libdl.so.2 —— OHOS musl 一个都没有，加载必失败。

关键结论：OHOS 下不需要 OpenSSL
--------------------------------
realm-core 只在 `REALM_ENABLE_ENCRYPTION && CMAKE_SYSTEM_NAME MATCHES "Linux|Android"`
时才要求 OpenSSL。OHOS 的 CMAKE_SYSTEM_NAME 是 "OHOS"，不匹配；
把加密关掉（lazer 的本地库不加密）后自动落到**内置 SHA-1/SHA-2 实现**
（src/external/sha-1、sha-2，realm-core 的 git 子模块）。
因此没有任何外部加密依赖。

源码布局（本脚本假定已按此组装）
--------------------------------
  native-src/realm/realm-dotnet-20.1.0/wrappers/
    realm-core/            <- realm-core v20.1.2 全量源码
      src/external/sha-1/  <- clibs/sha1 的 sha1.c sha1.h（子模块，tarball 里没有）
      src/external/sha-2/  <- kalven/sha-2 的 sha2*.(cpp|hpp)（同上）
    src/                   <- realm-dotnet 的 wrappers C++ 源码
    CMakeLists.txt

必须的源码补丁（本脚本幂等施加）
--------------------------------
realm-core/src/realm/util/thread.cpp：
  判断 robust mutex 是否可用的启发式是
  `_POSIX_THREADS >= 200809L && !__GNU_LIBRARY__ && !REALM_ANDROID -> 可用`。
  musl 声明了 _POSIX_THREADS=200809L，但**没有实现** robust mutex
  （pthread_mutexattr_setrobust / pthread_mutex_consistent 未导出），
  于是编译期直接报 use of undeclared identifier。补上 __OHOS__ 排除。

用法：
  python build-realm-wrappers.py --arch x86_64
  python build-realm-wrappers.py --arch arm64-v8a
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
READELF = OHOS / "llvm/bin/llvm-readelf.exe"

WRAPPERS = ROOT / "native-src/realm/realm-dotnet-20.1.0/wrappers"
DEST = ROOT / "osu-ohos/native/realm-wrappers"

ARCHES = {
    "x86_64": ("x86_64", "x86_64", 62),
    "arm64-v8a": ("arm64", "arm64-v8a", 183),
}


def log(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def check_sources() -> None:
    need = [
        WRAPPERS / "CMakeLists.txt",
        WRAPPERS / "src/CMakeLists.txt",
        WRAPPERS / "realm-core/CMakeLists.txt",
        WRAPPERS / "realm-core/src/external/sha-1/sha1.c",
        WRAPPERS / "realm-core/src/external/sha-2/sha224.cpp",
    ]
    missing = [p for p in need if not p.exists()]
    if missing:
        die("源码不完整，缺：\n  " + "\n  ".join(str(p) for p in missing) + "\n"
            "  需要：realm-dotnet 20.1.0 的 wrappers/ + realm-core v20.1.2 全量源码"
            "（放到 wrappers/realm-core/）+ clibs/sha1 与 kalven/sha-2 两个子模块"
            "（分别放进 realm-core/src/external/sha-1 和 sha-2）")


def patch_thread_cpp() -> None:
    p = WRAPPERS / "realm-core/src/realm/util/thread.cpp"
    text = p.read_text(encoding="utf-8", errors="replace")
    if "__OHOS__" in text:
        log("patch", "thread.cpp 已有 __OHOS__ 排除，跳过")
        return
    old = "#elif !REALM_ANDROID\n#define REALM_HAVE_ROBUST_PTHREAD_MUTEX"
    if old not in text:
        die("thread.cpp 结构变化，找不到 robust mutex 判定分支")
    new = ("#elif !REALM_ANDROID && !defined(__OHOS__)\n"
           "// HarmonyOS 的 C 运行库是 musl。musl 虽然声明了 _POSIX_THREADS=200809L，\n"
           "// 但**没有实现** robust mutex（pthread_mutexattr_setrobust /\n"
           "// pthread_mutex_consistent 未导出），上面的启发式判定会误判。\n"
           "#define REALM_HAVE_ROBUST_PTHREAD_MUTEX")
    p.write_text(text.replace(old, new, 1), encoding="utf-8")
    log("patch", "thread.cpp 已排除 __OHOS__ 的 robust mutex")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=list(ARCHES), default="x86_64")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()

    ohos_arch, abi, machine = ARCHES[a.arch]
    check_sources()
    patch_thread_cpp()

    build = WRAPPERS / "build" / abi
    cfg = [
        str(CMAKE), "-G", "Ninja", "-S", str(WRAPPERS), "-B", str(build),
        f"-DCMAKE_MAKE_PROGRAM={NINJA}",
        f"-DCMAKE_TOOLCHAIN_FILE={TOOLCHAIN}",
        f"-DOHOS_ARCH={ohos_arch}",
        "-DOHOS_STL=c++_static",
        "-DOHOS_PLATFORM=phone",
        "-DCMAKE_BUILD_TYPE=Release",
        # 关掉加密 -> 不找 OpenSSL -> 用内置 SHA-1/SHA-2。
        # lazer 的本地 Realm 不加密，这个能力用不到。
        "-DREALM_ENABLE_ENCRYPTION=OFF",
        "-DREALM_NO_TESTS=ON",
        "-DREALM_BUILD_LIB_ONLY=ON",
        # OHOS 工具链注入 --gcc-toolchain，clang 视作未使用参数给警告，
        # realm-core 部分 target 开 -Werror。
        "-DCMAKE_C_FLAGS=-Wno-unused-command-line-argument",
        "-DCMAKE_CXX_FLAGS=-Wno-unused-command-line-argument",
    ]
    log("cmake", f"configure -> {build}")
    p = subprocess.run(cfg, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-4000:], file=sys.stderr)
        die(f"cmake 配置失败 (exit={p.returncode})")

    log("ninja", f"build target realm-wrappers -j {a.jobs}")
    p = subprocess.run([str(NINJA), "-C", str(build), "realm-wrappers", "-j", str(a.jobs)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        errs = [l for l in (p.stdout + p.stderr).splitlines()
                if "error:" in l or l.startswith("FAILED")]
        print("\n".join(errs[:40]) or (p.stdout + p.stderr)[-3000:], file=sys.stderr)
        die(f"ninja 编译失败 (exit={p.returncode})")

    so = build / "src/librealm-wrappers.so"
    if not so.exists():
        die(f"编译结束但产物不存在：{so}")

    dest = DEST / abi / "librealm-wrappers.so"
    dest.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(so, dest)
    raw = dest.stat().st_size
    if STRIP.exists():
        subprocess.run([str(STRIP), "--strip-unneeded", str(dest)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")

    # 校验：架构、SONAME、DT_NEEDED 只允许 libc
    hdr = subprocess.run([str(READELF), "-h", str(dest)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace").stdout
    got = [l for l in hdr.splitlines() if "Machine" in l]
    dyn = subprocess.run([str(READELF), "-d", str(dest)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace").stdout
    needed = [l.split("[")[-1].rstrip("]") for l in dyn.splitlines() if "NEEDED" in l]
    bad = [n for n in needed if n != "libc.so"]
    log("ok", f"{dest} ({raw} -> {dest.stat().st_size} bytes)")
    log("ok", " ".join(l.strip() for l in got))
    log("ok", "DT_NEEDED = " + ", ".join(needed))
    if bad:
        die(f"依赖里出现了非 libc 的库（musl 上很可能加载失败）：{bad}")
    log("ok", f"目标架构 e_machine={machine}（{abi}）")


if __name__ == "__main__":
    main()
