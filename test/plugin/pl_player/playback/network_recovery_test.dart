import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/network_recovery.dart';

void main() {
  const empty = (
    buffering: true,
    position: Duration(seconds: 10),
    buffer: Duration(seconds: 10),
  );

  testWidgets('错误风暴合并，终止读取升级已安排的缓冲等待', (tester) async {
    final retries = <bool>[];
    final recovery =
        PlaybackNetworkRecovery(
            isCurrent: () => true,
            readState: () => (
              buffering: false,
              position: const Duration(seconds: 10),
              buffer: const Duration(seconds: 30),
            ),
            reload: (cdn) async => retries.add(cdn),
            onError: (error) => fail('$error'),
          )
          ..schedule(requireEmptyBuffer: true, throttle: true)
          ..schedule(tryNextCdn: true, throttle: true)
          ..schedule(requireEmptyBuffer: true, throttle: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, [true]);
    recovery.dispose();
  });

  testWidgets('缓冲耗尽时恢复，无需等待另一条错误事件', (tester) async {
    var state = (
      buffering: true,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 30),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(requireEmptyBuffer: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    state = empty;
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('新媒体有独立恢复窗口，CDN 候选有独立预算', (tester) async {
    var retries = 0;
    PlaybackNetworkRecovery create() => PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => empty,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    );
    final first = create()..schedule(throttle: true);
    await tester.pump(const Duration(seconds: 3));
    first.schedule(throttle: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    first.schedule(throttle: true, candidate: 1);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 2);
    first.dispose();
    final second = create()..schedule(throttle: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 3);
    second.dispose();
  });

  testWidgets('加载队列繁忙时继续等待，保留本轮恢复机会', (tester) async {
    var ready = false;
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => empty,
      reload: (_) {
        if (!ready) return null;
        retries++;
        return Future<void>.value();
      },
      onError: (error) => fail('$error'),
    )..schedule();
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    ready = true;
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('切源或关闭后计时器不能重开媒体', (tester) async {
    var current = true;
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => current,
      readState: () => empty,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule();
    current = false;
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    current = true;
    recovery
      ..schedule()
      ..dispose();
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
  });
}
