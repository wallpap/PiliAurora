import 'dart:convert';

import 'package:pili_aurora/models/common/video/audio_quality.dart';
import 'package:pili_aurora/models/common/video/video_decode_type.dart';
import 'package:pili_aurora/models/common/video/video_quality.dart';
import 'package:pili_aurora/models/video/play/url.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';
import 'package:pili_aurora/utils/video_utils.dart';

/// 画质、编码、音轨与地址来自同一次选择，页面不再分别维护候选列表。
class VideoPlaybackSource {
  VideoPlaybackSource({
    required this.video,
    required this.audio,
    required this.codec,
    required this.source,
  });

  final VideoItem video;
  final AudioItem? audio;
  final VideoDecodeFormatType codec;
  final NetworkSource source;

  factory VideoPlaybackSource.resolve(
    PlayUrlModel data, {
    required int videoQuality,
    required int audioQuality,
    required List<VideoDecodeFormatType> preferredCodecs,
    VideoDecodeFormatType? codec,
  }) {
    if (data.dash == null) {
      final segments = data.durl!;
      final List<String> candidates;
      if (segments.length == 1) {
        candidates = VideoUtils.getCdnUrls(segments.single.playUrls);
      } else {
        final edl = StringBuffer('edl://!no_chapters;');
        for (final segment in segments) {
          final url = VideoUtils.getCdnUrl(segment.playUrls);
          edl.write(
            '%${utf8.encode(url).length}%$url,length=${segment.length! / 1000};',
          );
        }
        candidates = [edl.toString()];
      }
      return VideoPlaybackSource(
        video: VideoItem(
          id: data.quality!,
          baseUrl: candidates.first,
          codecs: 'avc1',
          quality: VideoQuality.fromCode(data.quality!),
        ),
        audio: null,
        codec: VideoDecodeFormatType.AVC,
        source: NetworkSource(
          videoSource: candidates.first,
          audioSource: null,
          videoCandidates: candidates,
        ),
      );
    }
    final video = selectVideoTrack(
      data.dash!.video!,
      quality: videoQuality,
      codec: codec,
      preferredCodecs: preferredCodecs,
    );
    final audio = selectAudioTrack(data.dash!.audio, audioQuality);
    final videos = VideoUtils.getCdnUrls(video.playUrls);
    final audios = audio == null
        ? const <String>[]
        : VideoUtils.getCdnUrls(audio.playUrls, isAudio: true);
    return VideoPlaybackSource(
      video: video,
      audio: audio,
      codec: VideoDecodeFormatType.fromString(video.codecs!),
      source: NetworkSource(
        videoSource: videos.first,
        audioSource: audios.firstOrNull,
        videoCandidates: videos,
        audioCandidates: audios,
      ),
    );
  }

  static VideoItem selectVideoTrack(
    List<VideoItem> tracks, {
    required int quality,
    required List<VideoDecodeFormatType> preferredCodecs,
    VideoDecodeFormatType? codec,
  }) {
    VideoItem? first;
    VideoItem? best;
    var rank = preferredCodecs.length;
    for (final track in tracks) {
      if (track.id != quality) continue;
      first ??= track;
      final code = track.codecs!;
      if (codec?.codes.any(code.startsWith) == true) return track;
      for (var i = 0; i < rank; i++) {
        if (preferredCodecs[i].codes.any(code.startsWith)) {
          rank = i;
          best = track;
          break;
        }
      }
    }
    return best ?? first ?? (throw StateError('没有可用的画质：$quality'));
  }

  static AudioItem? selectAudioTrack(List<AudioItem>? tracks, int quality) {
    if (tracks == null || tracks.isEmpty) return null;
    AudioItem? closest;
    var hasHigher = false;
    for (final track in tracks) {
      if (track.id == quality) return track;
      if (track.id > quality) hasHigher = true;
      if (track.id <= quality && (closest == null || track.id > closest.id)) {
        closest = track;
      }
    }
    // 保留原有偏好：缺少指定音质且存在更高音质时优先使用普通 192K。
    if (hasHigher) {
      return tracks.firstWhere(
        (track) => track.id == AudioQuality.k192.code,
        orElse: () => tracks.first,
      );
    }
    return closest;
  }
}
