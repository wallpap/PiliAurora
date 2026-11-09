"""真实 libmpv 分片音轨回退回归；固定合成输入，不访问网络或扬声器。"""

import argparse
import collections
import ctypes as c
import json
from pathlib import Path
import time

from native_media_smoke import Event, LogMessage


def run(library: Path, fixtures: Path) -> dict:
    mpv = c.CDLL(str(library.resolve(strict=True)))
    mpv.mpv_create.restype = c.c_void_p
    mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    mpv.mpv_initialize.argtypes = [c.c_void_p]
    mpv.mpv_command_async.argtypes = [c.c_void_p, c.c_uint64, c.POINTER(c.c_char_p)]
    mpv.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    mpv.mpv_wait_event.restype = c.POINTER(Event)
    mpv.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_get_property_string.restype = c.c_void_p
    mpv.mpv_free.argtypes = [c.c_void_p]
    mpv.mpv_request_log_messages.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = mpv.mpv_create()
    if not handle:
        raise RuntimeError('mpv_create failed')
    errors = collections.Counter()
    resets = 0
    serial = 0

    def prop(name):
        pointer = mpv.mpv_get_property_string(handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode('utf-8')
        finally:
            mpv.mpv_free(pointer)

    def command(*args):
        nonlocal serial
        serial += 1
        argv = (c.c_char_p * (len(args) + 1))(
            *(arg.encode('utf-8') for arg in args), None)
        if mpv.mpv_command_async(handle, serial, argv) < 0:
            raise RuntimeError(f'{args[0]} submission failed')
        return serial

    def event(timeout=.02):
        nonlocal resets
        value = mpv.mpv_wait_event(handle, timeout).contents
        if value.event_id == 2:
            log = c.cast(value.data, c.POINTER(LogMessage)).contents
            message = log.text.decode('utf-8').strip()
            if log.level in (b'error', b'fatal'):
                # 只保存分类，避免未来替换输入时把媒体地址写入报告。
                errors[log.prefix.decode('utf-8')] += 1
            if 'Reset playback due to audio timestamp reset.' in message:
                resets += 1
        return value

    def wait_restart(request):
        acknowledged = started = restarted = False
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            value = event()
            if value.event_id == 5 and value.reply_userdata == request:
                if value.error < 0:
                    raise RuntimeError('native command failed')
                acknowledged = True
            if value.event_id == 20:
                started = True
            if value.event_id == 21:
                restarted = True
            if acknowledged and started and restarted and prop('seeking') == 'no':
                return time.monotonic()
        raise RuntimeError('native seek completion timeout')

    def play_for(seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            event(min(.02, max(0, deadline - time.monotonic())))

    try:
        options = {
            'config': 'no', 'vo': 'null', 'ao': 'null', 'hwdec': 'no',
            'terminal': 'no', 'cache': 'yes', 'cache-secs': '16',
            'demuxer-max-bytes': '4MiB', 'demuxer-max-back-bytes': '4MiB',
            'start': '16',
            'audio-files': str((fixtures / 'backward-seek-aac.m4s').resolve(strict=True)),
        }
        for name, value in options.items():
            if mpv.mpv_set_option_string(handle, name.encode(), value.encode()) < 0:
                raise RuntimeError(f'option {name} failed')
        if mpv.mpv_initialize(handle) < 0:
            raise RuntimeError('mpv_initialize failed')
        if mpv.mpv_request_log_messages(handle, b'warn') < 0:
            raise RuntimeError('native log subscription failed')
        command('loadfile', str((fixtures / 'backward-seek-av1.m4s').resolve(strict=True)))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if event().event_id == 21 and prop('seeking') == 'no':
                break
        else:
            raise RuntimeError('initial playback timeout')
        play_for(2)
        # 必须先从后面的分片开始，再回到尚未加载过的较早分片。
        # 从片头正向 seek 或仅在缓存内移动无法捕获本次回归。
        target = 8.133
        restarted_at = wait_restart(command('seek', str(target), 'absolute'))
        play_for(2)
        elapsed = time.monotonic() - restarted_at
        position = float(prop('time-pos') or 'nan')
        audio = float(prop('audio-pts') or 'nan')
        result = {
            'mpv': prop('mpv-version'), 'ffmpeg': prop('ffmpeg-version'),
            'target': target, 'elapsed': elapsed, 'position': position,
            'audioPts': audio, 'timestampResets': resets,
            'nativeErrors': dict(errors),
            'passed': (abs(position - target - elapsed) < .6
                       and abs(position - audio) < .25
                       and not resets and not errors),
        }
        return result
    finally:
        mpv.mpv_terminate_destroy(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--rounds', type=int, default=3)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error('--rounds must be positive')
    fixtures = Path(__file__).with_name('fixtures')
    for _ in range(args.rounds):
        result = run(args.library, fixtures)
        print(json.dumps(result), flush=True)
        if not result['passed']:
            raise SystemExit('FAIL: fragmented external audio backward seek')


if __name__ == '__main__':
    main()
