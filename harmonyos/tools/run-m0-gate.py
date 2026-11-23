#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""M0 Gate 一键验收：把含 NativeAOT 产物的 HAP 装到 OHOS 设备/模拟器，跑一次，读 hilog 判定。

判定标准（二值 Gate）：
  构建侧已过（ELF / DT_NEEDED / 符号）；本脚本验的是设备侧
  → hilog 出现 "ohos_hello(21) = 84" 且 "M0 PASS" 才 PASS。

用法：
  python run-m0-gate.py [--target 127.0.0.1:5555] [--hap <path>] [--skip-install]

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
    hits = [h for h in hits if "signed" in h.name or "default" in h.name]
    if not hits:
        raise SystemExit(f"在 {PROJECT} 下找不到 .hap，先跑 assembleHap")
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

    # 清日志，避免上一次的 M0 PASS 造成误判
    hdc(["shell", "hilog", "-r"], a.target)

    r = hdc(["shell", "aa", "start", "-a", ABILITY, "-b", BUNDLE], a.target)
    print("[start] " + (r.stdout + r.stderr).strip()[:500])
    time.sleep(3)

    r = hdc(["shell", "hilog", "-x"], a.target, timeout=90)
    lines = (r.stdout + r.stderr).splitlines()
    interesting = [l for l in lines
                   if re.search(r"OSU-AOT|aotsample|dlopen|dlsym|ohos_hello|M0 |AOT_", l, re.I)]

    print("=== 相关日志 ===")
    for l in interesting[-40:]:
        print("  " + l.strip())

    text = "\n".join(interesting)
    passed = bool(re.search(r"ohos_hello\(21\)\s*=\s*84", text)) and ("M0 PASS" in text)
    failed_load = bool(re.search(r"dlopen Hello\.so failed|aot hello failed", text, re.I))

    result = {
        "success": passed,
        "gate": "M0 PASS" if passed else "M0 FAIL",
        "target": a.target,
        "device_arch": "see hdc shell uname -m",
        "matched_log_lines": len(interesting),
        "dlopen_failed": failed_load,
    }
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0 if passed else 1)


if __name__ == "__main__":
    main()
