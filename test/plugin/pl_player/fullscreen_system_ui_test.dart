import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/fullscreen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('系统 UI 模型：方向或系统栏写入失败后，同值请求必须能重试', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    for (final command in <Future<void>? Function()>[
      landscapeLeftMode,
      hideSystemBar,
      showSystemBar,
    ]) {
      var calls = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) async {
        if (++calls == 1) throw PlatformException(code: 'system-ui-failed');
        return null;
      });
      await expectLater(command(), throwsA(isA<PlatformException>()));
      await command();
      expect(calls, 2, reason: '失败的原生写入不能作为已成功应用的缓存');
    }
  });
  test('迟到的系统 UI 失败不能覆盖更新的同值缓存', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    addTearDown(
      () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
    );
    for (final commands in <List<Future<void>? Function()>>[
      [portraitUpMode, landscapeLeftMode, portraitUpMode],
      [hideSystemBar, showSystemBar, hideSystemBar],
    ]) {
      final gate = Completer<Object?>();
      var calls = 0;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (_) {
        calls++;
        return calls == 1 ? gate.future : Future<Object?>.value();
      });
      final old = commands[0]()!;
      final oldFailure = expectLater(old, throwsA(isA<PlatformException>()));
      await commands[1]();
      await commands[2]();
      gate.completeError(PlatformException(code: 'late-failure'));
      await oldFailure;
      expect(commands[2](), isNull);
      expect(calls, 3);
    }
    await showSystemBar();
  });
}
