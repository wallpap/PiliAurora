"""仅在已启动的只读模拟器上，使用本地产生的视频检查暂停旋转后的整帧显示。"""

import argparse
import io
import re
import subprocess
import threading
from pathlib import Path

from PIL import Image

PACKAGE = "io.github.wallpap.piliaurora.debug"


def verify(image):
    image = image.convert("RGB")
    mask = image.point(lambda channel: 255 if channel > 100 else 0).convert("L")
    bounds = mask.getbbox()
    if bounds is None:
        return False, "no rendered video"
    left, top, right, bottom = bounds
    width, height = right - left, bottom - top
    expected = [((0.25, 0.25), (240, 30, 30)), ((0.75, 0.25), (30, 220, 30)),
                ((0.25, 0.75), (30, 30, 240)), ((0.75, 0.75), (240, 220, 30))]
    errors = []
    for (x, y), color in expected:
        actual = image.getpixel((left + int(width * x), top + int(height * y)))
        if max(abs(actual[i] - color[i]) for i in range(3)) > 60:
            errors.append(f"quadrant {x},{y}: {actual}")
    for x, y in [(0.01, 0.01), (0.99, 0.01), (0.01, 0.99), (0.99, 0.99)]:
        actual = image.getpixel((left + int(width * x), top + int(height * y)))
        if min(actual) < 190:
            errors.append(f"missing source border {x},{y}: {actual}")
    return not errors, "; ".join(errors) or f"all source quadrants and borders visible ({width}x{height})"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adb", required=True, type=Path)
    parser.add_argument("--serial", required=True)
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--output", type=Path, default=Path("build/rotation-smoke"))
    args = parser.parse_args()
    if not args.serial.startswith("emulator-"):
        parser.error("Only an isolated emulator is supported; this tool never installs onto a physical device")
    args.output.mkdir(parents=True, exist_ok=True)
    adb = [str(args.adb), "-s", args.serial]

    def run(*command):
        return subprocess.check_output(adb + list(command), stderr=subprocess.STDOUT)

    media = args.fixture.resolve(strict=True)
    run("install", "-r", str(args.apk))
    run("push", str(media), "/data/local/tmp/pili-rotation-fixture.mp4")
    run("shell", "run-as", PACKAGE, "cp", "/data/local/tmp/pili-rotation-fixture.mp4", "cache/rotation-fixture.mp4")
    run("shell", "am", "force-stop", PACKAGE)
    run("logcat", "-c")
    log = subprocess.Popen(adb + ["logcat", "-v", "brief", "flutter:I", "*:S"], stdout=subprocess.PIPE, text=True, encoding="utf-8")
    run("shell", "am", "start", "-n", f"{PACKAGE}/io.github.wallpap.piliaurora.MainActivity")
    watchdog = threading.Timer(90, log.terminate)
    watchdog.start()
    results = []
    try:
        for line in log.stdout:
            if "PILI_ROTATION" not in line:
                continue
            print(line.strip(), flush=True)
            if "done" in line:
                break
            stage = re.search(r"PILI_ROTATION ([a-z-]+)", line).group(1)
            png = run("exec-out", "screencap", "-p")
            (args.output / f"{stage}.png").write_bytes(png)
            passed, reason = verify(Image.open(io.BytesIO(png)))
            paused = "paused=true" in line
            if stage == "landscape-before" and not passed:
                print(f"INVALID BASELINE: {reason}; no rotation verdict can be inferred", flush=True)
                raise SystemExit(2)
            results.append(passed and paused)
            print(f"{stage}: {'PASS' if passed and paused else 'FAIL'}: {reason}", flush=True)
    finally:
        watchdog.cancel()
        log.terminate()
        log.wait(timeout=10)
    if len(results) != 3:
        raise SystemExit(2)
    if not all(results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
