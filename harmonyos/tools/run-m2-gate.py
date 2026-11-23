#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M2 Gate：真 osu!lazer 在 OHOS 上冷启动到「稳定帧循环 + 主界面」。

与 M1b Gate 的差别：
  * M1b 只要求「SDL_main 被调到、托管代码开始跑、没崩」，
    这是路径 A 可行性的证明；
  * M2 要求真的**跑起来**，所以判据额外看运行期日志：
    osu.Framework 把异步加载/渲染线程里的异常交给 Logger 记一条就算过去，
    进程不会退出，所以「进程还活着」完全不代表没问题。
    实测踩过的坑：Settings 为 null、着色器缓存反序列化丢反射、
    本地化静态属性没生成代码——三者都表现为「每帧一条未处理异常」，
    但 SDL_main 一直没返回，M1b 判据会误判成 PASS。

判据（全部满足才 PASS）：
  1. hilog 有 "Calling SDL_main!" 且有 OSU-CS "SDL_main entered"
  2. 没有 native 崩溃栈（Fault thread / abort+ / SIGSEGV / LastFatalMessage）
  3. SDL_main 没有返回（返回就说明启动失败，GameHost.Run() 本应永久阻塞）
  4. 最新 runtime.log 里没有 "An unhandled error has occurred"
  5. 最新 runtime.log 里没有 NullReferenceException / NotSupportedException
  6. runtime.log 里出现了进入主界面的痕迹（LoadComplete / 加载某个组件 / realm 打开）

用法：
  python run-m2-gate.py                 # 装最新 HAP 并冷启动
  python run-m2-gate.py --skip-install  # 只重启（libmain.so 未变时省时间）
  python run-m2-gate.py --wait 40
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

HDC = pathlib.Path("C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/toolchains/hdc.exe")
BUNDLE = "com.example.myapplication"
ABILITY = "EntryAbility"
PROJECT = pathlib.Path("C:/Users/z3306/DevEcoStudioProjects/MyApplication")
OUT = pathlib.Path(__file__).resolve().parents[1]

HILOG_FILE = OUT / "m2-hilog.txt"
RUNTIME_LOG = OUT / "m2-runtime.log"
SHOT = OUT / "m2.jpeg"

REMOTE_LOGS_DIR = f"/data/app/el2/100/base/{BUNDLE}/files/osu/logs"

KEY = re.compile(
    r"OSU-AOT|OSU-CS|SDL/STARTUP|SDL_main|libmain\.so|CPP_CRASH|SIGABRT|"
    r"FailFast|Unhandled|Exception|DllNotFound|Couldn't find|"
    r"Fault thread|LastFatalMessage|abort\+",
    re.I)

# 这些异常出现在 runtime.log 里就说明「游戏在带病跑」，不能算 PASS。
BAD_EXCEPTIONS = (
    "NullReferenceException",
    "NotSupportedException",
    "An unhandled error has occurred",
    "ObjectDisposedException",
    "ArgumentOutOfRangeException",
    "InvalidOperationException",
)


def hdc(args: list[str], target: str, cwd: pathlib.Path | None = None, timeout: int = 120):
    cmd = [str(HDC), "-t", target] + args
    return subprocess.run(cmd, cwd=str(cwd) if cwd else None, capture_output=True,
                          text=True, encoding="utf-8", errors="replace", timeout=timeout)


def find_hap(explicit: str | None) -> pathlib.Path:
    if explicit:
        p = pathlib.Path(explicit).resolve()
        if not p.exists():
            raise SystemExit(f"HAP 不存在：{p}")
        return p
    hits = sorted(PROJECT.glob("**/*.hap"), key=lambda x: x.stat().st_mtime, reverse=True)
    hits = [h for h in hits if "signed" in h.name]
    if not hits:
        raise SystemExit(f"在 {PROJECT} 下找不到 signed .hap，先跑 assembleHap")
    return hits[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", default="127.0.0.1:5555")
    ap.add_argument("--hap")
    ap.add_argument("--skip-install", action="store_true")
    ap.add_argument("--wait", type=int, default=40)
    ap.add_argument("--keep-shader-cache", action="store_true",
                    help="不清理 cache/shaders（用来验证「第二次启动走缓存」这条路）")
    a = ap.parse_args()

    if not HDC.exists():
        raise SystemExit(f"hdc 不存在：{HDC}")

    online = hdc(["list", "targets"], a.target).stdout.strip()
    print(f"[device] {online or '(empty)'}")
    if a.target not in online:
        print(json.dumps({"success": False, "error": "目标设备不在线", "target": a.target},
                         ensure_ascii=False))
        sys.exit(1)

    if not a.skip_install:
        hap = find_hap(a.hap)
        print(f"[install] {hap}  ({hap.stat().st_size} bytes)")
        r = hdc(["install", "-r", hap.name], a.target, cwd=hap.parent, timeout=300)
        print((r.stdout + r.stderr).strip()[-800:])
        if r.returncode != 0 and "success" not in (r.stdout + r.stderr).lower():
            print(json.dumps({"success": False, "stage": "install",
                              "output": (r.stdout + r.stderr)[-2000:]}, ensure_ascii=False))
            sys.exit(1)

    if not a.keep_shader_cache:
        # 着色器缓存是可再生的；每次冷启动前清掉，能保证测的是「真实编译」而不是
        # 上一版遗留的、格式可能已经变了的旧缓存。
        r = hdc(["shell", f"rm -rf /data/app/el2/100/base/{BUNDLE}/files/osu/cache/shaders/*"], a.target)
        print("[cache] cleared shader cache " + (r.stdout + r.stderr).strip()[:200])

    hdc(["shell", "aa", "force-stop", BUNDLE], a.target)
    time.sleep(1)
    # 设备时间被改回 09:00 后，旧日志的 mtime 反而是「未来时间」（12:12），
    # ls -t 会把旧文件排在最前，导致每次都拉到上次运行的 runtime.log。
    # 启动前清掉旧日志，保证下面拿到的一定是本次启动写出的。
    r = hdc(["shell", f"rm -f {REMOTE_LOGS_DIR}/*.runtime.log"], a.target)
    print("[logs] cleared old runtime.log " + (r.stdout + r.stderr).strip()[:200])
    hdc(["shell", "hilog", "-r"], a.target)

    r = hdc(["shell", "aa", "start", "-a", ABILITY, "-b", BUNDLE], a.target)
    print("[start] " + (r.stdout + r.stderr).strip()[:400])
    time.sleep(a.wait)

    # 截图要趁进程还活着
    hdc(["shell", "snapshot_display -f /data/local/tmp/m2.jpeg"], a.target, timeout=60)
    rr = hdc(["file", "recv", "/data/local/tmp/m2.jpeg", str(SHOT)], a.target, timeout=120)
    print("[shot] " + (rr.stdout + rr.stderr).strip()[-200:])

    r = hdc(["shell", "hilog", "-x"], a.target, timeout=180)
    all_lines = (r.stdout + r.stderr).splitlines()
    HILOG_FILE.write_text("\n".join(all_lines), encoding="utf-8", errors="replace")
    interesting = [l.strip() for l in all_lines if KEY.search(l)]
    text = "\n".join(interesting)

    # 拉取本次启动写出的最新 runtime.log
    ls = hdc(["shell", f"ls -t {REMOTE_LOGS_DIR}/*.runtime.log"], a.target).stdout.strip().splitlines()
    latest = ls[0].strip() if ls else ""
    runtime_text = ""
    if latest:
        hdc(["file", "recv", latest, str(RUNTIME_LOG)], a.target, timeout=120)
        if RUNTIME_LOG.exists():
            runtime_text = RUNTIME_LOG.read_text(encoding="utf-8", errors="replace")

    sdl_main_called = "Calling SDL_main!" in text
    managed_entered = bool(re.search(r"OSU-CS.*SDL_main entered", text))
    sdl_main_returned = "SDL_main returned" in text
    native_crash = (not sdl_main_returned) and bool(
        re.search(r"Fault thread info|abort\+|SIGSEGV|LastFatalMessage", text, re.I))

    bad_runtime = [line for line in runtime_text.splitlines()
                   if any(e in line for e in BAD_EXCEPTIONS)]

    # 「进入了主界面」的最低证据：realm 已打开 + 开始加载组件
    reached_menu = ("Opened realm" in runtime_text) and bool(
        re.search(r"Loading [A-Z]\w+", runtime_text))

    passed = (sdl_main_called and managed_entered and not sdl_main_returned
              and not native_crash and not bad_runtime and reached_menu)

    print(f"=== hilog {len(all_lines)} 行 -> {HILOG_FILE}")
    print(f"=== runtime.log {len(runtime_text.splitlines())} 行 -> {RUNTIME_LOG}")
    print("=== runtime.log 末尾 45 行 ===")
    for line in runtime_text.splitlines()[-45:]:
        print("  " + line)
    if bad_runtime:
        print("=== runtime.log 里的病态异常 ===")
        for line in bad_runtime[:15]:
            print("  " + line)

    result = {
        "success": passed,
        "gate": "M2 PASS" if passed else "M2 FAIL",
        "sdl_main_called": sdl_main_called,
        "managed_entered": managed_entered,
        "sdl_main_returned": sdl_main_returned,
        "native_crash": native_crash,
        "bad_runtime_lines": bad_runtime[:10],
        "reached_menu": reached_menu,
        "screenshot": str(SHOT) if SHOT.exists() else None,
        "runtime_log": str(RUNTIME_LOG) if RUNTIME_LOG.exists() else None,
        "hilog_file": str(HILOG_FILE),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
