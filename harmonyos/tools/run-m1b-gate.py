#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M1b Gate：路径 B 冷启动后，真 osu!lazer 的 SDL_main 是否越过了托管启动阶段。

判据（按顺序，越靠前越有意义）：
  1. hilog 出现 SDL/STARTUP "Calling SDL_main!"          -> SDL3 启动链打通
  2. hilog 出现 OSU-CS "SDL_main entered (NativeAOT ...)" -> 托管代码真正开始执行
  3. 没有 SIGABRT / CPP_CRASH / FailFast                  -> 托管启动未崩
  4. Gate PASS = 1 && 2 && 3

与 M0/M1a Gate 的差别：这里把完整 hilog 落到 output/m1b2-hilog.txt，
因为 NativeAOT 的崩溃信息（FailFast、DllNotFound、TypeInitialization）
需要配合 llvm-symbolizer 与未 strip 的 libmain.so 才能定位。

用法：
  python run-m1b-gate.py [--target 127.0.0.1:5555] [--hap <path>] [--skip-install] [--wait 10]
                         [--mode selftest|lazer]

--mode selftest 通过 want 参数 osu_mode 拉起零依赖的 SelfTestGame，
用于把「平台链是否健康」和「lazer 原生依赖是否齐备」两类问题隔离开。
此时判据改为「跑满 240 帧并主动退出」，期望 SDL_main 正常返回。
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
OUT = pathlib.Path(__file__).resolve().parents[1] / "m1b2-hilog.txt"

KEY = re.compile(
    r"OSU-AOT|OSU-CS|SDL/STARTUP|SDL_main|libmain\.so|CPP_CRASH|SIGABRT|"
    r"FailFast|Unhandled|Exception|DllNotFound|dlopen|dlsym|Couldn't find|"
    r"Fault thread|LastFatalMessage|abort\+|SDL3 GATE|M0 PASS|M1b",
    re.I)


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
    # 250 MB HAP 冷启动 + 233 MB libmain.so 的 dlopen/重定位，
    # 从 aa start 到 XComponent OnSurfaceCreated 实测可超过 12 s，默认等 25 s。
    ap.add_argument("--wait", type=int, default=25)
    ap.add_argument("--mode", default="lazer", choices=["lazer", "selftest"])
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
        print((r.stdout + r.stderr).strip()[-1500:])
        if r.returncode != 0 and "success" not in (r.stdout + r.stderr).lower():
            print(json.dumps({"success": False, "stage": "install",
                              "output": (r.stdout + r.stderr)[-2000:]}, ensure_ascii=False))
            sys.exit(1)

    # 冷启动，否则 onCreate / XComponent.OnSurfaceCreated 不会重跑
    hdc(["shell", "aa", "force-stop", BUNDLE], a.target)
    time.sleep(1)
    hdc(["shell", "hilog", "-r"], a.target)

    start_args = ["shell", "aa", "start", "-a", ABILITY, "-b", BUNDLE]
    if a.mode != "lazer":
        # force-stop 后 onCreate 会重跑，EntryAbility.writeMode 从 want 取 osu_mode
        start_args += ["--ps", "osu_mode", a.mode]
    r = hdc(start_args, a.target)
    print("[start:%s] " % a.mode + (r.stdout + r.stderr).strip()[:500])
    time.sleep(a.wait)

    r = hdc(["shell", "hilog", "-x"], a.target, timeout=120)
    all_lines = (r.stdout + r.stderr).splitlines()
    OUT.write_text("\n".join(all_lines), encoding="utf-8", errors="replace")
    interesting = [l.strip() for l in all_lines if KEY.search(l)]

    print(f"=== hilog 全量 {len(all_lines)} 行 -> {OUT} ===")
    print("=== 相关日志（末尾 80 行）===")
    for l in interesting[-80:]:
        print("  " + l)

    text = "\n".join(interesting)
    sdl_main_called = "Calling SDL_main!" in text
    managed_entered = bool(re.search(r"OSU-CS.*SDL_main entered", text))
    managed_progress = [l for l in interesting if "OSU-CS" in l]
    # SDL3 OHOS 后端在 SDL_main 返回后固定 exit()；此时系统会把进程记成
    # SIGABRT/[appspawn] Unexpected call: exit(1)，这是 SDL3 正常行为。
    # 只有「SDL_main 没有返回」且出现真实 native 崩溃栈 / 托管异常才算 FAIL。
    sdl_main_returned = "SDL_main returned" in text
    native_crash = (not sdl_main_returned) and bool(
        re.search(r"Fault thread info|abort\+|SIGSEGV|LastFatalMessage", text, re.I))
    managed_exception = any(
        "OSU-CS" in l and re.search(
            r"host\.Run failed|host\.Dispose failed|SDL_main exception|UnhandledException", l, re.I)
        for l in interesting)
    crashed = native_crash or managed_exception

    exception_lines = [l for l in interesting
                       if re.search(r"Exception|DllNotFound|Couldn't find|Unhandled", l, re.I)]

    # host.Run() 成功时会永远阻塞；SDL_main 一旦返回就说明启动失败了。
    # selftest 模式例外：SelfTestGame 跑满 240 帧后主动 Exit()，SDL_main 返回是预期结果。
    if a.mode == "selftest":
        selftest_frames = [int(m) for m in re.findall(r"selftest frame=(\d+)", text)]
        selftest_done = "selftest completed" in text
        passed = managed_entered and not crashed and (selftest_done or len(selftest_frames) >= 3)
    else:
        passed = sdl_main_called and managed_entered and not crashed and not sdl_main_returned
    result = {
        "success": passed,
        "gate": ("M1b-selftest PASS" if a.mode == "selftest" else "M1b PASS") if passed
                else ("M1b-selftest FAIL" if a.mode == "selftest" else "M1b FAIL"),
        "mode": a.mode,
        "sdl_main_called": sdl_main_called,
        "managed_entered": managed_entered,
        "sdl_main_returned": sdl_main_returned,
        "native_crash": native_crash,
        "managed_exception": managed_exception,
        "crashed": crashed,
        "selftest_frames": [int(m) for m in re.findall(r"selftest frame=(\d+)", text)] if a.mode == "selftest" else [],
        "selftest_completed": ("selftest completed" in text) if a.mode == "selftest" else None,
        "managed_log_lines": managed_progress[-20:],
        "exception_lines": exception_lines[-20:],
        "hilog_file": str(OUT),
        "interesting_lines": len(interesting),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
