import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/services/diagnostics/player_diagnostics.dart';

void main() {
  test('disposed players never enter native property reads', () {
    expect(readMpvProperty(_DisposedNativePlayer(), 'hwdec-current'), isNull);
  });
}

class _DisposedNativePlayer implements NativePlayer {
  @override
  bool get disposed => true;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Disposed player must not access native state');
}
