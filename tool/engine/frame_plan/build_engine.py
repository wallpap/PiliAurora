"""Compile the isolated Android arm64 engine and record native test provenance."""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine_identity
import apply


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--mode", choices=["profile", "release"], default="profile")
    parser.add_argument("--architecture", choices=["arm", "arm64", "x64"], default="arm64")
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--device")
    parser.add_argument("--qemu", type=Path, help="使用 QEMU user-mode 运行 Android 原生回归")
    parser.add_argument("--android-rootfs", type=Path, help="与 QEMU 配套的 Android 系统库目录")
    parser.add_argument("--skip-tests", action="store_true")
    args = parser.parse_args()
    if bool(args.qemu) != bool(args.android_rootfs):
        parser.error("--qemu and --android-rootfs must be used together")
    if args.qemu and args.architecture != "arm":
        parser.error("QEMU Android rootfs runner requires --architecture arm")
    if args.qemu and args.skip_tests:
        parser.error("QEMU runner cannot be combined with --skip-tests")
    checkout, sdk = args.checkout.resolve(), args.flutter_sdk.resolve()
    engine_identity.validate_sdk(sdk)
    subprocess.run([sys.executable, Path(__file__).with_name("apply.py"), checkout,
                    "--framework-sdk", sdk], check=True)
    source = Path(__file__).resolve().parent
    if not engine_identity.patch_matches(
            apply.git(checkout, "diff", "--binary").stdout,
            engine_identity.PATCHES["androidFramePlan"].read_text(encoding="utf-8")):
        raise ValueError("Engine checkout contains changes outside the registered patch")
    for name, destination in {
        "frame_presentation_plan.h": "flow/frame_presentation_plan.h",
        "frame_presentation_plan_unittests.cc": "shell/platform/android/frame_presentation_plan_unittests.cc",
    }.items():
        if (source / name).read_bytes() != (checkout / "engine/src/flutter" / destination).read_bytes():
            raise ValueError(f"Engine overlay differs: {name}")
    src = checkout / "engine/src"
    subprocess.run([src / "flutter/tools/gn", "--android", "--android-cpu", args.architecture,
                    "--runtime-mode", args.mode, "--no-lto", "--stripped",
                    "--no-build-engine-artifacts", "--target-dir", f"android_{args.mode}_{args.architecture}"], cwd=src, check=True)
    output = src / "out" / f"android_{args.mode}_{args.architecture}"
    targets = ["libflutter.so"]
    if not args.skip_tests:
        targets.append("flutter_shell_native_unittests")
    subprocess.run(["ninja", "-C", output, "-j", str(args.jobs), *targets], cwd=src, check=True)
    if not args.skip_tests:
        if args.qemu:
            subprocess.run([args.qemu.resolve(), "-L", args.android_rootfs.resolve(),
                            output / "flutter_shell_native_unittests",
                            "--gtest_filter=FramePresentationPlanTest.*"], check=True)
        else:
            adb = [args.adb, *(["-s", args.device] if args.device else [])]
            destination = "/data/local/tmp/piliaurora-frame-plan-tests"
            subprocess.run([*adb, "push", output / "flutter_shell_native_unittests", destination], check=True)
            subprocess.run([*adb, "shell", "chmod", "755", destination], check=True)
            subprocess.run([*adb, "shell", destination, "--gtest_filter=FramePresentationPlanTest.*"], check=True)
    library = output / "lib.stripped/libflutter.so"
    identity = engine_identity.create_identity(library, profile="androidFramePlan",
        mode=args.mode, sdk=sdk, native_tests_passed=not args.skip_tests, architecture=args.architecture)
    if args.qemu:
        identity["nativeTestEnvironment"] = {
            "executor": "qemu-user-android-bionic",
            "runnerSha256": engine_identity.sha256(args.qemu.resolve()),
            "linkerSha256": engine_identity.sha256(args.android_rootfs / "system/bin/linker"),
            "libcSha256": engine_identity.sha256(args.android_rootfs / "system/lib/libc.so"),
        }
    engine_identity.write_json(library.with_name("engine-identity.json"), identity)
    print(library)


if __name__ == "__main__":
    main()
