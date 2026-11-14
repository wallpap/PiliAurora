"""Build the shipping worker and create deterministic, public test inputs."""
from pathlib import Path
import hashlib
import json
import os
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUTPUT = ROOT / 'build/probes/image-region'


def cmake_tool():
    found = shutil.which('cmake')
    if found:
        return found
    vswhere = Path(os.environ.get('ProgramFiles(x86)', 'C:/Program Files (x86)')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
    result = subprocess.check_output([str(vswhere), '-latest', '-products', '*', '-find',
        'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'], text=True).strip()
    if not result:
        raise RuntimeError('Install Visual Studio C++ CMake tools')
    return result.splitlines()[0]


def prepare():
    from PIL import Image, ImageCms
    OUTPUT.mkdir(parents=True, exist_ok=True)
    cmake = cmake_tool()
    subprocess.run([cmake, '-S', str(ROOT / 'windows/image_worker'), '-B', str(OUTPUT / 'native'), '-A', 'x64'], check=True)
    subprocess.run([cmake, '--build', str(OUTPUT / 'native'), '--config', 'Release'], check=True)
    specs = [
        ('wide', (8192, 3972), 'JPEG'), ('tall', (512, 6000), 'PNG'),
        ('png', (720, 550), 'PNG'), ('jpeg', (720, 550), 'JPEG'),
        ('webp', (720, 550), 'WEBP'), ('alpha', (720, 550), 'PNG'),
        ('webp-alpha', (720, 550), 'WEBP'), ('icc-jpeg', (720, 550), 'JPEG'),
        ('icc-webp', (720, 550), 'WEBP'), ('small', (320, 300), 'PNG'),
        ('lossless', (720, 550), 'WEBP'), ('animated', (1600, 1000), 'GIF'),
        ('progressive', (6000, 4000), 'JPEG'), ('oriented', (720, 550), 'JPEG'),
        ('huge-webp', (8192, 6144), 'WEBP'),
        ('avif', (720, 550), 'AVIF'),
    ]
    images = []
    srgb = ImageCms.ImageCmsProfile(ImageCms.createProfile('sRGB')).tobytes()
    for name, size, format in specs:
        image = Image.new('RGBA' if 'alpha' in name else 'RGB', size)
        # 大图用确定性色块，避免生成数百万个 Python 像素对象。
        for y in range(0, size[1], 64):
            for x in range(0, size[0], 64):
                color = ((x // 64 * 29) % 256, (y // 64 * 53) % 256, ((x + y) // 64 * 17) % 256)
                if image.mode == 'RGBA':
                    color += ((x // 64 * 31 + y // 64 * 47) % 256,)
                image.paste(color, (x, y, min(x + 64, size[0]), min(y + 64, size[1])))
        file = OUTPUT / f'{name}.{format.lower()}'
        options = dict(quality=95)
        if name == 'progressive':
            options['progressive'] = True
        if name == 'lossless':
            options['lossless'] = True
        if name.startswith('icc-'):
            options['icc_profile'] = srgb
        if name == 'oriented':
            exif = Image.Exif()
            exif[274] = 6
            options['exif'] = exif
        if name == 'animated':
            options.update(save_all=True, append_images=[Image.new('RGB', size, '#68ace0')], duration=80, loop=0)
        image.save(file, format=format, **options)
        images.append(dict(id=name, file=str(file), sha256=hashlib.sha256(file.read_bytes()).hexdigest()))
    (OUTPUT / 'fixtures.json').write_text(json.dumps(dict(source='deterministic generated test inputs', images=images), indent=2), encoding='utf-8')
    return OUTPUT / 'native/Release/piliaurora_image_worker.exe'


if __name__ == '__main__':
    print(prepare())
