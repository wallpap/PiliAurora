"""Install the verified engine and record the files owned by this Windows build."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import sys

MANIFEST = 'piliaurora-runtime.sha256'
HEADER = '# PiliAurora runtime manifest v1'


def write_manifest(runtime: Path) -> Path:
    runtime = runtime.resolve(strict=True)
    if not (runtime / 'PiliAurora.exe').is_file():
        raise ValueError('Windows runtime is missing PiliAurora.exe')
    lines = [HEADER]
    for entry in sorted(runtime.rglob('*')):
        if entry.is_symlink() or entry.is_junction():
            raise ValueError('Runtime files must not contain links')
        if not entry.is_file() or entry == runtime / MANIFEST:
            continue
        relative = entry.relative_to(runtime).as_posix()
        if any(char in relative for char in '\t\r\n'):
            raise ValueError('Runtime file name cannot be represented in the manifest')
        with entry.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        lines.append(f'{digest}\t{relative}')
    output = runtime / MANIFEST
    output.write_text('\n'.join(lines) + '\n', encoding='utf-8')
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    runtime = args.runtime.resolve(strict=True)
    subprocess.run([
        sys.executable, str(root / 'third_party/flutter_engine/package.py'),
        'install-windows', '--target', 'windows-x64', '--output', str(runtime),
    ], cwd=root, check=True)
    print(f'Windows runtime manifest: {write_manifest(runtime).name}')


if __name__ == '__main__':
    main()
