import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/playback/playback_contracts.dart';
import 'package:pili_aurora/plugin/pl_player/playback/progress_projection.dart';

void main() {
  test('重载和页面续播过滤卸载零值，ready 后直接交接续播位置', () {
    final progress = PlaybackProgressProjection();
    for (final phase in [PlaybackPhase.loading, PlaybackPhase.recovering]) {
      progress.begin(const Duration(seconds: 120));
      expect(progress.accept(phase, Duration.zero), isFalse);
      expect(progress.accept(phase, const Duration(seconds: 3)), isFalse);
      expect(progress.accept(PlaybackPhase.ready, Duration.zero), isFalse);
      expect(
        progress.accept(PlaybackPhase.ready, const Duration(seconds: 600)),
        isFalse,
      );
      expect(progress.awaitingPosition, isTrue);
      expect(
        progress.accept(
          PlaybackPhase.ready,
          const Duration(milliseconds: 120100),
        ),
        isTrue,
      );
      expect(progress.awaitingPosition, isFalse);
      // 交接完成后的真实回到片头应正常显示。
      expect(progress.accept(PlaybackPhase.ready, Duration.zero), isTrue);
    }
  });

  test('新视频从片头开始可接收零值，旧加载的尾部通知被隔离', () {
    final progress = PlaybackProgressProjection()..begin(Duration.zero);
    expect(
      progress.accept(PlaybackPhase.loading, const Duration(seconds: 600)),
      isFalse,
    );
    expect(progress.accept(PlaybackPhase.ready, Duration.zero), isTrue);
    expect(progress.accept(PlaybackPhase.failed, Duration.zero), isFalse);
  });

  test('交接期间用户跳回片头时使用最新目标', () {
    final progress = PlaybackProgressProjection()
      ..begin(const Duration(seconds: 120))
      ..begin(Duration.zero);
    expect(progress.accept(PlaybackPhase.ready, Duration.zero), isTrue);
  });
}
