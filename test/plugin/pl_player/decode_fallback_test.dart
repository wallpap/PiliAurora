import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';
import 'package:pili_aurora/plugin/pl_player/utils/decode_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prefers d3d11va passthrough by default on Windows only', () {
    final expected = Platform.isAndroid
        ? kDebugMode
              ? 'auto-safe'
              : 'mediacodec,auto-safe'
        : Platform.isWindows
        // Windows 视频纹理桥基于 D3D11/ANGLE 共享纹理，默认先试已验证的
        // d3d11va 非 copy 直通，失败再由 mpv 的 auto 探测。
        ? 'd3d11va,auto'
        : 'auto';
    expect(HwDecType.kHwdec, expected);
  });

  test('recognizes AV1 hardware decoder failures', () {
    expect(
      isHardwareDecodeFailure(
        "Your platform doesn't support hardware accelerated AV1 decoding.",
      ),
      isTrue,
    );
    expect(
      isHardwareDecodeFailure(
        'Failed setup for format dxva2_vld: hwaccel initialisation returned error.',
      ),
      isTrue,
    );
    expect(
      isHardwareDecodeFailure('av1: Failed to get pixel format.'),
      isTrue,
    );
  });

  test('does not classify malformed AV1 packets as hardware failures', () {
    expect(
      isHardwareDecodeFailure(
        'av1: No sequence header available: unable to decode frame header.',
      ),
      isFalse,
    );
    expect(
      isHardwareDecodeFailure('h264: Failed to get pixel format.'),
      isFalse,
    );
  });

  test(
    'keeps configured decoder order and terminates with software decoding',
    () {
      expect(
        HwDecType.orderedCandidates('d3d11va,dxva2'),
        ['d3d11va', 'dxva2', 'no'],
      );
      expect(HwDecType.orderedCandidates('auto').last, 'no');
    },
  );
}
