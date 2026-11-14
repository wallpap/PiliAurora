"""Build a Profile, dev Release or official Release APK with the frame-plan engine."""
import argparse
import json
import os
import subprocess
import zipfile
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine_identity

ENGINE_REVISION = engine_identity.ENGINE_COMMIT


def validate_source_identity(identity, *, target, mode, package, apk_hash,
                             ticker_hash, dart_defines, engine_digest, source_hash):
    application = identity.get("application", {})
    if (application.get("target") != target or identity.get("mode") != mode or
            application.get("package") != package or identity.get("engineCommit") != ENGINE_REVISION or
            application.get("apkSha256") != apk_hash or application.get("tickerSha256") != ticker_hash or
            identity.get("profile") != "androidFramePlan" or
            identity.get("identityDigest") != engine_digest or
            engine_identity.identity_digest(identity) != engine_digest or
            application.get("sourceSha256") != source_hash or
            application.get("dartDefines") != dart_defines):
        raise ValueError("Source APK identity differs from the requested build configuration")



def restore_workspace_state(backup):
    for path, content in backup.items():
        if content is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--flutter-sdk", type=Path, required=True)
    parser.add_argument("--engine-library", type=Path, required=True)
    parser.add_argument("--android-sdk", type=Path, required=True)
    parser.add_argument("--mode", choices=("profile", "dev-release", "release"), default="profile")
    parser.add_argument("--abi", choices=("arm64-v8a", "armeabi-v7a", "x86_64"), default="arm64-v8a")
    parser.add_argument("--target", default="lib/main.dart")
    parser.add_argument("--dart-define", action="append", default=[])
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--source-apk", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--skip-patch", action="store_true")
    parser.add_argument("--skip-pub-get", action="store_true")
    args = parser.parse_args()
    if args.mode == "dev-release" and args.abi != "arm64-v8a":
        parser.error("dev-release requires arm64-v8a; use release for other ABIs")
    if args.skip_build != (args.source_apk is not None):
        parser.error("--skip-build and --source-apk must be used together")
    try:
        engine_identity.validate_defines(args.dart_define)
    except ValueError as error:
        parser.error(str(error))
    repo = Path(__file__).resolve().parents[3]
    sdk = args.flutter_sdk.resolve()
    mode = "profile" if args.mode == "profile" else "release"
    architecture, target_platform = {"arm64-v8a": ("arm64", "android-arm64"),
        "armeabi-v7a": ("arm", "android-arm"), "x86_64": ("x64", "android-x64")}[args.abi]
    package = "io.github.wallpap.piliaurora" if args.mode == "release" else f"io.github.wallpap.piliaurora.{'dev' if mode == 'release' else 'profile'}"
    default_output = (f"build/android-test/PiliAurora-dev-{args.abi}-release.apk"
                      if mode == "release" else
                      f"build/android-frame-plan/PiliAurora-frame-plan-{args.abi}-profile.apk")
    if args.mode == "release":
        default_output = f"build/release/PiliAurora-{args.abi}-release.apk"
    output = (repo / (args.output or default_output)).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    library = args.engine_library.resolve()
    engine = engine_identity.validate_engine(library, profile="androidFramePlan", mode=mode, sdk=sdk, architecture=architecture)
    engine_digest = engine_identity.identity_digest(engine)
    generated_defines = engine_identity.dart_defines("androidFramePlan", engine)
    source_hash = engine_identity.source_fingerprint(repo, args.target)
    pinned_engine = (sdk / "bin/internal/engine.version").read_text().strip()
    if pinned_engine != ENGINE_REVISION:
        raise ValueError(f"SDK engine mismatch: {pinned_engine}")
    # 只替换 APK 内的引擎，不改写 SDK 缓存；默认入口可安全复用固定 FVM SDK。
    flutter = sdk / ("bin/flutter.bat" if os.name == "nt" else "bin/flutter")
    log_path = output.with_suffix(".build.log")
    manifest_path = output.with_suffix(".json")
    env = {**os.environ, "FLUTTER_ROOT": str(sdk),
           "PATH": str(sdk / "bin") + os.pathsep + os.environ["PATH"],
           "JAVA_OPTS": os.environ.get("JAVA_OPTS", "") + " --enable-native-access=ALL-UNNAMED",
           "PILIAURORA_TEST_RELEASE": "true" if args.mode == "dev-release" else "false",
           "TEMP": str(repo / ".gradle-tmp"), "TMP": str(repo / ".gradle-tmp")}
    (repo / ".gradle-tmp").mkdir(exist_ok=True)
    tracked_state = [repo / "android/local.properties", repo / ".dart_tool/package_config.json"]
    backup = {path: path.read_bytes() if path.exists() else None for path in tracked_state}
    source = (repo / args.source_apk).resolve() if args.source_apk else (
        repo / f"build/app/outputs/flutter-apk/app-{mode}.apk")
    if args.source_apk:
        identity = json.loads(source.with_suffix(".json").read_text(encoding="utf-8"))
        validate_source_identity(
            identity, target=args.target, mode=mode, package=package,
            apk_hash=engine_identity.sha256(source),
            ticker_hash=engine_identity.sha256(repo / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart"),
            dart_defines=args.dart_define, engine_digest=engine_digest, source_hash=source_hash)
    library = args.engine_library.resolve()
    if not library.is_file():
        raise FileNotFoundError(library)
    gn_args = library.parent.parent / "args.gn"
    if gn_args.is_file() and f'flutter_runtime_mode = "{mode}"' not in gn_args.read_text():
        raise ValueError(f"Engine runtime mode must be {mode}")
    with log_path.open("a" if args.skip_build else "w", encoding="utf-8") as log:
        def run(command):
            result = subprocess.run([str(arg) for arg in command], cwd=repo,
                                    env=env, stdout=log, stderr=subprocess.STDOUT)
            log.flush()
            if result.returncode:
                raise RuntimeError(f"{Path(command[0]).name} failed ({result.returncode}); see {log_path}")

        try:
            if not args.skip_build:
                if not args.skip_pub_get:
                    run([flutter, "pub", "get", "--offline", "--enforce-lockfile"])
                if not args.skip_patch:
                    run(["pwsh", "-NoProfile", "-File", "lib/scripts/patch.ps1", "android", "-SkipPubGet"])
                run([sdk / ("bin/cache/dart-sdk/bin/dart.exe" if os.name == "nt" else "bin/cache/dart-sdk/bin/dart"), "--packages=.dart_tool/package_config.json",
                     "tool/check_dependencies.dart"])
                run([flutter, "build", "apk", f"--{mode}", "--no-pub", f"--target-platform={target_platform}",
                     f"--target={args.target}",
                     *[f"--dart-define={value}" for value in generated_defines],
                     *[f"--dart-define={value}" for value in args.dart_define]])
            verified_engine = engine_identity.validate_engine(library, profile="androidFramePlan", mode=mode, sdk=sdk, architecture=architecture)
            if engine_identity.identity_digest(verified_engine) != engine_digest:
                raise ValueError("Engine identity changed during application compilation")
            if engine_identity.source_fingerprint(repo, args.target) != source_hash:
                raise ValueError("Application sources changed during compilation")
            intermediate = output.with_suffix(".unsigned.apk")
            with zipfile.ZipFile(source) as src, zipfile.ZipFile(intermediate, "w") as dst:
                for entry in src.infolist():
                    name = entry.filename
                    if name.startswith("META-INF/") or name in {f"lib/{args.abi}/libflutter.so", "assets/piliaurora-engine-identity.json"}:
                        continue
                    if name.startswith("lib/") and not name.startswith(f"lib/{args.abi}/"):
                        continue
                    if name.endswith(("/libpacing.so", "/wrap.sh")):
                        raise ValueError(f"Unexpected preload probe in input APK: {name}")
                    dst.writestr(entry, src.read(name))
                dst.writestr("assets/piliaurora-engine-identity.json", json.dumps({
                    **engine, "identityDigest": engine_digest,
                }, sort_keys=True))
                dst.write(library, f"lib/{args.abi}/libflutter.so", compress_type=zipfile.ZIP_DEFLATED)
            tools = args.android_sdk / "build-tools/37.0.0"
            aligned = output.with_suffix(".aligned.apk")
            run([tools / ("zipalign.exe" if os.name == "nt" else "zipalign"), "-f", "-P", "16", "4", intermediate, aligned])
            if mode == "release":
                run(["java", Path(__file__).with_name("ReleaseApkSigner.java"), repo,
                     tools / "lib/apksigner.jar", aligned, output])
            else:
                run([tools / ("apksigner.bat" if os.name == "nt" else "apksigner"), "sign", "--ks",
                     Path.home() / ".android/debug.keystore",
                     "--ks-key-alias", "androiddebugkey", "--ks-pass", "pass:android",
                     "--key-pass", "pass:android", "--out", output, aligned])
            run(["java", "--enable-native-access=ALL-UNNAMED", "-jar",
                 tools / "lib/apksigner.jar", "verify", output])
            engine_identity.verify_packaged_engine(output, library, args.abi)
            engine_identity.write_json(manifest_path, {
                **engine, "identityDigest": engine_digest,
                "application": {
                    "sourceSha256": source_hash, "apkSha256": engine_identity.sha256(output),
                    "target": args.target, "abi": args.abi, "package": package,
                    "dartDefines": args.dart_define,
                    "tickerSha256": engine_identity.sha256(repo / "third_party/canvas_danmaku/lib/frame_rate_ticker.dart"),
                },
            })
        finally:
            restore_workspace_state(backup)
    print(output)
    print(manifest_path)


if __name__ == "__main__":
    main()
