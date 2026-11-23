#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M1a Gate 一键验收：SDL3 官方 OHOS 后端能否在 HarmonyOS 应用进程里加载并初始化。

判定标准（二值 Gate）：
  hilog 出现 "SDL3 GATE PASS" 且带 ver=<SDL3 版本号> 才 PASS。
  同时回归检查 M0（NativeAOT）是否仍然 PASS。

用法：
  python run-m1a-gate.py [--target 127.0.0.1:5555] [--hap <path>] [--skip-install]

踩坑（已在本机复现）：hdc install / file recv 传 Windows 绝对路径会被拼成相对路径，
必须用 cwd=<hap 所在目录> + 只给文件名。
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
        r = hdc(["install", "-r", hap.name], a.target, cwd=hap.parent, timeout=180)
        print((r.stdout + r.stderr).strip()[-1500:])
        if r.returncode != 0 and "success" not in (r.stdout + r.stderr).lower():
            print(json.dumps({"success": False, "stage": "install",
                              "output": (r.stdout + r.stderr)[-2000:]}, ensure_ascii=False))
            sys.exit(1)

    # 必须强制冷启动：若应用进程仍在，aa start 只把已有 Ability 拉到前台，
    # 不会重新触发 onCreate，M0/M1a 的日志就完全不会出现（本机已复现）。
    hdc(["shell", "aa", "force-stop", BUNDLE], a.target)
    time.sleep(1)

    # 清日志，避免上一次的 PASS 造成误判
    hdc(["shell", "hilog", "-r"], a.target)

    r = hdc(["shell", "aa", "start", "-a", ABILITY, "-b", BUNDLE], a.target)
    print("[start] " + (r.stdout + r.stderr).strip()[:500])
    time.sleep(4)

    r = hdc(["shell", "hilog", "-x"], a.target, timeout=90)
    lines = (r.stdout + r.stderr).splitlines()
    interesting = [l for l in lines
                   if re.search(r"OSU-AOT|OSU-SDL|SDL3|libSDL3|aotsample|dlopen|dlsym|ohos_hello|M0 |M1a|GATE", l, re.I)]

    print("=== 相关日志 ===")
    for l in interesting[-50:]:
        print("  " + l.strip())

    text = "\n".join(interesting)
    gate_lines = [l.strip() for l in interesting if "SDL3 GATE" in l]
    passed = any("SDL3 GATE PASS" in l
                 and re.search(r"ver=\d{7}", l)
                 and re.search(r"platform=\S*[Hh]armony", l)
                 for l in gate_lines)
    m0_still_pass = "M0 PASS" in text
    load_failed = bool(re.search(r"SDL3 GATE FAIL|dlopen libSDL3|SDL3 symbol missing|SDL3 gate failed", text, re.I))

    result = {
        "success": passed,
        "gate": "M1a PASS" if passed else "M1a FAIL",
        "target": a.target,
        "gate_lines": gate_lines[-5:],
        "m0_regression": "PASS" if m0_still_pass else "NOT SEEN",
        "load_failed": load_failed,
        "matched_log_lines": len(interesting),
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
