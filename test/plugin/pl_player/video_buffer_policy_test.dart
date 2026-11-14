import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/video_buffer_policy.dart';

void main() {
  test('无设置、未知设置均使用均衡；策略使用稳定名称持久化', () {
    expect(VideoBufferPolicy.fromName(null), VideoBufferPolicy.balanced);
    expect(VideoBufferPolicy.fromName('unknown'), VideoBufferPolicy.balanced);
    for (final policy in VideoBufferPolicy.values) {
      expect(VideoBufferPolicy.fromName(policy.name), policy);
    }
  });

  test('时长和字节双阈值均小于上限；前向预算增加时后向预算保持有界', () {
    var previousBytes = 0;
    var previousThreshold = 0.0;
    for (final policy in VideoBufferPolicy.values) {
      final options = policy.options(
        baseMiB: 4,
        seconds: 16,
        byteHysteresisSupported: true,
      );
      final bytes = int.parse(options['demuxer-max-bytes']!);
      final refill = int.parse(options['demuxer-hysteresis-bytes']!);
      final seconds = double.parse(options['demuxer-hysteresis-secs']!);
      expect(bytes, greaterThan(previousBytes));
      expect(refill, inExclusiveRange(0, bytes));
      expect(seconds, inExclusiveRange(previousThreshold, 16));
      expect(options['demuxer-max-back-bytes'], '${4 * 1024 * 1024}');
      previousBytes = bytes;
      previousThreshold = seconds;
    }
  });

  test('倍速换算为媒体时长，字节上限不随倍速无界增长', () {
    for (final policy in VideoBufferPolicy.values) {
      final normal = policy.options(
        baseMiB: 8,
        seconds: 24,
        byteHysteresisSupported: true,
      );
      final fast = policy.options(
        baseMiB: 8,
        seconds: 24,
        speed: 2,
        byteHysteresisSupported: true,
      );
      expect(fast['cache-secs'], '48.000');
      expect(
        double.parse(fast['demuxer-hysteresis-secs']!),
        double.parse(normal['demuxer-hysteresis-secs']!) * 2,
      );
      for (final key in [
        'demuxer-max-bytes',
        'demuxer-max-back-bytes',
        'demuxer-hysteresis-bytes',
      ]) {
        expect(fast[key], normal[key]);
      }
    }
  });

  test('不支持字节阈值的平台只传可识别选项，零预算不擅自抬高', () {
    final options = VideoBufferPolicy.balanced.options(
      baseMiB: 0,
      seconds: 0,
      byteHysteresisSupported: false,
    );
    expect(options.containsKey('demuxer-hysteresis-bytes'), isFalse);
    expect(options['demuxer-hysteresis-secs'], '0.000');
    expect(options['demuxer-max-bytes'], '0');
    expect(options['demuxer-max-back-bytes'], '0');
  });
}
