import 'dart:convert';

import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_source.dart';

/// 构造原生播放器可直接加载的 [Media]。
///
/// 视频与独立音轨分开交给 mpv 处理：主 URL 直接作为播放目标，音轨通过
/// `audio-files-append` 追加，无需为 DASH 构建两路 EDL。
/// media_kit 的 `_add` 会把 extras 拼成 loadfile 的逗号分隔
/// key-value 字符串，因此路径中的逗号会被解析为选项分隔符，必须用
/// `%<UTF-8 字节数>%` 定长前缀转义；append 本身不再拆分路径列表。
Media nativeMediaSource({
  required DataSource source,
  bool audioOnly = false,
  Duration? start,
  Map<String, String> extras = const {},
}) {
  final audio = source.audioSource;
  final hasAudio = audio != null && audio.isNotEmpty;
  if (audioOnly && hasAudio) {
    return Media(audio, start: start, extras: extras.isEmpty ? null : extras);
  }
  if (!hasAudio || audioOnly) {
    // audioOnly 且无独立音轨时只能退回原视频源。
    return Media(
      source.videoSource,
      start: start,
      extras: extras.isEmpty ? null : extras,
    );
  }
  // 复制而非修改调用方传入的 map。
  final merged = <String, String>{
    ...extras,
    'audio-files-append': '%${utf8.encode(audio).length}%$audio',
  };
  return Media(source.videoSource, start: start, extras: merged);
}
