import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/hardware_video_configuration.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';

void main() {
  test('Windows default prefers verified d3d11va passthrough before auto', () {
    final candidates = HwDecType.orderedCandidates(HwDecType.kHwdec);

    expect(candidates.take(2), ['d3d11va', 'auto']);
    expect(candidates.last, 'no');
  }, skip: !Platform.isWindows);

  test(
    'disabling hardware acceleration falls back to software decoding only',
    () {
      final configuration = hardwareVideoConfiguration(
        enabled: false,
        configured: HwDecType.kHwdec,
      );

      expect(configuration.enableHardwareAcceleration, isFalse);
      expect(configuration.hwdec, 'no');
    },
  );
  test('Windows auto-copy does not append incompatible direct backends', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy',
    );

    expect(configuration.hwdec, 'auto-copy,no');
    expect(configuration.androidAttachSurfaceAfterVideoParameters, isFalse);
  }, skip: !Platform.isWindows);

  test('Windows auto-copy preserves explicitly configured direct backends', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy,d3d11va',
    );

    expect(configuration.hwdec, 'auto-copy,d3d11va,no');
  }, skip: !Platform.isWindows);

  test('Windows explicit auto still expands the direct backend candidates', () {
    final configuration = hardwareVideoConfiguration(
      enabled: true,
      configured: 'auto-copy,auto',
    );

    expect(configuration.hwdec!.split(',').take(2), ['auto-copy', 'auto']);
    expect(configuration.hwdec!.split(','), contains('d3d11va'));
    expect(configuration.hwdec!.split(',').last, 'no');
  }, skip: !Platform.isWindows);

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
