import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/pages/video/playback_source.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';

void main() {
  late Directory directory;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('pili-playback-source-');
    Hive.init(directory.path);
    GStorage.setting = await Hive.openBox('setting');
    await GStorage.setting.put(SettingBoxKey.enableMultiCdn, true);
  });
  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  VideoItem video(String codec, {int quality = 80}) => VideoItem(
    id: quality,
    quality: VideoQuality.fromCode(quality),
    codecs: codec,
    baseUrl: 'https://example.com/$quality/$codec',
    backupUrl: ['https://backup.example.com/$quality/$codec'],
  );
  AudioItem audio(int quality) => AudioItem.fromJson({
    'id': quality,
    'base_url': 'https://example.com/audio/$quality',
  });

  test('选择当前编码，否则按偏好顺序回退到实际存在的编码', () {
    final tracks = [video('avc1'), video('hev1')];
    expect(
      VideoPlaybackSource.selectVideoTrack(
        tracks,
        quality: 80,
        codec: VideoDecodeFormatType.AVC,
        preferredCodecs: [VideoDecodeFormatType.HEVC],
      ),
      same(tracks.first),
    );
    expect(
      VideoPlaybackSource.selectVideoTrack(
        tracks,
        quality: 80,
        codec: VideoDecodeFormatType.AV1,
        preferredCodecs: [
          VideoDecodeFormatType.AV1,
          VideoDecodeFormatType.HEVC,
        ],
      ),
      same(tracks.last),
    );
  });

  test('无音轨媒体清除旧音质，后续切画质仍可解析', () {
    final data = PlayUrlModel(dash: Dash(video: [video('avc1')]));
    final resolved = VideoPlaybackSource.resolve(
      data,
      videoQuality: 80,
      audioQuality: AudioQuality.hiRes.code,
      preferredCodecs: [VideoDecodeFormatType.AVC],
    );
    expect(resolved.audio, isNull);
    expect(resolved.source.audioSource, isNull);
    expect(resolved.source.audioCandidates, isEmpty);
    expect(resolved.source.videoCandidates.length, 2);
  });

  test('音质偏好保留精确匹配和普通 192K 回退', () {
    final tracks = [audio(30251), audio(30280), audio(30216)];
    expect(
      VideoPlaybackSource.selectAudioTrack(tracks, 30251),
      same(tracks[0]),
    );
    expect(
      VideoPlaybackSource.selectAudioTrack(tracks, 30232),
      same(tracks[1]),
    );
    expect(
      VideoPlaybackSource.selectAudioTrack(tracks, 100000),
      same(tracks[1]),
    );
    expect(VideoPlaybackSource.selectAudioTrack([], 30280), isNull);
  });

  test('旧格式分段源以 UTF-8 长度构造 EDL，音轨状态保持一致', () {
    final data = PlayUrlModel(quality: 80)
      ..durl = [
        Durl(url: 'https://example.com/片段一.mp4', length: 1000),
        Durl(url: 'https://example.com/片段二.mp4', length: 2000),
      ];
    final resolved = VideoPlaybackSource.resolve(
      data,
      videoQuality: 80,
      audioQuality: 30280,
      preferredCodecs: [VideoDecodeFormatType.AVC],
    );
    expect(resolved.codec, VideoDecodeFormatType.AVC);
    expect(resolved.audio, isNull);
    expect(resolved.source.videoSource, startsWith('edl://!no_chapters;%33%'));
    expect(resolved.source.videoSource, contains('length=2.0;'));
  });
}
