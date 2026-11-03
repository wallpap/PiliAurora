"""导出头像、动画、平台图标和 imagegen 背景。依赖开发工具 Pillow。"""

import argparse
import math
import tempfile
from io import BytesIO
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps

from coin_motion import export_coin_motion

ICON_ARTWORK = (
    ('chibi', 'app-icon-chibi', 'logo_chibi'),
    ('upright', 'app-icon-upright', 'logo_upright'),
    ('tilted', 'app-icon-tilted', 'logo_tilted'),
    ('portrait', 'app-icon', 'logo'),
)

ICON_DARK_OVERLAY_OPACITY = 0.18


def darken_icon(source):
    # 黑色遮罩只降低 RGB 亮度，保留色相、原有构图和透明度。
    rgba = source.convert('RGBA')
    lookup = [round(value * (1 - ICON_DARK_OVERLAY_OPACITY)) for value in range(256)]
    red, green, blue, alpha = rgba.split()
    return Image.merge('RGBA', (red.point(lookup), green.point(lookup), blue.point(lookup), alpha))


def save_image(image, path, **options):
    # 先完整编码到同目录临时文件，再替换目标，避免预览读取期间截断资源。
    buffer = BytesIO()
    image.save(buffer, format=Image.registered_extensions()[path.suffix], **options)
    with tempfile.NamedTemporaryFile(dir=path.parent, suffix=path.suffix, delete=False) as output:
        output.write(buffer.getvalue())
        temporary = Path(output.name)
    try:
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def export_brand_artwork(root, assets):
    # Windows 与应用内使用圆角；Android 自适应图标交由系统裁切。
    mask = Image.new('L', (1024, 1024))
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 1023, 1023), radius=220, fill=255)
    resource = root / 'android/app/src/main/res'
    # 108dp 前景中，中心 72dp 放入完整方形原稿，保留系统遮罩与视差余量。
    for variant, source_name, logo_name in ICON_ARTWORK:
        with Image.open(root / f'tool/artwork/raster/{source_name}.png') as source:
            light_square = source.convert('RGBA').resize((512, 512), Image.Resampling.LANCZOS)
        launcher = 'ic_launcher' if variant == 'chibi' else f'ic_launcher_{variant}'
        artwork = 'app_icon_artwork' if variant == 'chibi' else f'app_icon_{variant}_artwork'
        for dark in [False, True]:
            suffix = '_dark' if dark else ''
            square = darken_icon(light_square) if dark else light_square
            logo = square.copy()
            logo.putalpha(mask.resize((512, 512), Image.Resampling.LANCZOS))
            save_image(logo, assets / f'logo/{logo_name}{suffix}.png', optimize=True)
            foreground = Image.new('RGBA', (768, 768), square.getpixel((0, 0)))
            foreground.alpha_composite(square, (128, 128))
            drawable = resource / ('drawable-night-nodpi' if dark else 'drawable-nodpi')
            drawable.mkdir(exist_ok=True)
            save_image(foreground, drawable / f'{artwork}.png', optimize=True)
        (resource / f'drawable/{launcher}_foreground.xml').write_text(
            '<?xml version="1.0" encoding="utf-8"?>\n'
            '<bitmap xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:src="@drawable/{artwork}"\n'
            '    android:gravity="fill"\n'
            '    android:filter="true" />\n', encoding='utf-8')
        for directory in resource.glob('mipmap-anydpi*'):
            (directory / f'{launcher}.xml').write_text(
                '<?xml version="1.0" encoding="utf-8"?>\n'
                '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
                '    <background android:drawable="@color/ic_launcher_background"/>\n'
                f'    <foreground android:drawable="@drawable/{launcher}_foreground"/>\n'
                '    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />\n'
                '</adaptive-icon>\n', encoding='utf-8')


def export_platform_icons(root, assets):
    sizes = [(size, size) for size in [16, 24, 32, 48, 64, 128, 256]]
    resource = root / 'android/app/src/main/res'
    density_paths = [path for path in resource.glob('mipmap-*/ic_launcher.png')
                     if '-night-' not in path.parent.name]
    for variant, _, logo_name in ICON_ARTWORK:
        suffix = '' if variant == 'portrait' else f'_{variant}'
        launcher = 'ic_launcher' if variant == 'chibi' else f'ic_launcher_{variant}'
        with Image.open(assets / f'logo/{logo_name}.png') as mark, \
                Image.open(assets / f'logo/{logo_name}_dark.png') as dark_mark:
            save_image(mark, assets / f'logo/ico/app_icon{suffix}.ico', sizes=sizes)
            if variant == 'chibi':
                save_image(mark, root / 'windows/runner/resources/app_icon.ico', sizes=sizes)
            save_image(dark_mark, assets / f'logo/ico/app_icon{suffix}_dark.ico', sizes=sizes)
            for path in density_paths:
                with Image.open(path) as previous:
                    size = previous.size
                save_image(mark.resize(size, Image.Resampling.LANCZOS),
                           path.with_name(f'{launcher}.png'), optimize=True)
                dark_path = resource / path.parent.name.replace('mipmap-', 'mipmap-night-', 1) / f'{launcher}.png'
                dark_path.parent.mkdir(exist_ok=True)
                save_image(dark_mark.resize(size, Image.Resampling.LANCZOS), dark_path, optimize=True)
    with Image.open(assets / 'logo/logo_chibi.png') as mark, \
            Image.open(assets / 'logo/logo_chibi_dark.png') as dark_mark:
        for path in resource.glob('drawable-*/splash.png'):
            with Image.open(path) as previous:
                size = previous.size
            sprite = dark_mark if 'night' in path.parent.name else mark
            splash = sprite.resize(size, Image.Resampling.LANCZOS)
            save_image(splash, path, optimize=True)


def fit_sprite(source, size, margin=0.04):
    with Image.open(source) as original:
        image = original.convert('RGBA')
        bounds = image.getchannel('A').point(lambda alpha: 255 if alpha > 8 else 0).getbbox()
        image = image.crop(bounds)
    extent = (round(size[0] * (1 - 2 * margin)), round(size[1] * (1 - 2 * margin)))
    image.thumbnail(extent, Image.Resampling.LANCZOS)
    result = Image.new('RGBA', size)
    result.alpha_composite(image, ((size[0] - image.width) // 2, (size[1] - image.height) // 2))
    return result


def export_coin_artwork(root, assets, font):
    raster = root / 'tool/artwork/raster'
    destination = assets / 'paycoins'
    for name, source, size in [
        ('ic_pay_coins_box', 'coin-box', (306, 306)),
    ]:
        save_image(fit_sprite(raster / f'{source}.png', size), destination / f'{name}.png', optimize=True)

    text_font = ImageFont.truetype(str(font), 34)
    for count, size in [(1, (129, 192)), (2, (183, 192))]:
        image = Image.new('RGBA', size)
        if count == 1:
            image.alpha_composite(fit_sprite(raster / 'coin.png', (122, 132)), (3, 2))
        else:
            image.alpha_composite(fit_sprite(raster / 'coin.png', (117, 129)), (0, 14))
            image.alpha_composite(fit_sprite(raster / 'coin.png', (122, 132)), (60, 0))
        ImageDraw.Draw(image).text(
            (size[0] / 2, 158), str(count), font=text_font,
            fill='#F4E8D2', anchor='mm', stroke_width=1, stroke_fill='#756143',
        )
        word = 'one' if count == 1 else 'two'
        save_image(image, destination / f'ic_coins_{word}.png', optimize=True)


def bars(phase, size=(36, 36), color='#F5F3EF'):
    scale = 4
    image = Image.new('RGBA', (size[0] * scale, size[1] * scale))
    draw = ImageDraw.Draw(image)
    for i in range(3):
        height = 10 + 14 * (0.5 + 0.5 * math.sin(phase - i * 1.7))
        x = 7 + i * 9
        draw.rounded_rectangle(
            (x * scale, (29 - height) * scale, (x + 5) * scale, 29 * scale),
            radius=2 * scale,
            fill=color,
        )
    return image.resize(size, Image.Resampling.LANCZOS)


def gif_frame(image):
    # GIF 的透明索引统一为 0，整帧替换，避免动画尾迹。
    palette = image.convert('RGB').quantize(colors=255)
    result = Image.new('P', image.size, 0)
    result.putpalette([0, 0, 0] + palette.getpalette()[:765])
    result.putdata(
        [
            p + 1 if alpha >= 128 else 0
            for p, alpha in zip(palette.tobytes(), image.getchannel('A').tobytes())
        ]
    )
    return result


def export_animations(assets, font):
    frames = [bars(i * math.tau / 24) for i in range(24)]
    frames[0].save(assets / 'live.png', optimize=True)
    chart = [gif_frame(frame) for frame in frames]
    chart[0].save(
        assets / 'live.gif',
        save_all=True,
        append_images=chart[1:],
        duration=50,
        loop=0,
        transparency=0,
        disposal=2,
        optimize=False,
    )
    badge = []
    text_font = ImageFont.truetype(str(font), 96)
    for frame in frames:
        image = Image.new('RGBA', (540, 168))
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((0, 0, 539, 167), radius=27, fill='#A96E75')
        image.alpha_composite(
            frame.resize((120, 120), Image.Resampling.NEAREST), (16, 24)
        )
        draw.text((144, 77), '直播中', font=text_font, fill='#FAF6F2', anchor='lm')
        badge.append(gif_frame(image.resize((135, 42), Image.Resampling.LANCZOS)))
    badge[0].save(
        assets / 'live/live.gif',
        save_all=True,
        append_images=badge[1:],
        duration=50,
        loop=0,
        transparency=0,
        disposal=2,
        optimize=False,
    )

    spinner = []
    for frame in range(24):
        image = Image.new('RGBA', (288, 288))
        draw = ImageDraw.Draw(image)
        # 长短双弧围绕播放三角转动，长度不同可保持循环中的运动方向清晰。
        start = frame * 15
        draw.arc((43, 43, 245, 245), start=start, end=start + 215, fill=(255, 255, 255, 240), width=14)
        draw.arc((62, 62, 226, 226), start=start + 240, end=start + 300, fill=(255, 255, 255, 115), width=7)
        draw.rounded_rectangle((69, 82, 219, 206), radius=34, outline=(255, 255, 255, 50), width=3)
        draw.polygon([(125, 113), (125, 179), (179, 146)], fill=(255, 255, 255, 230))
        spinner.append(image.resize((72, 72), Image.Resampling.LANCZOS))
    spinner[0].save(
        assets / 'loading.webp',
        save_all=True,
        append_images=spinner[1:],
        duration=50,
        loop=0,
        lossless=True,
        method=6,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icons-only', action='store_true', help='仅导出应用图标和启动图')
    parser.add_argument("--live", type=Path, help="imagegen 直播背景原稿")
    parser.add_argument("--trending", type=Path, help="imagegen 热搜背景原稿")
    parser.add_argument(
        "--font",
        type=Path,
        default=Path('C:/Windows/Fonts/msyh.ttc'),
        help="直播徽章使用的中文字体",
    )
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[2]
    assets = root / "assets/images"
    export_brand_artwork(root, assets)
    export_platform_icons(root, assets)
    if args.icons_only:
        return
    export_animations(assets, args.font)
    export_coin_artwork(root, assets, args.font)
    export_coin_motion(root, assets, gif_frame, save_image)

    with Image.open(root / "build/asset-refresh/avatar.png") as avatar:
        avatar.convert("RGB").save(
            assets / "noface.jpeg", quality=95, subsampling=0, optimize=True
        )
    with Image.open(root / "build/asset-refresh/avatar_dark.png") as avatar:
        save_image(avatar.convert('RGB'), assets / 'noface_dark.jpeg',
                   quality=95, subsampling=0, optimize=True)

    for source, destination, size in [
        (args.live, assets / "live/default_bg.webp", (1125, 2436)),
        (args.trending, assets / "trending_banner.png", (1125, 528)),
    ]:
        if source is None:
            continue
        with Image.open(source) as image:
            output = ImageOps.fit(image.convert("RGB"), size, Image.Resampling.LANCZOS)
            if destination.suffix == ".webp":
                output.save(destination, quality=85, method=6)
            else:
                output.save(destination, optimize=True)


if __name__ == "__main__":
    main()
