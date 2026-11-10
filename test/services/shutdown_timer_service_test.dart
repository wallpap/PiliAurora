import 'dart:async';

import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/services/shutdown_timer_service.dart';

void main() {
  final service = shutdownTimerService;
  final messages = <String>[];

  void check(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      service
        ..reset()
        ..isPlaying = () => true;
      messages.clear();
      await tester.pumpWidget(
        MaterialApp(
          builder: FlutterSmartDialog.init(
            toastBuilder: (message) {
              messages.add(message);
              return Text(message);
            },
          ),
          home: const SizedBox(),
        ),
      );
      try {
        await body(tester);
      } finally {
        service
          ..reset()
          ..onPause = null
          ..isPlaying = null;
        SmartDialog.dismiss(status: SmartStatus.allToast);
        await tester.pump(const Duration(seconds: 6));
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 16));
        await tester.pumpAndSettle();
      }
    });
  }

  Future<void> expire(WidgetTester tester) async {
    service.startShutdownTimer(1);
    await tester.pump();
    SmartDialog.dismiss(status: SmartStatus.allToast);
    await tester.pump(const Duration(seconds: 6));
    messages.clear();
    // 停在触发时刻，避免一次推进越过 Toast 的整个显示期。
    await tester.pump(const Duration(seconds: 54));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  check('定时暂停等待控制回执后才提示成功', (tester) async {
    final paused = Completer<void>();
    var calls = 0;
    service.onPause = () {
      calls++;
      return paused.future;
    };
    await expire(tester);
    expect(calls, 1);
    expect(messages, isEmpty);
    paused.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(messages, contains('定时时间已到，已暂停'));
  });

  for (final synchronous in [true, false]) {
    check('定时暂停消费${synchronous ? '同步' : '异步'}错误并提示失败', (tester) async {
      final cause = StateError('https://private.example/?token=secret');
      service.onPause = () {
        if (synchronous) throw cause;
        return Future<void>.error(cause);
      };
      await expire(tester);
      expect(messages, contains('定时暂停失败，请手动暂停'));
      expect(messages.join(), isNot(contains('secret')));
      expect(messages, isNot(contains('定时时间已到，已暂停')));
    });
  }

  check('取消或重设定时后不发布旧暂停的迟到结果', (tester) async {
    for (final failed in [false, true]) {
      final paused = Completer<void>();
      service.onPause = () => paused.future;
      await expire(tester);
      service.reset();
      if (failed) {
        paused.completeError(StateError('synthetic late pause failure'));
      } else {
        paused.complete();
      }
      await tester.pump();
      expect(messages, isEmpty);
    }
  });
}
