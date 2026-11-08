import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/plugin/pl_player/utils/decode_fallback.dart';

void main() {
  test('硬解故障分类保留 AV1 初始化失败，排除损坏码流和其它格式错误', () {
    for (final (message, expected) in [
      (
        "Your platform doesn't support hardware accelerated AV1 decoding.",
        true,
      ),
      (
        'Failed setup for format dxva2_vld: hwaccel initialisation returned error.',
        true,
      ),
      ('av1: Failed to get pixel format.', true),
      (
        'av1: No sequence header available: unable to decode frame header.',
        false,
      ),
      ('h264: Failed to get pixel format.', false),
    ]) {
      expect(isHardwareDecodeFailure(message), expected, reason: message);
    }
  });

  test('显式候选保持顺序并去重，空配置及自动探测最终回退软解', () {
    for (final (configured, expected) in [
      ('d3d11va,dxva2', ['d3d11va', 'dxva2', 'no']),
      (' d3d11va, ,dxva2,d3d11va ', ['d3d11va', 'dxva2', 'no']),
      ('no', ['no']),
      ('', ['no']),
      (null, ['no']),
    ]) {
      expect(
        HwDecType.orderedCandidates(configured),
        expected,
        reason: '$configured',
      );
    }
    expect(HwDecType.orderedCandidates('auto').last, 'no');
  });
}
