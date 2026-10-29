"""采集指定 Android 应用的数值帧时间，输出到本地 JSON。"""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time
from datetime import datetime, timezone


MAX_TIMESTAMP = (1 << 63) - 1
GFX_FIELDS = ("Flags", "IntendedVsync", "Vsync", "FrameCompleted")


def parse_latency(text):
    period = None
    rows = []
    for line in text.splitlines():
        fields = line.split()
        if not fields or not all(re.fullmatch(r"[0-9]+", v) for v in fields):
            continue
        values = tuple(map(int, fields))
        if len(values) == 1 and period is None and 0 < values[0] < 1_000_000_000:
            period = values[0]
        elif len(values) == 3 and all(0 < v < MAX_TIMESTAMP for v in values):
            rows.append(values)
    return period, rows


def parse_gfxinfo(text):
    indexes = None
    rows = []
    for line in text.splitlines():
        fields = line.strip().rstrip(",").split(",")
        if all(name in fields for name in GFX_FIELDS):
            indexes = [fields.index(name) for name in GFX_FIELDS]
            continue
        if indexes is None or len(fields) <= max(indexes):
            continue
        if not all(re.fullmatch(r"[0-9]+", value) for value in fields):
            continue
        values = tuple(int(fields[index]) for index in indexes)
        if all(0 < value < MAX_TIMESTAMP for value in values[1:]):
            rows.append(values)
    return rows


class WindowRows:
    def __init__(self, baseline, limit=16384):
        self.seen = set(baseline)
        self.rows = []
        self.limit = limit
        self.truncated = False

    def add(self, rows):
        for row in rows:
            if row in self.seen:
                continue
            if len(self.rows) >= self.limit:
                self.truncated = True
                continue
            self.seen.add(row)
            self.rows.append(row)


class Device:
    def __init__(self, adb, serial):
        self.adb = adb
        self.serial = serial

    def read(self, *args):
        try:
            result = subprocess.run(
                [self.adb, "-s", self.serial, "shell", shlex.join(args)],
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=True,
                timeout=10,
            )
        except (OSError, subprocess.SubprocessError) as error:
            # adb 错误输出可能含设备或图层名，交由调用者报告固定错误。
            raise RuntimeError("adb 读取失败，请核对设备连接和 dumpsys 权限。") from error
        return result.stdout


def choose_layer(text, package, requested):
    def layer_name(line):
        # Android 16 的列表包含状态外壳，--latency 接受其中的 name#id。
        match = re.fullmatch(r"RequestedLayerState\{(.+?#\d+)(?:\s+\w+=.*?)?\}", line)
        return match.group(1) if match else line

    listing = text.splitlines()
    layers = [layer_name(line) for line in listing]
    if requested:
        requested = layer_name(requested)
        if requested not in layers or package not in requested:
            raise ValueError("指定图层不在当前应用的图层列表中。")
        return requested
    # SurfaceFlinger 会保留已销毁的层；!handle 层没有活动输出，自动选择时排除。
    candidates = [
        layer_name(line) for line in listing
        if package in line and "SurfaceView" in line
        and not re.search(r"(?:\s)!handle(?=\s|\})", line)
    ]
    buffers = [name for name in candidates if "(BLAST)#" in name]
    if buffers:
        candidates = buffers
    if len(candidates) != 1:
        raise ValueError("应用 SurfaceView 图层无法唯一确定，请通过 --layer 指定。")
    return candidates[0]


def capture(device, package, layer, seconds, *, clock=time.monotonic, sleep=time.sleep):
    def snapshot():
        period, surface = parse_latency(
            device.read("dumpsys", "SurfaceFlinger", "--latency", layer)
        )
        gfx = parse_gfxinfo(device.read("dumpsys", "gfxinfo", package, "framestats"))
        return period, surface, gfx

    period, surface, gfx = snapshot()
    surface_window = WindowRows(surface)
    gfx_window = WindowRows(gfx)
    periods = {period} if period else set()
    started = clock()
    while clock() - started < seconds:
        sleep(min(0.5, max(0, seconds - (clock() - started))))
        period, surface, gfx = snapshot()
        if period:
            periods.add(period)
        surface_window.add(surface)
        gfx_window.add(gfx)
    return {
        "schemaVersion": 1,
        "package": package,
        "layerHash": hashlib.sha256(layer.encode("utf-8")).hexdigest()[:16],
        "hostElapsedSeconds": round(clock() - started, 3),
        "surfaceFlinger": {
            "refreshPeriodsNs": sorted(periods),
            "columns": ["desiredPresentNs", "actualPresentNs", "frameReadyNs"],
            "rows": sorted(surface_window.rows),
            "truncated": surface_window.truncated,
        },
        "gfxinfo": {
            "columns": list(GFX_FIELDS),
            "rows": sorted(gfx_window.rows),
            "truncated": gfx_window.truncated,
        },
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--serial", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--layer", help="省略时选择该包唯一的 SurfaceView 图层")
    parser.add_argument("--seconds", type=float, default=10)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+", args.package):
        parser.error("--package 必须为 Android 包名")
    if not 1 <= args.seconds <= 60:
        parser.error("--seconds 范围为 1–60")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    output = args.output or Path("build/android-frame-timing") / f"{stamp}.json"
    try:
        device = Device(args.adb, args.serial)
        layer = choose_layer(
            device.read("dumpsys", "SurfaceFlinger", "--list"), args.package, args.layer
        )
        result = capture(device, args.package, layer, args.seconds)
        result["startedUtc"] = stamp
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open("x", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
    except (ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        return 1
    except OSError:
        print("输出文件无法创建，请选择不存在且可写的路径。", file=sys.stderr)
        return 1
    counts = [len(result[key]["rows"]) for key in ("surfaceFlinger", "gfxinfo")]
    print(f"已保存数值帧时间：SurfaceFlinger={counts[0]}，gfxinfo={counts[1]}；{output}")
    if any(result[key]["truncated"] for key in ("surfaceFlinger", "gfxinfo")):
        print("记录达到上限，请缩短采样窗口。", file=sys.stderr)
        return 1
    if not any(counts):
        print("窗口内未获得新帧；请核对播放状态、图层和系统支持。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
