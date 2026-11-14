"""Exercise real libmpv cache limits and seek reuse over loopback HTTP."""
import argparse
import ctypes as c
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
from pathlib import Path
import re
import threading
import time


class Node(c.Structure):
    pass


class NodeList(c.Structure):
    _fields_ = [('num', c.c_int), ('values', c.POINTER(Node)),
                ('keys', c.POINTER(c.c_char_p))]


class Value(c.Union):
    _fields_ = [('string', c.c_char_p), ('flag', c.c_int),
                ('integer', c.c_int64), ('number', c.c_double),
                ('list', c.POINTER(NodeList))]


Node._fields_ = [('u', Value), ('format', c.c_int)]


def decode(node):
    if node.format == 1:
        return node.u.string.decode()
    if node.format == 3:
        return bool(node.u.flag)
    if node.format == 4:
        return node.u.integer
    if node.format == 5:
        return node.u.number
    if node.format in (7, 8):
        items = node.u.list.contents
        values = [decode(items.values[i]) for i in range(items.num)]
        return (dict(zip((items.keys[i].decode() for i in range(items.num)), values))
                if node.format == 8 else values)
    return None


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', required=True, type=Path)
    p.add_argument('--source', required=True, type=Path)
    p.add_argument('--options', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--seconds', type=float, default=8)
    p.add_argument('--min-headroom', type=float, default=2)
    args = p.parse_args()
    if (not math.isfinite(args.seconds) or not math.isfinite(args.min_headroom) or
            args.seconds < 3 or args.min_headroom < 0):
        p.error('seconds must be at least 3; min-headroom must be nonnegative')
    source = args.source.resolve(strict=True)
    requests = []

    class Handler(BaseHTTPRequestHandler):
        protocol_version = 'HTTP/1.1'

        def log_message(self, *_):
            pass

        def handle(self):
            try:
                super().handle()
            except (ConnectionResetError, ConnectionAbortedError):
                pass

        def do_GET(self):
            if self.path != '/fixture.mp4':
                self.send_error(404)
                return
            size = source.stat().st_size
            value = self.headers.get('Range')
            match = re.fullmatch(r'bytes=(\d+)-(\d*)', value or '')
            if value and not match:
                self.send_error(416)
                return
            first = int(match[1]) if match else 0
            last = min(int(match[2]) if match and match[2] else size-1, size-1)
            if first > last:
                self.send_error(416)
                return
            requests.append({'first': first, 'last': last})
            self.send_response(206 if match else 200)
            self.send_header('Content-Type', 'video/mp4')
            self.send_header('Content-Length', str(last-first+1))
            self.send_header('Accept-Ranges', 'bytes')
            if match:
                self.send_header('Content-Range', f'bytes {first}-{last}/{size}')
            self.end_headers()
            try:
                with source.open('rb') as f:
                    f.seek(first)
                    remaining = last-first+1
                    while remaining:
                        chunk = f.read(min(65536, remaining))
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                        remaining -= len(chunk)
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                pass

    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    mpv = c.CDLL(str(args.library.resolve(strict=True)))
    mpv.mpv_create.restype = c.c_void_p
    mpv.mpv_set_option_string.argtypes = [c.c_void_p, c.c_char_p, c.c_char_p]
    mpv.mpv_initialize.argtypes = [c.c_void_p]
    mpv.mpv_command.argtypes = [c.c_void_p, c.POINTER(c.c_char_p)]
    mpv.mpv_get_property.argtypes = [c.c_void_p, c.c_char_p, c.c_int, c.c_void_p]
    mpv.mpv_free_node_contents.argtypes = [c.POINTER(Node)]
    mpv.mpv_terminate_destroy.argtypes = [c.c_void_p]
    handle = mpv.mpv_create()

    def prop(name):
        node = Node()
        if mpv.mpv_get_property(handle, name.encode(), 6, c.byref(node)) < 0:
            return None
        try:
            return decode(node)
        finally:
            mpv.mpv_free_node_contents(c.byref(node))

    def command(*parts):
        argv = (c.c_char_p*(len(parts)+1))(*(x.encode() for x in parts), None)
        if mpv.mpv_command(handle, argv) < 0:
            raise RuntimeError('native command failed: '+parts[0])

    report = {'options': json.loads(args.options.read_text(encoding='utf-8-sig'))}
    try:
        options = {'config': 'no', 'terminal': 'no', 'vo': 'null', 'ao': 'null',
                   'hwdec': 'no', 'audio': 'no', 'keep-open': 'yes',
                   **report['options']}
        for k, v in options.items():
            if mpv.mpv_set_option_string(handle, k.encode(), str(v).encode()) < 0:
                raise RuntimeError('unsupported option: '+k)
        if mpv.mpv_initialize(handle) < 0:
            raise RuntimeError('mpv_initialize failed')
        command('loadfile', f'http://127.0.0.1:{server.server_port}/fixture.mp4')
        samples = []
        deadline = time.monotonic()+args.seconds+15
        while time.monotonic() < deadline:
            pos = prop('time-pos')
            cache = prop('demuxer-cache-state')
            if isinstance(pos, (int, float)) and isinstance(cache, dict):
                samples.append({'position': pos, 'cache': cache,
                                'buffering': prop('paused-for-cache')})
                if pos >= args.seconds:
                    break
            time.sleep(.05)
        else:
            raise TimeoutError('native playback did not advance')
        valid = [r for r in samples if r['position'] >= 2 and
                 not r['cache'].get('eof') and not r['buffering']]
        if not valid:
            raise RuntimeError('Fixture has no steady, non-EOF cache samples')
        headrooms = [r['cache']['cache-end']-r['position'] for r in valid]
        report.update(samples=samples, minimumHeadroom=min(headrooms),
                      meanHeadroom=sum(headrooms)/len(headrooms),
                      nativeVersion=prop('mpv-version'),
                      maxTotalBytes=max(r['cache']['total-bytes'] for r in samples),
                      requestsBeforeSeek=len(requests))
        # 当前缓存内短距离回退应复用数据，不能一跳转就清空整个缓存。
        command('set', 'pause', 'yes')
        cache = prop('demuxer-cache-state')
        pos = prop('time-pos')
        ranges = cache['seekable-ranges']
        active = next(x for x in ranges if x['start'] <= pos <= x['end'])
        target = max(active['start']+.05, pos-.3)
        if target >= pos:
            raise RuntimeError('Fixture has no usable cached rewind range')
        before = len(requests)
        command('seek', str(target), 'absolute+exact')
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            pos = prop('time-pos')
            if (prop('seeking') is False and isinstance(pos, (int, float)) and
                    abs(pos-target) < .1):
                break
            time.sleep(.05)
        report['maxTotalBytes'] = max(report['maxTotalBytes'],
                                       prop('demuxer-cache-state')['total-bytes'])
        report['cachedSeek'] = {'target': target, 'newRequests': len(requests)-before,
                                'position': prop('time-pos')}
        # 已淘汰位置必须重新读取；不得把旧范围伪装为当前有效缓存。
        cache = prop('demuxer-cache-state')
        if any(x['start'] <= 0 <= x['end'] for x in cache['seekable-ranges']):
            raise RuntimeError('Fixture has not evicted its initial range')
        before = len(requests)
        command('seek', '0', 'absolute+exact')
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            if len(requests)>before and prop('seeking') is False:
                break
            time.sleep(.05)
        report['maxTotalBytes'] = max(report['maxTotalBytes'],
                                       prop('demuxer-cache-state')['total-bytes'])
        report['evictedSeek'] = {'newRequests': len(requests)-before,
                                 'position': prop('time-pos')}
        # 远距离前跳越过全部缓存范围，应读取目标附近数据并正确落点。
        target = prop('duration') - 2
        cache = prop('demuxer-cache-state')
        if any(x['start'] <= target <= x['end'] for x in cache['seekable-ranges']):
            raise RuntimeError('Fixture is too short for an uncached forward seek')
        before = len(requests)
        command('seek', str(target), 'absolute+exact')
        deadline = time.monotonic()+5
        while time.monotonic() < deadline:
            pos = prop('time-pos')
            if (len(requests) > before and prop('seeking') is False and
                    isinstance(pos, (int, float)) and abs(pos-target) < .5):
                break
            time.sleep(.05)
        report['maxTotalBytes'] = max(report['maxTotalBytes'],
                                       prop('demuxer-cache-state')['total-bytes'])
        report['uncachedSeek'] = {'target': target, 'newRequests': len(requests)-before,
                                   'position': prop('time-pos')}
        byte_limit = (int(report['options']['demuxer-max-bytes']) +
                      int(report['options']['demuxer-max-back-bytes']))
        report['withinBudget'] = report['maxTotalBytes'] <= byte_limit + 1024*1024
        report['passed'] = (min(headrooms) >= args.min_headroom and
                            report['cachedSeek']['newRequests']==0 and
                            abs(report['cachedSeek']['position']-
                                report['cachedSeek']['target']) < .1 and
                            report['evictedSeek']['newRequests']>0 and
                            abs(report['evictedSeek']['position']) < .5 and
                            report['uncachedSeek']['newRequests']>0 and
                            abs(report['uncachedSeek']['position']-target) < .5 and
                            report['withinBudget'])
        report['requests'] = requests
    finally:
        mpv.mpv_terminate_destroy(handle)
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k:v for k,v in report.items() if k not in ('samples','requests')}))
    return 0 if report['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
