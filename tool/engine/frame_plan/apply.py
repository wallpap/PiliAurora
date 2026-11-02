"""Apply pinned frame-plan patches to isolated Flutter checkouts."""
import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import engine_identity

REVISION = "af7e796e161ae0bb1ff0758c71a7105418bd9ded"


def git(root, *args):
    return subprocess.run(["git", *map(str, args)], cwd=root,
                          capture_output=True, text=True, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checkout", type=Path)
    parser.add_argument("--framework-sdk", type=Path)
    args = parser.parse_args()
    root = args.checkout.resolve()
    source = Path(__file__).resolve().parent
    revision = git(root, "rev-parse", "HEAD")
    if revision.returncode or revision.stdout.strip() != REVISION:
        raise ValueError(f"Engine checkout must be at {REVISION}")
    framework = args.framework_sdk.resolve() if args.framework_sdk else root
    if args.framework_sdk:
        pinned = (framework / "bin/internal/engine.version").read_text().strip()
        if pinned != REVISION:
            raise ValueError("Framework SDK engine revision differs")
    patches = [(root, engine_identity.PATCHES["androidFramePlan"])]
    pending = []
    for target, patch in patches:
        if git(target, "apply", "--reverse", "--check", patch).returncode == 0:
            continue
        check = git(target, "apply", "--check", patch)
        if check.returncode:
            raise ValueError(f"Patch conflict: {patch.name}\n{check.stderr}")
        pending.append((target, patch))
    copies = [
        (source / "frame_presentation_plan.h", root / "engine/src/flutter/flow/frame_presentation_plan.h"),
        (source / "frame_presentation_plan_unittests.cc",
         root / "engine/src/flutter/shell/platform/android/frame_presentation_plan_unittests.cc"),
    ]
    for original, target in copies:
        if target.exists() and target.read_bytes() != original.read_bytes():
            raise ValueError(f"Existing overlay source differs: {target}")
    for target, patch in pending:
        result = git(target, "apply", patch)
        if result.returncode:
            raise RuntimeError(result.stderr)
    for original, target in copies:
        if not target.exists():
            target.write_bytes(original.read_bytes())
    print(f"Frame-plan overlay ready: {root}")


if __name__ == "__main__":
    main()
