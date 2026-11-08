import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/setting/decoder_test.dart';
import 'package:pili_aurora/plugin/pl_player/models/hwdec_type.dart';

DecoderTestObservation observation({
  String decoder = 'd3d11va',
  String format = 'h264',
  int seconds = 4,
  int frames = 100,
  bool progressing = true,
  int width = 1920,
}) => DecoderTestObservation(
  decoder: decoder,
  format: format,
  position: Duration(seconds: seconds),
  consumedFrames: frames,
  videoProgressing: progressing,
  width: width,
  height: 1080,
);

DecoderTestResult evaluate(
  DecoderTestObservation after, {
  HwDecType mode = HwDecType.d3d11va,
}) => evaluateDecoderTest(
  requested: mode,
  codec: 7,
  before: observation(seconds: 1, frames: 20),
  after: after,
  elapsed: const Duration(seconds: 3),
);

VideoItem video(
  int codec,
  int quality, {
  String? url = 'https://example.test/video',
}) => VideoItem(
  id: quality,
  codecid: codec,
  quality: VideoQuality.high1080,
  baseUrl: url,
);

void main() {
  test('位置前进或旧截图不能证明纹理继续输出', () {
    expect(() => evaluate(observation(frames: 20)), throwsStateError);
    expect(() => evaluate(observation(progressing: false)), throwsStateError);
    expect(() => evaluate(observation(width: 0)), throwsStateError);
    expect(() => evaluate(observation(seconds: 2)), throwsStateError);
    expect(evaluate(observation()).passed, isTrue);
  });

  test('未知解码器不得当作软件解码成功', () {
    for (final value in ['', '   ']) {
      expect(
        () => evaluate(observation(decoder: value), mode: HwDecType.no),
        throwsStateError,
      );
    }
    final software = evaluate(observation(decoder: 'no'), mode: HwDecType.no);
    expect(software.passed, isTrue);
    expect(software.fallback, isFalse);
  });

  test('实际编码必须与请求样本一致', () {
    expect(() => evaluate(observation(format: 'av1')), throwsStateError);
  });

  test('回退与复制模式按实际后端报告', () {
    expect(evaluate(observation(decoder: 'no')).fallback, isTrue);
    expect(evaluate(observation(), mode: HwDecType.auto).fallback, isFalse);
    expect(evaluate(observation(), mode: HwDecType.autoCopy).fallback, isTrue);
    expect(
      evaluate(
        observation(decoder: 'd3d11va-copy'),
        mode: HwDecType.autoCopy,
      ).fallback,
      isFalse,
    );
  });

  test('测试样本优先1080p而不是接口中的首个4K流', () {
    final preferred = video(7, 80);
    expect(decoderTestSamples([video(7, 120), preferred, video(7, 64)]), [
      preferred,
    ]);
    expect(
      decoderTestSamples([video(7, 80, url: ' '), video(13, 80, url: '')]),
      isEmpty,
    );
  });

  test('无1080p时选最接近目标的可用档位', () {
    final lower = video(7, 64);
    final higher = video(13, 112);
    expect(decoderTestSamples([video(7, 32), lower, video(13, 120), higher]), [
      lower,
      higher,
    ]);
  });
}
