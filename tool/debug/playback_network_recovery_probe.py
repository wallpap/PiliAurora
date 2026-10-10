"""回放脱敏的 Windows / Android 断流事件，检查控制器是否安排媒体重连。

使用生产日志分发、监听回调和重连定时器；原生播放由状态桩替代。
"""

from pathlib import Path
import re
import subprocess
import tempfile


def block(source, start):
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[opening:end]


def method(source, signature):
    start = source.index(signature)
    opening = start + re.search(r'\)\s*(?:async\s*)?\{', source[start:]).end() - 1
    return source[start:opening] + block(source, opening)


HEADER = r"""
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/decode_fallback.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_load_queue.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';
import 'package:pili_aurora/utils/rate_limiter.dart';

class Pref { static bool enableMultiCdn = false; }
class Value<T> { Value(this.value); T value; }
class FakeStream implements PlayerStream {
  final logController = StreamController<PlayerLog>.broadcast(sync: true);
  final errorController = StreamController<String>.broadcast(sync: true);
  Stream<PlayerLog> get log => logController.stream;
  Stream<String> get error => errorController.stream;
  void emit(String prefix, String level, String text) {
    final logController = this.logController;
    final errorController = this.errorController;
    DISPATCH
  }
  Future<void> dispose() async {
    await logController.close();
    await errorController.close();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class FakePlayer implements NativePlayer {
  FakePlayer(Media media) : current = [media];
  bool disposed = false;
  final List<Media> current;
  final state = PlayerState()
    ..playing = true
    ..position = const Duration(seconds: 3031)
    ..buffer = const Duration(seconds: 3047);
  final FakeStream stream = FakeStream();
  int opens = 0;
  Media? opened;
  bool? openedPlaying;
  Future<void> open(Playable playable, {bool play = true, bool synchronized = true}) async {
    opens++;
    opened = playable as Media;
    openedPlaying = play;
    current..clear()..add(opened!);
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
class FakeAndroidRecovery {
  void onLog({required String prefix, required String level, required String message}) {}
}
class SmartDialog {
  static void showToast(String text, {Duration? displayTime}) {}
}
class Utils {
  static void reportError(Object error) { throw StateError(error.toString()); }
}
class FixtureController {
  FixtureController() {
    _videoPlayerController = FakePlayer(nativeMediaSource(source: dataSource));
    _startListeners(_videoPlayerController);
  }
  DataSource dataSource = NetworkSource(
    videoSource: 'https://primary.example/video.m4s',
    audioSource: 'https://primary.example/audio.m4s',
    videoCandidates: ['https://backup.example/video.m4s'],
    audioCandidates: ['https://backup.example/audio.m4s'],
  );
  int _playerCount = 1;
  final _loadQueue = PlaybackLoadQueue();
  bool get processing => _loadQueue.isLoading;
  bool isLive = false;
  bool _av1DecodeErrorObserved = false;
  final onlyPlayAudio = Value(false);
  final isBuffering = Value(false);
  late final FakePlayer _videoPlayerController;
  FakePlayer get videoPlayerController => _videoPlayerController;
  FakeAndroidRecovery? _androidDecodeRecovery;
  List<StreamSubscription>? _subscriptions;
  Timer? _reloadTimer;
  EXTRA_FIELDS
  int get reloads => _videoPlayerController.opens;
  Duration? get restoredPosition => _videoPlayerController.opened?.start;
  bool? get restoredPlaying => _videoPlayerController.openedPlaying;
  REFRESH
  void _startListeners(FakePlayer player) {
    final stream = player.stream;
    _subscriptions = [LOG_LISTENER stream.error.listen((String event) ERROR_LISTENER),];
  }
  SCHEDULE
  EXTRA_METHODS
  void stop() {
    _reloadTimer?.cancel();
    _loadQueue.dispose();
    for (final base in ['controllerStream.error.listen', 'controllerStream.error.listen.cdn.0', 'controllerStream.error.listen.cdn.1']) {
      ActionThrottle.cancel(base);
      ActionThrottle.cancel('$base.readFailure');
    }
  }
  Future<void> dispose() async {
    stop();
    for (final subscription in _subscriptions!) { await subscription.cancel(); }
    await _videoPlayerController.stream.dispose();
  }
}
"""

MAIN = r"""
void testReplay(String name, Future<void> Function(WidgetTester, FixtureController) run) {
  testWidgets(name, (tester) async {
    Pref.enableMultiCdn = false;
    final controller = FixtureController();
    addTearDown(controller.dispose);
    try { await run(tester, controller); }
    finally { controller.stop(); }
  });
}
void terminal(FixtureController controller) => controller.videoPlayerController.stream.emit(
  'curl', 'error', 'transfer failed: Failure when receiving data from the peer');
void main() {
  testReplay('Windows video transfer failure reconnects while external audio keeps playing', (tester, controller) async {
    terminal(controller);
    await tester.pump(const Duration(seconds: 3));
    print('PROBE playing=${controller.videoPlayerController.state.playing} buffering=${controller.isBuffering.value} reloads=${controller.reloads}');
    expect(controller.reloads, 1, reason: 'Video EOF must reconnect even when the external audio clock remains active');
    expect(controller.restoredPosition, const Duration(seconds: 3031));
    expect(controller.restoredPlaying, isTrue);
    expect(controller.videoPlayerController.opened!.uri, 'https://primary.example/video.m4s');
    expect(controller.videoPlayerController.opened!.extras!['audio-files-append'], contains('https://primary.example/audio.m4s'));
    expect((controller.dataSource as NetworkSource).candidateIndex, 0);
  });
  testReplay('Windows truncated video packet reconnects without global buffering', (tester, controller) async {
    controller.videoPlayerController.stream.emit('ffmpeg/demuxer', 'error',
      'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0x67358bd: partial file');
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 1);
  });
  testReplay('Android premature HTTPS EOF reconnects while external audio stays active', (tester, controller) async {
    controller.videoPlayerController.stream.emit('ffmpeg', 'error',
      'https: Stream ends prematurely at 6077440, should be 12527587');
    await tester.pump(const Duration(seconds: 3));
    print('ANDROID_ROUTE playing=${controller.videoPlayerController.state.playing} buffering=${controller.isBuffering.value} reloads=${controller.reloads}');
    expect(controller.reloads, 1);
    expect(controller.restoredPlaying, isTrue);
  });
  testReplay('terminal read errors upgrade a pending buffer check', (tester, controller) async {
    controller.isBuffering.value = true;
    controller.videoPlayerController.stream.errorController.add('https: Stream ends prematurely at 6077440, should be 12527587');
    await tester.pump(const Duration(seconds: 1));
    terminal(controller);
    controller.isBuffering.value = false;
    await tester.pump(const Duration(seconds: 2));
    expect(controller.reloads, 1);
  });
  testReplay('error burst and cooldown produce one reload', (tester, controller) async {
    for (var i = 0; i < 20; i++) { terminal(controller); }
    await tester.pump(const Duration(seconds: 3));
    terminal(controller);
    await tester.pump(const Duration(seconds: 6));
    expect(controller.reloads, 1);
  });
  testReplay('old media errors do not reopen a new source', (tester, controller) async {
    terminal(controller);
    controller.dataSource = NetworkSource(videoSource: 'https://other.example/video.m4s', audioSource: null);
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 0);
  });
  testReplay('local truncated files do not enter network recovery', (tester, controller) async {
    controller.dataSource = FileSource(dir: 'fixture', isMp4: true, hasDashAudio: false, typeTag: 'video');
    controller.videoPlayerController.stream.emit('ffmpeg/demuxer', 'error',
      'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0x67358bd: partial file');
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 0);
  });
  testReplay('transient curl retries leave playback uninterrupted', (tester, controller) async {
    controller.videoPlayerController.stream.emit('curl', 'warn',
      'Failure when receiving data from the peer, retrying (#1) from 96018379');
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 0);
  });
  testReplay('ordinary network errors still wait for remaining media buffer', (tester, controller) async {
    controller.isBuffering.value = true;
    controller.videoPlayerController.stream.errorController.add('https: Stream ends prematurely at 6077440, should be 12527587');
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 0);
    controller.videoPlayerController.state.position = controller.videoPlayerController.state.buffer;
    await tester.pump(const Duration(seconds: 3));
    expect(controller.reloads, 1);
  });
}
"""


def main():
    root = Path(__file__).resolve().parents[2]
    source = (root / 'lib/plugin/pl_player/controller.dart').read_text(encoding='utf-8')
    native = (root / 'third_party/media_kit/lib/src/player/native/player/real.dart').read_text(encoding='utf-8')
    dispatch_start = native.index('if (!logController.isClosed)', native.index('case generated.mpv_event_id.MPV_EVENT_LOG_MESSAGE:'))
    listeners_start = source.index('_subscriptions = [', source.index('void _startListeners('))
    log_start = listeners_start + len('_subscriptions = [')
    log_end = source.index('/// playing', log_start)
    error_start = source.index('stream.error.listen((String event)', listeners_start)
    extras = ''
    fields = ''
    for signature in ['void _recoverPlaybackNetwork(']:
        if signature in source:
            extras += method(source, signature)
    for name in ['_reloadRequiresEmptyBuffer']:
        declaration = re.search(r'  bool ' + name + r'[^;]*;', source)
        if declaration:
            fields += declaration[0]
    output = (root / 'build/playback-network-diagnosis').resolve()
    if not output.is_relative_to(root):
        raise RuntimeError('回放输出目录必须位于当前工作区内')
    output.mkdir(parents=True, exist_ok=True)
    content = (HEADER.replace('DISPATCH', block(native, dispatch_start))
               .replace('LOG_LISTENER', source[log_start:log_end])
               .replace('ERROR_LISTENER', block(source, error_start))
               .replace('SCHEDULE', method(source, 'void _scheduleRefresh('))
               .replace('REFRESH', method(source, 'Future<void>? refreshPlayer('))
               .replace('EXTRA_METHODS', extras).replace('EXTRA_FIELDS', fields))
    with tempfile.TemporaryDirectory(prefix='network-recovery-', dir=output) as directory:
        fixture = Path(directory) / 'network_recovery_probe_test.dart'
        fixture.write_text(content + MAIN, encoding='utf-8')
        result = subprocess.run([
            'fvm.bat', 'flutter', 'test', '--no-pub', str(fixture), '--reporter', 'expanded',
        ], cwd=root).returncode
    raise SystemExit(result)


if __name__ == '__main__':
    main()
