import 'package:PiliPlus/plugin/pl_player/models/hwdec_type.dart';
import 'package:PiliPlus/plugin/pl_player/utils/decode_fallback.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
