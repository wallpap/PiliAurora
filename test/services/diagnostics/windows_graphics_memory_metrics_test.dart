import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/windows_graphics_memory_metrics.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(
    'pili_aurora/graphics_memory',
    JSONMethodCodec(),
  );
  final messenger = binding.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('caches and passes through engine contexts', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'sample');
      expect(call.arguments, {'resources': false});
      return {
        'status': 'sampled',
        'schemaVersion': 1,
        'contexts': {
          'raster': {'available': true, 'resourceBytes': 42},
        },
      };
    });
    final metrics = WindowsGraphicsMemoryMetrics();
    addTearDown(metrics.stop);
    await metrics.start();
    expect(metrics.sample()['status'], 'sampled');
    expect(
      ((metrics.sample()['contexts'] as Map)['raster'] as Map)['resourceBytes'],
      42,
    );
    expect(metrics.sample()['cacheAgeMs'], isA<int>());
  });

  test('resource details are opt in', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.arguments, {'resources': true});
      return {'status': 'sampled'};
    });
    final metrics = WindowsGraphicsMemoryMetrics(includeResources: true);
    addTearDown(metrics.stop);
    await metrics.start();
    expect(metrics.sample()['status'], 'sampled');
  });

  testWidgets('missing channel stops polling', (tester) async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      return Future.error(MissingPluginException());
    });
    final metrics = WindowsGraphicsMemoryMetrics();
    final start = metrics.start();
    await tester.pump();
    await start;
    expect(metrics.sample()['status'], 'unsupported');
    await tester.pump(const Duration(seconds: 20));
    expect(calls, 1);
    await metrics.stop();
  });

  testWidgets('timeout keeps one request; old reply cannot cross restart', (
    tester,
  ) async {
    var calls = 0;
    final reply = Completer<Object?>();
    messenger.setMockMethodCallHandler(channel, (_) {
      calls++;
      return calls == 1
          ? reply.future
          : Future.value({'status': 'sampled', 'generation': 2});
    });
    final metrics = WindowsGraphicsMemoryMetrics();
    final start = metrics.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await start;
    expect(metrics.sample()['status'], 'timeout');
    await tester.pump(const Duration(seconds: 15));
    expect(calls, 1);
    await metrics.stop();
    await metrics.start();
    reply.complete({'status': 'sampled', 'generation': 1});
    await tester.pump();
    expect(metrics.sample()['status'], 'warmingUp');
    await tester.pump(const Duration(seconds: 5));
    expect(metrics.sample()['generation'], 2);
    await metrics.stop();
  });
}
