import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/src/player/native/player/seek_command.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/plugin/pl_player/utils/native_media_source.dart';

void main() {
  test('Android DASH seeks align video with the separate audio track', () {
    final media = nativeMediaSource(
      source: NetworkSource(
        videoSource: 'https://example.com/video.m4s',
        audioSource: 'https://example.com/audio.m4s',
      ),
    );
    expect(
      nativeSeekCommand(
        const Duration(milliseconds: 729186),
        keyframe: true,
        mediaExtras: media.extras,
      ),
      ['seek', '729.186', 'absolute+exact'],
    );
  });

  test('audio-files also aligns a file-local external audio track', () {
    expect(
      nativeSeekCommand(
        const Duration(milliseconds: 2400),
        keyframe: true,
        mediaExtras: {'audio-files': 'audio.wav'},
      ),
      ['seek', '2.400', 'absolute+exact'],
    );
  });

  test(
    'switching to a source without separate audio restores keyframe seeks',
    () {
      final media = nativeMediaSource(
        source: NetworkSource(
          videoSource: 'https://example.com/video.mp4',
          audioSource: null,
        ),
      );
      expect(
        nativeSeekCommand(
          const Duration(milliseconds: 2400),
          keyframe: true,
          mediaExtras: media.extras,
        ),
        ['seek', '2.400', 'absolute+keyframes'],
      );
    },
  );

  test('backward DASH seeks remain exact at non-keyframe targets', () {
    expect(
      nativeSeekCommand(
        const Duration(milliseconds: 96873),
        keyframe: true,
        externalAudio: true,
      ),
      ['seek', '96.873', 'absolute+exact'],
    );
  });

  test('Android progress seeks use keyframes instead of exact decode', () {
    expect(
      nativeSeekCommand(
        const Duration(seconds: 20, milliseconds: 500),
        keyframe: true,
      ),
      ['seek', '20.500', 'absolute+keyframes'],
    );
  });

  test('other platforms retain exact absolute seeks', () {
    expect(
      nativeSeekCommand(const Duration(milliseconds: 1250)),
      ['seek', '1.250', 'absolute'],
    );
  });
}
