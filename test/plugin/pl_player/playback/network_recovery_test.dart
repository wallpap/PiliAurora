import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/network_recovery.dart';
import 'package:pili_aurora/plugin/pl_player/utils/playback_network_recovery.dart';

void main() {
  const empty = (
    buffering: true,
    position: Duration(seconds: 10),
    buffer: Duration(seconds: 10),
  );

  testWidgets('声音仍前进但画面持续停滞时重连，短暂失帧恢复则取消', (tester) async {
    var progressing = false;
    var retries = 0;
    final recovery =
        PlaybackNetworkRecovery(
          isCurrent: () => true,
          readState: () => empty,
          videoProgressing: () => progressing,
          reload: (_) async => retries++,
          onError: (error) => fail('$error'),
        )..schedule(
          requireVideoProgress: true,
          allowNativeRecovery: false,
          throttle: true,
        );
    progressing = true;
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    progressing = false;
    recovery.schedule(
      requireVideoProgress: true,
      allowNativeRecovery: false,
      throttle: true,
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('重载仍在途时合并错误，避免重复提交媒体加载', (tester) async {
    final pending = Completer<void>();
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => empty,
      reload: (_) {
        retries++;
        return pending.future;
      },
      onError: (error) => fail('$error'),
    )..schedule();
    addTearDown(recovery.dispose);
    await tester.pump(const Duration(seconds: 3));
    recovery.schedule();
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    pending.complete();
    await tester.pump();
  });

  testWidgets('权限错误取消已有定时重连，后续断流日志不重开媒体', (tester) async {
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => empty,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule();
    addTearDown(recovery.dispose);
    recovery.stopForPermissionFailure();
    await tester.pump(const Duration(seconds: 3));
    recovery.schedule();
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
  });

  testWidgets('分离流缓存时间仍超前但缓冲和进度持续停滞时恢复', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 20),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(waitForCachedPlayback: true);
    addTearDown(recovery.dispose);
    state = (
      buffering: true,
      position: const Duration(seconds: 13),
      buffer: const Duration(seconds: 20),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
  });

  testWidgets('首次检查尚未进入缓冲时保留机会，随后耗尽仍重连', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 20),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(requireEmptyBuffer: true);
    addTearDown(recovery.dispose);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    state = empty;
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
  });

  testWidgets('默认缓冲恢复连续两轮停滞后重连，不被超前缓存时间卡住', (tester) async {
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => (
        buffering: true,
        position: const Duration(seconds: 10),
        buffer: const Duration(seconds: 20),
      ),
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(requireEmptyBuffer: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('分离音视频读取失败先保留剩余缓存，耗尽后恢复主视频', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 20),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(waitForCachedPlayback: true);
    state = (
      buffering: false,
      position: const Duration(seconds: 13),
      buffer: const Duration(seconds: 20),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    state = (
      buffering: false,
      position: const Duration(seconds: 20),
      buffer: const Duration(seconds: 20),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('残余 33ms 数据不能取消断流恢复，缓存耗尽后重载', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(milliseconds: 838500),
      buffer: const Duration(milliseconds: 851067),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(waitForCachedPlayback: true);
    state = (
      buffering: false,
      position: const Duration(milliseconds: 841500),
      buffer: const Duration(milliseconds: 851100),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    state = (
      buffering: false,
      position: const Duration(milliseconds: 851480),
      buffer: const Duration(milliseconds: 851100),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('独立音轨故障但主视频缓存健康，取消主视频重载', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(milliseconds: 645478),
      buffer: const Duration(milliseconds: 651651),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(waitForCachedPlayback: true);
    state = (
      buffering: false,
      position: const Duration(milliseconds: 648478),
      buffer: const Duration(milliseconds: 654651),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    recovery.dispose();
  });

  testWidgets('独立音轨截断后，视频缓冲继续增长仍需重载音轨', (tester) async {
    // 诊断包中的截断发生于 645.478 秒，主媒体缓存仅包含 video。
    var state = (
      buffering: false,
      position: const Duration(milliseconds: 645478),
      buffer: const Duration(milliseconds: 651651),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    );
    if (isPlaybackStreamReadFailure(
      prefix: 'ffmpeg/demuxer',
      level: 'error',
      message:
          'mov,mp4,m4a,3gp,3g2,mj2: stream 0, offset 0xeb17ab: partial file',
    )) {
      recovery.schedule(tryNextCdn: true, allowNativeRecovery: false);
    }
    state = (
      buffering: false,
      position: const Duration(milliseconds: 648478),
      buffer: const Duration(milliseconds: 654651),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('音频解码失败升级缓冲等待，后续网络日志不能取消重载', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(milliseconds: 658858),
      buffer: const Duration(milliseconds: 664664),
    );
    final retries = <bool>[];
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (cdn) async => retries.add(cdn),
      onError: (error) => fail('$error'),
    )..schedule(requireEmptyBuffer: true);
    await tester.pump(const Duration(seconds: 1));
    recovery
      ..schedule(allowNativeRecovery: false, tryNextCdn: true)
      ..schedule()
      ..schedule(requireEmptyBuffer: true);
    state = (
      buffering: false,
      position: const Duration(milliseconds: 661858),
      buffer: const Duration(milliseconds: 667664),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(retries, [true]);
    recovery.dispose();
  });

  testWidgets('音轨恢复仍合并错误风暴并遵守重试限频', (tester) async {
    final retries = <bool>[];
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => empty,
      reload: (cdn) async => retries.add(cdn),
      onError: (error) => fail('$error'),
    );
    for (var i = 0; i < 20; i++) {
      recovery.schedule(
        allowNativeRecovery: false,
        tryNextCdn: true,
        throttle: true,
      );
    }
    await tester.pump(const Duration(seconds: 3));
    expect(retries, [true]);
    recovery.schedule(allowNativeRecovery: false, throttle: true);
    await tester.pump(const Duration(seconds: 3));
    expect(retries, [true]);
    recovery.dispose();
  });

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

  testWidgets('原生重连后播放与缓冲同时推进，不再重载健康媒体', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(milliseconds: 196600),
      buffer: const Duration(milliseconds: 209960),
    );
    var retries = 0;
    final recovery =
        PlaybackNetworkRecovery(
            isCurrent: () => true,
            readState: () => state,
            reload: (_) async => retries++,
            onError: (error) => fail('$error'),
          )
          ..schedule(tryNextCdn: true)
          // 同一错误还会经过 stream.error，但不能抹掉原始断流时的观察值。
          ..schedule(requireEmptyBuffer: true);
    state = (
      buffering: false,
      position: const Duration(milliseconds: 199600),
      buffer: const Duration(milliseconds: 213040),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    recovery.dispose();
  });

  testWidgets('取消未执行的重载后，新断流仍可获得恢复机会', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 30),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule(throttle: true);
    state = (
      buffering: false,
      position: const Duration(seconds: 13),
      buffer: const Duration(seconds: 33),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 0);
    recovery.schedule(throttle: true);
    state = (
      buffering: false,
      position: const Duration(seconds: 16),
      buffer: const Duration(seconds: 33),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('播放时钟推进但缓冲不再增长，仍恢复终止读取', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 30),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule();
    state = (
      buffering: false,
      position: const Duration(seconds: 13),
      buffer: const Duration(seconds: 30),
    );
    await tester.pump(const Duration(seconds: 3));
    expect(retries, 1);
    recovery.dispose();
  });

  testWidgets('恢复窗口内再次断流，以最新故障的缓冲位置判断', (tester) async {
    var state = (
      buffering: false,
      position: const Duration(seconds: 10),
      buffer: const Duration(seconds: 30),
    );
    var retries = 0;
    final recovery = PlaybackNetworkRecovery(
      isCurrent: () => true,
      readState: () => state,
      reload: (_) async => retries++,
      onError: (error) => fail('$error'),
    )..schedule();
    await tester.pump(const Duration(seconds: 1));
    state = (
      buffering: false,
      position: const Duration(seconds: 11),
      buffer: const Duration(seconds: 31),
    );
    recovery.schedule();
    state = (
      buffering: false,
      position: const Duration(seconds: 13),
      buffer: const Duration(seconds: 31),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(retries, 1);
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
