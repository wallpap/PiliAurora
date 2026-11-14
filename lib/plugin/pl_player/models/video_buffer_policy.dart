import 'package:pili_aurora/models/common/enum_with_label.dart';

/// 原生 demuxer 同时受时长和字节上限约束；高码率不能只提高时长目标。
enum VideoBufferPolicy implements EnumWithLabel {
  memory('省内存', '较小预读空间，减少内存占用', 1, 0.5),
  balanced('均衡', '适度预读，兼顾内存与网络波动', 4, 0.75),
  smooth('流畅优先', '保留更多前向缓存，更早补读', 8, 0.875);

  const VideoBufferPolicy(
    this.label,
    this.description,
    this.forwardMultiplier,
    this.refillFraction,
  );

  @override
  final String label;
  final String description;
  final int forwardMultiplier;
  final double refillFraction;

  static VideoBufferPolicy fromName(Object? value) =>
      values.where((policy) => policy.name == value).firstOrNull ?? balanced;

  Map<String, String> options({
    required double baseMiB,
    required double seconds,
    double speed = 1,
    required bool byteHysteresisSupported,
  }) {
    final bytes = (baseMiB * 0x100000).round();
    final forwardBytes = bytes * forwardMultiplier;
    final mediaSeconds = seconds * speed;
    return {
      'cache': 'yes',
      'cache-secs': mediaSeconds.toStringAsFixed(3),
      'demuxer-max-bytes': '$forwardBytes',
      // 后向缓存用于短距离回退复用，不随前向策略增大。
      'demuxer-max-back-bytes': '$bytes',
      'demuxer-hysteresis-secs': (mediaSeconds * refillFraction)
          .toStringAsFixed(3),
      // Android 固定 libmpv 尚无此选项；不能让不支持的参数使加载失败。
      if (byteHysteresisSupported)
        'demuxer-hysteresis-bytes': (forwardBytes * refillFraction)
            .round()
            .toString(),
    };
  }
}
