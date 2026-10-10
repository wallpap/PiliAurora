#!/usr/bin/env python3
"""Run production Windows size subscription and disposal with a fake channel."""
from pathlib import Path
import subprocess

from windows_texture_frame_probe import method


HEADER = r"""
import 'dart:async';
import 'dart:io';
void debugPrint(String message) => print(message);
class FakeChannel {
  final calls = <(String, Map<String, Object>)>[];
  Future<T?> invokeMethod<T>(String name, Map<String, Object> args) async {
    calls.add((name, args));
    return null;
  }
}
class FakePlayer {
  final handle = 42;
  final state = (width: 1920, height: 1080);
  final changes = StreamController<(int, int)>.broadcast(sync: true);
  ({Stream<(int, int)> size}) get stream => (size: changes.stream);
}
class FixtureController {
  final player = FakePlayer();
  final _channel = FakeChannel();
  static final _controllers = <int, FixtureController>{};
  StreamSubscription<(int, int)>? _sourceSizeSubscription;
  void attach() {
    final controller = this;
    final player = this.player;
    ATTACH
  }
"""

MAIN = r"""
}
Future<void> main() async {
  final controller = FixtureController()..attach();
  final calls = controller._channel.calls;
  if (calls.length != 1 || calls.single.$2['width'] != 1920 ||
      calls.single.$2['height'] != 1080 || calls.single.$2['handle'] != '42') {
    throw StateError('Existing player geometry was not sent after creation');
  }
  controller.player.changes.add((0, 0));
  if (calls.length != 1) throw StateError('Invalid dimensions reached native output');
  controller.player.changes.add((1080, 1920));
  if (calls.length != 2 || calls.last.$1 != 'VideoOutputManager.SetSourceSize' ||
      calls.last.$2['width'] != 1080 || calls.last.$2['height'] != 1920) {
    throw StateError('Observed output size was not forwarded');
  }
  print('PASS existing geometry and observed size changes reach the native channel');
  await controller._dispose();
  final disposedCount = calls.length;
  controller.player.changes.add((640, 360));
  if (calls.length != disposedCount || calls.last.$1 != 'VideoOutputManager.Dispose') {
    throw StateError('Size subscription survived player disposal');
  }
  await controller.player.changes.close();
  print('PASS disposal cancels the size subscription before destroying output');
}
"""


def main():
    root = Path(__file__).resolve().parents[2]
    source = (root / 'third_party/media_kit_video/lib/src/video_controller/'
              'native_video_controller/real.dart').read_text(encoding='utf-8')
    attach = method(source, 'if (Platform.isWindows) {')
    update = method(source, 'void _updateSourceSize(')
    dispose = method(source, 'Future<void> _dispose(')
    output = root / 'build/windows-playback-diagnosis/source_size_probe.dart'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(HEADER.replace('ATTACH', attach) + update + dispose + MAIN,
                      encoding='utf-8')
    raise SystemExit(subprocess.run(['fvm.bat', 'dart', str(output)], cwd=root).returncode)


if __name__ == '__main__':
    main()
