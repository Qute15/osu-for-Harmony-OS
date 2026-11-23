#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""为 HarmonyOS 交叉编译 libe_sqlite3.so（osu!lazer 的在线谱面元数据缓存）。

为什么需要
----------
`osu.Game/Beatmaps/LocalCachedBeatmapMetadataSource.cs` 直接用
`Microsoft.Data.Sqlite`（SQLitePCLRaw.bundle_e_sqlite3），
P/Invoke 的库名是 `e_sqlite3`。
NuGet 里 `sqlite/3.53.4/runtimes/linux-x64/native/libe_sqlite3.so` 的
DT_NEEDED 是 `libc.so.6` —— OHOS musl 只有 `libc.so`，名字对不上，加载失败。

好在 SQLite 是单文件 amalgamation、纯 C、可移植性极好，
用 OHOS clang 直接编一遍即可，不需要打任何补丁。

源码：https://www.sqlite.org/<year>/sqlite-amalgamation-<ver>.zip
      （本脚本按 3.53.4 / sqlite-amalgamation-3530400 定位，与 NuGet 包版本一致）

编译选项对齐 SQLitePCLRaw 的 e_sqlite3 发行配置，保证 lazer 用到的
FTS/JSON/RTREE 等能力都在；`SQLITE_THREADSAFE=1` 对应
`LocalCachedBeatmapMetadataSource` 开头的 `sqlite3_config(SQLITE_CONFIG_MULTITHREAD)`。

用法：
  python build-sqlite.py --arch x86_64
  python build-sqlite.py --arch arm64-v8a
"""
from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OHOS = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native")
CLANG = OHOS / "llvm/bin/clang.exe"
STRIP = OHOS / "llvm/bin/llvm-strip.exe"
READELF = OHOS / "llvm/bin/llvm-readelf.exe"

SRC_DIR = ROOT / "native-src/sqlite/sqlite-amalgamation-3530400"
DEST = ROOT / "osu-ohos/native/sqlite"

ARCHES = {
    "x86_64": ("x86_64-linux-ohos", "x86_64", 62),
    "arm64-v8a": ("aarch64-linux-ohos", "arm64-v8a", 183),
}

# 与 SQLitePCLRaw 的 e_sqlite3 发行版对齐。少一个只是少一项能力，
# 不会导致加载失败；但 FTS5/JSON 是 lazer 可能用到的，宁可全开。
DEFINES = [
    "SQLITE_THREADSAFE=1",
    "SQLITE_ENABLE_COLUMN_METADATA",
    "SQLITE_ENABLE_FTS3",
    "SQLITE_ENABLE_FTS3_PARENTHESIS",
    "SQLITE_ENABLE_FTS4",
    "SQLITE_ENABLE_FTS5",
    "SQLITE_ENABLE_JSON1",
    "SQLITE_ENABLE_RTREE",
    "SQLITE_ENABLE_MATH_FUNCTIONS",
    "SQLITE_ENABLE_GEOPOLY",
    "SQLITE_ENABLE_DBSTAT_VTAB",
    "SQLITE_ENABLE_BATCH_ATOMIC_WRITE",
    "SQLITE_ENABLE_LOAD_EXTENSION=1",
    "SQLITE_DEFAULT_MEMSTATUS=0",
    "SQLITE_OMIT_DEPRECATED",
    "SQLITE_OMIT_PROGRESS_CALLBACK",
    # OHOS 的主线程栈不大，且 SQLite 递归深度对齐发行版默认值即可。
    "SQLITE_MAX_MMAP_SIZE=0",
]


def log(tag: str, msg: str) -> None:
    print(f"[{tag}] {msg}", flush=True)


def die(msg: str) -> None:
    print(f"[ERROR] {msg}", file=sys.stderr, flush=True)
    sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--arch", choices=list(ARCHES), default="x86_64")
    a = ap.parse_args()

    target, abi, machine = ARCHES[a.arch]
    src = SRC_DIR / "sqlite3.c"
    if not src.exists():
        die(f"缺少 SQLite amalgamation：{src}\n"
            "  从 https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip 解压到 "
            "native-src/sqlite/")

    out_dir = DEST / abi
    out_dir.mkdir(parents=True, exist_ok=True)
    out = out_dir / "libe_sqlite3.so"

    cmd = [
        str(CLANG), str(src), "-o", str(out),
        f"--target={target}",
        f"--sysroot={OHOS / 'sysroot'}",
        *[f"-D{d}" for d in DEFINES],
        "-O2", "-fPIC", "-shared", "-fvisibility=default",
        f"-Wl,-soname,libe_sqlite3.so",
        "-lm",
        "-Wno-unused-command-line-argument",
    ]
    log("clang", f"{target} -> {out}")
    p = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        print((p.stdout + p.stderr)[-4000:], file=sys.stderr)
        die(f"clang 编译失败 (exit={p.returncode})")
    if p.stderr.strip():
        warn = [l for l in p.stderr.splitlines() if "warning:" in l]
        if warn:
            log("warn", f"{len(warn)} 条警告，首条：{warn[0][:200]}")

    raw = out.stat().st_size
    if STRIP.exists():
        subprocess.run([str(STRIP), "--strip-unneeded", str(out)],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")

    dyn = subprocess.run([str(READELF), "-d", str(out)], capture_output=True,
                         text=True, encoding="utf-8", errors="replace").stdout
    needed = [l.split("[")[-1].rstrip("]") for l in dyn.splitlines() if "NEEDED" in l]
    bad = [n for n in needed if n != "libc.so"]
    log("ok", f"{out} ({raw} -> {out.stat().st_size} bytes)")
    log("ok", "DT_NEEDED = " + (", ".join(needed) or "(none)"))
    if bad:
        die(f"依赖里出现了非 libc 的库：{bad}")
    log("ok", f"目标架构 e_machine={machine}（{abi}）")


if __name__ == "__main__":
    main()
