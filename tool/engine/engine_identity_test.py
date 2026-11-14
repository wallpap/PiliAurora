import copy
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zipfile
from unittest.mock import patch

import engine_identity as protocol


class EngineIdentityTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def artifact(self, profile="androidFramePlan"):
        library = self.root / ("libflutter.so" if profile == "androidFramePlan" else "flutter_windows.dll")
        header = bytearray(128)
        if profile == "androidFramePlan":
            header[:6] = b"\x7fELF\x02\x01"
            struct.pack_into("<H", header, 18, 183)
        else:
            header[:2] = b"MZ"
            struct.pack_into("<I", header, 60, 64)
            header[64:70] = b"PE\0\0\x64\x86"
        library.write_bytes(header)
        with patch.object(protocol, "validate_sdk"):
            identity = protocol.create_identity(library, profile=profile, mode="profile",
                sdk=self.root, native_tests_passed=True)
        protocol.write_json(library.with_name("engine-identity.json"), identity)
        return library, identity

    def test_both_platforms_require_exact_artifact_and_configuration(self):
        for profile in protocol.PROFILES:
            library, identity = self.artifact(profile)
            self.assertEqual(protocol.validate_engine(library, profile=profile, mode="profile"), identity)
            for field, value in {
                "schemaVersion": 0, "profile": "standard", "frameworkCommit": "old",
                "engineCommit": "old", "patchSha256": "changed", "overlaySha256": "changed",
                "binarySha256": "changed", "mode": "release", "architecture": "x86",
                "nativeTestsPassed": False,
            }.items():
                changed = {**identity, field: value}
                protocol.write_json(library.with_name("engine-identity.json"), changed)
                with self.subTest(profile=profile, field=field), self.assertRaises(ValueError):
                    protocol.validate_engine(library, profile=profile, mode="profile")

    def test_android_abis_validate_elf_headers_and_packaged_library(self):
        for architecture, abi, elf_class, machine in [
            ("arm", "armeabi-v7a", 1, 40), ("arm64", "arm64-v8a", 2, 183),
            ("x64", "x86_64", 2, 62),
        ]:
            with self.subTest(architecture=architecture):
                library = self.root / "libflutter.so"
                header = bytearray(64)
                header[:6] = b"\x7fELF" + bytes((elf_class, 1))
                struct.pack_into("<H", header, 18, machine)
                library.write_bytes(header)
                with patch.object(protocol, "validate_sdk"):
                    identity = protocol.create_identity(library, profile="androidFramePlan",
                        mode="release", sdk=self.root, native_tests_passed=True,
                        architecture=architecture)
                protocol.write_json(library.with_name("engine-identity.json"), identity)
                protocol.validate_engine(library, profile="androidFramePlan", mode="release",
                    architecture=architecture)
                with self.assertRaises(ValueError):
                    protocol.validate_engine(library, profile="androidFramePlan", mode="release",
                        architecture="arm" if architecture != "arm" else "arm64")
                apk = self.root / "test.apk"
                with zipfile.ZipFile(apk, "w") as archive:
                    archive.write(library, f"lib/{abi}/libflutter.so")
                    archive.writestr(f"lib/{abi}/libapp.so", b"aot")
                protocol.verify_packaged_engine(apk, library, abi)
                header[4] = 2 if elf_class == 1 else 1
                library.write_bytes(header)
                with self.assertRaises(ValueError):
                    protocol.validate_architecture(library, architecture)

    def test_binary_architecture_is_checked_independently_of_manifest(self):
        library, identity = self.artifact()
        library.write_bytes(b"wrong architecture")
        identity["binarySha256"] = protocol.sha256(library)
        protocol.write_json(library.with_name("engine-identity.json"), identity)
        with self.assertRaises(ValueError):
            protocol.validate_engine(library, profile="androidFramePlan", mode="profile")

    def test_binary_format_is_bound_to_platform(self):
        for source, target in [("androidFramePlan", "windowsDwmPaced"),
                               ("windowsDwmPaced", "androidFramePlan")]:
            library, _ = self.artifact(source)
            with self.subTest(source=source), patch.object(protocol, "validate_sdk"):
                with self.assertRaises(ValueError):
                    protocol.create_identity(library, profile=target, mode="release", sdk=self.root,
                        native_tests_passed=True, architecture="x64")

    def test_packaged_apk_requires_aot_library(self):
        library, _ = self.artifact()
        apk = self.root / "missing-aot.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.write(library, "lib/arm64-v8a/libflutter.so")
        with self.assertRaisesRegex(ValueError, "AOT"):
            protocol.verify_packaged_engine(apk, library)

    def test_identity_digest_binds_generated_defines_but_excludes_application_receipt(self):
        _, identity = self.artifact()
        digest = protocol.identity_digest(identity)
        self.assertIn(f"PILIAURORA_ENGINE_IDENTITY={digest}", protocol.dart_defines("androidFramePlan", identity))
        self.assertEqual(protocol.identity_digest({**identity, "identityDigest": digest, "application": {}}), digest)
        changed = copy.deepcopy(identity)
        changed["binarySha256"] = "other"
        self.assertNotEqual(protocol.identity_digest(changed), digest)
        self.assertEqual(protocol.dart_defines("standard"), [
            "PILIAURORA_PRESENTATION_PROFILE=standard", "PILIAURORA_ENGINE_IDENTITY="])
        with self.assertRaises(ValueError):
            protocol.dart_defines("androidFramePlan")
        for key in protocol.RESERVED_DEFINES:
            with self.assertRaises(ValueError):
                protocol.validate_defines([key + "=override"])

    def test_packaged_engine_and_extra_abi_are_verified(self):
        library, _ = self.artifact()
        apk = self.root / "test.apk"
        for extra in [False, True]:
            with zipfile.ZipFile(apk, "w") as archive:
                archive.write(library, "lib/arm64-v8a/libflutter.so")
                archive.writestr("lib/arm64-v8a/libapp.so", b"aot")
                if extra:
                    archive.writestr("lib/x86_64/libflutter.so", b"wrong")
            if extra:
                with self.assertRaises(ValueError):
                    protocol.verify_packaged_engine(apk, library)
            else:
                protocol.verify_packaged_engine(apk, library)

    def test_standard_output_removes_old_identity_after_binary_verification(self):
        artifacts = self.root / "bin/cache/artifacts/engine/windows-x64"
        artifacts.mkdir(parents=True)
        (artifacts / "flutter_windows.dll").write_bytes(b"standard")
        output = self.root / "output"
        output.mkdir()
        (output / "flutter_windows.dll").write_bytes(b"custom")
        identity = output / "engine-identity.json"
        identity.write_text("old custom identity")
        with self.assertRaises(ValueError):
            protocol.verify_standard_output(output, sdk=self.root, platform="windows", mode="debug")
        self.assertTrue(identity.exists())
        (output / "flutter_windows.dll").write_bytes(b"standard")
        protocol.verify_standard_output(output, sdk=self.root, platform="windows", mode="debug")
        self.assertFalse(identity.exists())

    def test_apk_reuse_fingerprint_includes_plugin_native_sources(self):
        (self.root / "lib").mkdir()
        (self.root / "lib/main.dart").write_text("void main() {}")
        (self.root / "pubspec.yaml").write_text("name: fixture")
        (self.root / "pubspec.lock").write_text("fixture")
        native = self.root / "third_party/video/android/src"
        native.mkdir(parents=True)
        (self.root / "android/.gradle").mkdir(parents=True)
        source = native / "VideoOutput.java"
        source.write_text("original")
        before = protocol.source_fingerprint(self.root, "lib/main.dart")
        source.write_text("changed")
        self.assertNotEqual(protocol.source_fingerprint(self.root, "lib/main.dart"), before)

    def test_fixed_sdk_commits_are_required(self):
        (self.root / "bin/internal").mkdir(parents=True)
        (self.root / "bin/internal/engine.version").write_text(protocol.ENGINE_COMMIT)
        with patch.object(protocol.subprocess, "check_output", return_value=protocol.FRAMEWORK_COMMIT):
            protocol.validate_sdk(self.root)
        with patch.object(protocol.subprocess, "check_output", return_value="different"):
            with self.assertRaises(ValueError):
                protocol.validate_sdk(self.root)

    def test_patch_comparison_accepts_git_empty_context_and_preserves_changes(self):
        registered = "diff --git a/test b/test\nindex 123..456 100644\n@@ -1,2 +1,2 @@\n\n-old\n+new\n"
        actual = registered.replace("@@ -1,2 +1,2 @@\n\n", "@@ -1,3 +1,3 @@\n \n") + " \n"
        self.assertTrue(protocol.patch_matches(actual, registered))
        self.assertFalse(protocol.patch_matches(actual.replace("+new", "+new "), registered))
        self.assertFalse(protocol.patch_matches(actual + "+extra\n", registered))
        self.assertFalse(protocol.patch_matches(actual.replace("123..456", "123..789"), registered))

    def test_windows_identity_binds_angle_policy_and_native_regression(self):
        profile = "windowsDwmPaced"
        architecture, directory, overlays = protocol.PROFILES[profile]
        self.assertIn("angle-image-upload.patch", overlays)
        self.assertIn("image_upload_unittests.cc", overlays)
        for name in overlays:
            (self.root / name).write_bytes((directory / name).read_bytes())
        profiles = {**protocol.PROFILES, profile: (architecture, self.root, overlays)}
        with patch.object(protocol, "PROFILES", profiles):
            original = protocol.materials(profile)
            for name in overlays:
                source = self.root / name
                before = source.read_bytes()
                source.write_bytes(before + b"\n")
                self.assertNotEqual(protocol.materials(profile)["overlaySha256"],
                                    original["overlaySha256"])
                source.write_bytes(before)


if __name__ == "__main__":
    unittest.main()
