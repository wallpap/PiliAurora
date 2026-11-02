"""Shared identity protocol for compiled engines and application assembly."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import tempfile
from pathlib import Path
import struct
import subprocess


FRAMEWORK_COMMIT = "6a19cca56475dbfba1478ee68d7bd0c2ef891da1"
ENGINE_COMMIT = "af7e796e161ae0bb1ff0758c71a7105418bd9ded"
SCHEMA_VERSION = 1
ROOT = Path(__file__).resolve().parent
PATCH_ROOT = ROOT.parents[1] / "doc/development/engine-patches"
PATCHES = {
    "androidFramePlan": PATCH_ROOT / "android-frame-plan.patch",
    "windowsDwmPaced": PATCH_ROOT / "windows-frame-pacing.patch",
}
PROFILES = {
    "androidFramePlan": ("arm64", ROOT / "frame_plan", (
        "frame_presentation_plan.h", "frame_presentation_plan_unittests.cc")),
    "windowsDwmPaced": ("x64", ROOT / "windows_frame_pacing", ()),
}
RESERVED_DEFINES = {
    "PILIAURORA_PRESENTATION_PROFILE", "PILIAURORA_ENGINE_IDENTITY",
    "PILIAURORA_CONTENT_COMPOSITION",
}


def sha256(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def patch_matches(actual: str, registered: str) -> bool:
    # 文件 blob 身份和增删行绑定实际修改；上下文与 hunk 范围可随 Git 输出变化。
    def normalize(value: str) -> str:
        return "\n".join(line for line in value.splitlines()
                         if line and not line.startswith((" ", "@@ ")))
    return normalize(actual) == normalize(registered)


def digest_json(value) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"),
                                     ensure_ascii=True).encode()).hexdigest()


def identity_digest(identity: dict) -> str:
    return digest_json({key: value for key, value in identity.items()
                        if key not in {"application", "identityDigest"}})


def materials(profile: str) -> dict:
    _, directory, overlays = PROFILES[profile]
    return {"patchSha256": sha256(PATCHES[profile]),
            "overlaySha256": digest_json({name: sha256(directory / name) for name in overlays})}


def validate_sdk(sdk: Path) -> None:
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=sdk,
                                       text=True).strip()
    engine = (sdk / "bin/internal/engine.version").read_text().strip()
    if revision != FRAMEWORK_COMMIT or engine != ENGINE_COMMIT:
        raise ValueError("Flutter framework/engine commits differ from the pinned SDK")


def validate_architecture(library: Path, architecture: str, *, profile: str | None = None) -> None:
    with library.open("rb") as binary:
        header = binary.read(64)
        if profile != "windowsDwmPaced" and architecture in {"arm", "arm64", "x64"} and header[:4] == b"\x7fELF":
            elf_class, machine = {"arm": (1, 40), "arm64": (2, 183), "x64": (2, 62)}[architecture]
            valid = (len(header) >= 52 and header[4:6] == bytes((elf_class, 1)) and
                     struct.unpack_from("<H", header, 18)[0] == machine)
        else:
            valid = False
            if profile != "androidFramePlan" and architecture == "x64" and len(header) == 64 and header[:2] == b"MZ":
                binary.seek(struct.unpack_from("<I", header, 60)[0])
                pe = binary.read(6)
                valid = len(pe) == 6 and pe[:4] == b"PE\0\0" and pe[4:] == b"\x64\x86"
    if not valid:
        raise ValueError(f"Engine binary architecture is not {architecture}: {library}")


def create_identity(library: Path, *, profile: str, mode: str, sdk: Path,
                    native_tests_passed: bool, architecture: str | None = None, **metadata) -> dict:
    validate_sdk(sdk)
    architecture = architecture or PROFILES[profile][0]
    if architecture not in ({"arm", "arm64", "x64"} if profile == "androidFramePlan" else {"x64"}):
        raise ValueError("Unsupported engine architecture")
    validate_architecture(library, architecture, profile=profile)
    if mode not in {"profile", "release"}:
        raise ValueError("Custom engines require profile or release mode")
    return {**metadata, "schemaVersion": SCHEMA_VERSION, "profile": profile,
            "frameworkCommit": FRAMEWORK_COMMIT, "engineCommit": ENGINE_COMMIT,
            **materials(profile), "binarySha256": sha256(library),
            "mode": mode, "architecture": architecture,
            "nativeTestsPassed": native_tests_passed}


def validate_engine(library: Path, *, profile: str, mode: str, sdk: Path | None = None,
                    require_native_tests: bool = True, architecture: str | None = None) -> dict:
    if sdk is not None:
        validate_sdk(sdk)
    identity = json.loads(library.with_name("engine-identity.json").read_text(encoding="utf-8"))
    architecture = architecture or PROFILES[profile][0]
    if architecture not in ({"arm", "arm64", "x64"} if profile == "androidFramePlan" else {"x64"}):
        raise ValueError("Unsupported engine architecture")
    expected = {"schemaVersion": SCHEMA_VERSION, "profile": profile,
                "frameworkCommit": FRAMEWORK_COMMIT, "engineCommit": ENGINE_COMMIT,
                "mode": mode, "architecture": architecture,
                **materials(profile), "binarySha256": sha256(library)}
    if mode not in {"profile", "release"}:
        raise ValueError("Custom engines require profile or release mode")
    for field, value in expected.items():
        if identity.get(field) != value:
            raise ValueError(f"Engine identity mismatch: {field}")
    if require_native_tests and identity.get("nativeTestsPassed") is not True:
        raise ValueError("This engine artifact has not passed native regression tests")
    validate_architecture(library, architecture, profile=profile)
    return identity


def dart_defines(profile: str, identity: dict | None = None) -> list[str]:
    if profile != "standard" and (identity is None or identity["profile"] != profile):
        raise ValueError("Custom presentation configuration requires a matching engine identity")
    if profile == "standard" and identity is not None:
        raise ValueError("Standard presentation configuration cannot bind a custom engine")
    return [f"PILIAURORA_PRESENTATION_PROFILE={profile}",
            "PILIAURORA_ENGINE_IDENTITY=" + (identity_digest(identity) if identity else "")]


def validate_defines(values: list[str]) -> None:
    if any(value.split("=", 1)[0] in RESERVED_DEFINES for value in values):
        raise ValueError("Presentation defines are generated by the engine assembly entry point")


def source_fingerprint(repo: Path, target: str) -> str:
    files = list((repo / "lib").rglob("*.dart"))
    for package in (repo / "third_party").iterdir():
        if (package / "lib").is_dir():
            files.extend((package / "lib").rglob("*.dart"))
        if (package / "pubspec.yaml").is_file():
            files.append(package / "pubspec.yaml")
    # 复用的是整份 APK；插件原生实现和 Android 资源也参与来源身份。
    native_roots = [repo / "android/app/src", *[p / "android/src" for p in (repo / "third_party").iterdir()]]
    for directory in native_roots:
        if directory.is_dir():
            files.extend(path for path in directory.rglob("*") if path.is_file())
    android_roots = [repo / "android", *[p / "android" for p in (repo / "third_party").iterdir()]]
    for directory in android_roots:
        for pattern in ["*.gradle", "*.gradle.kts", "CMakeLists.txt"]:
            files.extend(path for path in directory.glob(pattern) if path.is_file())
    if (repo / "android/app/build.gradle.kts").is_file():
        files.append(repo / "android/app/build.gradle.kts")
    if (repo / "assets").is_dir():
        files.extend(path for path in (repo / "assets").rglob("*") if path.is_file())
    files.extend([repo / "pubspec.yaml", repo / "pubspec.lock", repo / target])
    return digest_json({path.resolve().relative_to(repo.resolve()).as_posix(): sha256(path)
                        for path in files})


def verify_packaged_engine(apk: Path, library: Path, abi: str = "arm64-v8a") -> None:
    import zipfile
    with zipfile.ZipFile(apk) as archive:
        embedded = hashlib.sha256(archive.read(f"lib/{abi}/libflutter.so")).hexdigest()
        abis = {name.split("/")[1] for name in archive.namelist() if name.startswith("lib/")}
        if f"lib/{abi}/libapp.so" not in archive.namelist():
            raise ValueError("Packaged APK is missing the target ABI AOT library")
        if embedded != sha256(library) or abis != {abi}:
            raise ValueError("Packaged engine binary or ABI differs from the verified artifact")


def verify_standard_output(output: Path, *, sdk: Path, platform: str, mode: str) -> None:
    import zipfile
    suffix = "" if mode == "debug" else "-" + mode
    artifacts = sdk / "bin/cache/artifacts/engine"
    if platform == "windows":
        expected = artifacts / f"windows-x64{suffix}/flutter_windows.dll"
        if sha256(output / "flutter_windows.dll") != sha256(expected):
            raise ValueError("Standard Windows output differs from the selected FVM engine")
        stale = output / "engine-identity.json"
    else:
        with zipfile.ZipFile(output) as apk:
            found = False
            for abi in ["arm64-v8a", "armeabi-v7a", "x86_64"]:
                name = f"lib/{abi}/libflutter.so"
                if name not in apk.namelist():
                    continue
                found = True
                gradle_home = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
                module = abi.replace("-", "_") + "_" + mode
                version = "1.0.0-" + (sdk / "bin/cache/engine.stamp").read_text().strip()
                cache = gradle_home / "caches/modules-2/files-2.1/io.flutter" / module / version
                jars = list(cache.glob(f"*/{module}-{version}.jar"))
                if len(jars) != 1:
                    raise ValueError(f"Expected one resolved FVM engine artifact for {abi}: {cache}")
                with zipfile.ZipFile(jars[0]) as engine:
                    stock = engine.read(f"lib/{abi}/libflutter.so")
                embedded_hash = hashlib.sha256(apk.read(name)).hexdigest()
                if embedded_hash != hashlib.sha256(stock).hexdigest():
                    # AGP 对标准 Maven 引擎执行 strip-unneeded，复现相同变换后比较。
                    local = (ROOT.parents[1] / "android/local.properties").read_text(encoding="utf-8")
                    android_sdk = Path(re.search(r"^sdk\.dir=(.+)$", local, re.MULTILINE)[1].strip().replace("\\\\", "\\"))
                    extension = (sdk / "packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt").read_text()
                    ndk = re.search(r'val ndkVersion: String = "([^"]+)"', extension)[1]
                    host = "windows-x86_64" if os.name == "nt" else "linux-x86_64"
                    strip = android_sdk / f"ndk/{ndk}/toolchains/llvm/prebuilt/{host}/bin/llvm-strip"
                    if os.name == "nt":
                        strip = strip.with_suffix(".exe")
                    with tempfile.TemporaryDirectory(prefix="standard-engine-", dir=output.parent) as temporary:
                        original, stripped = Path(temporary) / "original.so", Path(temporary) / "stripped.so"
                        original.write_bytes(stock)
                        subprocess.run([strip, "--strip-unneeded", "-o", stripped, original], check=True)
                        if embedded_hash != sha256(stripped):
                            raise ValueError(f"Standard APK engine differs for {abi}")
            if not found:
                raise ValueError("Standard APK contains no supported engine ABI")
            if "assets/piliaurora-engine-identity.json" in apk.namelist():
                raise ValueError("Standard APK still carries a custom engine identity")
        stale = output.with_suffix(".json")
    stale.unlink(missing_ok=True)


def write_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--profile", choices=["standard", *PROFILES], required=True)
    parser.add_argument("--mode", choices=["debug", "profile", "release"], required=True)
    parser.add_argument("--flutter-sdk", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-standard-output", type=Path)
    parser.add_argument("--platform", choices=["android", "windows"])
    args = parser.parse_args()
    if args.library is None and args.profile != "standard":
        parser.error("Custom profiles require --library")
    if args.profile == "standard" and args.library is not None:
        parser.error("Standard profile cannot bind --library")
    if args.flutter_sdk is not None:
        validate_sdk(args.flutter_sdk)
    if args.verify_standard_output:
        if args.profile != "standard" or args.flutter_sdk is None or args.platform is None:
            parser.error("Standard output verification requires standard profile, SDK and platform")
        verify_standard_output(args.verify_standard_output, sdk=args.flutter_sdk, platform=args.platform, mode=args.mode)
    identity = (validate_engine(args.library, profile=args.profile, mode=args.mode)
                if args.library else None)
    result = {"schemaVersion": SCHEMA_VERSION, "profile": args.profile,
              "identity": identity, "identityDigest": identity_digest(identity) if identity else "",
              "dartDefines": dart_defines(args.profile, identity)}
    if args.output:
        write_json(args.output, result)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
