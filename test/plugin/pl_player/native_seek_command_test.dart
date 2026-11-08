import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/src/player/native/player/seek_command.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

void main() {
  test('独立音轨强制精确 seek，合流源保留关键帧策略和绝对时间', () {
    final separate = nativeMediaSource(
      source: NetworkSource(
        videoSource: 'https://example.com/video.m4s',
        audioSource: 'https://example.com/audio.m4s',
      ),
    );
    final combined = nativeMediaSource(
      source: NetworkSource(
        videoSource: 'https://example.com/video.mp4',
        audioSource: null,
      ),
    );
    for (final (extras, externalAudio, keyframe, position, expected) in [
      (
        separate.extras,
        false,
        true,
        729186,
        ['seek', '729.186', 'absolute+exact'],
      ),
      (
        <String, dynamic>{'audio-files': 'audio.wav'},
        false,
        true,
        2400,
        ['seek', '2.400', 'absolute+exact'],
      ),
      (
        combined.extras,
        false,
        true,
        20500,
        ['seek', '20.500', 'absolute+keyframes'],
      ),
      (null, true, true, 96873, ['seek', '96.873', 'absolute+exact']),
      (null, false, false, 1250, ['seek', '1.250', 'absolute']),
    ]) {
      expect(
        nativeSeekCommand(
          Duration(milliseconds: position),
          keyframe: keyframe,
          mediaExtras: extras,
          externalAudio: externalAudio,
        ),
        expected,
        reason:
            'extras=$extras, externalAudio=$externalAudio, keyframe=$keyframe',
      );
    }
  });
}
