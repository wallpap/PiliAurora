"""Windows libmpv：本地音轨断流、缓存内跳转与后台音轨重连的故障注入。"""

import argparse
import ctypes as c
import http.server
import json
import os
import re
import socket
import struct
import threading
import time
import wave
from datetime import datetime
from pathlib import Path

from native_media_smoke import Event, LogMessage


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True)
    parser.add_argument('--video', type=Path, required=True, help='至少20秒的本地连续视频')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    require(os.name == 'nt', '此探针使用Windows socket RST故障注入')
    video = args.video.resolve(strict=True)
    library = args.library.resolve(strict=True)
    root = Path(__file__).resolve().parents[3]
    output = args.output or root / 'build/native-audio-stream-recovery' / datetime.now().strftime('%Y%m%d-%H%M%S')
    output.mkdir(parents=True, exist_ok=False)
    audio = output / 'audio.wav'
    with wave.open(str(audio), 'wb') as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(8000)
        wav.writeframes(b'\0\0' * 8000 * 90)
    payload = audio.read_bytes()
    broken = True
    requests = []
    cut = 44 + 16000 * 4

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *unused):
            pass

        def do_GET(self):
            match = re.search(r'bytes=(\d+)-', self.headers.get('Range', ''))
            start = int(match[1]) if match else 0
            requests.append(dict(start=start, interrupted=broken))
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'audio/wav')
            self.send_header('Accept-Ranges', 'bytes')
            self.send_header('Content-Length', str(len(payload) - start))
            if match:
                self.send_header('Content-Range', f'bytes {start}-{len(payload)-1}/{len(payload)}')
            self.end_headers()
            if broken:
                self.wfile.write(payload[start:max(start, cut)])
                self.wfile.flush()
                time.sleep(.2)
                # Windows linger结构由两个short构成；RST产生curl接收失败。
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack('hh', 1, 0))
                self.connection.close()
                self.close_connection = True
            else:
                self.wfile.write(payload[start:])

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    mpv = c.CDLL(str(library))
    mpv.mpv_create.restype = c.c_void_p
    mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    mpv.mpv_initialize.argtypes = [c.c_void_p]
    mpv.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    mpv.mpv_wait_event.argtypes = [c.c_void_p, c.c_double]
    mpv.mpv_wait_event.restype = c.POINTER(Event)
    mpv.mpv_get_property_string.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_get_property_string.restype = c.c_void_p
    mpv.mpv_free.argtypes = [c.c_void_p]
    mpv.mpv_request_log_messages.argtypes = [c.c_void_p, c.c_char_p]
    mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = mpv.mpv_create()
    logs, rows = [], []

    def read(name):
        pointer = mpv.mpv_get_property_string(handle, name.encode())
        if not pointer:
            return None
        try:
            return c.string_at(pointer).decode('utf-8')
        finally:
            mpv.mpv_free(pointer)

    def command(*words):
        argv = (c.c_char_p * (len(words) + 1))(*(word.encode('utf-8') for word in words), None)
        require(mpv.mpv_command(handle, argv) >= 0, f'{words[0]} failed')

    def poll(seconds, label):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            event = mpv.mpv_wait_event(handle, .05).contents
            if event.event_id == 2:
                log = c.cast(event.data, c.POINTER(LogMessage)).contents
                prefix = log.prefix.decode()
                if log.level in (b'error', b'fatal') and prefix in ('curl', 'ffmpeg/demuxer', 'ad'):
                    text = re.sub(r'https?://\S+', '<URL>', log.text.decode().strip())
                    logs.append(dict(prefix=prefix, message=text))
        sample = dict(label=label, position=float(read('time-pos') or 0), audioPts=read('audio-pts'),
                      paused=read('pause'), buffering=read('paused-for-cache'), requests=len(requests))
        rows.append(sample)
        print(json.dumps(sample), flush=True)
        return sample

    passed = False
    try:
        require(bool(handle), 'mpv_create failed')
        for key, value in {
            'config': 'no', 'vo': 'null', 'ao': 'null', 'hwdec': 'no', 'terminal': 'no',
            'curl-enabled': 'yes', 'curl-max-retries': '0', 'curl-buffer-size': '131072',
            'cache': 'yes', 'demuxer-readahead-secs': '10', 'network-timeout': '1',
        }.items():
            require(mpv.mpv_set_option_string(handle, key.encode(), value.encode()) >= 0, f'option {key} failed')
        require(mpv.mpv_initialize(handle) >= 0, 'mpv_initialize failed')
        require(mpv.mpv_request_log_messages(handle, b'warn') >= 0, 'log subscription failed')
        uri = f'http://127.0.0.1:{server.server_port}/audio.wav'
        command('loadfile', str(video), 'replace', '0', f'audio-files-append=%{len(uri.encode())}%{uri}')
        initial = poll(2, 'playing')
        require(initial['audioPts'] is not None, '音频未正常开始，故障夹具无效')
        poll(4, 'audio-cache-exhausted')
        stalled = poll(2, 'audio-stalled')
        require(stalled['audioPts'] is None and stalled['position'] > initial['position'] + 4,
                '未复现音频耗尽但视频时钟继续')
        require(stalled['buffering'] == 'no', '整体缓冲状态与目标场景不同')
        command('seek', str(stalled['position'] + 2), 'absolute+exact')
        poll(1, 'after-cached-seek')
        silent = poll(2, 'cached-seek-still-silent')
        require(silent['audioPts'] is None and silent['position'] > stalled['position'] + 2,
                '未复现向右跳转后依旧无声')
        require(silent['requests'] == stalled['requests'], '跳转重新发起网络读取，未复现缓存内跳转')
        broken = False
        track = next(t for t in json.loads(read('track-list')) if t['type'] == 'audio' and t.get('external'))
        command('audio-reload', str(track['id']))
        restored = poll(2, 'audio-reloaded')
        require(restored['audioPts'] is not None and float(restored['audioPts']) > silent['position'] + 1,
                'audio-reload未恢复音频时钟')
        require(restored['position'] > silent['position'] + 1 and restored['paused'] == 'no',
                '重连改变了视频位置或暂停状态')
        require(restored['requests'] > silent['requests'], '音轨重连未创建新连接')
        require(any(log['prefix'] == 'curl' and log['message'].startswith('transfer failed:') for log in logs),
                '未记录预期curl传输失败')
        passed = True
    finally:
        if handle:
            mpv.mpv_terminate_destroy(handle)
        server.shutdown()
        server.server_close()
        (output / 'summary.json').write_text(json.dumps(dict(passed=passed, rows=rows, errors=logs, requests=requests), indent=2), encoding='utf-8')
    print(json.dumps(dict(passed=passed, report=str(output / 'summary.json'))))


if __name__ == '__main__':
    main()
