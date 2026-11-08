#!/usr/bin/env python3
"""以暂停逐帧的真实 libmpv/ANGLE 输出，对比 SDR BT.709 软件参考帧。"""
import argparse
import ctypes as c
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time

from PIL import Image, ImageChops, ImageDraw, ImageStat


class Param(c.Structure):
    _fields_ = [('type', c.c_int), ('data', c.c_void_p)]


class FBO(c.Structure):
    _fields_ = [('fbo', c.c_int), ('w', c.c_int), ('h', c.c_int), ('format', c.c_int)]


class FrameInfo(c.Structure):
    _fields_ = [('flags', c.c_uint64), ('target_time', c.c_int64)]


class Event(c.Structure):
    _fields_ = [('id', c.c_int), ('error', c.c_int), ('userdata', c.c_uint64), ('data', c.c_void_p)]


class Log(c.Structure):
    _fields_ = [('prefix', c.c_char_p), ('level', c.c_char_p), ('text', c.c_char_p)]


def bind(lib, name, restype, *args):
    function = getattr(lib, name)
    function.restype, function.argtypes = restype, list(args)
    return function


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def rendering_options(root):
    source = (root / 'third_party/media_kit/lib/src/player/native/player/real.dart').read_text(encoding='utf-8')
    properties = source.split('final properties = <String, String>{', 1)[1].split('\n    };', 1)[0]
    options = {}
    for key in ('scale', 'dscale', 'dither', 'correct-downscaling',
                'linear-downscaling', 'sigmoid-upscaling', 'hdr-compute-peak'):
        match = re.search(r"'" + re.escape(key) + r"': '([^']+)'", properties)
        require(match, f'Production rendering option missing: {key}')
        options[key] = match[1]
    creation = (root / 'lib/plugin/pl_player/utils/native_video_options.dart').read_text(encoding='utf-8')
    windows = dict(re.findall(r"if \(Platform.isWindows\) '([^']+)': '([^']+)'", creation))
    require('gpu-dumb-mode' in windows, 'Production Windows rendering options not found')
    options.update(windows)
    shader = re.search(r"'glsl-shaders': AssetUtils.tryGetPath\(\s*'([^']+)'", creation)
    if shader:
        shader_path = root / shader[1]
        require(shader_path.is_file(), f'Production shader missing: {shader_path}')
        options['glsl-shaders'] = str(shader_path.resolve())
    return options


def mean_error(image):
    return sum(ImageStat.Stat(image).mean) / len(image.getbands())


def green_rows(image):
    width, height = image.size
    data = image.convert('RGB').tobytes()
    rows = 0
    for y in range(height - 1, -1, -1):
        row = data[y * width * 3:(y + 1) * width * 3]
        green = sum(row[x] < 10 and 40 < row[x + 1] < 100 and row[x + 2] < 10
                    for x in range(0, len(row), 3))
        if green / width <= 0.95:
            break
        rows += 1
    return rows


def image_metrics(actual, reference):
    require(actual.size == reference.size, 'Reference dimensions differ')
    difference = ImageChops.difference(actual.convert('RGB'), reference.convert('RGB'))
    histogram = difference.histogram()
    count = actual.width * actual.height * 3
    mse = sum((i % 256) ** 2 * n for i, n in enumerate(histogram)) / count
    bands = difference.split()
    maximum = ImageChops.lighter(ImageChops.lighter(bands[0], bands[1]), bands[2])
    bad = sum(maximum.histogram()[33:]) / (actual.width * actual.height)
    # 整帧均值会掩盖一行绿条或局部黑屏，另检查最坏行及 32×32 区域。
    row_errors = [mean_error(difference.crop((0, y, actual.width, y + 1))) for y in range(actual.height)]
    row_mae = max(row_errors)
    tile_mae = max(mean_error(difference.crop((x, y, min(x + 32, actual.width), min(y + 32, actual.height))))
                   for y in range(0, actual.height, 32) for x in range(0, actual.width, 32))
    black = lambda image: sum(image.convert('L').histogram()[:8]) / (image.width * image.height)
    return {'mae': mean_error(difference), 'psnrDb': 10 * math.log10(255 ** 2 / mse) if mse else None,
            'badPixelRatio': bad, 'maxRowMae': row_mae, 'worstRow': row_errors.index(row_mae),
            'rowsAboveMae12': [y for y, error in enumerate(row_errors) if error > 12], 'maxTileMae': tile_mae,
            'blackPixelRatio': black(actual), 'referenceBlackPixelRatio': black(reference),
            'greenRows': green_rows(actual), 'referenceGreenRows': green_rows(reference)}


def quality_failures(metrics):
    # 固定 SDR、同帧同尺寸基准的容差，不适用于任意 HDR 色调映射链路。
    limits = {'mae': 3.0, 'badPixelRatio': 0.01, 'maxRowMae': 12.0, 'maxTileMae': 12.0}
    errors = [f'{key}={metrics[key]:.4f} exceeds {limit}' for key, limit in limits.items() if metrics[key] > limit]
    if metrics['psnrDb'] is not None and metrics['psnrDb'] < 30:
        errors.append(f'PSNR={metrics["psnrDb"]:.2f} dB below 30')
    if metrics['blackPixelRatio'] - metrics['referenceBlackPixelRatio'] > 0.02:
        errors.append('Unexpected black pixels')
    if metrics['greenRows'] > metrics['referenceGreenRows']:
        errors.append('Unexpected bottom green strip')
    return errors


def frozen_frame(actual, previous, reference, previous_reference):
    return (mean_error(ImageChops.difference(actual, previous)) < 0.01 and
            mean_error(ImageChops.difference(reference, previous_reference)) > 1.0)


def match_frame(pts, timestamps):
    index = min(range(len(timestamps)), key=lambda i: abs(timestamps[i] - pts))
    gaps = [abs(timestamps[index] - timestamps[i]) for i in (index - 1, index + 1)
            if 0 <= i < len(timestamps)]
    tolerance = min(gaps) / 4 if gaps else 0.001
    require(abs(timestamps[index] - pts) <= max(0.0001, tolerance), f'Unaligned video PTS {pts}')
    return index


def is_new_frame(flags):
    return bool(flags & 1 and not flags & 6)


def reference_frames(args):
    probe = subprocess.run([args.ffprobe, '-v', 'error', '-select_streams', 'v:0',
                            '-read_intervals', f'%+#{args.frames + 16}', '-show_frames', '-show_streams',
                            '-show_entries', 'stream=codec_name,width,height,pix_fmt,sample_aspect_ratio,color_range,color_space,color_transfer,color_primaries,chroma_location,start_time:stream_side_data=rotation:frame=best_effort_timestamp_time',
                            '-of', 'json', str(args.video)], check=True, capture_output=True, text=True, timeout=30)
    info = json.loads(probe.stdout)
    stream = info['streams'][0]
    require(stream.get('pix_fmt') == 'yuv420p' and
            all(stream.get(key) == 'bt709' for key in ('color_space', 'color_transfer', 'color_primaries')),
            'Quality reference requires tagged SDR BT.709 8-bit yuv420p input')
    require(stream.get('sample_aspect_ratio', '1:1') in ('1:1', 'N/A'), 'Non-square pixels are not supported')
    require(not any(d.get('rotation', 0) for d in stream.get('side_data_list', [])), 'Rotated input is not supported')
    require(stream.get('color_range') in ('tv', 'pc'), 'Reference requires an explicit color range')
    args.width = args.width or stream['width']
    args.height = args.height or stream['height']
    require(args.width * stream['height'] == args.height * stream['width'], 'Output must preserve source aspect ratio')
    timestamps = [float(f['best_effort_timestamp_time']) for f in info['frames'] if 'best_effort_timestamp_time' in f]
    require(len(timestamps) >= args.frames, 'Insufficient reference frames')
    timestamps = timestamps[:args.frames]
    require(all(b > a for a, b in zip(timestamps, timestamps[1:])), 'Reference PTS must be strictly increasing')
    indices = sorted(set(range(0, args.frames, args.sample_every)) | {args.frames - 1})
    select = '+'.join(f'eq(n,{i})' for i in indices)
    chroma = stream.get('chroma_location', 'left')
    positions = {'left': (0, 128), 'center': (128, 128), 'topleft': (0, 0),
                 'top': (128, 0), 'bottomleft': (0, 256), 'bottom': (128, 256)}
    require(chroma in positions, f'Unsupported chroma location: {chroma}')
    horizontal, vertical = positions[chroma]
    # swscale 的快速 RGB 转换与 GPU 的逐像素色度插值不同，需固定位置和完整插值。
    filters = (f"select='{select}',scale={args.width}:{args.height}:flags=bilinear+accurate_rnd+full_chroma_int:"
               f"in_color_matrix=bt709:in_range={stream['color_range']}:out_range=full:"
               f'in_h_chr_pos={horizontal}:in_v_chr_pos={vertical},format=rgb24')
    command = [args.ffmpeg, '-v', 'error', '-hwaccel', 'none', '-noautorotate', '-i', str(args.video),
               '-an', '-sn', '-vf', filters, '-frames:v', str(len(indices)), '-fps_mode', 'passthrough',
               '-f', 'rawvideo', 'pipe:1']
    decoded = subprocess.run(command, check=True, capture_output=True, timeout=45)
    size = args.width * args.height * 3
    require(len(decoded.stdout) == size * len(indices), 'Incomplete software reference output')
    references = {index: Image.frombytes('RGB', (args.width, args.height), decoded.stdout[n * size:(n + 1) * size])
                  for n, index in enumerate(indices)}
    version = subprocess.run([args.ffmpeg, '-version'], check=True, capture_output=True, text=True, timeout=10).stdout.splitlines()[0]
    return timestamps, references, {'stream': stream, 'effectiveChromaLocation': chroma, 'ffmpeg': version, 'filter': filters,
                                    'sampleIndices': indices, 'thresholds': {'mae': 3, 'minPsnrDb': 30,
                                    'badPixelRatio': 0.01, 'maxRowMae': 12, 'maxTileMae': 12}}


def contact_sheet(pairs, path):
    thumb_width = 480
    thumb_height = round(thumb_width * pairs[0][1].height / pairs[0][1].width)
    sheet = Image.new('RGB', (thumb_width * 3, (thumb_height + 26) * len(pairs)), '#202020')
    draw = ImageDraw.Draw(sheet)
    for row, (pts, actual, reference) in enumerate(pairs):
        difference = ImageChops.difference(actual, reference).point(lambda x: min(255, x * 4))
        for column, (title, image) in enumerate((('ANGLE', actual), ('FFmpeg SW', reference), ('Difference x4', difference))):
            x, y = column * thumb_width, row * (thumb_height + 26)
            draw.text((x + 5, y + 5), f'{title}  PTS {pts:.6f}', fill='white')
            sheet.paste(image.resize((thumb_width, thumb_height)), (x, y + 26))
    sheet.save(path)


def capture(args, options, timestamps, references, result, name):
    dll_directory = os.add_dll_directory(str(args.library_dir))
    display = surface = context = player = None
    render = c.c_void_p()
    egl = gl = mpv = None
    pairs = []
    try:
        egl = c.WinDLL(str(args.library_dir / 'libEGL.dll'))
        gl = c.WinDLL(str(args.library_dir / 'libGLESv2.dll'))
        mpv = c.CDLL(str(args.library_dir / 'libmpv-2.dll'))
        ptr = c.c_void_p
        get_proc = bind(egl, 'eglGetProcAddress', ptr, c.c_char_p)
        platform_address = get_proc(b'eglGetPlatformDisplayEXT')
        require(platform_address, 'EGL platform display extension unavailable')
        platform_display = c.WINFUNCTYPE(ptr, c.c_uint, ptr, c.POINTER(c.c_int))(platform_address)
        display = platform_display(0x3202, None, (c.c_int * 3)(0x3203, 0x3208, 0x3038))

        def egl_check(status, operation):
            require(status, f'{operation} failed: EGL 0x{bind(egl, "eglGetError", c.c_uint)():04x}' if not status else '')

        egl_check(bind(egl, 'eglInitialize', c.c_uint, ptr, ptr, ptr)(display, None, None), 'eglInitialize')
        config, count = ptr(), c.c_int()
        attributes = (c.c_int * 13)(0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3033, 1, 0x3040, 4, 0x3038)
        egl_check(bind(egl, 'eglChooseConfig', c.c_uint, ptr, ptr, ptr, c.c_int, ptr)(display, attributes, c.byref(config), 1, c.byref(count)), 'eglChooseConfig')
        require(count.value, 'EGL config unavailable')
        context = bind(egl, 'eglCreateContext', ptr, ptr, ptr, ptr, ptr)(display, config, None, (c.c_int * 3)(0x3098, 2, 0x3038))
        surface = bind(egl, 'eglCreatePbufferSurface', ptr, ptr, ptr, ptr)(display, config, (c.c_int * 5)(0x3057, args.width, 0x3056, args.height, 0x3038))
        egl_check(surface and context, 'EGL surface/context creation')
        make_current = bind(egl, 'eglMakeCurrent', c.c_uint, ptr, ptr, ptr, ptr)
        egl_check(make_current(display, surface, surface, context), 'eglMakeCurrent')
        renderer = bind(gl, 'glGetString', c.c_char_p, c.c_uint)(0x1F01)
        require(renderer, 'OpenGL renderer string unavailable')
        result['renderer'] = renderer.decode()
        player = bind(mpv, 'mpv_create', ptr)()
        require(player, 'mpv_create failed')
        option = bind(mpv, 'mpv_set_option_string', c.c_int, ptr, c.c_char_p, c.c_char_p)
        values = {'vo': 'libmpv', 'hwdec': args.decoder, 'ao': 'null', 'audio': 'no', 'pause': 'yes',
                  'terminal': 'no', 'config': 'no', 'rebase-start-time': 'no', 'video-sync': 'audio', **options}
        for key, value in values.items():
            require(option(player, key.encode(), value.encode()) >= 0, f'Invalid mpv option: {key}')
        require(bind(mpv, 'mpv_initialize', c.c_int, ptr)(player) >= 0, 'mpv_initialize failed')
        bind(mpv, 'mpv_request_log_messages', c.c_int, ptr, c.c_char_p)(player, b'debug')
        get_property = bind(mpv, 'mpv_get_property_string', ptr, ptr, c.c_char_p)
        free = bind(mpv, 'mpv_free', None, ptr)

        def property_string(name):
            pointer = get_property(player, name.encode())
            try:
                return c.string_at(pointer).decode() if pointer else None
            finally:
                if pointer:
                    free(pointer)

        result['mpv'] = property_string('mpv-version')
        getproc_type = c.CFUNCTYPE(ptr, ptr, c.c_char_p)
        callback = getproc_type(lambda _, name: get_proc(name))

        class Init(c.Structure):
            _fields_ = [('get_proc', getproc_type), ('ctx', ptr)]

        init, api = Init(callback, None), c.create_string_buffer(b'opengl')
        params = (Param * 3)(Param(1, c.cast(api, ptr)), Param(2, c.cast(c.pointer(init), ptr)), Param(0, None))
        require(bind(mpv, 'mpv_render_context_create', c.c_int, ptr, ptr, ptr)(c.byref(render), player, params) >= 0, 'Render context creation failed')
        command = bind(mpv, 'mpv_command_async', c.c_int, ptr, c.c_uint64, ptr)

        def send(*values):
            arguments = (c.c_char_p * (len(values) + 1))(*(v.encode() for v in values), None)
            require(command(player, 1, arguments) >= 0, f'mpv command failed: {values[0]}')

        send('loadfile', str(args.video), 'replace')
        wait = bind(mpv, 'mpv_wait_event', c.POINTER(Event), ptr, c.c_double)
        update = bind(mpv, 'mpv_render_context_update', c.c_uint64, ptr)
        get_info = bind(mpv, 'mpv_render_context_get_info', c.c_int, ptr, Param)
        draw = bind(mpv, 'mpv_render_context_render', c.c_int, ptr, ptr)
        read = bind(gl, 'glReadPixels', None, c.c_int, c.c_int, c.c_int, c.c_int, c.c_uint, c.c_uint, ptr)
        finish = bind(gl, 'glFinish', None)
        gl_error = bind(gl, 'glGetError', c.c_uint)
        pixels = (c.c_ubyte * (args.width * args.height * 4))()
        fbo = FBO(0, args.width, args.height, 0)
        draw_params = (Param * 2)(Param(3, c.cast(c.pointer(fbo), ptr)), Param(0, None))
        previous_index = -1
        frame_pending = False
        pending_flags = 0
        start = time.monotonic()
        expected = args.expect_decoder
        if expected is None and ',' not in args.decoder and not args.decoder.startswith('auto'):
            expected = args.decoder
        result['expectedDecoder'] = expected
        while result['frames'] < args.frames and time.monotonic() - start < args.timeout:
            while True:
                event = wait(player, 0).contents
                if event.id == 0:
                    break
                if event.id == 2:
                    log = c.cast(event.data, c.POINTER(Log)).contents
                    message = (log.text or b'').decode(errors='replace').strip()
                    if any(text in message for text in ('hardware decoding', 'Decoder format:', 'dumb mode', 'Failed to create EGL surface')):
                        if len(result['messages']) < 100:
                            result['messages'].append(message)
                if event.id == 8:
                    require(event.error >= 0, f'mpv asynchronous command error: {event.error}')
            if update(render) & 1:
                info = FrameInfo()
                require(get_info(render, Param(11, c.cast(c.pointer(info), ptr))) >= 0, 'Frame info unavailable')
                require(draw(render, draw_params) >= 0, 'mpv render failed')
                finish()
                require(gl_error() == 0, 'OpenGL render error')
                # UPDATE_FRAME 也可能只是旧画面重绘；仅接受 PRESENT 且非 REDRAW/REPEAT。
                # 在真正新帧画完前不读取时间戳，防止时钟先行造成一帧错配。
                if is_new_frame(info.flags):
                    frame_pending = True
                    pending_flags = info.flags
            if frame_pending and property_string('pause') == 'yes' and property_string('seeking') == 'no':
                # 无音轨、暂停逐帧时 time-pos 对应当前视频显示时间。
                pts_string = property_string('time-pos')
                if pts_string is None:
                    continue
                pts = float(pts_string)
                index = match_frame(pts, timestamps)
                if index <= previous_index:
                    time.sleep(0.002)
                    continue
                require(index == previous_index + 1, f'Frame-step skipped reference frame: {previous_index} -> {index}')
                actual_decoder = property_string('hwdec-current')
                require(actual_decoder is not None, 'Missing actual decoder')
                result['lastActualDecoder'] = actual_decoder
                actual_chroma = property_string('video-params/chroma-location')
                actual_chroma = {'mpeg2/4/h264': 'left', 'mpeg1/jpeg': 'center'}.get(actual_chroma, actual_chroma)
                require(actual_chroma == result['reference']['effectiveChromaLocation'],
                        f'Chroma location mismatch: {actual_chroma}')
                if expected is not None:
                    require(actual_decoder == expected, f'Decoder mismatch: expected {expected}, actual {actual_decoder}')
                result['decoderByFrame'].append(actual_decoder)
                result['newFrameFlags'].append(pending_flags)
                result['pts'].append(pts)
                result['frames'] += 1
                previous_index = index
                frame_pending = False
                if index in references:
                    read(0, 0, args.width, args.height, 0x1908, 0x1401, pixels)
                    require(gl_error() == 0, 'OpenGL pixel readback error')
                    # mpv 默认输出翻转抵消 glReadPixels 的底部起始行序。
                    actual = Image.frombytes('RGBA', (args.width, args.height), bytes(pixels)).convert('RGB')
                    reference = references[index]
                    metrics = image_metrics(actual, reference)
                    errors = quality_failures(metrics)
                    if pairs and frozen_frame(actual, pairs[-1][1], reference, pairs[-1][2]):
                        errors.append('Frozen pixels despite changing reference')
                    result['samples'].append({'index': index, 'pts': pts, 'referencePts': timestamps[index],
                                              'actualDecoder': actual_decoder, **metrics, 'failures': errors})
                    result['failures'].extend(f'frame {index}: {error}' for error in errors)
                    actual.save(args.output_dir / f'{name}-frame-{index:04d}.png')
                    pairs.append((pts, actual, reference))
                if result['frames'] < args.frames:
                    send('frame-step')
            time.sleep(0.002)
        result['elapsedSeconds'] = time.monotonic() - start
        require(result['frames'] == args.frames, f'Insufficient distinct frames: {result["frames"]}/{args.frames}')
    finally:
        if mpv and render:
            bind(mpv, 'mpv_render_context_free', None, c.c_void_p)(render)
        if mpv and player:
            bind(mpv, 'mpv_terminate_destroy', None, c.c_void_p)(player)
        if egl and display:
            bind(egl, 'eglMakeCurrent', c.c_uint, c.c_void_p, c.c_void_p, c.c_void_p, c.c_void_p)(display, None, None, None)
            if surface:
                bind(egl, 'eglDestroySurface', c.c_uint, c.c_void_p, c.c_void_p)(display, surface)
            if context:
                bind(egl, 'eglDestroyContext', c.c_uint, c.c_void_p, c.c_void_p)(display, context)
            bind(egl, 'eglTerminate', c.c_uint, c.c_void_p)(display)
        dll_directory.close()
        if pairs:
            contact_sheet(pairs, args.output_dir / f'{name}-comparison.png')


def main():
    root = Path(__file__).resolve().parents[3]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--video', type=Path, required=True)
    parser.add_argument('--library-dir', type=Path, default=root / 'build/windows/x64/runner/Release')
    parser.add_argument('--width', type=int)
    parser.add_argument('--height', type=int)
    parser.add_argument('--decoder', default='d3d11va')
    parser.add_argument('--expect-decoder', help='允许显式测试回退，例如 --decoder dxva2 --expect-decoder no')
    parser.add_argument('--frames', type=int, default=30)
    parser.add_argument('--sample-every', type=int, default=5)
    parser.add_argument('--timeout', type=float, default=20)
    parser.add_argument('--ffmpeg', default='ffmpeg')
    parser.add_argument('--ffprobe', default='ffprobe')
    parser.add_argument('--control-dumb-mode', choices=('yes', 'no', 'auto'))
    parser.add_argument('--control-disable-chroma-clamp', action='store_true', help='单独关闭生产色度边界修正，验证原始异常仍被检出')
    parser.add_argument('--output-dir', type=Path, default=root / 'build/windows-video-sampling')
    args = parser.parse_args()
    if args.frames < 2 or not 1 <= args.sample_every < args.frames or not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error('Require frames >= 2, 1 <= sample-every < frames and timeout > 0')
    if bool(args.width) != bool(args.height) or (args.width is not None and (args.width < 1 or args.height < 1)):
        parser.error('Provide both positive width and height, or neither')
    args.video, args.library_dir = args.video.resolve(), args.library_dir.resolve()
    if not args.video.is_file():
        parser.error('Local video file missing')
    args.output_dir.mkdir(parents=True, exist_ok=True)
    suffix = args.control_dumb_mode or 'production'
    if args.control_disable_chroma_clamp:
        suffix += '-no-chroma-clamp'
    name = re.sub(r'[^\w.-]', '_', f'{args.video.stem}-{args.decoder}-{suffix}')
    result = {'schema': 2, 'video': args.video.name, 'requestedDecoder': args.decoder, 'frames': 0,
              'pts': [], 'decoderByFrame': [], 'newFrameFlags': [], 'samples': [], 'messages': [], 'failures': [],
              'scope': 'Paused libmpv/ANGLE pixel readback; excludes Flutter texture import and screen presentation'}
    try:
        with args.video.open('rb') as video:
            result['videoSha256'] = hashlib.file_digest(video, 'sha256').hexdigest()
        options = rendering_options(root)
        if args.control_dumb_mode:
            options['gpu-dumb-mode'] = args.control_dumb_mode
        if args.control_disable_chroma_clamp:
            options.pop('glsl-shaders', None)
        result['options'] = options
        timestamps, references, result['reference'] = reference_frames(args)
        result['outputSize'] = [args.width, args.height]
        capture(args, options, timestamps, references, result, name)
    except (RuntimeError, OSError, ValueError, KeyError, IndexError, subprocess.SubprocessError) as error:
        result['failures'].append(str(error))
    observed = set(result['decoderByFrame'])
    if result.get('lastActualDecoder'):
        observed.add(result['lastActualDecoder'])
    result['actualDecoders'] = sorted(observed)
    result['softwareFallback'] = args.decoder != 'no' and 'no' in result['actualDecoders']
    result['passed'] = not result['failures']
    output = args.output_dir / f'{name}.json'
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
    print(json.dumps({'passed': result['passed'], 'frames': result['frames'], 'actualDecoders': result['actualDecoders'],
                      'failures': result['failures'], 'report': str(output)}, ensure_ascii=False))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
