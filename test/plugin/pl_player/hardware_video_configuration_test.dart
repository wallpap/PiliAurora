import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';

void main() {
  test('passes every configured backend to the native video controller', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'amf,nvdec,d3d12va,auto',
    );

    expect(configuration.enableHardwareAcceleration, isTrue);
    expect(
      configuration.hwdec!.split(',').take(4),
      ['amf', 'nvdec', 'd3d12va', 'auto'],
    );
    expect(configuration.hwdec!.split(',').last, 'no');
  });

  test('keeps explicit software fallback in its configured position', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'amf,no,nvdec-copy',
    );

    expect(configuration.hwdec, 'amf,no,nvdec-copy');
  });

  test(
    'disabling hardware acceleration explicitly disables native decoding',
    () {
      final configuration = hardwareVideoConfiguration(
        enabled: false,
        configured: 'auto',
      );

      expect(configuration.enableHardwareAcceleration, isFalse);
      expect(configuration.hwdec, 'no');
    },
  );

  test('each media configuration uses the latest backend order', () {
    final first = hardwareVideoConfiguration(
      enabled: true,
      configured: 'amf,nvdec-copy',
    );
    final second = hardwareVideoConfiguration(
      enabled: true,
      configured: 'nvdec-copy,amf',
    );

    expect(first.hwdec, 'amf,nvdec-copy,no');
    expect(second.hwdec, 'nvdec-copy,amf,no');
  });
}
