"""下载并校验固定的标准上游 libmpv 包，供 CI 独立验收。"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import urllib.request


def verify_notices(package: Path) -> None:
    windows = package / 'windows'
    manifest = json.loads((windows / 'NOTICE_SOURCES.json').read_text(encoding='utf-8'))
    content = (windows / manifest['notice_file']).read_bytes()
    if hashlib.sha256(content).hexdigest() != manifest['notice_file_sha256']:
        raise RuntimeError('Combined native notice SHA-256 mismatch')
    for name, section in manifest['sections'].items():
        offset, length = section['offset'], section['length']
        original = content[offset:offset + length]
        if offset < 0 or length < 0 or len(original) != length:
            raise RuntimeError(f'Invalid native notice range: {name}')
        if hashlib.sha256(original).hexdigest() != section['sha256']:
            raise RuntimeError(f'Native notice original SHA-256 mismatch: {name}')
    for component in manifest['components'].values():
        for notice in component['notices']:
            if notice['section'] not in manifest['sections']:
                raise RuntimeError(f'Missing native notice section: {notice["original_path"]}')
    print(f'Verified {len(manifest["sections"])} combined native notice sections.')


def verify(package: Path) -> Path:
    verify_notices(package)
    metadata = json.loads((package / 'windows/libmpv.json').read_text(encoding='utf-8'))
    expected = metadata['sha256']
    cache = package.resolve().parents[1] / 'build' / 'upstream-mpv'
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f'{expected}.7z'
    if not archive.exists():
        temporary = archive.with_suffix('.part')
        try:
            urllib.request.urlretrieve(metadata['url'], temporary)
            with temporary.open('rb') as source:
                if hashlib.file_digest(source, 'sha256').hexdigest() != expected:
                    raise RuntimeError('Upstream libmpv archive SHA-256 mismatch')
            temporary.replace(archive)
        finally:
            temporary.unlink(missing_ok=True)
    with archive.open('rb') as source:
        if hashlib.file_digest(source, 'sha256').hexdigest() != expected:
            raise RuntimeError(f'Upstream libmpv archive SHA-256 mismatch: {archive}')
    print(f'Verified upstream libmpv {metadata["version"]}: {archive}')
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backward-seek', action='store_true',
                        help='在 Windows 运行分片独立音轨的真实回退回归')
    args = parser.parse_args()
    if args.backward_seek:
        if sys.platform != 'win32':
            parser.error('--backward-seek requires Windows')
        if not shutil.which('cmake'):
            parser.error('--backward-seek requires CMake on PATH')
    root = Path(__file__).resolve().parents[1]
    archive = verify(root / 'third_party/media_kit_libs_windows_video')
    if args.backward_seek:
        with tempfile.TemporaryDirectory(prefix='piliaurora-mpv-seek-') as directory:
            subprocess.run(['cmake', '-E', 'tar', 'xf', str(archive)],
                           cwd=directory, check=True)
            subprocess.run([
                sys.executable, str(root / 'tool/probes/playback/native_backward_seek.py'),
                '--library', str(Path(directory) / 'libmpv-2.dll'),
            ], check=True)
